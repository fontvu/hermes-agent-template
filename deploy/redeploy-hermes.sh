#!/usr/bin/env bash
# Safely rebuild and redeploy Hermes on an existing OCI VM.
# The image is built before the current container is replaced. On a failed
# cutover, the previous image is restored and Hermes is started again.
set -Eeuo pipefail

APP_DIR="/opt/hermes-agent-template"
DEPLOY_DIR="/opt/hermes-deploy"
REPO="https://github.com/fontvu/hermes-agent-template.git"
REF="${HERMES_REPO_REF:-main}"
IMAGE_TAG="${HERMES_IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"
PREVIOUS_IMAGE="hermes-agent:previous"
LOCAL_IMAGE="hermes-agent:local"
NEW_IMAGE="hermes-agent:${IMAGE_TAG}"
CUTOVER_OK=0

rollback() {
  local rc=$?
  if [[ "$rc" -ne 0 && "$CUTOVER_OK" -ne 1 ]]; then
    echo "Deployment failed; attempting to restore the previous Hermes image." >&2
    if docker image inspect "$PREVIOUS_IMAGE" >/dev/null 2>&1; then
      docker tag "$PREVIOUS_IMAGE" "$LOCAL_IMAGE"
      if (cd "$DEPLOY_DIR" && docker compose up -d --no-deps --force-recreate hermes); then
        echo "Previous Hermes image restored." >&2
      else
        echo "Rollback could not restart Hermes automatically." >&2
      fi
    else
      echo "No previous Hermes image tag is available for rollback." >&2
    fi
  fi
  exit "$rc"
}
trap rollback EXIT

[[ -d "$APP_DIR/.git" ]] || {
  echo "Hermes checkout not found: $APP_DIR" >&2
  exit 1
}

cd "$APP_DIR"
git remote set-url origin "$REPO"
git fetch --depth=1 origin "$REF"
git checkout --detach FETCH_HEAD
DEPLOY_SHA="$(git rev-parse HEAD)"
echo "Deploying hermes-agent-template ${DEPLOY_SHA}"

# Keep the currently running image available while the new image is built.
if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
  docker tag "$LOCAL_IMAGE" "$PREVIOUS_IMAGE"
fi

docker build --pull -t "$NEW_IMAGE" .
docker tag "$NEW_IMAGE" "$LOCAL_IMAGE"

# Replace only Hermes. --no-deps leaves Caddy and Firecrawl untouched.
cd "$DEPLOY_DIR"
docker compose up -d --no-deps --force-recreate hermes

# Verify the process and its unauthenticated health endpoint.
for _ in {1..60}; do
  if [[ "$(docker inspect -f '{{.State.Running}}' hermes 2>/dev/null || true)" == "true" ]] \
    && docker exec hermes sh -c 'curl -fsS --max-time 3 http://127.0.0.1:8080/health >/dev/null'; then
    CUTOVER_OK=1
    break
  fi
  sleep 2
done

if [[ "$CUTOVER_OK" -ne 1 ]]; then
  echo "Hermes did not become healthy after the cutover." >&2
  docker logs --tail 100 hermes >&2 || true
  exit 1
fi

# Keep the last successful image available for a future rollback.
echo "Hermes deployment is healthy: ${DEPLOY_SHA}"
docker inspect hermes --format 'container={{.Name}} image={{.Image}} started={{.State.StartedAt}}'

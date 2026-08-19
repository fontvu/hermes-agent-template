#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
# NOTE (hermes >= v2026.7.1): several dirs were consolidated and are now
# resolved via get_hermes_dir("<new>", "<old>"), which returns the NEW path
# unless the OLD one already has *content*. Seeding an empty legacy stub no
# longer "claims" it — hermes ignores empty stubs and writes to the new path
# (upstream #27602). So we seed the NEW paths: pairing -> platforms/pairing,
# image_cache -> cache/images, audio_cache -> cache/audio. A populated legacy
# dir from a pre-v2026.7.1 deploy still wins on both sides, so no migration is
# needed. server.py:_resolve_pairing_dir() mirrors this same rule for the
# admin panel's Users tab — keep the two in sync on future bumps.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/platforms/pairing \
         /data/.hermes/hooks /data/.hermes/cache/images /data/.hermes/cache/audio \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

# Volume-backed bin dirs for ad-hoc CLI tools the agent installs itself.
# Dockerfile appends both to PATH; created here because a fresh Railway volume
# mounts empty over /data, and a PATH entry pointing at a missing directory is
# silently ignored — so an installer writing to ~/.local/bin would fail and the
# tool would be unreachable. Tools the agent needs *routinely* belong in the
# image (see the apt layer in the Dockerfile), not here: only single-binary
# installs survive on the volume, apt packages do not.
mkdir -p /data/.local/bin /data/bin

# Credential homes for the baked-in cloud CLIs. HOME=/data, so `oci` and
# `railway` already store their config on the persistent volume — `oci setup
# config` / `railway login` survive redeploys and need doing only once.
# .oci is created 700 up front because the OCI CLI refuses to use an API key
# whose file is group/world-readable ("Permissions on ... are too open"), and a
# dir created later by a umask-022 process makes that easy to trip over.
mkdir -p /data/.oci && chmod 700 /data/.oci

# Stamp the install method as "docker" so hermes treats this as an immutable
# container image, not a pip checkout. hermes's detect_install_method() reads
# $HERMES_HOME/.install_method FIRST (before any .git / pip fallback). Without
# this stamp the template falls through to "pip" — because the Dockerfile strips
# /opt/hermes-agent/.git — and the dashboard's "Update Hermes" button then runs
# a real `hermes update` (PyPI pip-upgrade) INSIDE the running container. That
# upgrade is ephemeral (reverts on the next redeploy) and can desync the Python
# package from the image's pre-built web_dist/ui-tui bundles. Stamping "docker"
# makes that button correctly refuse with "pull a fresh image / redeploy", which
# matches the real upgrade path here (bump HERMES_REF in Railway + redeploy).
# Written unconditionally each boot so it stays correct and self-heals.
printf 'docker\n' > /data/.hermes/.install_method

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# Tell the dashboard its externally reachable URL.
# hermes >= v2026.7.20 builds the MCP OAuth redirect_uri from the request's own
# Host header. Our reverse proxy must strip that Host (hermes 400s anything but
# loopback on a loopback bind), so hermes would otherwise hand the OAuth
# provider `http://127.0.0.1:9119/...` — a URL only reachable inside this
# container, leaving the browser on a dead tab after consent with nothing in the
# logs. resolve_public_url() checks HERMES_DASHBOARD_PUBLIC_URL first, so
# setting it is the supported fix. Railway injects RAILWAY_PUBLIC_DOMAIN; `:=`
# keeps an operator-set value (e.g. a custom domain) winning.
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  : "${HERMES_DASHBOARD_PUBLIC_URL:=https://${RAILWAY_PUBLIC_DOMAIN}}"
  export HERMES_DASHBOARD_PUBLIC_URL
fi

# Browser engine: honors the baked INSTALL_BROWSER unless the operator
# explicitly set AGENT_BROWSER_ENGINE at runtime. Hermes reads this via
# tools/browser_tool.py _get_browser_engine() as AGENT_BROWSER_ENGINE →
# auto | lightpanda | chrome. "none" bakes to /opt/browser_engine="none"
# and must not set the env at all (Hermes defaults to "auto" → Chrome).
if [ -z "${AGENT_BROWSER_ENGINE:-}" ] && [ -f /opt/browser_engine ]; then
  _baked="$(tr -d '[:space:]' < /opt/browser_engine 2>/dev/null || true)"
  case "${_baked}" in
    lightpanda|chromium)
      _engine_val="lightpanda"
      [ "${_baked}" = "chromium" ] && _engine_val="chrome"
      export AGENT_BROWSER_ENGINE="${_engine_val}"
      echo "[start.sh] browser engine: ${_engine_val} (baked INSTALL_BROWSER=${_baked})"
      ;;
    none|"") : ;; # lean image — no engine unless operator set AGENT_BROWSER_ENGINE
    *) echo "[start.sh] warning: unknown /opt/browser_engine='${_baked}'" >&2 ;;
  esac
  unset _baked _engine_val
fi

exec python /app/server.py

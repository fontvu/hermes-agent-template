FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Which hermes-agent revision to install. Accepts any git ref the upstream
# repo publishes — a release tag (recommended for reproducibility) or a
# branch name (`main`) for bleeding edge.
#
# To bump: check https://github.com/NousResearch/hermes-agent/releases for the
# newest tag (format `vYYYY.M.D`, optionally with a `.PATCH` suffix, e.g.
# `v2026.5.29.2`) and update the default below. Use `main` only if you accept
# that every rebuild can pull arbitrary new upstream commits.
ARG HERMES_REF=v2026.8.3

# Which repo to clone hermes-agent from. Defaults to upstream; override to
# build from a fork/branch that carries unreleased fixes, e.g.
#   HERMES_REPO=https://github.com/fontvu/hermes-agent.git
#   HERMES_REF=fix/nul-path-lifecycle-guard
ARG HERMES_REPO=https://github.com/NousResearch/hermes-agent.git

# Persist the build arg into the runtime env so the admin UI can display which
# Hermes release this image actually pins. Reading it (rather than hardcoding a
# version in the template) keeps the badge honest when someone overrides
# HERMES_REF as a Railway service variable to pin an older release — a Railway
# runtime variable simply shadows this ENV, so the UI still shows the truth.
ENV HERMES_REF=${HERMES_REF}

# tini = tiny init that we run as PID 1. Without it, hermes's grandchild
# processes (MCP stdio servers, git, bun, browser daemons spawned by tools)
# reparent to PID 1 when their parents exit and pile up as zombies. After
# weeks of uptime that exhausts the kernel's PID table → "fork: cannot
# allocate memory" and the container dies. tini reaps zombies in the
# background and forwards SIGTERM/SIGINT to our entrypoint so Railway's
# stop signal still triggers our graceful shutdown. Standard container init
# (same as Docker's `--init` flag and Kubernetes' pause container).
#
# Node.js is required only at build time to compile the Hermes React dashboard.
# We strip the source + apt lists afterwards to keep the image lean.
#
# Keep setup_22.x. v2026.8.3's new .npmrc sets engine-strict=true, so hermes'
# `node >=22.22.0` + `npm <11.10.0 || >=11.17.0` is now a hard EBADENGINE build
# failure, not a warning — setup_24.x bundles an npm that satisfies neither.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# The agent's terminal toolbox — BAKED IN ON PURPOSE.
#
# This container is immutable: Railway rebuilds it from this Dockerfile on every
# deploy, so anything the agent `apt-get install`s at runtime (it runs as root,
# so it can) is silently gone on the next redeploy while its shell commands keep
# referencing it. `gh` was lost exactly this way. Tools the agent reaches for
# routinely therefore belong here, not in a runtime install.
#
# gh is not in Debian main, so it comes from GitHub's own apt repo (the
# documented install path). Deliberately NOT pinned to a release tarball: the
# asset filename embeds the version, and resolving "latest" through the
# unauthenticated GitHub API at build time rate-limits on shared CI/builder IPs.
# The `stable` suite tracks current releases and is signed by the keyring below.
#
# Debian ships fd as `fdfind` (the name `fd` collides with an unrelated package),
# so the final `ln` restores the name every doc — and the agent — actually uses.
#
# See also: the volume-backed PATH further down, which is where AD-HOC tools
# (anything not listed here) should be installed so they survive a redeploy.
#
# WEIGHT: 51MB for the six packages, most of it gh.
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      gh jq ripgrep fd-find unzip less && \
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd && \
    rm -rf /var/lib/apt/lists/*

# Install hermes-agent (provides the `hermes` CLI) and pre-build its React
# dashboard so `hermes dashboard` has nothing to build at runtime.
#
# [all] in v2026.6.5 no longer pulls in [dev]; messaging platforms, TTS, and
# other heavy backends are lazy-installed by hermes at first use. We pre-install
# the ones this template actually uses so first-message latency is instant.
# `vision` (Pillow) is a soft-dep that is NOT in [all] and is otherwise
# lazy-installed at first image use: without it hermes can't downscale an
# oversized image (>5 MB / >8000px), which then bakes into immutable history
# and bricks the session on Anthropic's non-retryable 400. We bake it in.
# When bumping HERMES_REF, re-check hermes-agent's pyproject.toml [all] and
# the extras below against the new release's pyproject.toml.
#
# The `-e` is LOAD-BEARING since v2026.8.3: upstream's new setup.py raises on
# bdist_wheel/sdist unless HERMES_NIX_BUILD=1. PEP 660 editable installs route
# through build_editable and are exempt — drop `-e` and the image won't build.
#
# v2026.8.3 also added [tool.uv] to pyproject.toml, which uv reads from this
# cwd (upstream builds from a frozen lock; we re-resolve every time):
# override-dependencies fixes discord.py's vulnerable pynacl pin, and
# exclude-newer="14 days" can fail a build on a fresh dep — override with
# `uv pip install --exclude-newer <date>`.
RUN git clone --depth 1 --branch ${HERMES_REF} ${HERMES_REPO} /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all,messaging,tts-premium,honcho,bedrock,anthropic,edge-tts,hindsight,vision]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm

# Why pre-build ui-tui (and why we don't delete it after):
# - The dashboard's embedded Chat tab spawns `node ui-tui/dist/entry.js`
#   on every WebSocket connect to /api/pty.
# - Without HERMES_TUI_DIR, hermes's _make_tui_argv falls through to the
#   npm install + build path (since git-editable installs don't have the
#   bundled tui_dist/ that PyPI wheels include), adding 30-60s to the
#   first chat-open and blocking the asyncio event loop.
# - Pre-building at image time surfaces build failures here rather than
#   at user request time, and makes first-chat-open instant.
# - We keep ui-tui/ entirely (node_modules + dist + src) so HERMES_TUI_DIR
#   can point at it (see below).

# Stamp the CODE-SCOPED install method next to the running package. hermes'
# detect_install_method() reads <install-tree>/.install_method FIRST (priority 1,
# authoritative) — before the home-scoped $HERMES_HOME/.install_method that
# start.sh writes (priority 2, honored only when is_container() is true). The
# install tree for our editable install is /opt/hermes-agent (parent of
# hermes_cli/, i.e. Path(config.py).parent.parent). Baking the stamp here makes
# the dashboard "Update Hermes" button refuse regardless of runtime container
# detection — exactly what upstream's own published image does (it bakes a
# docker stamp into /opt/hermes). Belt-and-suspenders with start.sh's home stamp:
# if a future hermes release changes or drops is_container()'s Railway marker
# (/run/.containerenv), the home stamp would stop being honored but this one
# still refuses. Re-verify the install-tree path if hermes stops installing
# editable from /opt/hermes-agent.
RUN printf 'docker\n' > /opt/hermes-agent/.install_method

COPY requirements.txt /app/requirements.txt
RUN uv pip install --system --no-cache -r /app/requirements.txt

# ── Cloud CLIs the agent operates this deployment with ────────────────────────
# Placed AFTER the hermes clone/npm build on purpose: both are version-pinned, so
# a bump here must not invalidate those (slow) layers. Placed BEFORE the COPY of
# server.py/templates so ordinary app edits don't rebuild them either.

# Railway CLI — prebuilt binary, matching the approach in the wake workflow at
# fontvu/hermes-agent-scripts (`npm i -g @railway/cli` postinstall intermittently
# fails on shared runners with a self-signed-cert TLS error; a direct release
# download does not).
#
# To bump: check https://github.com/railwayapp/cli/releases and update the
# default below. Note the asset targets differ per arch — amd64 publishes a
# glibc build, arm64 only a musl one — hence the case mapping rather than a
# single hardcoded filename. The wake workflow pins its own copy separately;
# the two do not need to match.
ARG RAILWAY_CLI_VERSION=5.37.2
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) rw_target=x86_64-unknown-linux-gnu ;; \
      arm64) rw_target=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported arch for railway cli: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/railwayapp/cli/releases/download/v${RAILWAY_CLI_VERSION}/railway-v${RAILWAY_CLI_VERSION}-${rw_target}.tar.gz" \
      -o /tmp/railway.tar.gz; \
    tar -xzf /tmp/railway.tar.gz -C /usr/local/bin railway; \
    rm /tmp/railway.tar.gz; \
    chmod +x /usr/local/bin/railway

# OCI CLI — installed into its OWN venv, not the system interpreter.
#
# oci-cli hard-pins several packages hermes also depends on (click, PyYAML,
# cryptography, python-dateutil, prompt-toolkit). `uv pip install --system`
# would resolve those pins against the shared site-packages this image installs
# hermes into, so an oci-cli upgrade could silently downgrade a hermes
# dependency and break the gateway — a failure that would surface as an
# unrelated import error at runtime. An isolated venv makes that impossible;
# only the `oci` entrypoint is exposed, via symlink.
#
# Oracle's official install.sh is deliberately avoided: it targets $HOME, which
# is /data here, and the Railway volume mounts OVER /data at runtime — the whole
# install would vanish the moment the container starts.
#
# WEIGHT: this layer measures 444MB (`docker history`) — by far the largest in
# the image. Measured breakdown, 33,403 files / 336MB apparent / 424MB allocated:
#   200MB  oci/       the SDK: 175 service subpackages, 16,247 generated model
#                     classes, 5.17M lines of Python. Oracle ships ONE package
#                     covering the entire cloud, not per-service distributions.
#    53MB  services/  oci_cli's generated command layer, 168 services
#    49MB  oci_cli/help_text_producer — 11,458 pre-rendered .txt help pages
#    14MB  cryptography
#   ~70MB  4KB-block slack: 33k files, most of them tiny
# Nothing is safely prunable while keeping every service working. The one real
# lever is help_text_producer (~85MB allocated), which only feeds `oci ... --help`
# command reference output. Note also: uv writes no .pyc, so the first `oci`
# invocation bytecompiles into the container's writable layer (~200MB, ephemeral).
#
# `railway redeploy` reuses the built image, so the daily wake does not re-pay
# any of this; only a push that rebuilds does. If the trade stops being worth it,
# delete this layer and install oci-cli into a venv under /data/.local instead —
# the volume persists, so it survives redeploys without shipping in the image.
RUN uv venv /opt/oci-cli && \
    uv pip install --python /opt/oci-cli/bin/python --no-cache oci-cli && \
    ln -sf /opt/oci-cli/bin/oci /usr/local/bin/oci

RUN mkdir -p /data/.hermes

COPY server.py /app/server.py
COPY templates/ /app/templates/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

# Volume-backed bin dirs — the durable home for AD-HOC tools.
#
# HOME=/data already puts ~/.local/bin and ~/bin on the persistent Railway
# volume, but nothing ever added them to PATH, so a binary dropped there was
# invisible and the agent had no place to install anything that outlives a
# redeploy. With these on PATH, `curl -o /data/.local/bin/<tool>` (or any
# installer honouring ~/.local/bin) survives every deploy. apt packages cannot
# work this way — dpkg spreads files across /usr, /etc and /var — so those
# belong in the apt layer above.
#
# APPENDED, not prepended, deliberately: the volume outlives every image, so a
# stale or broken binary left there (`python`, `hermes`, `node`…) would shadow
# the image's copy on every future deploy and could leave the service unbootable
# with no way in. Image tools win; the volume can only ADD commands.
ENV PATH=$PATH:/data/.local/bin:/data/bin

# Points hermes at our pre-built TUI bundle. hermes's _make_tui_argv checks
# HERMES_TUI_DIR first: if dist/entry.js exists there, it skips the npm
# install/build entirely. This is the official packager path (Nix uses it too)
# and avoids the 30-60s npm bootstrap that git-editable installs would otherwise
# trigger on first /chat connection.
ENV HERMES_TUI_DIR=/opt/hermes-agent/ui-tui

# tini wraps start.sh so it runs as PID 1's child instead of as PID 1 itself.
# `-g` propagates signals to the whole process group so `docker stop` /
# Railway's SIGTERM cleanly terminates the entire tree, not just start.sh.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]

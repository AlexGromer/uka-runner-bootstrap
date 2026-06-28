#!/usr/bin/env bash
# setup-toolcache.sh — fixes "actions/setup-python: version 3.12 not found for debian 13".
#
# actions/setup-python ships prebuilt CPython only for Ubuntu, so on Debian it can't find a
# version and fails. This populates a SHARED runner tool cache with Python (using uv's portable
# python-build-standalone, which runs on Debian), points every runner at it via
# AGENT_TOOLSDIRECTORY, and restarts the services. Idempotent — safe to re-run.
#
#   bash setup-toolcache.sh            # default: Python 3.12 into /opt/hostedtoolcache
#   PYVERS="3.12 3.13" bash setup-toolcache.sh
set -euo pipefail

TOOLCACHE="${TOOLCACHE:-/opt/hostedtoolcache}"
PYVERS="${PYVERS:-3.12}"
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# 1. uv on host (provides relocatable python-build-standalone for Debian)
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv (host)"
  curl -fsSL https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || { warn "uv not on PATH after install — open a new shell and re-run"; exit 1; }

# 2. shared tool cache, owned by the runner user
sudo mkdir -p "$TOOLCACHE/Python"
sudo chown -R "$USER:$USER" "$TOOLCACHE"

# 3. provision each Python into the setup-python cache layout: <cache>/Python/<X.Y.Z>/x64 + .complete
for V in $PYVERS; do
  log "Provisioning Python $V"
  uv python install "$V"
  PYBIN="$(uv python find "$V")"
  PYROOT="$(dirname "$(dirname "$PYBIN")")"
  FULL="$("$PYBIN" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])')"
  DEST="$TOOLCACHE/Python/$FULL/x64"
  rm -rf "$DEST"; mkdir -p "$DEST"
  cp -a "$PYROOT/." "$DEST/"
  [ -e "$DEST/bin/python" ] || ln -sf python3 "$DEST/bin/python"
  touch "$TOOLCACHE/Python/$FULL/x64.complete"
  log "  cached $("$DEST/bin/python" -V 2>&1)  ->  $DEST"
done

# 4. point every runner at the shared cache + restart its service
found=0
for d in "$HOME"/actions-runner-*; do
  [ -d "$d" ] || continue
  found=1
  touch "$d/.env"
  grep -q '^AGENT_TOOLSDIRECTORY=' "$d/.env" || echo "AGENT_TOOLSDIRECTORY=$TOOLCACHE" >> "$d/.env"
  log "Restarting $(basename "$d")"
  ( cd "$d" && sudo ./svc.sh stop && sudo ./svc.sh start ) >/dev/null 2>&1 || warn "restart of $d failed"
done
[ "$found" = 1 ] || warn "No ~/actions-runner-* found — run register.sh first, then re-run this."

log "Tool cache ready at $TOOLCACHE. Re-run CI — setup-python will now find Python ${PYVERS}."

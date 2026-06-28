#!/usr/bin/env bash
# setup-toolcache.sh — give EACH runner its OWN tool cache.
#
# Two problems this solves:
#  1. actions/setup-python ships prebuilt CPython only for Ubuntu -> on Debian it fails
#     ("version 3.12 not found for debian 13"). We pre-seed Python (uv's portable build).
#  2. A SHARED tool cache (AGENT_TOOLSDIRECTORY pointing all runners at one dir) makes
#     concurrent jobs RACE when they extract a runtime-downloaded tool — e.g. two CodeQL
#     Analyze jobs untar the CodeQL bundle into the same dir at once ("tar: Permission denied").
#     Per-runner caches remove that race entirely (one job per runner, distinct paths).
#
# Idempotent. Run after register.sh:  bash setup-toolcache.sh   (PYVERS="3.12 3.13" to add 3.13)
set -euo pipefail

PYVERS="${PYVERS:-3.12}"
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# uv on host (portable python-build-standalone source)
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv (host)"; curl -fsSL https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || { warn "uv not on PATH — open a new shell and re-run"; exit 1; }
for V in $PYVERS; do uv python install "$V" >/dev/null; done

found=0
for d in "$HOME"/actions-runner-*; do
  [ -d "$d" ] || continue
  found=1
  TC="$d/_toolcache"
  log "Building per-runner tool cache for $(basename "$d") -> $TC"
  mkdir -p "$TC/Python"
  for V in $PYVERS; do
    PYBIN="$(uv python find "$V")"
    PYROOT="$(dirname "$(dirname "$PYBIN")")"
    FULL="$("$PYBIN" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])')"
    DEST="$TC/Python/$FULL/x64"
    rm -rf "$DEST"; mkdir -p "$DEST"
    cp -a "$PYROOT/." "$DEST/"
    [ -e "$DEST/bin/python" ] || ln -sf python3 "$DEST/bin/python"
    # PEP 668: drop EXTERNALLY-MANAGED so `pip install` into the base env works (hosted parity)
    find "$DEST" -name EXTERNALLY-MANAGED -delete 2>/dev/null || true
    touch "$TC/Python/$FULL/x64.complete"
    log "  Python $FULL ready"
  done
  # point THIS runner at its OWN cache (replace any earlier shared AGENT_TOOLSDIRECTORY)
  touch "$d/.env"
  grep -v '^AGENT_TOOLSDIRECTORY=' "$d/.env" > "$d/.env.tmp" 2>/dev/null || true
  echo "AGENT_TOOLSDIRECTORY=$TC" >> "$d/.env.tmp"
  mv "$d/.env.tmp" "$d/.env"
done
[ "$found" = 1 ] || { warn "No ~/actions-runner-* found — run register.sh first."; exit 1; }

# retire the old shared cache (no longer referenced; also clears any corrupt CodeQL extract)
sudo rm -rf /opt/hostedtoolcache 2>/dev/null || true

log "Restarting runners"
for d in "$HOME"/actions-runner-*; do
  [ -d "$d" ] || continue
  ( cd "$d" && sudo ./svc.sh stop && sudo ./svc.sh start ) >/dev/null 2>&1 || warn "restart of $(basename "$d") failed"
done
log "Done. Each runner has an isolated tool cache. Re-run CI."

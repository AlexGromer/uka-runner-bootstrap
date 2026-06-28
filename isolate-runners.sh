#!/usr/bin/env bash
# isolate-runners.sh — fix two self-hosted gaps that GitHub-hosted (ephemeral) runners don't have:
#
#  (1) syft/grype install to /usr/local/bin, which isn't writable by the runner user
#      ("install: cannot create '/usr/local/bin/syft': Permission denied").
#  (2) The 3 runners share one $HOME (/home/adminus), so actions that write to ~ — notably
#      pnpm/action-setup's ~/setup-pnpm — RACE when two pnpm jobs (lint + test-web) run at once
#      ("ENOENT ... chmod '~/setup-pnpm/...'"). Give each runner its own $HOME via a systemd
#      drop-in so per-job global state never collides.
#
# Idempotent. Run inside WSL2 Debian after register.sh:  bash isolate-runners.sh
set -euo pipefail
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# (1) let the runner user write to /usr/local/bin (syft + grype installers)
log "Granting $USER write access to /usr/local/bin (syft/grype)"
sudo chown "$USER" /usr/local/bin

# (2) per-runner $HOME isolation via systemd drop-in.
# HOME must be the runner's INSTALL dir ($d), not a sibling like $d/_home: gitleaks-action
# computes its SARIF artifact root from $HOME and the SARIF lives in $d/_work/... — so $HOME
# must be an ANCESTOR of _work. $d satisfies that AND is distinct per runner (no pnpm race).
rm -rf "$HOME/setup-pnpm" 2>/dev/null || true     # drop any stale shared pnpm state
changed=0
for d in "$HOME"/actions-runner-*; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  H="$d"
  svc="$(cat "$d/.service" 2>/dev/null || true)"
  if [ -z "$svc" ]; then warn "no .service file in $d — is the runner installed as a service? skipping"; continue; fi
  log "Isolating $n -> HOME=$H + PrivateTmp  (service: $svc)"
  sudo mkdir -p "/etc/systemd/system/${svc}.d"
  sudo rm -f "/etc/systemd/system/${svc}.d/home.conf" 2>/dev/null || true   # superseded
  # Per-runner $HOME (pnpm/gitleaks-artifact) + private /tmp (gitleaks downloads /tmp/gitleaks.tmp,
  # shared across runners otherwise -> "Destination file path /tmp/gitleaks.tmp already exists").
  printf '[Service]\nEnvironment=HOME=%s\nPrivateTmp=yes\n' "$H" \
    | sudo tee "/etc/systemd/system/${svc}.d/isolation.conf" >/dev/null
  rm -rf "$H/setup-pnpm" "$d/_home/setup-pnpm" 2>/dev/null || true
  changed=1
done

if [ "$changed" = 1 ]; then
  log "Reloading systemd + restarting runners"
  sudo systemctl daemon-reload
  for d in "$HOME"/actions-runner-*; do
    [ -d "$d" ] || continue
    ( cd "$d" && sudo ./svc.sh stop && sudo ./svc.sh start ) >/dev/null 2>&1 || warn "restart of $(basename "$d") failed"
  done
else
  warn "No runners updated (run register.sh first)."
fi

log "Done. /usr/local/bin writable; each runner has an isolated \$HOME. Re-run CI."

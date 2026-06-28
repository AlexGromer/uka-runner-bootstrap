#!/usr/bin/env bash
# register.sh <REGISTRATION_TOKEN> — register + start the self-hosted runner as a service.
# Fresh token (valid ~1h): ask Claude, or repo Settings -> Actions -> Runners -> New self-hosted runner.
set -euo pipefail

TOKEN="${1:-}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
REPO_URL="https://github.com/AlexGromer/uka.moscow"
LABELS="self-hosted,linux,x64"
NAME="uka-wsl2"

if [ -z "$TOKEN" ]; then
  echo "Usage: ./register.sh <REGISTRATION_TOKEN>"; exit 1
fi
[ -f "$RUNNER_DIR/config.sh" ] || { echo "Runner not found in $RUNNER_DIR — run setup-runner.sh first."; exit 1; }

cd "$RUNNER_DIR"
# idempotent: tear down any prior service/registration
sudo ./svc.sh stop 2>/dev/null || true
sudo ./svc.sh uninstall 2>/dev/null || true

./config.sh --url "$REPO_URL" --token "$TOKEN" --labels "$LABELS" --name "$NAME" --unattended --replace
sudo ./svc.sh install "$USER"
sudo ./svc.sh start
sudo ./svc.sh status || true

echo
echo "[OK] Runner '$NAME' (labels: $LABELS) registered + started."
echo "     Expect 'Idle' at https://github.com/AlexGromer/uka.moscow/settings/actions/runners"

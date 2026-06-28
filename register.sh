#!/usr/bin/env bash
# register.sh <REGISTRATION_TOKEN> [COUNT] — register COUNT self-hosted runners (default 3),
# each in its own dir (~/actions-runner-N) with its own systemd service, sharing the label
# self-hosted,linux,x64 so CI jobs run in parallel. One token registers all of them.
# Fresh token (valid ~1h): ask Claude, or repo Settings -> Actions -> Runners -> New self-hosted runner.
set -euo pipefail

TOKEN="${1:-}"
COUNT="${2:-3}"
BASE_DIR="${RUNNER_DIR:-$HOME/actions-runner}"     # clean runner extracted by setup-runner.sh
REPO_URL="https://github.com/AlexGromer/uka.moscow"
LABELS="self-hosted,linux,x64"

if [ -z "$TOKEN" ]; then
  echo "Usage: ./register.sh <REGISTRATION_TOKEN> [COUNT]   (COUNT default 3)"; exit 1
fi
[ -f "$BASE_DIR/config.sh" ] || { echo "Runner not found in $BASE_DIR — run setup-runner.sh first."; exit 1; }
case "$COUNT" in (*[!0-9]*|"") echo "COUNT must be a positive integer"; exit 1;; esac

for i in $(seq 1 "$COUNT"); do
  DIR="$HOME/actions-runner-$i"
  NAME="uka-wsl2-$i"
  echo
  echo "=== Runner $i/$COUNT  ->  $DIR  (name=$NAME) ==="
  if [ ! -f "$DIR/config.sh" ]; then
    mkdir -p "$DIR"
    cp -a "$BASE_DIR/." "$DIR/"                      # replicate the clean runner files
    rm -f  "$DIR/.runner" "$DIR/.credentials" "$DIR/.credentials_rsaparams" 2>/dev/null || true
    rm -rf "$DIR/_work" "$DIR/_diag" 2>/dev/null || true
  fi
  cd "$DIR"
  # idempotent: drop any prior service/registration for this instance
  sudo ./svc.sh stop 2>/dev/null || true
  sudo ./svc.sh uninstall 2>/dev/null || true
  ./config.sh --url "$REPO_URL" --token "$TOKEN" --labels "$LABELS" --name "$NAME" --unattended --replace
  sudo ./svc.sh install "$USER"
  sudo ./svc.sh start
done

echo
echo "[OK] $COUNT runner(s) registered + started: uka-wsl2-1 .. uka-wsl2-$COUNT (label: $LABELS)."
echo "     Expect them 'Idle' at https://github.com/AlexGromer/uka.moscow/settings/actions/runners"
echo "     Add more later: ./register.sh <TOKEN> <BIGGER_COUNT>  (re-runs are idempotent)."

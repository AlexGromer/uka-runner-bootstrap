#!/usr/bin/env bash
# setup-runner.sh — provision a self-hosted GitHub Actions runner host in WSL2 (Debian).
# Idempotent. Run inside WSL2 Debian:   bash setup-runner.sh
# RF Docker Hub blocked? pass a pull-through cache:
#   REGISTRY_MIRROR=http://<homelab-ip>:5000 bash setup-runner.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# --- 0. sanity --------------------------------------------------------------
grep -qiE 'debian|ubuntu' /etc/os-release || warn "Not Debian/Ubuntu — script is tuned for Debian WSL2."
[ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ] || \
  warn "systemd is not PID 1. Set /etc/wsl.conf [boot] systemd=true, then 'wsl --shutdown' and reopen."

# --- 1. base packages -------------------------------------------------------
log "Installing base packages"
sudo apt-get update -y
sudo apt-get install -y curl git jq build-essential ca-certificates unzip gnupg

# --- 2. Docker Engine -------------------------------------------------------
# NB: Debian + Docker Desktop ship a 'docker' STUB ("activate WSL integration")
# that fools `command -v docker`. Gate on the daemon (dockerd), not the client.
if command -v dockerd >/dev/null 2>&1; then
  log "Docker Engine present: $(docker --version 2>/dev/null || echo '?')"
else
  if command -v docker >/dev/null 2>&1; then
    warn "Removing Docker-Desktop 'docker' stub so native Docker Engine installs clean"
    sudo rm -f /usr/bin/docker /usr/bin/docker-compose 2>/dev/null || true
  fi
  log "Installing Docker Engine (get.docker.com)"
  curl -fsSL https://get.docker.com | sudo sh
fi

# --- 3. Docker daemon config (registry mirror — RF Docker Hub mitigation) ---
log "Configuring /etc/docker/daemon.json"
sudo mkdir -p /etc/docker
if [ -n "$REGISTRY_MIRROR" ]; then
  printf '{\n  "registry-mirrors": ["%s", "https://mirror.gcr.io"]\n}\n' "$REGISTRY_MIRROR" \
    | sudo tee /etc/docker/daemon.json >/dev/null
  log "registry-mirrors: $REGISTRY_MIRROR (+ mirror.gcr.io fallback)"
elif [ ! -f /etc/docker/daemon.json ]; then
  sudo install -m 0644 "$SCRIPT_DIR/daemon.json" /etc/docker/daemon.json
  log "registry-mirrors: mirror.gcr.io (official images only — see README for an RF cache)"
else
  log "Keeping existing /etc/docker/daemon.json"
fi

# --- 4. enable + (re)start dockerd -----------------------------------------
log "Enabling Docker service"
sudo systemctl enable --now docker || warn "enable docker failed — is systemd PID 1?"
sudo systemctl restart docker || true

# --- 5. docker group --------------------------------------------------------
if id -nG "$USER" | grep -qw docker; then
  log "$USER already in docker group"
else
  log "Adding $USER to docker group — RE-OPEN the WSL shell afterwards for it to take effect"
  sudo usermod -aG docker "$USER"
fi

# --- 6. passwordless sudo (CI: playwright --with-deps, syft/grype) -----------
log "Configuring passwordless sudo for $USER"
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-actions-runner >/dev/null
sudo chmod 0440 /etc/sudoers.d/99-actions-runner

# --- 7. download actions/runner --------------------------------------------
log "Resolving latest actions/runner version"
RUNNER_VER="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name // empty' | sed 's/^v//')"
[ -n "$RUNNER_VER" ] || { warn "Could not resolve runner version (API rate limit?). Re-run later."; exit 1; }
mkdir -p "$RUNNER_DIR"; cd "$RUNNER_DIR"
if [ -f config.sh ]; then
  log "Runner already extracted in $RUNNER_DIR"
else
  TARBALL="actions-runner-linux-x64-${RUNNER_VER}.tar.gz"
  log "Downloading runner v${RUNNER_VER}"
  curl -fsSL -o "$TARBALL" "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/${TARBALL}"
  tar xzf "$TARBALL" && rm -f "$TARBALL"
fi

# --- 8. runner OS dependencies ---------------------------------------------
log "Installing runner OS dependencies"
sudo ./bin/installdependencies.sh

cat <<'EOF'

[OK] setup-runner.sh complete.

Next:
  1) RE-OPEN the WSL shell (so 'docker' works without sudo), then verify:
       docker run --rm hello-world
       docker pull postgres:17-alpine     # RF Docker Hub go/no-go
       docker compose version
  2) Get a registration token from Claude, then from the clone dir:
       ./register.sh <TOKEN>
EOF

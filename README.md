# uka-runner-bootstrap

Stand up a **self-hosted GitHub Actions runner** in **WSL2 (Debian)** on Windows for the private repo
**AlexGromer/uka.moscow** — free unlimited CI, repo stays private, works from RF (no GitHub billing).

> **No secrets in this repo.** The runner **registration token** is passed at runtime — you get a fresh
> one (valid ~1h) from Claude, or from the repo's *Settings → Actions → Runners → New self-hosted runner*.
> You do **not** clone `uka.moscow` here — the runner checks out code per-job automatically.

**What the CI needs from this host:** Docker (service containers `postgres`/`redis` + container-actions +
2 image builds), passwordless sudo (`playwright install --with-deps`, syft/grype), ≥10 GB RAM / 6 vCPU /
40 GB disk, systemd.

---

## Step 1 — Windows (admin PowerShell): install WSL2 + set resources
```powershell
wsl --install -d Debian        # skip if Debian is already installed
@"
[wsl2]
memory=10GB
processors=6
swap=4GB
"@ | Out-File -Encoding ascii $env:USERPROFILE\.wslconfig
wsl --shutdown
```

## Step 2 — Inside Debian: enable systemd
```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
```
Then in PowerShell: `wsl --shutdown`, reopen Debian. Verify: `ps -p 1 -o comm=` prints `systemd`.

## Step 3 — Inside Debian: clone this repo + run setup
```bash
git clone https://github.com/AlexGromer/uka-runner-bootstrap.git
cd uka-runner-bootstrap
bash setup-runner.sh
# RF: Docker Hub blocked? point at your homelab pull-through cache:
#   REGISTRY_MIRROR=http://<homelab-ip>:5000 bash setup-runner.sh
```
`setup-runner.sh` installs Docker + base pkgs, writes the registry mirror, passwordless sudo, the docker
group, and downloads the runner into `~/actions-runner`.

**Re-open the WSL shell** (so `docker` works without sudo), then verify the go/no-go gate:
```bash
docker run --rm hello-world
docker pull postgres:17-alpine     # <-- MUST succeed (the RF Docker Hub test)
docker compose version
```

## Step 4 — Register the runner
Ask Claude for a fresh **registration token**, then from the clone dir:
```bash
./register.sh <TOKEN>
```
Registers `name=uka-wsl2`, `labels=self-hosted,linux,x64` and starts it as a systemd service. It should
show **Idle** under *Settings → Actions → Runners*.

---

## Docker Hub / RF mirror notes
`daemon.json` defaults `registry-mirrors` to `https://mirror.gcr.io`, which mirrors **official
`library/*` images** (postgres, redis) — covers the CI service containers. The security
container-actions pull **non-official** images; if Docker Hub is blocked from your RF connection, run a
**pull-through cache** on your homelab and pass it via `REGISTRY_MIRROR`:
```bash
docker run -d --name dockerhub-cache --restart=always -p 5000:5000 \
  -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io registry:2
# then on the runner host:
REGISTRY_MIRROR=http://<homelab-ip>:5000 bash setup-runner.sh
```

## Re-register / move the runner
`./register.sh <NEW_TOKEN>` is idempotent — it stops/uninstalls any prior service and re-registers.

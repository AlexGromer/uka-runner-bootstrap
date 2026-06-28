# uka-runner-bootstrap

Stand up **self-hosted GitHub Actions runners** in **WSL2 (Debian)** on Windows for the private repo
**AlexGromer/uka.moscow** — free unlimited CI, repo stays private, works from RF (no GitHub billing).
Registers **multiple runners** (default 3) so CI jobs run in parallel.

> **No secrets in this repo.** The runner **registration token** is passed at runtime — you get a fresh
> one (valid ~1h) from Claude, or from the repo's *Settings → Actions → Runners → New self-hosted runner*.
> You do **not** clone `uka.moscow` here — the runner checks out code per-job automatically.

**What the CI needs from this host:** Docker (service containers `postgres`/`redis` + container-actions +
2 image builds), passwordless sudo (`playwright install --with-deps`, syft/grype), systemd, and enough
RAM/CPU for N concurrent jobs (≈32 GB / 10 vCPU recommended for 3 runners on a 48 GB box).

---

## Step 1 — Windows (admin PowerShell): install WSL2 + set resources
```powershell
wsl --install -d Debian        # skip if Debian is already installed
@"
[wsl2]
memory=32GB
processors=10
swap=8GB
"@ | Out-File -Encoding ascii $env:USERPROFILE\.wslconfig
wsl --shutdown
```
> If `wsl` (no `-d`) opens a *different* distro, launch Debian explicitly: `wsl -d Debian`
> (optionally `wsl --set-default Debian`). Tune the numbers to your host.

## Step 2 — Inside Debian: enable systemd
```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
```
Then in PowerShell: `wsl --shutdown`, reopen with `wsl -d Debian`. Verify: `ps -p 1 -o comm=` → `systemd`.

## Step 3 — Inside Debian: clone this repo + run setup
```bash
git clone https://github.com/AlexGromer/uka-runner-bootstrap.git
cd uka-runner-bootstrap
bash setup-runner.sh
# RF: Docker Hub blocked? point at your homelab pull-through cache:
#   REGISTRY_MIRROR=http://<homelab-ip>:5000 bash setup-runner.sh
```
`setup-runner.sh` installs Docker + base pkgs, writes the registry mirror, passwordless sudo, the docker
group, and downloads the runner template into `~/actions-runner`.

**Re-open the WSL shell** (so `docker` works without sudo), then verify the go/no-go gate:
```bash
docker run --rm hello-world
docker pull postgres:17-alpine     # <-- MUST succeed (the RF Docker Hub test)
docker compose version
```

## Step 4 — Register N parallel runners
Ask Claude for a fresh **registration token**, then from the clone dir:
```bash
./register.sh <TOKEN> 3      # 3 parallel runners (default). One token registers all of them.
```
Creates `~/actions-runner-1..3`, each with its own systemd service, all sharing the label
`self-hosted,linux,x64`. They should show **Idle** under *Settings → Actions → Runners* as
`uka-wsl2-1 … uka-wsl2-3`. Add more later: `./register.sh <TOKEN> 4` (idempotent).

## Step 5 — Fix `actions/setup-python` on Debian
```bash
bash setup-toolcache.sh
```
`actions/setup-python` ships prebuilt CPython **only for Ubuntu**, so on Debian it fails with
*"version '3.12' … not found for debian 13"*. This script populates a shared runner tool cache
(`/opt/hostedtoolcache`) with Python via `uv`, points the runners at it (`AGENT_TOOLSDIRECTORY`),
and restarts them. Idempotent — re-run anytime (e.g. `PYVERS="3.12 3.13" bash setup-toolcache.sh`).

---

## Parallelism notes
One runner = one job at a time. `ci.yml`'s independent jobs (`lint`, `security`, `test-api`, `test-web`)
plus CodeQL's 2 matrix jobs can run concurrently — 3 runners covers most of the width; `build` waits for
`lint`+`security`. More runners → more concurrent RAM (each heavy job ≈4–6 GB), so keep `.wslconfig`
`memory` ≥ N×6 GB-ish. Note: `test-api` binds host ports 5432/6379 for its service containers, so don't
run two `test-api` jobs (i.e. two PR CI runs) simultaneously — trigger PR runs one at a time.

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

## Re-register / move the runners
`./register.sh <NEW_TOKEN> <COUNT>` is idempotent — it stops/uninstalls prior services and re-registers.

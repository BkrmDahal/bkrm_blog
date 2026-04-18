---
title: "Sandboxing Claude Code in a Long-Lived Container in MacOS"
date: "2026-04-17T22:12:03.284Z"
template: "post"
draft: false
slug: "claude-code-sandbox"
category: "tooling"
tags:
  - "claude-code"
  - "docker"
  - "sandbox"
description: "A wide allowlist is only safe when the blast radius is small. Running Claude Code inside a persistent Colima container keeps rm, bash, and gh pr create from ever touching host macOS."
socialImage: "/media/claude-sandbox.jpg"
---

![Sandboxing Claude Code in a Long-Lived Container](/media/claude-sandbox.jpg)

Letting an agent run with `rm`, `bash *`, and `gh pr create *` auto-approved is a productivity jump — right up until the moment the agent guesses wrong about which `rm -rf` it was meant to run. The fix isn't a narrower allowlist; it's a smaller blast radius. Drop Claude Code into a Linux container, bind-mount only the repos it should edit, and suddenly the wide allowlist is a feature instead of a footgun.

This post walks through the full setup end-to-end: installing Colima on macOS, building the sandbox image from a Dockerfile, and a launcher script that keeps one container alive across sessions so you don't re-login every time. You should be able to copy-paste your way from zero to a working sandbox in about fifteen minutes (plus ~5 minutes for the first image build).

## 1. Install Colima and the Docker CLI

On macOS we don't want Docker Desktop — it's proprietary and its license gets awkward for commercial use above a small headcount. [Colima](https://github.com/abiosoft/colima) is MIT-licensed and boots a lightweight Linux VM that speaks the Docker API, so the regular `docker` CLI talks to it transparently.

```bash
# Homebrew installs both; the docker CLI is a separate package from Docker Desktop.
brew install colima docker

# Boot the VM. --vm-type vz uses Apple's Virtualization.framework on Apple Silicon
# (faster, less RAM); drop that flag on Intel Macs and it falls back to QEMU.
colima start --cpu 4 --memory 4 --vm-type vz

# Verify: should print server + client versions, no "Cannot connect" error.
docker info
```

If `docker info` errors with "Cannot connect to the Docker daemon," Colima didn't start cleanly — `colima status` will tell you why, usually either "not enough disk" or a stale socket from a previous `Docker Desktop` install. `colima delete && colima start ...` is the reset button.

Colima's VM persists across reboots but not across `colima stop`. Once running, you can mostly forget it exists.

## 2. Wire up GitHub auth before you need it

The sandbox mounts `~/.config/gh` read-only, so `gh` and `git push` inside the container use whatever token your host user has. Create a **fine-grained** personal access token at <https://github.com/settings/personal-access-tokens/new> — scope it to only the repos the agent should touch, grant `Contents: read/write` and `Pull requests: read/write`, leave everything else as **No access**.

Stash the token in macOS Keychain rather than a plaintext dotfile, and export it from your shell rc so the launcher can forward it:

```bash
security add-generic-password -a "$USER" -s gh-token -w "<paste-token-once>"

cat >> ~/.zshrc <<'EOF'
export GH_TOKEN=$(security find-generic-password -s gh-token -w 2>/dev/null)
EOF

exec zsh
gh auth status   # should say: Logged in to github.com (GH_TOKEN)
```

Also make sure `~/.gitconfig` has your name + email — the container mounts it read-only, so commits inside inherit the host identity.

## 3. The Dockerfile

Debian slim base, non-root `agent` user whose uid/gid are injected at build time so bind-mounted files aren't owned by root. Installs a pragmatic toolchain for most projects Claude Code will touch: Node 20 (for `claude` itself), Go 1.22, Python 3, `gh`, `ripgrep`, `jq`, `git`, and `build-essential` — trim or extend as needed. A system-wide gitconfig rewrites `git@github.com:...` SSH remotes to HTTPS on the fly so the credential helper can auth via `gh` — that way we don't need to forward `~/.ssh` into the container at all.

```dockerfile
# sandbox/Dockerfile
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=1.22.6
# Injected by run-agent.sh so the in-container user matches the host's uid/gid.
ARG HOST_UID=1000
ARG HOST_GID=1000

# Base tooling — --no-install-recommends keeps the layer small.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        git \
        ripgrep jq make python3 \
        build-essential \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI — official apt repo.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Node 20 via NodeSource (Debian's nodejs package lags).
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# Go from official tarball — apt version is too old for us.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) goarch=amd64 ;; \
      arm64) goarch=arm64 ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" \
      | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:/home/agent/go/bin:${PATH}"
ENV GOPATH=/home/agent/go

# Claude Code CLI itself.
RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# Rewrite SSH remotes to HTTPS and use gh as credential helper — avoids
# needing to mount ~/.ssh at all.
RUN printf '%s\n' \
    '[url "https://github.com/"]' \
    '    insteadOf = git@github.com:' \
    '[credential "https://github.com"]' \
    '    helper = !gh auth git-credential' \
    > /etc/gitconfig

# Non-root user matching host uid/gid. macOS's gid 20 (staff) collides with
# Debian's dialout group, so reuse the existing group when the gid is taken.
RUN set -eux; \
    if ! getent group "${HOST_GID}" >/dev/null; then \
        groupadd --system --gid "${HOST_GID}" agent; \
    fi; \
    useradd --system --uid "${HOST_UID}" --gid "${HOST_GID}" \
            --home-dir /home/agent --shell /bin/bash --create-home agent; \
    mkdir -p /workspace /home/agent/go; \
    chown -R "${HOST_UID}:${HOST_GID}" /workspace /home/agent

# Tag the image with the baked-in uid so the launcher can detect stale
# images when the host uid changes and rebuild automatically.
ENV CLAUDE_SANDBOX_UID=${HOST_UID}

USER agent
WORKDIR /workspace
CMD ["claude"]
```

Build it once manually to sanity-check — the launcher will rebuild automatically after this:

```bash
docker build \
    --build-arg HOST_UID="$(id -u)" \
    --build-arg HOST_GID="$(id -g)" \
    -t claude-sandbox:latest sandbox/
```

First build takes ~2 minutes (mostly the Go tarball and `apt-get`). Subsequent builds hit the Docker layer cache and take seconds.

## 4. The launcher

The naïve `docker run --rm` throws away the Claude.ai OAuth token on every exit and makes you re-login constantly. Instead, keep one container alive with `sleep infinity` as PID 1, and `docker exec` into it on every subsequent call. `--cap-drop ALL` plus `--security-opt no-new-privileges` stops privilege escalation inside; `--memory 4g --cpus 4` caps a runaway loop. `~/.claude`, `~/.config/gh`, and `~/.gitconfig` are forwarded so auth survives across runs — `~/.ssh` is deliberately not, because the HTTPS + `gh` credential helper trick above is enough.

```bash
#!/usr/bin/env bash
# sandbox/run-agent.sh — launch Claude Code inside a long-lived container.
set -euo pipefail

IMAGE="claude-sandbox:latest"
CONTAINER="claude-sandbox"
SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER_DIR="$(cd "${SANDBOX_DIR}/.." && pwd)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Preflight ----------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "install colima + docker first"
docker info      >/dev/null 2>&1 || die "colima not running — 'colima start'"
[[ -n "${GH_TOKEN:-}" || -d "${HOME}/.config/gh" ]] \
    || die "no GH_TOKEN and no ~/.config/gh — set up GitHub auth first"

HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

# --- Rebuild image if host uid drifted ----------------------------------
IMAGE_UID=""
if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    IMAGE_UID="$(docker image inspect \
        --format '{{ range .Config.Env }}{{ println . }}{{ end }}' "${IMAGE}" \
      | awk -F= '$1=="CLAUDE_SANDBOX_UID"{print $2}')"
fi
if [[ -z "${IMAGE_UID}" || "${IMAGE_UID}" != "${HOST_UID}" ]]; then
    docker build \
        --build-arg HOST_UID="${HOST_UID}" \
        --build-arg HOST_GID="${HOST_GID}" \
        -t "${IMAGE}" "${SANDBOX_DIR}"
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
fi

# --- Create once, start, exec -------------------------------------------
if ! docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    docker create \
        --name "${CONTAINER}" --hostname "${CONTAINER}" \
        --cap-drop ALL --security-opt no-new-privileges \
        --memory 4g --cpus 4 \
        ${GH_TOKEN:+-e "GH_TOKEN=${GH_TOKEN}"} \
        -v "${MASTER_DIR}/repo-a:/workspace/repo-a" \
        -v "${MASTER_DIR}/repo-b:/workspace/repo-b" \
        -v "${HOME}/.config/gh:/home/agent/.config/gh" \
        -v "${HOME}/.gitconfig:/home/agent/.gitconfig:ro" \
        -v "${HOME}/.claude:/home/agent/.claude" \
        -w /workspace \
        "${IMAGE}" sleep infinity >/dev/null
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}")" != "true" ]]; then
    docker start "${CONTAINER}" >/dev/null
fi

exec docker exec -it -w /workspace "${CONTAINER}" "${@:-claude}"
```

## 5. First run and lifecycle

```bash
chmod +x sandbox/run-agent.sh
./sandbox/run-agent.sh
```

On first launch, Claude Code prompts for Claude.ai OAuth — macOS Keychain isn't reachable from the Linux VM, so the browser-based flow runs inside the container. The token is written to `~/.claude` (bind-mounted), so future runs skip login entirely.

A few commands you'll end up using:

| Command | Effect |
|---|---|
| `./sandbox/run-agent.sh` | starts the container if stopped, execs into it |
| `./sandbox/run-agent.sh bash` | drop into a shell instead of `claude` |
| `docker stop claude-sandbox` | pause — OAuth still cached for next start |
| `docker rm -f claude-sandbox` | destroy container, forces re-login next run |
| `colima stop` / reboot | drops container; one re-login after next start |

## What the sandbox buys you

- `rm -rf /` inside the container → container FS wiped, host untouched.
- `bash /tmp/random-thing.sh` → runs in container only, zero persistent effect.
- `gh pr create ...` → still hits real GitHub (outbound network is open).
- `rm -rf /workspace/repo-a/*` → **will delete host repo files** (that's the bind mount working as designed). Commit frequently; `git reflog` is your friend.

What's *not* isolated: anything you bind-mount is writable from inside by definition, and outbound HTTPS is open so the agent can still reach GitHub, npm, PyPI, and Claude.ai. This is a blast-radius reduction tool, not a containment tool for actively malicious code.

## Possible risks

The sandbox is a meaningful step up from "wide allowlist on bare macOS," but it is *not* a full security boundary. Go in knowing what it doesn't protect against:

- **Bind-mounted repo data is fully writable.** `rm -rf /workspace/*`, `git reset --hard`, `git push --force` all execute for real and hit your host files or the remote. The container doesn't stop destructive git operations — it just stops them from spreading beyond `/workspace/*`. Mitigation: commit often, push to branches not `main`, and set `receive.denyNonFastforwards` on any repo you really care about.
- **GitHub token scope is the real blast radius.** If the agent goes wrong, it can do anything your `GH_TOKEN` can do — open/close PRs, push, delete branches, read private code. **Use a fine-grained PAT scoped to only the repos you're working on**, never a classic token or a PAT with org-wide access. Rotate it on any suspected misbehavior (`security add-generic-password -U ...`).
- **Outbound network is open.** The container can reach any HTTPS endpoint — package registries, pastebins, attacker-controlled servers. A prompt-injected agent could exfiltrate code from `/workspace` or download a malicious dependency. If your threat model includes actively hostile prompts (random GitHub issues, arbitrary web pages fetched by the agent), consider an egress allowlist via Colima's network config or a proxy.
- **Supply-chain risk is unchanged.** `npm install`, `go get`, `pip install` inside the container still pull code from public registries and execute install scripts with the `agent` user's privileges. A compromised dependency can read `/workspace`, read your `GH_TOKEN` from the env, and use it. The sandbox doesn't vet dependencies — it just limits them to the container FS (but see: bind mounts + token above).
- **Claude.ai OAuth token is persisted to `~/.claude`.** That directory is bind-mounted rw, so anything inside the container can read it. If you share host `~/.claude` between this sandbox and other tooling, assume the container can read all of it. Keep it scoped to Claude Code only.
- **`--cap-drop ALL` is not a kernel-level guarantee.** Container escapes via kernel CVEs are rare but real. Keep Colima's VM updated (`colima stop && brew upgrade colima && colima start`), and don't treat the sandbox as strong enough to run genuinely untrusted binaries.
- **No audit trail.** There's no recording of what the agent ran inside the container. If something goes wrong, you get `git reflog` and your shell's scrollback, nothing more. If you need auditability, wrap `run-agent.sh` with `script(1)` or pipe to a logfile.
- **Host/container auth drift.** Env vars and the `~/.config/gh` mount are snapshotted at `docker create` time. If you rotate `GH_TOKEN` after creation, the container keeps using the old one until you `docker rm -f claude-sandbox` and let the launcher recreate it. Silent, and surprising.
- **`commit.gpgsign = true` on host breaks commits inside.** No GPG key in the container → commits fail. Either set `commit.gpgsign = false` locally or pass `-c commit.gpgsign=false` per-commit — but be aware you're skipping a check your org may rely on.

Rule of thumb: treat the sandbox like a junior dev with your GitHub credentials and `sudo` on a VM. You wouldn't let that person run arbitrary code without supervision, and you wouldn't give them production tokens. Same discipline here.

Quote from the book I am reading.

> _The first rule of any technology used in a business is that automation applied to an efficient operation will magnify the efficiency. The second is that automation applied to an inefficient operation will magnify the inefficiency._
>
> — Bill Gates, Business @ the Speed of Thought

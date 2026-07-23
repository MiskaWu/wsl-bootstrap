# wsl-bootstrap

Config-driven, unattended bootstrap for a clean WSL2 development distro on Windows.

One config file, one command, walk away. Builds a fresh Ubuntu WSL2 distro with a
container runtime (Podman by default), Go, Claude Code, and an opt-in toolchain —
no interactive prompts during the run.

## Why

WSL2 is already a full Linux VM boundary, so this setup treats the distro *itself*
as the dev environment rather than nesting a devcontainer per project. The container
runtime is used for dependency services (Postgres, NATS, Redis…) and image builds,
not as an app runtime. Podman is the default for rootless operation and clean
`podman generate kube` alignment with a k3s homelab.

## Requirements

- Windows 11 (24H2+) or a WSL version that supports `wsl --install --name`
- WSL2 enabled (`wsl --update` to be safe)
- Run from PowerShell

## Usage

```powershell
cp config.example.ps1 config.ps1   # first time
notepad config.ps1                 # edit to taste
.\bootstrap.ps1                    # unattended; auto-restarts WSL mid-run
```

The run is unattended. It restarts the WSL VM three times internally — after phase 1
(`wsl --shutdown`, so systemd and the default user take effect), after phase 2
(`wsl --terminate`, so container-group changes take effect), and after phase 3
(`wsl --terminate`, so the first session you enter is clean). All automatic, not
something you babysit.

Then check the result:

```powershell
wsl -d dev -u miskawu -- bash -l < scripts/verify.sh
```

This drives a real `docker-compose up` against the rootless Podman socket, not just
version strings — a bare `podman run` uses pasta and never touches firewall rules,
so it passes even when every compose project on the box is broken.

## What it installs & configures

Everything below happens with no prompts during the run.

**System (phase 1, as root)**
- Creates your user (`$User`) with passwordless `sudo`
- Writes `/etc/wsl.conf`: systemd on, `$User` as the default login, WSL-managed
  `resolv.conf`, Windows PATH appended
- `apt update && apt upgrade`

**Baseline packages (phase 2, as root) — always**
`git`, `tmux`, `ripgrep`, `jq`, `unzip`, `build-essential`, plus `ca-certificates`,
`curl`, `gnupg`, `lsb-release`.

**Container runtime (phase 2) — selected by `$Runtime`**
- **`podman`** (default): `podman buildah skopeo uidmap slirp4netns fuse-overlayfs
  iptables`, two WSL2-specific config files (below), `loginctl` lingering (so
  rootless services survive logout), and — with `$ComposeShim` — the official
  `docker-compose` binary. The rootless `podman.socket`, `DOCKER_HOST`, and
  `alias docker=podman` are then wired up in phase 3.
- **`docker`**: Docker Engine (`docker-ce`, CLI, `containerd`, buildx + compose
  plugins); adds `$User` to the `docker` group; enables the service.

**User toolchain (phase 3, as your user)**
- Always: Claude Code (native installer → `~/.local/bin`), Go (binary →
  `/usr/local/go`, version from `$GoVersion`)
- Optional, per the flags below: Node, Python (uv), client tools, SSH keys

**Two Podman config files WSL2 specifically needs** (written in phase 2)
- `/etc/containers/registries.conf` — a single unqualified search registry
  (`docker.io`). Ubuntu ships no `registries.conf` at all, and the bundled
  short-name alias table doesn't cover `postgres`, `redis` or `nats`, so without
  this `podman pull postgres` fails outright.
- `/etc/containers/containers.conf` — points netavark at the `iptables` firewall
  driver. Netavark's default nftables driver fails on the WSL2 kernel, which
  breaks every `docker-compose up` — compose always creates a bridge network,
  while a bare `podman run` uses pasta and never touches firewall rules.

## Config options (`config.ps1`)

| Option | Default | Controls |
|---|---|---|
| `$Distro` | `dev` | WSL distro name (`wsl -d <name>`); also the SSH key filename prefix |
| `$UbuntuImage` | `Ubuntu-26.04` | source image (`wsl --list --online`); 26.04 ships podman 5.7 vs 24.04's frozen 4.9.3 |
| `$User` | `miskawu` | Linux login user created in the distro |
| `$Runtime` | `podman` | `podman` or `docker` |
| `$ComposeShim` | `$true` | `docker-compose` binary + `DOCKER_HOST` so an existing `docker-compose.yml` runs on the Podman socket unchanged (podman only) |
| `$GoVersion` | `latest` | `latest` auto-resolves from go.dev, or pin e.g. `1.23.4` |
| `$InstallNode` / `$NodeVersion` | `$false` / `lts` | nvm + Node |
| `$InstallPython` | `$true` | uv |
| `$InstallClientTools` | `$true` | `psql`, `redis-cli`, `nats` |
| `$GenerateSSHKey` | `$true` | one `id_ed25519_<distro>_<scope>` per scope (prefix from `$Distro`) |
| `$SSHKeyScopes` | `github, gitlab, homelab` | which per-destination keys to generate |
| `$SSHKeyComment` | `miskawu@acme-dev` | key comment; phase 3 appends `-<scope>` and the build date |
| `$UnregisterOld` / `$OldDistroName` | `$false` / — | after a successful build, offer to remove a named old distro (asks for explicit confirmation) |

## Layout

```
wsl-bootstrap/
├── bootstrap.ps1            # PowerShell orchestrator (unattended)
├── config.example.ps1       # copy to config.ps1 and edit
├── scripts/
│   ├── phase1-system.sh     # root: user + /etc/wsl.conf (systemd, default user)
│   ├── phase2-runtime.sh    # root: container runtime + baseline packages
│   ├── phase3-user.sh       # user: Claude Code, Go, optional toolchain, SSH keys
│   └── verify.sh            # post-run acceptance checks (incl. compose end-to-end)
└── .gitignore               # ignores config.ps1 (personal info)
```

Phases are split because some WSL settings (systemd, default user, group
membership) only take effect after a VM restart. The orchestrator handles the
restarts between phases.

## Notes

- `config.ps1` is gitignored — it holds your username and SSH scopes. Only
  `config.example.ps1` is tracked.
- Keep repos on the WSL filesystem (`~/`), not `/mnt/c/`, for I/O performance.
- Environment variables (`PATH`, `DOCKER_HOST`) go in `~/.profile`, not `~/.bashrc`
  — Ubuntu's `.bashrc` returns early for non-interactive shells, so anything
  exported there is invisible to `wsl -d <distro> -e <cmd>` and to scripts.
  Shell aliases stay in `.bashrc`, where they belong.
- Old distro removal is opt-in and asks for explicit confirmation
  (`$UnregisterOld` + `$OldDistroName`).
- After the run, finish the manual checklist printed by phase 3 (Claude Code auth,
  add SSH public keys to platforms, set git identity).

## License

MIT

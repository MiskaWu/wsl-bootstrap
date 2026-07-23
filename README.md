# wsl-bootstrap

Config-driven, unattended **bring-up** of a clean Ubuntu WSL2 distro on Windows —
just enough to hand off to Ansible.

One config, one command, walk away. Produces a fresh Ubuntu 26.04 WSL2 distro with
systemd, your user, passwordless sudo, a baseline (`git`, `make`, `ansible-core`),
and Ubuntu's telemetry opted out — reachable and ready for configuration management.

The actual dev environment (Podman, Go, Claude Code, toolchain) is installed
separately by **dev-env-ansible**, run locally on the box with `make apply`. Two
repos on purpose: that Ansible role is host-agnostic and reusable on any Linux box,
so it isn't tied to this WSL-specific bootstrap.

## Why split into two repos

- **`wsl-bootstrap`** (this repo, Windows/PowerShell) does the parts only Windows
  can do: create the distro, set the default user + systemd in `/etc/wsl.conf`, and
  the VM restart that makes them take effect.
- **`dev-env-ansible`** (separate repo, runs on the box) is the software environment
  as an idempotent Ansible role: `make apply` to install, `make check` to preview
  (dry-run diff), `make apply TAGS=node` to add one thing later — no tear-down/rebuild.

## Requirements

- Windows 11 (24H2+) or a WSL version that supports `wsl --install --name`
- WSL2 enabled (`wsl --update` to be safe)
- Run from PowerShell

## Usage

```powershell
cp config.example.ps1 config.ps1   # first time
notepad config.ps1                 # set distro name + user
.\bootstrap.ps1                    # unattended; restarts WSL twice internally
```

Then, inside the distro, install the dev environment:

```bash
wsl -d dev
git clone <dev-env-ansible repo> ~/projects/dev-env-ansible
cd ~/projects/dev-env-ansible
make check    # preview what will be installed
make apply    # podman, go, claude, toolchain
```

Verify the bring-up:

```powershell
wsl -d dev -u miskawu -- bash -l < scripts/verify.sh
```

## What bring-up does (`scripts/provision.sh`, as root)

- Creates your user (`$User`) with passwordless `sudo`
- Writes `/etc/wsl.conf`: systemd on, `$User` as default login, WSL-managed
  `resolv.conf`, Windows PATH appended
- `apt update && upgrade`
- Installs baseline: `git`, `make`, `ansible-core`, `python3` — so the box can run
  the Ansible role locally
- Opts out of Ubuntu 26.04 telemetry: writes `~/.config/ubuntu-insights/*-consent.toml`
  (`consent_state = false`), so first launch has no interactive metrics prompt
- Creates `~/projects`

Then two automatic WSL restarts (one for systemd/default-user to take effect, one so
your first session is clean).

## Config (`config.ps1`)

| Option | Default | Controls |
|---|---|---|
| `$Distro` | `dev` | WSL distro name (`wsl -d <name>`) |
| `$UbuntuImage` | `Ubuntu-26.04` | source image (`wsl --list --online`) |
| `$User` | `miskawu` | Linux login user created in the distro |
| `$EnvRepo` | — | dev-env-ansible URL, shown in the finish message |
| `$UnregisterOld` / `$OldDistroName` | `$false` / — | after a successful build, offer to remove a named old distro (asks for explicit confirmation) |

Everything about the *software* environment (container runtime, Go version,
Node/Python/clients, SSH keys) lives in `dev-env-ansible`'s `group_vars`, not here.

## Networking: default NAT, not mirrored

Kept on default WSL2 **NAT**. Windows reaches services in the distro — including
rootless Podman container ports — at `localhost:<port>` with no forwarding, via
`localhostForwarding` (on by default). Mirrored mode is deliberately avoided: as of
2026 it has open bugs with rootless Podman (port-forwarding timeouts, `127.0.0.1`
unreachable inside WSL) and it turns `localhostForwarding` off. If a separate LAN
machine ever needs to reach the distro, use ProxyJump via the Windows OpenSSH server
or Tailscale — not mirrored.

## Layout

```
wsl-bootstrap/
├── bootstrap.ps1          # PowerShell orchestrator (unattended)
├── config.example.ps1     # copy to config.ps1
└── scripts/
    ├── provision.sh       # the single root bring-up phase
    └── verify.sh          # post-run bring-up checks
```

## Notes

- `config.ps1` is gitignored.
- Keep repos on the WSL filesystem (`~/`), not `/mnt/c/` — for I/O, and because
  Ansible ignores `ansible.cfg` in the world-writable `/mnt/c`.
- After bring-up: clone dev-env-ansible + `make apply`, then `claude` (first-run
  OAuth) and `git config --global user.name/email`.

## License

MIT

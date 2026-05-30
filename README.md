# et-zellij-setup

Portable installer for the Mac → remote Linux (e.g. WSL2 over Tailscale)
dev-shell stack: **Eternal Terminal** for sleep-resilient KKP-transparent
transport, **zellij** for session persistence, and a small interactive
session picker (`zjpick`) wired into a `zj` zsh helper.

Designed so you can clone this folder onto a new Mac (or new remote box) and
get back to an identical working setup in a few minutes.

## What this installs

### Local (Mac)
- `et` client + `zellij` via Homebrew
- A `Host <alias>` block in `~/.ssh/config`
- A managed block in `~/.zshrc` exposing:
  - `zj` — interactive picker (or `zj <name>` to attach/create directly)
  - `zjlong` — same, with `caffeinate -i`
  - `zjx` — same, but no port forwards (use in additional windows)
  - `zjls`, `zjkill <name>`
  - `zj --help` (and `-h` on all of the above)

### Remote (Linux; tested on Ubuntu 22.04 WSL2)
- `etserver` from the `ppa:jgmath2000/et` PPA, running as a systemd unit on port 2022
- `zellij` static binary in `~/.local/bin`
- `~/.zshenv` ensures `~/.local/bin` is on `PATH` for non-interactive shells
- A KKP pop hook in `~/.zshrc` (safety net for zellij detach/attach desync)
- `~/.local/bin/zjpick` — the interactive picker that `zj` invokes

All file edits are inside a single marked block (`# >>> et-zellij-setup >>>`)
so re-running the installer is idempotent.

## Prerequisites

- **Mac**: Homebrew installed.
- **Remote**: SSH access via key (configured in `IDENTITY_FILE`), `sudo` rights,
  Linux with `systemd` (WSL2 with `systemd=true` in `/etc/wsl.conf` works).
- **Network**: a path from Mac to remote on the configured `ET_PORT` (2022).
  Tailscale is the easiest way; direct LAN or any VPN works too.

## Usage

```bash
# 1) one-time: clone, configure
cp config.example.sh config.sh
$EDITOR config.sh

# 2) install both sides (or just one)
./install.sh all     # default — Mac + remote
./install.sh local   # only the Mac side
./install.sh remote  # only the remote side (will ssh in, may prompt for sudo)

# 3) reload your shell
source ~/.zshrc

# 4) go
zj                   # interactive picker
zj work              # attach/create session named 'work'
zj --help
```

## Notes

- `config.sh` is **gitignored** — keep personal hostnames / paths out of the repo.
- On the remote, `etserver` listens on `ET_PORT` for all interfaces. If you
  expose the box beyond a private network/VPN, restrict with firewall rules.
- The remote installer takes ~1 minute (PPA + apt + zellij download).
  The Mac installer takes longer the first time because Homebrew compiles `et`
  from source (5–10 min on Apple Silicon).
- To remove: delete the marked blocks from `~/.ssh/config` and `~/.zshrc`,
  `sudo systemctl disable --now et && sudo apt remove et` on remote,
  `brew uninstall et zellij` on Mac.

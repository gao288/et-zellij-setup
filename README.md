# et-zellij-setup

> A sleep-resilient, KKP-transparent remote dev shell for Mac → Linux.
> Close your laptop, walk away, open it tomorrow — your work is exactly where
> you left it, in the same session, with the same scrollback, with no
> reconnect dance.

Eternal Terminal handles the transport so the connection survives sleep and
network blips without killing the remote process. Zellij handles persistence
so a session can outlive any client. A small interactive picker (`zjpick`)
and a thin zsh wrapper (`zj`) make all of it disappear into a single command.

---

## The problem this solves

### 1. SSH reconnect is brutal

A bare `ssh user@host` is a single TCP connection. If anything interrupts it
— Mac sleep, WiFi switch, the network blink while you walk between rooms —
TCP breaks, the remote shell receives `SIGHUP`, and **every process inside
that shell dies**. The dev server in tab 2, the long training run in tab 5,
the editor with unsaved buffers in tab 1 — all gone. You SSH back in to a
fresh shell, in your home directory, with nothing.

The traditional fix is `tmux` or `screen` on the remote. They preserve the
*processes* across reconnects, but they don't fix the *transport*. You still
have to `ssh && tmux attach` every time, and the moment you do, your
terminal's mode state (cursor mode, mouse mode, modern-keyboard mode) is
often subtly out of sync with what tmux thinks it should be — leading to
garbled keys, mis-rendered prompts, or escape sequences leaking as text.

`mosh` tries to fix the transport with UDP roaming and local echo, but it
does so by running a server-side terminal emulator that **drops escape
sequences it doesn't understand**. That kills the modern Kitty Keyboard
Protocol (KKP), which kills `Shift+Enter`, modifier-key reporting, and a
growing number of things that today's TUIs (Helix, Zellij, Neovim with
modern keymaps, Claude Code, etc.) depend on.

### 2. Zellij sessions need a clean front door

Zellij is excellent — first-class session persistence (`session_serialization
true`), built-in resurrection of exited sessions, native multi-client attach,
tabs and panes. But the front door is awkward: you `ssh` in, type
`zellij list-sessions`, eyeball it, then `zellij attach <name>` or
`zellij attach -c <new-name>`. Multiply that by every new window, every
reconnect, every "what was I working on?", and friction adds up.

What's missing is a single command that shows you what's there, lets you
resurrect or create, and gets out of the way.

### 3. What you live with without this

- **Lost work after sleep.** Close lid → open tomorrow → broken pipe → SIGHUP
  storm → restart everything.
- **Mode desync.** Reattach to a tmux session and the next prompt is
  garbled because the terminal thinks you're still in alt-screen.
  Disconnect mid-KKP-push and the next session is in a "phantom" mode where
  `Shift+Enter` produces a literal escape sequence instead of a newline.
- **No `Shift+Enter` in remote tools.** Anything sophisticated about
  modifier-key reporting silently breaks under `mosh`.
- **Port-forward conflicts.** You always need `-L 3000:localhost:3000` for
  your dev server, but the second SSH window can't bind 3000 and silently
  drops the forward — and you debug your "broken" dev server for ten
  minutes before realizing.
- **Multiple disjoint workflows.** "Reconnect-safely" requires one tool,
  "session-persist" requires another, "modern keyboard" requires a third,
  "stop fighting port forwards" requires a fourth.

This repo combines them into one workflow with one command.

---

## What you get

A managed block of zsh helpers plus an installed picker:

```text
On the Mac:
  zj                 Interactive picker — pick a running session,
                     resurrect an exited one, create new, or drop to a
                     plain shell. Carries your port forwards AND the
                     reverse tunnel for editor dispatch (below).
  zj <name>          Skip picker, attach or create <name> directly.
  zjlong [name]      Same as zj, plus `caffeinate -i` so the Mac
                     doesn't idle-sleep mid-task.

  zjx [name]         Same as zj but with no port forwards / no reverse
                     tunnel — safe to open in additional windows
                     without fighting over local ports.

  zjls               List remote zellij sessions.
  zjkill <name>      Kill / clear a session (incl. resurrectable ones).

  zj --help          Cheat sheet (also: zjlong -h, zjx -h, etc.).

On the remote (in any zellij pane, once a primary `zj` is up):
  edit [path]        Open <path> (default $PWD) in your *primary* editor
                     on the Mac via Remote-SSH.
  zed [path]         Specifically open in Zed.
  code [path]        Specifically open in VSCode.
  cursor [path]      Specifically open in Cursor.
```

Under the hood:

- **Transport:** Eternal Terminal — TCP with per-byte sequence numbers; the
  remote pty stays alive across disconnects and missing bytes are replayed.
- **Multiplexer:** Zellij with `session_serialization true` — sessions are
  durable across the remote process restarting; exited sessions can be
  resurrected.
- **Picker:** A small Bash script (`zjpick`) installed on the remote and
  invoked by the local `zj` over `et -c`. Lists running vs exited sessions,
  offers "new" and "shell-only" actions.
- **Smart port forwarding:** Before invoking `et -t`, the local `zj`
  introspects which local ports are free and forwards only those, so a
  second window or a running dev server doesn't cause "Address already in
  use".
- **KKP safety net:** A `precmd` hook on the remote pops one Kitty Keyboard
  Protocol enhancement level each prompt, mitigating multiplexer-layer
  desync from zellij detach/attach.
- **Open-on-Mac editor dispatch:** A reverse tunnel from the remote to a
  `launchd`-supervised `socat` listener on the Mac. Remote `edit <path>`
  (or `zed`/`code`/`cursor`) sends the path back; the Mac dispatcher
  spawns your editor's local Remote-SSH client against `REMOTE_ALIAS`.
  You get the "open in Zed/VSCode/Cursor right here" reflex from inside
  any remote pane, without the editor needing to own the connection.

---

## Demonstration setup

The canonical example this was built against:

```
  ┌──────────────────────┐                              ┌──────────────────────┐
  │  MacBook Pro         │                              │  Windows desktop      │
  │  (Apple Silicon)     │                              │                       │
  │                      │                              │  WSL2 Ubuntu 22.04   │
  │  Ghostty (KKP)       │ ─── Tailscale (direct) ───►  │  systemd + zsh       │
  │  zsh + starship      │     <100ms LAN latency       │                       │
  │  et 6.2 + zellij     │                              │  etserver (systemd)   │
  └──────────────────────┘                              │  zellij + zjpick     │
                                                        └──────────────────────┘
```

- **Transport:** Eternal Terminal over Tailscale (direct, no DERP relay).
- **Session age:** at the time this repo was made, the primary zellij
  session was 7+ days old and unbroken across many Mac sleeps and several
  WiFi switches.
- **Forwarded ports:** `3000:3000 18789:18789 5800:5800` (dev server,
  Jupyter-style services, VNC). The forwards travel with the et session and
  auto-restore on reconnect.

Both Mac sleep (closed lid) and overnight idle are handled by et's
transport. The only failure mode that would kill the remote zellij is the
Windows host itself shutting down or WSL2 being garbage-collected — both
configurable away on the Windows side.

---

## Install — Option 1: scripted

For when you want to run a single command and be done.

```bash
git clone <this-repo-url> et-zellij-setup
cd et-zellij-setup

cp config.example.sh config.sh
$EDITOR config.sh                 # set REMOTE_ALIAS, REMOTE_HOST, REMOTE_USER,
                                  # IDENTITY_FILE, FORWARD_PORTS, ET_PORT

./install.sh all                  # Mac side first, then ssh + sudo on remote
                                  # (or `./install.sh local` / `./install.sh remote`)

source ~/.zshrc                   # pick up the new zj helpers
zj                                # open the picker
```

The installer is **idempotent**: every file it touches gets a marked block
(`# >>> et-zellij-setup start >>>` … `# <<< et-zellij-setup end <<<`), and
re-running replaces that block in place. You can run `./install.sh all`
after editing `config.sh` or the templates and nothing else in your
`~/.zshrc` or `~/.ssh/config` will be disturbed.

### Prerequisites

| Side | Requirement |
|------|-------------|
| Mac | Homebrew installed. |
| Remote | SSH access via key, `sudo` rights, Linux with `systemd` (WSL2 with `systemd=true` in `/etc/wsl.conf` is fine). |
| Network | A path from Mac to remote on `ET_PORT` (default 2022). Tailscale is the easiest; direct LAN or any VPN works. |

### What `./install.sh all` does

**Mac:**
- `brew install MisterTea/et/et zellij socat` (skips packages already present)
- Symlinks `code` / `cursor` CLIs from their `.app` bundles into
  `~/.local/bin` for the editors you enable in `EDITORS_ENABLED`
- Upserts a `Host <REMOTE_ALIAS>` block into `~/.ssh/config`
- Upserts the `zj` / `zjlong` / `zjx` / `zjls` / `zjkill` zsh helpers
  (plus `_zj_help`, `_zj_free_forwards`) into `~/.zshrc`
- Writes `~/.local/bin/open-remote.sh` (the editor dispatcher) and
  loads a `launchd` agent at
  `~/Library/LaunchAgents/local.et-zellij-setup.open-remote.plist` that
  runs `socat` on `127.0.0.1:$REVERSE_PORT`

**Remote (via ssh; first run will prompt for sudo, re-runs are sudo-free):**
- Adds `ppa:jgmath2000/et`, `apt install et`, enables systemd `et.service`
  (all skipped if `etserver` is already installed / active)
- Downloads the `zellij` static binary to `~/.local/bin/zellij`
- Upserts a PATH line into `~/.zshenv` so non-interactive shells can find
  `zellij` (this is what `et -c "zellij attach …"` runs under)
- Upserts a block in `~/.zshrc` containing the KKP-pop `precmd` hook
  plus the `edit` / `zed` / `code` / `cursor` functions
- Installs `zjpick` to `~/.local/bin/zjpick`

---

## Install — Option 2: agent-driven (Claude Code skill)

For when you want an interactive walkthrough — useful on a brand-new
machine, when you'd rather answer questions than read config docs, or when
you want the agent to verify each step as it goes.

This repo ships a [Claude Code](https://claude.com/claude-code) skill
at `.claude/skills/setup-et-zellij.md`. When Claude Code is launched inside
this directory, the skill is auto-discovered. To make it available
globally on this Mac (and reachable from any directory):

```bash
mkdir -p ~/.claude/skills
cp .claude/skills/setup-et-zellij.md ~/.claude/skills/
```

Then, in Claude Code:

```text
/setup-et-zellij
```

The skill will:

1. Detect whether `config.sh` already exists and offer to reuse, edit, or
   start fresh.
2. Walk you through each field with `AskUserQuestion`, suggesting sensible
   defaults (e.g. Tailscale MagicDNS for `REMOTE_HOST` if Tailscale is
   detected).
3. Test connectivity to the remote (`ssh`, port check) before committing.
4. Run `./install.sh local`, then ask whether to do `./install.sh remote`.
5. Reload your shell context check (you still source `~/.zshrc` yourself in
   your terminal) and verify with `zj --help`.

The skill is intentionally non-destructive: every edit goes through the
same `install.sh` flow with marked blocks, so it stays idempotent across
re-runs.

---

## Configuration reference

`config.sh` (copy of `config.example.sh`, gitignored) defines:

| Variable | Meaning |
|----------|---------|
| `REMOTE_ALIAS` | Name of the SSH alias added to `~/.ssh/config`. Used by both `ssh <alias>` and `et <alias>`. |
| `REMOTE_HOST` | Hostname or IP of the remote. Tailscale MagicDNS works well. |
| `REMOTE_USER` | Username on the remote. |
| `IDENTITY_FILE` | Local SSH private key. `~` is expanded. |
| `FORWARD_PORTS` | Space-separated `local:remote` pairs. `zj` auto-skips any whose local port is busy at connection time. |
| `ET_PORT` | TCP port `etserver` listens on (default 2022). |
| `REVERSE_PORT` | Local TCP port for the editor dispatch listener (default 8123). `zj`/`zjlong` add `et -r $REVERSE_PORT:$REVERSE_PORT` so remote `edit`/`zed`/`code`/`cursor` can reach the Mac. |
| `EDITORS_ENABLED` | Space-separated list of editors to enable. Supported: `zed`, `code`, `cursor`. The first one is the default for bare `edit` (without an editor-specific alias) from the remote. |

---

## Caveats and operational notes

- **Mac sleep is fine; Windows-host sleep is not.** Eternal Terminal
  preserves the remote pty across the client side disconnecting, but if the
  Windows host that runs WSL2 sleeps or shuts down, `etserver` and `zellij`
  go with it. In that case zellij sessions are typically `EXITED -- attach
  to resurrect` from the latest serialization (default every 60s), so you
  lose at most about a minute of scrollback.
- **WSL2 idle shutdown.** Windows can garbage-collect an idle WSL2 distro
  after a few seconds of no activity. If you see remote zellij sessions
  vanish overnight, add `idleTimeout=-1` to `~/.wslconfig` on the Windows
  side under `[wsl2]`.
- **Long-task mode.** `zjlong` wraps `et` with `caffeinate -i` so the Mac
  doesn't idle-sleep while a long remote job is running. It does **not**
  prevent lid-close sleep (use `pmset` or an external monitor for that).
  Per the point above, lid-close is usually fine anyway.
- **Port conflicts are now non-fatal.** Before each connection, `zj`
  introspects which of the `FORWARD_PORTS` are already taken locally and
  drops only those. If all are busy (e.g. you already have a `zj` session
  open in another window), `zj` connects bare and prints a one-line notice.
- **KKP `precmd` hook is opt-out.** The remote `~/.zshrc` block emits
  `\e[<u` (pop one KKP enhancement level) on every prompt. Pre-KKP
  terminals will silently ignore it; if your specific terminal renders it
  as garbage, remove the marked block on the remote.
- **One pure-SSH path is kept.** The `Host <REMOTE_ALIAS>` block has no
  `LocalForward` lines. Plain `ssh <alias>` works for `scp`, `git`, ad-hoc
  one-off commands. For ad-hoc forwarding, use `ssh -L 3000:localhost:3000
  <alias>`.
- **Editor dispatch is not transport-resilient.** Once Zed / VSCode /
  Cursor opens via Remote-SSH, it's running its own SSH connection — that
  one is NOT covered by `et`'s reconnect logic. If the connection drops,
  the editor will need to reconnect on its own (most do this gracefully).
  Only the *trigger* (`edit .` typed in a zellij pane) rides through `et`.
- **Multiple `zj` windows and the reverse tunnel.** Only the *first* `zj`
  window successfully binds the remote `REVERSE_PORT`; subsequent windows
  will print a "port busy" warning from `et`. This is harmless — `edit`
  invocations from any pane on the remote route through the first window's
  tunnel. Use `zjx` for additional windows that don't need editor dispatch.
- **Editor dispatch security.** The Mac dispatcher only accepts a `verb`
  and a `path`; the SSH host is baked into the dispatcher at install time
  (from `REMOTE_ALIAS`), so a stray connection to `127.0.0.1:REVERSE_PORT`
  can't make you open arbitrary remote hosts. The listener is bound to
  loopback only.

---

## Uninstall

```bash
# Mac
brew uninstall et zellij
# then delete the marked block from ~/.zshrc and ~/.ssh/config

# Remote (over ssh)
sudo systemctl disable --now et
sudo apt remove --purge et
rm -f ~/.local/bin/zellij ~/.local/bin/zjpick
# then delete the marked blocks from ~/.zshenv and ~/.zshrc
```

---

## Repository layout

```
et-zellij-setup/
├── .claude/skills/
│   └── setup-et-zellij.md       # agent-driven setup walkthrough
├── .gitignore
├── README.md
├── config.example.sh            # template — copy to config.sh and edit
├── install.sh                   # entry: local / remote / all
└── zjpick                       # remote interactive picker
```

---

## License

MIT — see [LICENSE](LICENSE).

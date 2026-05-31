---
name: setup-et-zellij
description: Use this skill when the user wants to install or configure the et-zellij-setup remote-shell stack on a Mac (and optionally bootstrap the remote Linux side via SSH). Walks through gathering config values, writes config.sh, then runs install.sh with verification at each step. Trigger phrases include "set up et-zellij", "install zj", "set up the remote shell stack", or running this skill via `/setup-et-zellij`.
---

# Set up et + zellij remote shell

You are walking the user through installing the et + zellij + zjpick stack
from this repository. Be conversational, concise, and verify each step
before moving on.

## What the user is opting into

A managed block of zsh helpers (`zj`, `zjlong`, `zjx`, `zjls`, `zjkill`)
plus `etserver`, `zellij`, and the `zjpick` picker on a remote Linux box.
Read `README.md` in this repo for the full problem statement and design.
**Do not** re-explain the README at length — assume the user has skimmed it.

## Hard requirements

- This skill must be invoked from inside a clone of the `et-zellij-setup`
  repository. Check by looking for `install.sh`, `config.example.sh`, and
  `zjpick` in the current directory or skill-script directory.
- The user must have Homebrew installed locally and SSH access to the
  remote (the remote can be configured later if they only want the Mac
  side now).

## Workflow

### Step 1 — Orient and detect state

Run these probes in parallel and report a one-line summary:

- `command -v brew` — bail if missing, tell user to install from
  https://brew.sh and stop.
- `command -v et`, `command -v zellij` — note which are already present.
- `test -f config.sh && cat config.sh` — if it exists, show the values and
  ask whether to reuse, edit, or start fresh.
- `command -v tailscale && tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' && tailscale ip -4` — useful for suggesting
  `REMOTE_HOST` defaults if Tailscale is in use.
- `ls ~/.ssh/*.pub 2>/dev/null` — to suggest `IDENTITY_FILE` candidates.

### Step 2 — Gather config

Use `AskUserQuestion` for each required field. **Suggest sensible defaults
from the probes above as the first option.** Always include enough context
in each question that the user can answer without leaving the chat.

Required fields (defined in `config.example.sh`):

| Field | What to ask |
|-------|-------------|
| `REMOTE_ALIAS` | The SSH alias name for this host. Suggest something short like `dev` or `<hostname>et`. |
| `REMOTE_HOST` | Hostname/IP. If Tailscale was detected, suggest the MagicDNS for known peers (let the user pick which peer). |
| `REMOTE_USER` | Username on the remote. If you have shell access, you can probe with `ssh -o BatchMode=yes <candidate-host> whoami`. |
| `IDENTITY_FILE` | Path to SSH key. Default to `~/.ssh/id_ed25519` if present, otherwise list keys found. |
| `FORWARD_PORTS` | Space-separated `local:remote` pairs. Default to `3000:3000` and ask whether they want to add more. |
| `ET_PORT` | TCP port for `etserver`. Default `2022`; only change if there's a known conflict. |
| `REVERSE_PORT` | TCP port for the open-on-Mac editor dispatcher. Default `8123`; only change on conflict. |
| `EDITORS_ENABLED` | Multi-select via `AskUserQuestion`. Detect which of zed/code/cursor have either a CLI on PATH (`command -v`) or the app at `/Applications/<Name>.app`. The first item in the resulting list is the default for bare `edit`. |

After collecting, show a summary table and ask "Looks right?" before
writing anything.

### Step 3 — Test connectivity (before changing files)

Before writing `config.sh`, do a sanity check:

```bash
ssh -i <IDENTITY_FILE> -o BatchMode=yes -o ConnectTimeout=5 \
    <REMOTE_USER>@<REMOTE_HOST> 'echo OK; uname -a; sudo -n true && echo SUDO_OK || echo SUDO_PROMPT'
```

If SSH fails, surface the error and offer to retry with corrected values
(don't proceed to writing the config).

If `SUDO_PROMPT` shows, warn the user that the remote install step will
prompt for a sudo password interactively.

### Step 4 — Write config.sh

Use `Write` to create `config.sh` in the repo root with the collected
values. Match the exact format of `config.example.sh` (variable names,
quoting style, comments).

### Step 5 — Run local install

Run `./install.sh local` and stream output. Look for:

- `✓ et:` and `✓ zellij:` and `✓ socat already installed` (or fresh install)
- `✓ zed CLI:` / `✓ code CLI:` / `✓ cursor CLI:` lines for whichever editors
  the user enabled. If the line starts with `!`, the editor was enabled but
  its CLI / app wasn't found — surface this and ask whether to install or
  drop the editor from the config.
- `✓ ~/.local/bin/open-remote.sh`
- `✓ launchd agent loaded, listening on 127.0.0.1:<REVERSE_PORT>` (a `!`
  here usually means socat couldn't bind — check `/tmp/open-remote.err`)
- `✓ ~/.ssh/config:` and `✓ ~/.zshrc:` block confirmations

If `brew install MisterTea/et/et` is starting for the first time, warn the
user it compiles from source and takes 5–10 minutes on Apple Silicon. Run
it with `run_in_background: true` and continue with config writes /
informational text while it builds, checking in periodically.

### Step 6 — Offer remote install

Ask: "Bootstrap the remote side now? You'll be prompted for the sudo
password on `<REMOTE_HOST>` once."

If yes, run `./install.sh remote`. This streams an SSH session with `-t`,
so sudo prompts work. Stream output and look for:

- `✓ et:` and `✓ etserver:` (with port shown)
- `✓ zellij:`
- `✓ ~/.zshenv:` and `✓ ~/.zshrc:` blocks
- `✓ ~/.local/bin/zjpick installed`

If sudo password fails or the remote install errors, surface the error,
don't retry blindly. Offer to investigate or rerun.

### Step 7 — Verify

Two checks:

1. Source the new zshrc in a subshell and probe `zj`:
   ```bash
   zsh -ic 'source ~/.zshrc; type zj' 2>&1 | tail -3
   ```
   Expect `zj is a shell function from ~/.zshrc`.

2. Show the help output:
   ```bash
   zsh -ic 'source ~/.zshrc; zj --help' 2>&1 | tail -30
   ```

3. (Optional but useful) verify the editor dispatch chain without opening
   the editor:
   ```bash
   printf 'bogus_verb|/tmp\n' | nc -w 1 127.0.0.1 8123
   sleep 0.3
   tail -3 /tmp/open-remote.err
   ```
   Expect `open-remote: unknown verb: bogus_verb` — confirms socat + the
   dispatcher script are wired together. Don't run a real verb here; that
   actually opens an editor window.

Tell the user to run `source ~/.zshrc` in any open shell, or open a new
window, then run `zj`. To use the editor dispatch: from inside a zellij
pane on the remote, `cd` somewhere and run `edit .` (or `zed .` / `code .`
/ `cursor .` for a specific editor).

## Behavioral guidance

- **Be conversational, not robotic.** Don't restate "Step 1, Step 2"
  headers verbatim; weave the work into normal back-and-forth.
- **Parallelize probes.** Step 1 probes are independent; run them in one
  message with multiple Bash calls.
- **Never write `config.sh` without confirmation.** Step 4 must follow an
  explicit "Looks right?" approval.
- **Never run `./install.sh remote` without confirmation.** It uses sudo
  and modifies a system the user may share with others.
- **Don't re-paste the README.** Reference it (`README.md` in this repo)
  if the user asks for the why; assume they've skimmed it.
- **Surface, don't swallow, errors.** If a brew install fails, an SSH
  probe fails, or sudo is denied, stop and report. Don't auto-retry.
- **Keep memory in mind.** If the user already has `config.sh` from a
  previous run on a different machine (e.g. synced via dotfiles), default
  to reusing it.

## Done state

When done, post a single-message summary with:

- What was installed (Mac side, remote side, or both)
- The single command the user runs next: `zj`
- A reminder that `zj --help` shows the cheat sheet

Do not run `zj` for the user — it's an interactive command and you can't
attach to a real terminal from the agent context.

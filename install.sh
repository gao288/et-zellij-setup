#!/usr/bin/env bash
# Installer for et + zellij + zjpick across local Mac and remote Linux.
# Idempotent: re-running replaces the marked block in each managed file.
#
# Usage:
#   ./install.sh           # same as 'all'
#   ./install.sh local     # Mac side only
#   ./install.sh remote    # remote side only (ssh + sudo)
#   ./install.sh all       # both
#   ./install.sh -h        # help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="et-zellij-setup"
START_MARK="# >>> $TAG start >>>"
END_MARK="# <<< $TAG end <<<"

# ---------- helpers ----------

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { printf "  %s\n" "$*"; }
head() { printf "\n==> %s\n" "$*"; }

# Replace or append a block delimited by START_MARK / END_MARK in $1, content from stdin.
upsert_block() {
  local file="$1"
  local body; body="$(cat)"
  touch "$file"
  if grep -qF "$START_MARK" "$file" 2>/dev/null; then
    awk -v s="$START_MARK" -v e="$END_MARK" '
      $0==s { skip=1; next }
      $0==e { skip=0; next }
      !skip
    ' "$file" > "$file.tmp.$$"
    mv "$file.tmp.$$" "$file"
  fi
  {
    printf "\n%s\n" "$START_MARK"
    printf "%s\n"   "$body"
    printf "%s\n"   "$END_MARK"
  } >> "$file"
}

load_config() {
  local cfg="$SCRIPT_DIR/config.sh"
  [[ -f "$cfg" ]] || die "config.sh not found.
  Run: cp $SCRIPT_DIR/config.example.sh $SCRIPT_DIR/config.sh && \$EDITOR $SCRIPT_DIR/config.sh"
  # shellcheck disable=SC1090
  source "$cfg"
  for v in REMOTE_ALIAS REMOTE_HOST REMOTE_USER IDENTITY_FILE FORWARD_PORTS \
           ET_PORT REVERSE_PORT EDITORS_ENABLED; do
    [[ -n "${!v:-}" ]] || die "$v not set in config.sh"
  done
  IDENTITY_EXPANDED="${IDENTITY_FILE/#\~/$HOME}"
  PRIMARY_EDITOR="$(printf '%s\n' $EDITORS_ENABLED | head -1)"
}

# ---------- LOCAL (Mac) ----------

install_local() {
  head "Mac (local) install"

  command -v brew >/dev/null || die "Homebrew not found. Install from https://brew.sh first."

  # 1. brew packages
  if brew list et >/dev/null 2>&1; then
    info "✓ et already installed: $(et --version 2>/dev/null | head -1)"
  else
    info "installing et (compiles from source, 5–10 min on Apple Silicon)..."
    brew install MisterTea/et/et
    info "✓ et: $(et --version | head -1)"
  fi
  if brew list zellij >/dev/null 2>&1; then
    info "✓ zellij already installed: $(zellij --version)"
  else
    info "installing zellij..."
    brew install zellij
    info "✓ zellij: $(zellij --version)"
  fi
  if brew list socat >/dev/null 2>&1; then
    info "✓ socat already installed (open-remote dispatcher)"
  else
    info "installing socat (open-remote dispatcher)..."
    brew install socat
  fi
  local SOCAT_BIN="$(brew --prefix)/bin/socat"

  # 1b. Ensure editor CLIs are reachable for the enabled editors
  mkdir -p "$HOME/.local/bin"
  for ed in $EDITORS_ENABLED; do
    case "$ed" in
      zed)
        if command -v zed >/dev/null; then info "✓ zed CLI: $(command -v zed)"
        else info "! zed enabled but no 'zed' CLI on PATH — install via Zed: 'Install CLI' command"; fi ;;
      code)
        if command -v code >/dev/null; then info "✓ code CLI: $(command -v code)"
        else
          local vsc="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
          if [[ -x "$vsc" ]]; then
            ln -sf "$vsc" "$HOME/.local/bin/code"
            info "✓ code CLI: symlinked $vsc → ~/.local/bin/code"
          else
            info "! code enabled but VSCode app not found at $vsc"
          fi
        fi ;;
      cursor)
        if command -v cursor >/dev/null; then info "✓ cursor CLI: $(command -v cursor)"
        else
          local crs="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
          if [[ -x "$crs" ]]; then
            ln -sf "$crs" "$HOME/.local/bin/cursor"
            info "✓ cursor CLI: symlinked $crs → ~/.local/bin/cursor"
          else
            info "! cursor enabled but Cursor app not found at $crs"
          fi
        fi ;;
      *) info "! unknown editor in EDITORS_ENABLED: $ed (supported: zed code cursor)" ;;
    esac
  done

  # 1c. Write open-remote dispatcher
  local dispatcher="$HOME/.local/bin/open-remote.sh"
  cat > "$dispatcher" <<DISPATCHER_EOF
#!/usr/bin/env bash
# open-remote.sh — managed by et-zellij-setup.  socat invokes this per
# connection; we read "verb|path" on stdin and open the matching editor.
set -uo pipefail

REMOTE_ALIAS="$REMOTE_ALIAS"
PRIMARY="$PRIMARY_EDITOR"

read -r line
verb="\${line%%|*}"
path="\${line#*|}"
path="\${path%\$'\r'}"

[[ "\$path" = /* ]] || { echo "open-remote: invalid path: \$path" >&2; exit 1; }
[[ "\$verb" == "edit" ]] && verb="\$PRIMARY"

ZED="/usr/local/bin/zed"
VSCODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
CURSOR="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"

case "\$verb" in
  zed)    exec "\$ZED" "ssh://\$REMOTE_ALIAS\$path" ;;
  code)   exec "\$VSCODE" --remote "ssh-remote+\$REMOTE_ALIAS" "\$path" -r ;;
  cursor) exec "\$CURSOR" --remote "ssh-remote+\$REMOTE_ALIAS" "\$path" -r ;;
  *)      echo "open-remote: unknown verb: \$verb" >&2; exit 1 ;;
esac
DISPATCHER_EOF
  chmod +x "$dispatcher"
  info "✓ ~/.local/bin/open-remote.sh"

  # 1d. Write + reload launchd agent
  local plist="$HOME/Library/LaunchAgents/local.et-zellij-setup.open-remote.plist"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.et-zellij-setup.open-remote</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SOCAT_BIN</string>
    <string>TCP-LISTEN:$REVERSE_PORT,bind=127.0.0.1,reuseaddr,fork</string>
    <string>EXEC:$dispatcher</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/open-remote.out</string>
  <key>StandardErrorPath</key>
  <string>/tmp/open-remote.err</string>
</dict>
</plist>
PLIST_EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load -w "$plist"
  if lsof -nP -iTCP:$REVERSE_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    info "✓ launchd agent loaded, listening on 127.0.0.1:$REVERSE_PORT"
  else
    info "! launchd agent loaded but nothing on 127.0.0.1:$REVERSE_PORT — check /tmp/open-remote.err"
  fi

  # 2. ~/.ssh/config Host block
  mkdir -p ~/.ssh
  local ssh_block
  ssh_block="Host $REMOTE_ALIAS
    HostName $REMOTE_HOST
    User $REMOTE_USER
    IdentityFile $IDENTITY_FILE"
  printf "%s\n" "$ssh_block" | upsert_block ~/.ssh/config
  chmod 600 ~/.ssh/config
  info "✓ ~/.ssh/config: Host $REMOTE_ALIAS"

  # 3. ~/.zshrc block (templated via @PLACEHOLDER@).
  # NOTE: using `read -r -d ''` instead of `$(cat <<'X' ... X)` to dodge a
  # bash 3.2 parser bug that mis-handles apostrophes inside heredoc bodies
  # nested in command substitution. macOS ships bash 3.2 by default.
  local zrc_body=""
  IFS= read -r -d '' zrc_body <<'ZBLOCK' || true
# --- Eternal Terminal + zellij (managed by et-zellij-setup) ---
export ET_FORWARDS="@FORWARD_PORTS@"
export ET_REVERSE_PORT="@REVERSE_PORT@"   # remote `edit/zed/code/cursor` dispatch

unalias    zj zjlong zjx zjls zjkill zjto 2>/dev/null
unfunction zj zjlong zjx zjls zjkill zjto _zj_help _zj_free_forwards 2>/dev/null

# Filter ET_FORWARDS to only the pairs whose local port is currently free.
function _zj_free_forwards {
  local free="" dropped="" pair lport
  for pair in ${(s: :)ET_FORWARDS}; do
    lport="${pair%%:*}"
    if lsof -nP -iTCP:$lport -sTCP:LISTEN >/dev/null 2>&1; then
      dropped+=" $lport"
    else
      free+=" $pair"
    fi
  done
  [[ -n "$dropped" ]] && print -u2 "zj: local port(s) busy, skipping forward:$dropped"
  echo "${free# }"
}

function _zj_help {
  cat <<'HELP_EOF'

zj — Eternal Terminal + zellij helpers (Mac → @REMOTE_HOST@)

  PRIMARY  (port forwards 3000/18789/5800 follow the session, auto-skip if busy
            — plus reverse tunnel @REVERSE_PORT@ for remote `edit` → Mac editor)
    zj                 Interactive picker (running / resurrectable / new / shell)
    zj <name>          Attach or create <name> directly (skip picker)
    zjlong [name]      Same as zj, plus `caffeinate -i` (Mac won't idle-sleep)

  SECONDARY  (no forwards / no reverse tunnel — safe in additional windows)
    zjx                Picker, no forwards
    zjx <name>         Attach or create <name>, no forwards

  UTILITIES
    zjls               List remote zellij sessions (status + age)
    zjkill <name>      Kill a session (incl. clearing EXITED ones)

  REMOTE → MAC EDITOR (run on remote inside any zj pane)
    edit [path]        Open path (default $PWD) in primary editor on Mac
    zed [path]         → Zed via ssh://@REMOTE_ALIAS@/path
    code [path]        → VSCode via Remote-SSH
    cursor [path]      → Cursor via Remote-SSH

  HELP
    zj --help | -h     Show this message (also: zjlong -h, zjx -h)

  OTHER ACCESS
    ssh @REMOTE_ALIAS@        Plain ssh (no forwards). Ad-hoc forward:
                       ssh -L 3000:localhost:3000 @REMOTE_ALIAS@

  CONNECTION
    Endpoint           @REMOTE_HOST@:@ET_PORT@ (et)
    Survives           Mac sleep / lid-close (et reconnects, replays bytes)
    KKP / Shift+Enter  passes through end-to-end

HELP_EOF
}

function zj {
  case "${1:-}" in -h|--help) _zj_help; return 0 ;; esac
  local cmd
  if [[ -n "${1:-}" ]]; then cmd="zellij attach -c $1"; else cmd="zjpick"; fi
  local fwd="$(_zj_free_forwards)"
  local rev="$ET_REVERSE_PORT:$ET_REVERSE_PORT"
  if [[ -n "$fwd" ]]; then
    et @REMOTE_ALIAS@ -t "$fwd" -r "$rev" -c "$cmd"
  else
    print -u2 "zj: all forward ports busy — connecting bare (reverse tunnel still attempted)"
    et @REMOTE_ALIAS@ -r "$rev" -c "$cmd"
  fi
}

function zjlong {
  case "${1:-}" in -h|--help) _zj_help; return 0 ;; esac
  local cmd
  if [[ -n "${1:-}" ]]; then cmd="zellij attach -c $1"; else cmd="zjpick"; fi
  local fwd="$(_zj_free_forwards)"
  local rev="$ET_REVERSE_PORT:$ET_REVERSE_PORT"
  if [[ -n "$fwd" ]]; then
    caffeinate -i et @REMOTE_ALIAS@ -t "$fwd" -r "$rev" -c "$cmd"
  else
    print -u2 "zjlong: all forward ports busy — connecting bare (reverse tunnel still attempted)"
    caffeinate -i et @REMOTE_ALIAS@ -r "$rev" -c "$cmd"
  fi
}

function zjx {
  case "${1:-}" in -h|--help) _zj_help; return 0 ;; esac
  if [[ -n "${1:-}" ]]; then
    et @REMOTE_ALIAS@ -c "zellij attach -c $1"
  else
    et @REMOTE_ALIAS@ -c "zjpick"
  fi
}

function zjls   {
  case "${1:-}" in -h|--help) _zj_help; return 0 ;; esac
  et @REMOTE_ALIAS@ -c "zellij list-sessions"
}

function zjkill {
  case "${1:-}" in -h|--help) _zj_help; return 0 ;; esac
  et @REMOTE_ALIAS@ -c "zellij kill-session ${1:?usage: zjkill <name>}"
}
ZBLOCK

  zrc_body="${zrc_body//@FORWARD_PORTS@/$FORWARD_PORTS}"
  zrc_body="${zrc_body//@REMOTE_ALIAS@/$REMOTE_ALIAS}"
  zrc_body="${zrc_body//@REMOTE_HOST@/$REMOTE_HOST}"
  zrc_body="${zrc_body//@ET_PORT@/$ET_PORT}"
  zrc_body="${zrc_body//@REVERSE_PORT@/$REVERSE_PORT}"

  printf "%s" "$zrc_body" | upsert_block ~/.zshrc
  info "✓ ~/.zshrc: et+zellij block (reload with: source ~/.zshrc)"
}

# ---------- REMOTE (Linux) ----------

# Bash script that gets sent and executed on the remote host. Single-quoted
# heredoc — local bash does NOT expand variables here; remote bash does.
remote_script() {
  cat <<'REMOTE_EOF'
set -euo pipefail
TAG="et-zellij-setup"
START_MARK="# >>> $TAG start >>>"
END_MARK="# <<< $TAG end <<<"
info() { printf "  %s\n" "$*"; }

upsert_block() {
  local file="$1"; local body; body="$(cat)"
  touch "$file"
  if grep -qF "$START_MARK" "$file" 2>/dev/null; then
    awk -v s="$START_MARK" -v e="$END_MARK" '$0==s{skip=1;next} $0==e{skip=0;next} !skip' "$file" > "$file.tmp.$$"
    mv "$file.tmp.$$" "$file"
  fi
  { printf "\n%s\n" "$START_MARK"; printf "%s\n" "$body"; printf "%s\n" "$END_MARK"; } >> "$file"
}

echo "==> Remote install on $(hostname)"

# 1. et + etserver via PPA
if ! command -v etserver >/dev/null 2>&1; then
  info "installing et (PPA + apt, will prompt for sudo)..."
  sudo add-apt-repository -y ppa:jgmath2000/et
  sudo apt-get update -qq
  sudo apt-get install -y et
fi
if ! systemctl is-active et >/dev/null 2>&1; then
  sudo systemctl enable --now et
fi
info "✓ et:       $(et --version | head -1)"
info "✓ etserver: $(systemctl is-active et) on $(ss -tln 2>/dev/null | awk '/:2022/{print $4; exit}')"

# 2. zellij static binary
if [[ ! -x "$HOME/.local/bin/zellij" ]]; then
  info "installing zellij to ~/.local/bin..."
  mkdir -p "$HOME/.local/bin"
  cd /tmp
  curl -fsSL https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz -o zellij.tar.gz
  tar -xzf zellij.tar.gz
  install -m755 zellij "$HOME/.local/bin/zellij"
  rm -f zellij.tar.gz zellij
fi
info "✓ zellij:   $("$HOME/.local/bin/zellij" --version)"

# 3. ~/.zshenv — PATH for non-interactive shells
printf '%s\n' \
  '# Ensure ~/.local/bin is on PATH for non-interactive shells (et -c, ssh cmd, etc.)' \
  'export PATH="$HOME/.local/bin:$PATH"' \
  | upsert_block "$HOME/.zshenv"
info "✓ ~/.zshenv: PATH block"

# 4. ~/.zshrc — KKP pop hook + edit/zed/code/cursor dispatch
upsert_block "$HOME/.zshrc" <<'ZRC_REMOTE_EOF'
# --- KKP safety net for zellij detach/attach desync ---
# Pops one KKP enhancement-stack level on each prompt. Inner apps re-push
# their own level. Only enable from KKP-capable terminals (Ghostty/Kitty/WezTerm).
_kkp_pop() { printf "\e[<u" }
precmd_functions+=(_kkp_pop)

# --- Open current dir / arg on Mac via et reverse tunnel ---
# A launchd agent on the Mac listens on this port (socat → open-remote.sh)
# and dispatches to Zed / VSCode / Cursor with ssh-remote into REMOTE_ALIAS.
# Requires the zj/zjlong reverse tunnel to be up (default in those helpers).
# Uses zsh's built-in TCP module (zsh/net/tcp). /dev/tcp/... is bash-only
# and would fail under zsh — this works the same way without a subshell.
export ET_REVERSE_PORT="@REVERSE_PORT@"
_edit_send() {
  emulate -L zsh
  local verb="$1" p="$(realpath -- "${2:-$PWD}")"
  zmodload -F zsh/net/tcp b:ztcp 2>/dev/null || {
    print -u2 "edit: zsh/net/tcp module unavailable on this zsh"; return 1
  }
  if ! ztcp 127.0.0.1 $ET_REVERSE_PORT 2>/dev/null; then
    print -u2 "edit: no listener on 127.0.0.1:$ET_REVERSE_PORT — zj reverse tunnel up? Mac launchd agent loaded?"
    return 1
  fi
  printf '%s|%s\n' "$verb" "$p" >&$REPLY
  ztcp -c $REPLY
}
edit()   { _edit_send edit   "$@" }
zed()    { _edit_send zed    "$@" }
code()   { _edit_send code   "$@" }
cursor() { _edit_send cursor "$@" }
ZRC_REMOTE_EOF
info "✓ ~/.zshrc: KKP hook + edit dispatch block"

# 5. zjpick (uploaded separately to $HOME/.cache/zjpick.upload)
if [[ -f "$HOME/.cache/zjpick.upload" ]]; then
  mkdir -p "$HOME/.local/bin"
  install -m755 "$HOME/.cache/zjpick.upload" "$HOME/.local/bin/zjpick"
  rm -f "$HOME/.cache/zjpick.upload"
  info "✓ ~/.local/bin/zjpick installed"
else
  echo "  ! zjpick.upload not found at $HOME/.cache/zjpick.upload — picker NOT installed" >&2
fi

echo "==> Remote install done"
REMOTE_EOF
}

install_remote() {
  head "Remote install via ssh $REMOTE_USER@$REMOTE_HOST (sudo may prompt for password)"

  [[ -f "$SCRIPT_DIR/zjpick" ]] || die "zjpick not found in $SCRIPT_DIR"

  local ssh_opts=(-i "$IDENTITY_EXPANDED" -o StrictHostKeyChecking=accept-new)
  local target="$REMOTE_USER@$REMOTE_HOST"

  # Upload zjpick to ~/.cache/ (remote install script picks it up)
  info "uploading zjpick..."
  ssh "${ssh_opts[@]}" "$target" "mkdir -p ~/.cache" >/dev/null
  scp -q "${ssh_opts[@]}" "$SCRIPT_DIR/zjpick" "$target:~/.cache/zjpick.upload"

  # Stream the install script over ssh -t so sudo can prompt.
  # Substitute @REVERSE_PORT@ in the remote script before sending so the
  # remote zshrc block carries the resolved port literal.
  info "running remote installer..."
  local rscript
  rscript="$(remote_script)"
  rscript="${rscript//@REVERSE_PORT@/$REVERSE_PORT}"
  printf '%s' "$rscript" | ssh -t "${ssh_opts[@]}" "$target" 'bash -s'
}

# ---------- main ----------

usage() {
  cat <<EOF
Usage: $(basename "$0") [local|remote|all]

  local    Install Mac side: brew (et+zellij), ~/.ssh/config, ~/.zshrc helpers
  remote   Install remote side via ssh: apt (etserver), zellij binary,
           ~/.zshenv (PATH), ~/.zshrc (KKP hook), ~/.local/bin/zjpick
  all      Both (default). Local first, then remote.

Requires config.sh — copy config.example.sh and edit.
EOF
}

main() {
  case "${1:-all}" in
    -h|--help) usage; exit 0 ;;
    local)  load_config; install_local  ;;
    remote) load_config; install_remote ;;
    all)    load_config; install_local; install_remote ;;
    *)      usage; exit 1 ;;
  esac
  printf "\n==> All done.  Reload Mac shell with:  source ~/.zshrc\n"
}

main "$@"

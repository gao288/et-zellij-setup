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
  for v in REMOTE_ALIAS REMOTE_HOST REMOTE_USER IDENTITY_FILE FORWARD_PORTS ET_PORT; do
    [[ -n "${!v:-}" ]] || die "$v not set in config.sh"
  done
  IDENTITY_EXPANDED="${IDENTITY_FILE/#\~/$HOME}"
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

  PRIMARY  (port forwards 3000/18789/5800 follow the session, auto-skip if busy)
    zj                 Interactive picker (running / resurrectable / new / shell)
    zj <name>          Attach or create <name> directly (skip picker)
    zjlong [name]      Same as zj, plus `caffeinate -i` (Mac won't idle-sleep)

  SECONDARY  (no forwards — safe to open in additional windows)
    zjx                Picker, no forwards
    zjx <name>         Attach or create <name>, no forwards

  UTILITIES
    zjls               List remote zellij sessions (status + age)
    zjkill <name>      Kill a session (incl. clearing EXITED ones)

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
  if [[ -n "$fwd" ]]; then
    et @REMOTE_ALIAS@ -t "$fwd" -c "$cmd"
  else
    print -u2 "zj: all forward ports busy — connecting bare"
    et @REMOTE_ALIAS@ -c "$cmd"
  fi
}

function zjlong {
  case "${1:-}" in -h|--help) _zj_help; return 0 ;; esac
  local cmd
  if [[ -n "${1:-}" ]]; then cmd="zellij attach -c $1"; else cmd="zjpick"; fi
  local fwd="$(_zj_free_forwards)"
  if [[ -n "$fwd" ]]; then
    caffeinate -i et @REMOTE_ALIAS@ -t "$fwd" -c "$cmd"
  else
    print -u2 "zjlong: all forward ports busy — connecting bare"
    caffeinate -i et @REMOTE_ALIAS@ -c "$cmd"
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
sudo systemctl enable --now et
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

# 4. ~/.zshrc — KKP pop hook
printf '%s\n' \
  '# KKP pop on each prompt — safety net for zellij detach/attach desync.' \
  '# Pops one KKP enhancement-stack level. Inner apps re-push their own level.' \
  '# Only enable from KKP-capable terminals (Ghostty/Kitty/WezTerm).' \
  '_kkp_pop() { printf "\e[<u" }' \
  'precmd_functions+=(_kkp_pop)' \
  | upsert_block "$HOME/.zshrc"
info "✓ ~/.zshrc: KKP hook block"

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

  # Stream the install script over ssh -t so sudo can prompt
  info "running remote installer..."
  remote_script | ssh -t "${ssh_opts[@]}" "$target" 'bash -s'
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

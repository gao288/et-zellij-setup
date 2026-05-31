# et-zellij-setup config — copy to config.sh and edit for your environment.
#   cp config.example.sh config.sh
#   $EDITOR config.sh

# SSH alias that et and ssh will both use. Added to ~/.ssh/config.
REMOTE_ALIAS="gxfet"

# Tailscale MagicDNS hostname (or IP) of the remote machine.
REMOTE_HOST="xufei-pc.tail110452.ts.net"

# User on the remote.
REMOTE_USER="gao288"

# Local SSH private key. ~ is expanded.
IDENTITY_FILE="~/.ssh/id_ed25519_nopass"

# Port forwards that follow the et session (space-separated local:remote pairs).
# zj auto-skips any whose local port is already busy.
FORWARD_PORTS="3000:3000 18789:18789 5800:5800"

# etserver TCP port. Default 2022.
ET_PORT="2022"

# --- Open-on-Mac dispatcher (`edit`, `zed`, `code`, `cursor` from remote) ---

# Reverse tunnel port. `zj` / `zjlong` add `et -r $REVERSE_PORT:$REVERSE_PORT`
# so remote `edit <path>` can write back to a launchd agent on this Mac that
# opens the appropriate editor against ssh://REMOTE_ALIAS/<path>.
REVERSE_PORT="8123"

# Which editors to wire up. Space-separated.  Supported: zed, code, cursor.
# The first one in this list is the default target for bare `edit` (no
# verb-specific alias) from the remote.
EDITORS_ENABLED="zed code"

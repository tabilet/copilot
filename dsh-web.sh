#!/usr/bin/env bash
# dsh-web — run the remote dsh web UI and open it in your local browser.
#
# One SSH connection does both halves: it forwards a local port to the
# remote server's loopback, and starts `dsh web` over that same session.
# Closing the connection (Ctrl-C, or quitting the browser tab and then
# Ctrl-C) stops the remote process too.
#
# Usage:
#   ./dsh-web.sh                      # host from $DSH_WEB_REMOTE
#   ./dsh-web.sh peter@example.com    # or pass it explicitly
#   ./dsh-web.sh myhost -- --trusted-host foo   # args after -- reach `dsh web`
#
# Environment:
#   DSH_WEB_REMOTE       user@host, or an ~/.ssh/config alias (required)
#   DSH_WEB_REMOTE_PORT  port dsh binds on the server     (default 3080)
#   DSH_WEB_LOCAL_PORT   local end of the tunnel          (default: first
#                        free port at or above the remote port)
#   DSH_WEB_OPEN         0 to skip opening a browser      (default 1)
#
# Install: copy to ~/.local/bin/dsh-web and chmod +x.

set -euo pipefail

REMOTE_PORT="${DSH_WEB_REMOTE_PORT:-3080}"
OPEN_BROWSER="${DSH_WEB_OPEN:-1}"
REMOTE="${DSH_WEB_REMOTE:-}"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

case "${1-}" in
    -h | --help)
        usage
        exit 0
        ;;
    --) ;;
    -*)
        echo "dsh-web: unknown option $1" >&2
        exit 2
        ;;
    ?*)
        REMOTE="$1"
        shift
        ;;
esac
[ "${1-}" = "--" ] && shift

if [ -z "$REMOTE" ]; then
    echo "dsh-web: no remote host. Pass one, or set DSH_WEB_REMOTE." >&2
    echo "         e.g. DSH_WEB_REMOTE=peter@example.com dsh-web" >&2
    exit 2
fi

# A port is "taken" if something on loopback accepts a connection there.
port_taken() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

LOCAL_PORT="${DSH_WEB_LOCAL_PORT:-}"
if [ -z "$LOCAL_PORT" ]; then
    LOCAL_PORT="$REMOTE_PORT"
    while port_taken "$LOCAL_PORT"; do
        LOCAL_PORT=$((LOCAL_PORT + 1))
        if [ "$LOCAL_PORT" -gt $((REMOTE_PORT + 20)) ]; then
            echo "dsh-web: no free local port near $REMOTE_PORT" >&2
            exit 1
        fi
    done
elif port_taken "$LOCAL_PORT"; then
    echo "dsh-web: local port $LOCAL_PORT is already in use" >&2
    exit 1
fi

URL="http://127.0.0.1:${LOCAL_PORT}"

# `dsh` lives under nvm, whose PATH setup only runs for interactive
# shells — so a plain `ssh host dsh` would not find it. Load nvm first
# when the bare command is missing.
extra=""
[ "$#" -gt 0 ] && extra="$(printf ' %q' "$@")"
remote_cmd="
if ! command -v dsh >/dev/null 2>&1; then
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" >/dev/null 2>&1
fi
command -v dsh >/dev/null 2>&1 || {
    echo 'dsh-web: dsh not found on the remote PATH' >&2
    exit 127
}
exec dsh web --port ${REMOTE_PORT}${extra}
"

# Wait for the forwarded port to answer, then hand the URL to the browser.
open_when_ready() {
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if port_taken "$LOCAL_PORT"; then
            if command -v xdg-open >/dev/null 2>&1; then
                xdg-open "$URL" >/dev/null 2>&1 || true
            elif command -v open >/dev/null 2>&1; then
                open "$URL" >/dev/null 2>&1 || true
            fi
            return
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# Backgrounded before the exec below replaces this shell: it opens the
# browser once the tunnel answers, and gives up by itself after 60s.
[ "$OPEN_BROWSER" != "0" ] && open_when_ready &

echo "dsh-web: $REMOTE  ${LOCAL_PORT} -> 127.0.0.1:${REMOTE_PORT}"
echo "dsh-web: $URL   (Ctrl-C here stops the remote server)"

exec ssh -t \
    -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    "$REMOTE" "$remote_cmd"

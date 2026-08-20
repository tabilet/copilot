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
#   ./dsh-web.sh --replace myhost     # stop a stale server holding the port
#
# Environment:
#   DSH_WEB_REMOTE   user@host, or an ~/.ssh/config alias (required)
#   DSH_WEB_PORT     port used on BOTH ends                (default 3080)
#   DSH_WEB_OPEN     0 to skip opening a browser           (default 1)
#   DSH_WEB_REPLACE  1 to stop a server already holding the remote port
#                    (same as --replace; default 0, which reports and exits)
#
# Both ends use the same port number on purpose. The web UI fences its
# /api routes to its own authority, so a browser reaching it through a
# tunnel on a different local port is answered with 403 on every API
# call and both event WebSockets — a page that renders and then spins
# forever. Browse the printed 127.0.0.1 URL for the same reason:
# http://localhost:PORT is a different authority and is refused too.
#
# Install: copy to ~/.local/bin/dsh-web and chmod +x.

set -euo pipefail

PORT="${DSH_WEB_PORT:-${DSH_WEB_REMOTE_PORT:-3080}}"
OPEN_BROWSER="${DSH_WEB_OPEN:-1}"
REMOTE="${DSH_WEB_REMOTE:-}"
REPLACE="${DSH_WEB_REPLACE:-0}"

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

host_seen=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --replace)
            REPLACE=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "dsh-web: unknown option $1" >&2
            exit 2
            ;;
        *)
            [ "$host_seen" = 1 ] && break
            REMOTE="$1"
            host_seen=1
            shift
            ;;
    esac
done

if [ -z "$REMOTE" ]; then
    echo "dsh-web: no remote host. Pass one, or set DSH_WEB_REMOTE." >&2
    echo "         e.g. DSH_WEB_REMOTE=peter@example.com dsh-web" >&2
    exit 2
fi

# A port is "taken" if something on loopback accepts a connection there.
port_taken() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# If this port is busy locally, move BOTH ends to the next free number:
# the server has to bind whatever the browser will address it by.
start_port="$PORT"
while port_taken "$PORT"; do
    PORT=$((PORT + 1))
    if [ "$PORT" -gt $((start_port + 20)) ]; then
        echo "dsh-web: no free local port near $start_port" >&2
        exit 1
    fi
done
[ "$PORT" = "$start_port" ] ||
    echo "dsh-web: local $start_port busy; using $PORT on both ends" >&2

URL="http://127.0.0.1:${PORT}"

# The remote port matters as much as the local one: if something already
# holds it, our `dsh web` dies with EADDRINUSE *after* the tunnel is up,
# and the browser silently reaches the other process instead. Check
# first, over its own connection, and say who has it.
remote_probe="
if (exec 3<>/dev/tcp/127.0.0.1/${PORT}) 2>/dev/null; then
    echo BUSY
    ss -ltnp \"sport = :${PORT}\" 2>/dev/null | grep -oE 'pid=[0-9]+' |
        cut -d= -f2 | sort -u |
        while read -r p; do ps -o pid=,cmd= -p \"\$p\" 2>/dev/null; done
else
    echo FREE
fi
"
probe_out="$(ssh "$REMOTE" "$remote_probe")" || {
    echo "dsh-web: could not reach $REMOTE" >&2
    exit 1
}
if [ "${probe_out%%$'\n'*}" = "BUSY" ]; then
    holder="$(printf '%s\n' "$probe_out" | tail -n +2)"
    if [ "$REPLACE" != "1" ]; then
        echo "dsh-web: port $PORT on $REMOTE is already in use by:" >&2
        printf '%s\n' "${holder:-  (owner not visible: it may belong to another user)}" >&2
        echo "dsh-web: use --replace to stop it, or set DSH_WEB_PORT to another port" >&2
        exit 1
    fi
    echo "dsh-web: --replace: stopping the process holding $PORT on $REMOTE" >&2
    printf '%s\n' "$holder" >&2
    ssh "$REMOTE" "
        pids=\$(ss -ltnp \"sport = :${PORT}\" 2>/dev/null |
            grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
        [ -n \"\$pids\" ] && kill \$pids 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            (exec 3<>/dev/tcp/127.0.0.1/${PORT}) 2>/dev/null || exit 0
            sleep 1
        done
        exit 1
    " || {
        echo "dsh-web: port $PORT on $REMOTE did not free up" >&2
        exit 1
    }
fi

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
exec dsh web --port ${PORT}${extra}
"

# Wait for the forwarded port to answer, then hand the URL to the browser.
open_when_ready() {
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if port_taken "$PORT"; then
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

echo "dsh-web: $REMOTE  ${PORT} -> 127.0.0.1:${PORT}"
echo "dsh-web: $URL   (Ctrl-C here stops the remote server)"

exec ssh -t \
    -L "${PORT}:127.0.0.1:${PORT}" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    "$REMOTE" "$remote_cmd"

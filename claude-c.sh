# claude-c.sh — Claude Code CLI routed through a local copilot-api proxy,
# so REPL sessions bill against a GitHub Copilot subscription instead of
# api.anthropic.com.
#
# Source it from ~/.profile (or ~/.bashrc / ~/.zshrc):
#
#     . /path/to/claude-c.sh
#
# Then:
#     claude-c [args...]    # Claude Code, Copilot-billed
#     claude-d [args...]    # same binary, Anthropic-billed
#
# Requires bash or zsh: the function names contain a hyphen, which POSIX
# sh (dash) rejects.
#
# No credentials belong in this file. copilot-api authenticates upstream
# with the GitHub OAuth token it stores itself, and ANTHROPIC_AUTH_TOKEN
# is a placeholder the proxy ignores.
#
# Every setting below can be overridden by exporting it before sourcing.

: "${CLAUDE_C_BIN:=$HOME/.local/bin/claude}"
: "${CLAUDE_C_CONFIG_DIR:=$HOME/.claude-copilot}"
: "${CLAUDE_C_BASE_URL:=http://localhost:4141}"
: "${CLAUDE_C_EFFORT:=high}"

# Model aliases. Each must be an id the gateway actually serves — check
# with:  curl -s "$CLAUDE_C_BASE_URL/v1/models" | jq -r '.data[].id'
# A stale id here fails every call with `model_not_supported`.
: "${CLAUDE_C_MODEL:=claude-fable-5}"
: "${CLAUDE_C_SONNET_MODEL:=claude-sonnet-5}"
: "${CLAUDE_C_FAST_MODEL:=gemini-3.7-flash}"

# Resolve the Claude Code binary: CLAUDE_C_BIN if it is executable,
# otherwise whatever `claude` is on PATH.
_claude_c_bin() {
    if [ -x "$CLAUDE_C_BIN" ]; then
        printf '%s\n' "$CLAUDE_C_BIN"
    else
        command -v claude
    fi
}

# Copilot-billed. The subshell body keeps the exports out of the caller's
# environment; `exec` avoids leaving a wrapper process behind.
claude-c() (
    bin=$(_claude_c_bin) || {
        echo "claude-c: no claude binary found; set CLAUDE_C_BIN" >&2
        exit 127
    }
    export CLAUDE_CONFIG_DIR="$CLAUDE_C_CONFIG_DIR" \
        ANTHROPIC_BASE_URL="$CLAUDE_C_BASE_URL" \
        ANTHROPIC_AUTH_TOKEN=dummy \
        ANTHROPIC_MODEL="$CLAUDE_C_MODEL" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$CLAUDE_C_SONNET_MODEL" \
        ANTHROPIC_SMALL_FAST_MODEL="$CLAUDE_C_FAST_MODEL" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$CLAUDE_C_FAST_MODEL" \
        DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    exec "$bin" --effort "$CLAUDE_C_EFFORT" "$@"
)

# Anthropic-billed: same binary with every Copilot-mode variable stripped,
# so it uses stock ~/.claude state and api.anthropic.com.
claude-d() (
    bin=$(_claude_c_bin) || {
        echo "claude-d: no claude binary found; set CLAUDE_C_BIN" >&2
        exit 127
    }
    exec env \
        -u CLAUDE_CONFIG_DIR \
        -u ANTHROPIC_BASE_URL \
        -u ANTHROPIC_AUTH_TOKEN \
        -u ANTHROPIC_MODEL \
        -u ANTHROPIC_DEFAULT_SONNET_MODEL \
        -u ANTHROPIC_SMALL_FAST_MODEL \
        -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
        -u DISABLE_NON_ESSENTIAL_MODEL_CALLS \
        -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
        "$bin" "$@"
)

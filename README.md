# Using GitHub Copilot as an LLM Backend for Terminal CLIs

Language versions: [🇨🇳 中文](README_cn.md).

Two CLIs let you drive an LLM session from your terminal and bill it
to your **GitHub Copilot subscription** instead of paying Anthropic
or OpenAI directly:

| CLI | Binary | Backend | Style |
|---|---|---|---|
| `copilot` | `~/.local/bin/copilot` | GitHub Copilot CLI (official) | GitHub-native, agentic, skill-driven |
| `claude-c` | shell function in `~/.profile` | Claude Code CLI through a local OpenAI-compatible proxy | Claude Code feel, model routing under your control |

Both ultimately consume your Copilot quota. Pick the one that fits the
job.

---

## 1. `copilot` — the official GitHub Copilot CLI

### Install

The binary is a single self-contained executable. Drop it on `PATH`:

```bash
# ~/.local/bin/copilot is already a 149 MB executable
chmod +x ~/.local/bin/copilot
copilot --version
# GitHub Copilot CLI 1.0.42.
```

That's it. There is no proxy, no config dance, no model routing to
think about.

### First run

```bash
copilot
```

The first invocation prints a URL and a **6-letter device code**. Open
the URL in a browser, paste the code, and approve the OAuth grant on
GitHub. After that you're dropped into an interactive setup where you
choose:

1. **LLM Mode** — which provider/family to default to (Claude, GPT,
   Gemini, etc.).
2. **Small Model** — the cheaper model used for background calls
   (subagents, fast checks, completions).

These choices are persisted, so subsequent runs go straight into the
session.

---

## 2. `claude-c` — Claude Code routed through `copilot-api`

This one is **deliberately the Claude Code CLI**, just rewired so its
HTTP traffic terminates at a local proxy that translates between the
Anthropic protocol and GitHub Copilot's OpenAI-flavored API. You get
the standard `claude` REPL, slash commands, and key bindings —
billed against Copilot.

### Component layout

```
~/.local/bin/claude    →  Claude Code CLI (Anthropic's binary)
copilot-api            →  Node tool from npm; OpenAI-compatible proxy
                          for GitHub Copilot, listens on :4141 by default
~/.profile             →  defines the `claude-c` shell function that
                          glues the two together
~/.claude-copilot/     →  separate CLAUDE_CONFIG_DIR so Copilot-mode
                          state (sessions, plans, history) does not
                          collide with stock `claude`
```

### Install — what actually happened, step by step

#### Step 1 — Install Claude Code itself

The Claude Code CLI is already on disk:

```
~/.local/bin/claude → ~/.local/share/claude/versions/2.1.126
```

Install it via the official installer if you don't have it; nothing
about that step is Copilot-specific.

#### Step 2 — Install `copilot-api`

```bash
npm install -g copilot-api
which copilot-api
# /home/user/.nvm/versions/node/v24.14.1/bin/copilot-api
```

#### Step 3 — Authenticate `copilot-api` against GitHub

```bash
copilot-api auth
```

This prints a URL and a **6-letter device code**, exactly like the
`copilot` CLI flow above. Approve the OAuth grant in the browser.
The token is written to:

```
~/.local/share/copilot-api/github_token
```

(Mode `0600`. If the file exists, future runs skip the OAuth flow and
reuse the token.)

> Step 3 is optional — `copilot-api start` will run the same OAuth flow
> on first launch if no token exists.

#### Step 4 — Start the proxy

```bash
copilot-api start                 # default port 4141
# or, to print a ready-made `claude` launch command with the Copilot env baked in:
copilot-api start --claude-code
```

On startup the proxy logs `Logged in as <your-gh-handle>` and prints
the list of upstream models it can route to — including
`claude-opus-4.6`, `claude-opus-4.7`, `claude-sonnet-4.6`,
`gemini-3-flash-preview`, `gpt-5.x`, and many more. Leave it running
(`tmux`, `systemd --user`, or just a background terminal — whatever
you prefer).

For an unattended setup, drop the bundled
[`copilot-api.service`](copilot-api.service) into
`~/.config/systemd/user/` and let `systemd --user` keep the proxy
alive across reboots:

```bash
cp copilot-api.service ~/.config/systemd/user/
# edit the ExecStart path if your `which copilot-api` is different
systemctl --user daemon-reload
systemctl --user enable --now copilot-api.service
systemctl --user status copilot-api.service     # confirm it's running
journalctl --user -u copilot-api.service -f      # tail logs
```

The unit declares `Restart=on-failure` with a 5 s back-off, so a
transient crash does not require manual intervention. To stop or
disable it later:

```bash
systemctl --user stop copilot-api.service
systemctl --user disable copilot-api.service
```

#### Step 5 — Carve out a separate config dir for Claude Code

This step is the subtle one. Stock `claude` writes its sessions, plan
files, project history, and settings under `~/.claude/`. If you point
the same binary at a different backend, the two states will mix
(prompt cache assumptions break, tool permissions get confused,
sessions overlap in the picker). The fix is to give Copilot-mode its
own root:

```bash
mkdir -p ~/.claude-copilot
```

`CLAUDE_CONFIG_DIR=~/.claude-copilot` will isolate everything written
during Copilot-mode runs — `sessions/`, `projects/`, `plans/`,
`settings.json`, etc. — without touching `~/.claude/`.

#### Step 6 — Define `claude-c` in `~/.profile`

This is the glue. The function:

- exports `ANTHROPIC_BASE_URL=http://localhost:4141` so Claude Code
  talks to the local proxy instead of `api.anthropic.com`,
- sets `ANTHROPIC_AUTH_TOKEN=dummy` (the proxy ignores it; your
  GitHub OAuth token does the real authentication upstream),
- pins each Claude Code model alias to a concrete Copilot-side model
  (`ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
  `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`) —
  this is how you choose, per alias, which model burns your
  Copilot quota,
- sets `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` and
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` so Claude Code does
  not spend quota on telemetry-style background pings,
- wraps everything in a subshell `( ... )` so the env exports do not
  leak back into your interactive shell,
- finally `exec`s `claude` so there is no extra wrapper process.

The exact function as installed:

```bash
claude-c() (
    export CLAUDE_CONFIG_DIR="$HOME/.claude-copilot" \
        ANTHROPIC_BASE_URL=http://localhost:4141 \
        ANTHROPIC_AUTH_TOKEN=dummy \
        ANTHROPIC_MODEL=claude-opus-4.7 \
        ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4.6 \
        ANTHROPIC_SMALL_FAST_MODEL=gemini-3-flash-preview \
        ANTHROPIC_DEFAULT_HAIKU_MODEL=gemini-3-flash-preview \
        DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    exec /home/user/.local/bin/claude "$@"
)

# inverse: same binary, talking to api.anthropic.com on Anthropic credits
alias claude-d='unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL DISABLE_NON_ESSENTIAL_MODEL_CALLS CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC && /home/user/.local/bin/claude'
```

Source the profile (`. ~/.profile` or open a new shell), make sure
`copilot-api start` is running, and:

```bash
claude-c                  # Claude Code, Copilot-billed
claude-d                  # Claude Code, Anthropic-billed
```

---

## When to use which

Both spend the same Copilot quota. They feel different.

### `claude-c` — pros

- **Familiar**. If you already use Claude Code daily, `claude-c` is
  the same REPL, same slash commands, same plan-mode UX, same key
  bindings. Nothing to relearn.
- **Per-alias model routing**. The four `ANTHROPIC_*_MODEL` env vars
  let you decide that Opus = the strongest model, Haiku = the
  cheapest, etc. — and you can change the mapping by editing one
  line of `~/.profile`.
- **Isolated state**. `CLAUDE_CONFIG_DIR=~/.claude-copilot` keeps
  Copilot-mode sessions, plans, and settings separate from your
  stock-Anthropic Claude Code workspace. You can switch back and
  forth (`claude-c` ↔ `claude-d`) without the two histories ever
  contaminating each other.
- **Local proxy, full visibility**. `copilot-api` runs on your
  machine; `--verbose` shows every request, model, and token count.
  Easy to debug, easy to rate-limit (`-r`), easy to point at a
  different account type (`-a business`).

### `copilot` — pros

- **Zero plumbing**. One binary, one OAuth flow, one interactive
  picker. No proxy to keep alive, no env vars to manage, no separate
  config dir.
- **Native GitHub integration**. Out of the box it knows how to
  reason about repos, PRs, issues, and Actions runs without an MCP
  bridge — because it's GitHub's own client.
- **Bundled skills and agents**. The CLI ships with curated
  skills/automations and an agent runtime that can chain tool
  calls for common engineering tasks (review-this-PR, run-CI-on-fix,
  triage-this-issue) without you wiring anything up.
- **Officially supported**. Updates land via `copilot update`; the
  contract with GitHub Copilot is stable by definition because GitHub
  ships both ends.

### Rule of thumb

- Reach for **`claude-c`** when the work is pure code/text and you
  want the Claude Code experience you already know — planning,
  editing, multi-step refactors, deep file-tree exploration.
- Reach for **`copilot`** when the work is GitHub-shaped — touching
  PRs, issues, Actions, repo metadata — or when you want to invoke
  one of GitHub's pre-canned agentic skills.

You can keep both installed; they don't conflict.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `claude-c` hangs on first request | `copilot-api start` isn't running | Start the proxy in another terminal / under tmux |
| `connection refused` to `:4141` | Port collision | `copilot-api start -p <other-port>` and update `ANTHROPIC_BASE_URL` to match |
| Session list mixes Copilot and Anthropic chats | `CLAUDE_CONFIG_DIR` wasn't set | Re-source `~/.profile`; verify `echo $CLAUDE_CONFIG_DIR` inside `claude-c` |
| Quota burns faster than expected | Background telemetry calls | Confirm `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` are exported |
| `copilot-api auth` keeps re-prompting | Token file has wrong permissions or is corrupt | `chmod 600 ~/.local/share/copilot-api/github_token`; if corrupt, delete and re-auth |
| `copilot` opens auth flow on every run | Login state lost | Re-run interactive setup; pick LLM Mode + Small Model again |

Check current Copilot usage at any time:

```bash
copilot-api check-usage
```

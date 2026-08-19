# Using the Claude CLI with a GitHub Copilot Subscription

Language versions: [🇨🇳 中文](README_cn.md).

This recipe wires the **Claude Code CLI** to a local proxy that
translates between the Anthropic protocol and GitHub Copilot's
OpenAI-flavored API. Your Claude REPL sessions then bill against your
**GitHub Copilot subscription** instead of `api.anthropic.com`.

> GitHub also ships a first-party `copilot` CLI — a single binary that
> talks to Copilot natively, exposes its tools through MCP, and bundles
> agentic skills (review-PR, run-CI-on-fix, triage-issue). Reach for
> that when the work is GitHub-shaped. The recipe below is for everyone
> who wants the familiar Claude Code REPL.

---

## `claude-c` — Claude Code routed through `copilot-api`

You get the standard `claude` REPL, slash commands, and key bindings —
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
~/.local/bin/claude → ~/.local/share/claude/versions/2.1.158
```

Install it via the official installer if you don't have it; nothing
about that step is Copilot-specific.

#### Step 2 — Install `copilot-api`

We use the **`@jeffreycao/copilot-api`** fork, which adds native
Anthropic-Messages support, exposes newer upstream models
(`claude-fable-5`, `claude-opus-5`, `claude-sonnet-5`, `gpt-5.6-sol`,
`gpt-5.3-codex`, `kimi-k3`, `grok-4.6`), and ships a built-in usage
dashboard. The local setup here is on `@jeffreycao/copilot-api@2.2.7`.

```bash
npm install -g @jeffreycao/copilot-api
which copilot-api
# /home/peter/.nvm/versions/node/v24.14.1/bin/copilot-api
```

The installed binary is still called `copilot-api`, so the rest of
this guide and the bundled systemd unit work unchanged. The original
`copilot-api` (ericc-ch) is wire-compatible if you prefer it; just
swap the install line.

#### Step 3 — Authenticate `copilot-api` against GitHub

```bash
copilot-api auth
```

This prints a URL and a **6-letter device code**. Approve the OAuth
grant in the browser. The token is written to:

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
the list of upstream models it can route to. It also exposes a live
usage dashboard at:

```
http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

Leave the proxy running (`tmux`, `systemd --user`, or just a
background terminal — whatever you prefer).

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
- finally `exec`s `claude --effort high` so there is no extra wrapper
  process and the default session asks for high effort.

The exact function as installed:

```bash
claude-c() (
    export CLAUDE_CONFIG_DIR="$HOME/.claude-copilot" \
        ANTHROPIC_BASE_URL=http://localhost:4141 \
        ANTHROPIC_AUTH_TOKEN=dummy \
        ANTHROPIC_MODEL=claude-fable-5 \
        ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5 \
        ANTHROPIC_SMALL_FAST_MODEL=gemini-3.7-flash \
        ANTHROPIC_DEFAULT_HAIKU_MODEL=gemini-3.7-flash \
        DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    exec /home/peter/.local/bin/claude --effort high "$@"
)

# inverse: same binary, talking to api.anthropic.com on Anthropic credits
alias claude-d='unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL DISABLE_NON_ESSENTIAL_MODEL_CALLS CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC && /home/peter/.local/bin/claude'
```

> **Note:** the two fast-lane aliases must name a model that is on the
> current gateway list. Copilot dropped `claude-haiku-4.5`, and anything
> the gateway no longer exposes fails every background call with
> `model_not_supported`. This setup uses `gemini-3.7-flash`;
> `gpt-5.6-luna` and `mai-code-1.1-flash` are the other cheap choices.

Source the profile (`. ~/.profile` or open a new shell), make sure
`copilot-api start` is running, and:

```bash
claude-c                  # Claude Code, Copilot-billed
claude-d                  # Claude Code, Anthropic-billed
```

### Models exposed by the gateway

`curl -s http://127.0.0.1:4141/v1/models` is the source of truth — the
upstream list changes without warning. As of 2026-08-19, on
`copilot-api@2.2.7`, the proxy routes to these chat models (plus
`text-embedding-3-small`,
`text-embedding-3-small-inference`, and `text-embedding-ada-002`):

| Model | Vendor | Context | Max output | Price tier | `reasoning_effort` |
| --- | --- | --- | --- | --- | --- |
| `claude-fable-5` | Anthropic | 264K | 64K | very high | low → max |
| `claude-opus-5` | Anthropic | 264K | 64K | high | low → max |
| `claude-opus-4-6` | Anthropic | 264K | 64K | high | low/medium/high/max |
| `claude-sonnet-5` | Anthropic | 264K | 64K | medium | low → max |
| `gpt-5.6-sol` | OpenAI | 400K | 128K | high | none → max |
| `gpt-5.6-terra` | OpenAI | 400K | 128K | medium | none → max |
| `gpt-5.6-luna` | OpenAI | 328K | 128K | low | none → max |
| `gpt-5.3-codex` | OpenAI | 400K | 128K | medium | low/medium/high/xhigh |
| `kimi-k3` | Moonshot AI | 1.05M | 131K | medium | low/high/max |
| `grok-4.6` | xAI | 328K | 128K | medium | low/medium/high/xhigh |
| `gemini-3.7-flash` | Google | 264K | 64K | low | low/medium/high |
| `mai-code-1.1-flash` | Microsoft | 256K | 128K | low | low/medium/high |

Two caveats carried in the model metadata itself:

- `claude-opus-4-6` is flagged `model_pending_deprecation` with a
  planned removal date of **2026-09-01**.
- `claude-fable-5`, `claude-opus-5`, and `gpt-5.6-sol` are restricted to
  Copilot **Pro+ / Business / Enterprise / Max**; `gpt-5.6-luna` and
  `mai-code-1.1-flash` are the only two available on the free tier.

Note the ID shape: since `copilot-api@1.11.4` the gateway hyphenates
Claude model IDs, so Opus 4.6 is `claude-opus-4-6` here even though
Copilot upstream calls it `claude-opus-4.6`. Other vendors' IDs keep
their dots. Always copy IDs out of `/v1/models` rather than typing them.

Exact per-token prices live in each entry's `billing.token_prices`.

### Model and thinking level

`claude-c` starts on `claude-fable-5` and asks Claude Code for high
effort by default:

```bash
claude-c
```

To start on another model, pass Claude Code's model flag:

```bash
claude-c --model claude-sonnet-5
claude-c --model gemini-3.7-flash
```

Inside the REPL, use `/model` to switch between the models exposed by
the Anthropic-compatible route. For this setup, the practical choices
are `claude-fable-5`, `claude-opus-5`, `claude-sonnet-5`, and
`gemini-3.7-flash`.

Thinking level can be adjusted inside the REPL with `/effort`, for
example:

```text
/effort medium
/effort high
```

It can also be set when launching:

```bash
claude-c --effort medium
claude-c --effort high
```

Claude Code also stores Copilot-mode settings under
`~/.claude-copilot/settings.json`; this setup keeps `effortLevel` at
`high`.

One important gateway detail: the proxy clamps an Anthropic-Messages
effort request to whatever the upstream model advertises in its
metadata, silently. The Claude 5 family (`claude-fable-5`,
`claude-opus-5`, `claude-sonnet-5`) currently advertises the full
`low/medium/high/xhigh/max` range, so `claude-c --effort high` is
honored end to end. Watch the others: `claude-opus-4-6` has no `xhigh`,
`kimi-k3` advertises only `low/high/max`, and `gemini-3.7-flash` and
`mai-code-1.1-flash` cap out at `high`.

`curl http://127.0.0.1:4141/v1/models` shows the local gateway's
OpenAI-compatible view. To inspect the original GitHub Copilot model
report, fetch `https://api.githubcopilot.com/models` directly after
exchanging the stored GitHub OAuth token for a Copilot token:

```bash
node <<'NODE'
const fs = require("fs");
const crypto = require("crypto");

const githubToken = fs.readFileSync(
  `${process.env.HOME}/.local/share/copilot-api/github_token`,
  "utf8",
).trim();
const userAgent = "GitHubCopilotChat/0.50.1";

async function main() {
  const tokenResp = await fetch("https://api.github.com/copilot_internal/v2/token", {
    headers: {
      accept: "application/vnd.github+json",
      authorization: `token ${githubToken}`,
      "user-agent": userAgent,
      "x-github-api-version": "2022-11-28",
      "x-vscode-user-agent-library-version": "electron-fetch",
    },
  });
  if (!tokenResp.ok) throw new Error(`token ${tokenResp.status}: ${await tokenResp.text()}`);
  const { token } = await tokenResp.json();

  const requestId = crypto.randomUUID();
  const modelsResp = await fetch("https://api.githubcopilot.com/models", {
    headers: {
      authorization: `Bearer ${token}`,
      "copilot-integration-id": "vscode-chat",
      "editor-version": "vscode/1.122.1",
      "editor-plugin-version": "copilot-chat/0.50.1",
      "user-agent": userAgent,
      "openai-intent": "model-access",
      "x-github-api-version": "2026-01-09",
      "x-request-id": requestId,
      "x-vscode-user-agent-library-version": "electron-fetch",
      "x-agent-task-id": requestId,
      "x-interaction-type": "model-access",
    },
  });
  if (!modelsResp.ok) throw new Error(`models ${modelsResp.status}: ${await modelsResp.text()}`);
  console.log(JSON.stringify(await modelsResp.json(), null, 2));
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
NODE
```

For the gateway-normalized local view:

```bash
curl -s http://127.0.0.1:4141/v1/models |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s); for (const m of j.data||[]) console.log(m.id, JSON.stringify(m.capabilities?.supports?.reasoning_effort ?? null));})'
```

For a compact check of the models used by `claude-c`:

```bash
curl -s http://127.0.0.1:4141/v1/models |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s); for (const id of ["claude-fable-5","claude-sonnet-5","gemini-3.7-flash"]) { const m=(j.data||[]).find(x=>x.id===id); console.log(id, m?.capabilities?.supports?.reasoning_effort || null); }})'
```

To update the models used by `claude-c`, edit the model aliases in
`~/.profile`:

```bash
ANTHROPIC_MODEL=claude-fable-5
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
ANTHROPIC_SMALL_FAST_MODEL=gemini-3.7-flash
ANTHROPIC_DEFAULT_HAIKU_MODEL=gemini-3.7-flash
```

Then reload the shell config or open a new shell:

```bash
. ~/.profile
```

---

## Why this setup

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
  different account type (`-a business`). The
  `/usage-viewer` dashboard gives a live view of quota burn.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `claude-c` hangs on first request | `copilot-api start` isn't running | Start the proxy in another terminal / under tmux |
| `connection refused` to `:4141` | Port collision | `copilot-api start -p <other-port>` and update `ANTHROPIC_BASE_URL` to match |
| Session list mixes Copilot and Anthropic chats | `CLAUDE_CONFIG_DIR` wasn't set | Re-source `~/.profile`; verify `echo $CLAUDE_CONFIG_DIR` inside `claude-c` |
| Quota burns faster than expected | Background telemetry calls | Confirm `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` are exported |
| `copilot-api auth` keeps re-prompting | Token file has wrong permissions or is corrupt | `chmod 600 ~/.local/share/copilot-api/github_token`; if corrupt, delete and re-auth |

Check current Copilot usage at any time:

```bash
copilot-api check-usage
```

…or open the live dashboard:

```
http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

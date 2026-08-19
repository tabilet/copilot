# Using DeepSeek Harness (`dsh`) with a GitHub Copilot Subscription

Language versions: [🇨🇳 中文](DSH_cn.md).

Companion to [`README.md`](README.md), which covers the Claude Code CLI.
This one covers **`dsh`** — the DeepSeek Harness launcher — billed
against a **GitHub Copilot subscription** instead of the DeepSeek API,
and driven from a terminal instead of a browser.

Two independent parts:

1. [Copilot as the LLM provider](#part-1--copilot-as-the-llm-provider) —
   works for every profile, including the stock `web` and `headless`.
2. [A terminal chat front door](#part-2--a-terminal-chat-front-door) —
   `dsh-tui`, for a Claude-Code-style REPL over SSH.

Plus [`dsh-web.sh`](dsh-web.sh), a launcher for your own machine that
tunnels to the server's web UI and opens it in your browser.

Versions this was written against: `@deepseek-ai/dsh@0.1.0-rc.7`,
`@lujianjun19/dsh-llm-github-copilot@0.3.6`,
`@deepseek-harness-tui/dsh-tui@0.8.4`. This ecosystem moves daily.

---

## How `dsh` is put together

`dsh` is a launcher for **profiles**: a profile is a directory holding a
`package.json` (its plugin dependencies plus an ordered `bundles` list)
and a `cordis.patch.yml` (your own override layer). The runtime tree
composes in this order, each layer patching the one before:

```
each bundle's patch, in dsh.profile.bundles order
  → the profile's cordis.patch.yml
    → the home-level $DSH_HOME/cordis.patch.yml
      → any --patch overlays
```

The last layer wins, which is why a home-level override reaches every
profile. On disk:

```
~/.dsh/
├── cordis.patch.yml          your overrides for EVERY profile
├── .credentials.yaml         credential store, shared by every profile
├── sessions/                 transcripts, keyed by workspace directory
└── profiles/
    ├── web/                  browser UI      (auto-initializes)
    ├── headless/             one-shot runner (auto-initializes)
    └── tui/                  terminal chat   (you create it; see part 2)
```

Only `web` and `headless` self-initialize from shipped templates. Any
other profile has to be created through `dsh plugin`.

Inspect a composed tree without booting it — this is the single most
useful debugging command in the whole system:

```bash
dsh --profile <name> --dump-config          # with your layers
dsh --profile <name> --dump-default-config  # without them
```

---

## Part 1 — Copilot as the LLM provider

Stock `dsh` speaks to the DeepSeek API. Copilot support comes from an
out-of-tree adapter that signs in with GitHub's device flow, exchanges
the OAuth token for a short-lived Copilot token, refreshes it
transparently, and discovers models live from
`https://api.githubcopilot.com/models`.

### Step 1 — Install the adapter, per profile

Profiles have separate `node_modules`, so each one that should reach
Copilot needs its own copy:

```bash
dsh plugin --profile headless add @lujianjun19/dsh-llm-github-copilot
dsh plugin --profile web      add @lujianjun19/dsh-llm-github-copilot
```

The install registers the bundle in that profile's
`dsh.profile.bundles` for you.

### Step 2 — Point the default model at Copilot

Put this in `~/.dsh/cordis.patch.yml` so it applies to every profile —
present and future — rather than repeating it per profile:

```yaml
- id: agent-default-model
  config:
    provider: github-copilot-official
    model: claude-sonnet-5
```

Two details that are easy to get wrong, and both fail confusingly:

**The patch entry shape.** `id` belongs at the top level of the entry.
`- insert:` is the only form that omits it. Anything else — for example
nesting the body under a `change:` key — makes the loader reject the
whole file with:

```
dsh: [~/.dsh/profiles/<name>/cordis.patch.yml] patch: id is required for non-insert patches
```

A normal run swallows that line. The layer is silently dropped, the
default model stays DeepSeek, and what you actually see is a missing
DeepSeek API key. `--dump-config` prints the warning and shows whether
your override survived.

**The provider name is `github-copilot-official`.** Not `copilot`, not
`github-copilot` — the adapter deliberately suffixes itself to avoid
colliding with a dormant catalog route of the same name inside
`dsh-llm-pi-ai`.

### Step 3 — Sign in

Interactively, from the web UI's chat (the device flow needs a browser):

```
/copilot-login     # open the URL, enter the code, authorize
/copilot-status    # confirm, and list the models your plan can reach
```

The gear icon → **GitHub Copilot** settings section does the same thing.

For CI or a machine you never open a browser against, export a token
instead:

```bash
export GITHUB_COPILOT_OAUTH_TOKEN=<token>
```

| Prefix | Source | Accepted |
| --- | --- | --- |
| `gho_` | OAuth token (`gh auth login`) | yes |
| `ghu_` | GitHub App user token (VS Code client) | yes |
| `github_pat_` | fine-grained PAT with **Copilot** permission | yes |
| `ghp_` | classic PAT | no |

Either way the credential lands in `~/.dsh/.credentials.yaml`, which is
**DSH-home-scoped, not per-profile** — one sign-in covers `web`,
`headless`, `tui`, and anything you add later.

### Step 4 — Verify

```bash
dsh --profile headless "reply with exactly: copilot ok"
```

To prove which provider actually served it, read the session
transcript rather than trusting the absence of an error:

```bash
F=$(find ~/.dsh/sessions -name 'session.jsonl.zstd' -printf '%T@ %p\n' |
    sort -rn | head -1 | cut -d' ' -f2-)
zstd -dc "$F" | grep -oE '"(model|provider)":"[^"]+"' | sort | uniq -c
```

Every LLM call should report `"provider":"github-copilot-official"`.

### Choosing a model

Model ids come from your own Copilot catalog, and stale ones fail every
call with `model_not_supported`. List what your account actually serves:

```bash
dsh --profile web    # then, in the chat:  /copilot-status
```

As of 2026-08-19 the picker-enabled chat models were `claude-fable-5`,
`claude-opus-5`, `claude-opus-4.6`, `claude-sonnet-5`, `gpt-5.6-sol`,
`gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.3-codex`, `kimi-k3`, `grok-4.6`,
`gemini-3.7-flash`, and `mai-code-1.1-flash`. Older ids such as `gpt-4o`
are still in the catalog but flagged `model_picker_enabled: false`.

Note that upstream ids keep their dots (`claude-opus-4.6`) — the
hyphenated form (`claude-opus-4-6`) is specific to the `copilot-api`
gateway described in [`README.md`](README.md), which this adapter does
not go through.

### Billing visibility

The adapter talks straight to `api.githubcopilot.com`. It does **not**
pass through the local `copilot-api` proxy on `:4141`, so `dsh` usage
never appears in that proxy's usage viewer even though both draw down
the same Copilot subscription. Budget accordingly.

---

## Reaching the web UI from your laptop

`dsh web` binds `127.0.0.1:3080` on the server, so the browser that has
to talk to it is on the wrong machine. [`dsh-web.sh`](dsh-web.sh) — a
local script, run on your laptop, not the server — closes that gap with
a single SSH connection that both forwards the port and starts the
remote server:

```bash
cp dsh-web.sh ~/.local/bin/dsh-web && chmod +x ~/.local/bin/dsh-web
export DSH_WEB_REMOTE=peter@your-server     # in ~/.profile
dsh-web
```

It forwards a local port to the server's loopback, starts `dsh web`
over the same session, waits for the tunnel to answer, and hands the URL
to your browser. Ctrl-C closes the connection and stops the remote
process with it. If your local 3080 is busy it moves up to the next free
port and adjusts the URL, so a local `dsh web` and a remote one can run
side by side.

| Variable | Default |
| --- | --- |
| `DSH_WEB_REMOTE` | *(required)* `user@host`, or an `~/.ssh/config` alias |
| `DSH_WEB_REMOTE_PORT` | `3080` — what `dsh` binds on the server |
| `DSH_WEB_LOCAL_PORT` | first free port at or above the remote port |
| `DSH_WEB_OPEN` | `1`; set `0` to skip the browser |

Arguments after `--` reach `dsh web` itself:
`dsh-web myhost -- --trusted-host example.test`.

One thing the script exists to work around: `dsh` is installed under
nvm, and nvm's PATH setup lives in `~/.bashrc`, which Ubuntu's own guard
skips for non-interactive shells. A plain `ssh host dsh web` therefore
fails with `command not found`. The script sources `nvm.sh` explicitly
when the bare command is missing.

---

## Part 2 — A terminal chat front door

`dsh` ships two surfaces: `web` (a browser UI on `127.0.0.1:3080`) and
`headless` (one task, one answer, exit). Neither is an interactive
terminal REPL. The launcher's help shows `dsh --profile tui` examples,
but the README annotates them as hypothetical — no `tui` bundle is
published under `@deepseek-ai`.

Terminal front doors exist as community bundles. Adoption as of
2026-08-19, by weekly npm downloads:

| Package | Version | Weekly | Notes |
| --- | --- | --- | --- |
| `@deepseek-harness-tui/dsh-tui` | 0.8.4 | 16,959 | Claude-Code-style, Ink-based |
| `@dopejs/dsh-tui` | 0.9.1 | 2,313 | plugin-native TUI |
| `@heluo0991/cute-dsh-tui` | 1.3.1 | 2,121 | fork of the same Ink core |
| `@aiwayds/dsh-tui-pi` | 0.7.2 | 1,036 | pi-style look and feel |
| `@tomowang/dsh-tui` | 0.5.0 | 925 | out-of-tree TUI bundle |
| `dsh-claude-tui` | 0.1.3 | 734 | verified against PTY captures |

These are unofficial, days old, and run the agent with full tool access
on your machine. Read that as a real consideration, not boilerplate.
The setup below uses the most-adopted one.

### Step 1 — Create the profile

One command creates the profile directory and installs both the front
door and the Copilot adapter into it:

```bash
dsh plugin --profile tui add \
    @deepseek-harness-tui/dsh-tui@0.8.4 \
    @lujianjun19/dsh-llm-github-copilot
```

It reports `initialized profile tui at ~/.dsh/profiles/tui` and writes
the bundle order for you — `dsh-base`, then the TUI, then the adapter.

Pin the exact version. Asking for `@latest` when the manifest already
says `^0.8.1` resolves to whatever that range allows, so a newer release
is quietly skipped.

### Step 2 — Model and credential

Nothing to do if you followed part 1: `~/.dsh/cordis.patch.yml` already
routes every profile at Copilot, and `~/.dsh/.credentials.yaml` already
holds the token.

### Step 3 — Run it

```bash
dsh --profile tui
```

A shell alias saves the typing — add to `~/.profile`:

```bash
alias dsh-tui='dsh --profile tui'
```

The banner reports the version, the active model, the effort level, and
the workspace directory; the status line ends in `· copilot` when the
Copilot route is live. Inside: `/model` switches models, `/presets`
switches agent presets, `/help` lists commands, `?` shows shortcuts.

To smoke-test the boot without a human at the keyboard, give it a PTY:

```bash
script -qec "timeout 25 dsh --profile tui" /dev/null | head -40
```

### Sessions are shared

The TUI resolves its session root to
`DSH_TUI_SESSION_ROOT ?? ~/.dsh/sessions` — the same store the web UI
writes, keyed by workspace directory. Start a conversation in the
browser and resume it in the terminal from the same directory, or the
reverse.

### Supply-chain guard

pnpm 11 quarantines freshly published versions. Pinning a version that
young makes it record a waiver instead:

```
Added 2 entries to minimumReleaseAgeExclude in pnpm-workspace.yaml
```

To be asked instead of silently waived, set this in the profile's
`pnpm-workspace.yaml`:

```yaml
minimumReleaseAgeStrict: true
```

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"` | your patch layer was rejected, so the default model is still DeepSeek | run `--dump-config`, read the warning line, fix the entry shape |
| `patch: id is required for non-insert patches` | `id` is nested inside the entry instead of at its top level | `- id: <id>` then `config:` |
| `model_not_supported` | the model id is not in your Copilot catalog | `/copilot-status` for the live list |
| `GitHub Copilot: no GitHub OAuth token` | not signed in on this machine | `/copilot-login`, or export `GITHUB_COPILOT_OAUTH_TOKEN` |
| Override ignored, no warning | edited `cordis.yml` instead of `cordis.patch.yml` | `cordis.yml` is the generated root; your layer is the patch file |
| `dsh` usage missing from the `copilot-api` dashboard | the adapter bypasses the `:4141` proxy | expected; see [Billing visibility](#billing-visibility) |

## Command reference

```bash
dsh --profile tui                       # terminal chat
dsh web                                 # browser UI on 127.0.0.1:3080
dsh --profile headless "task"           # one answer, then exit
dsh --profile <name> --dump-config      # composed tree, with warnings
dsh plugin --profile <name> add <pkg>   # install a plugin into a profile
```

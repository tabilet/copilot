# 通过 Claude CLI 使用 GitHub Copilot 订阅

语言版本：[🇺🇸 English](README.md)。
姊妹篇：[`DSH_cn.md`](DSH_cn.md) —— 用同一个 Copilot 订阅驱动
`dsh`（DeepSeek Harness），并提供一个终端聊天入口。

这份指南会把 **Claude Code CLI** 接到一个本地代理上。代理负责在
Anthropic 协议和 GitHub Copilot 的 OpenAI 风格 API 之间转换请求，
这样你的 Claude REPL 会话会计入 **GitHub Copilot 订阅**，而不是直接
消耗 `api.anthropic.com` 的额度。

> GitHub 也提供官方的 `copilot` CLI：它是一个独立的可执行文件，能原生
> 连接 Copilot，通过 MCP 暴露工具，并内置一组 agentic skills
>（review-PR、run-CI-on-fix、triage-issue）。如果你的任务主要围绕
> GitHub 工作流展开，优先用它。下面这套方案适合想继续使用熟悉的
> Claude Code REPL 的人。

---

## `claude-c` —— 通过 `copilot-api` 路由的 Claude Code

你得到的仍是标准的 `claude` REPL、斜杠命令和快捷键，只是用量会计入
Copilot。

### 组件结构

```
~/.local/bin/claude    →  Claude Code CLI（Anthropic 提供的执行文件）
copilot-api            →  来自 npm 的 Node 工具；面向 GitHub Copilot 的
                          OpenAI 兼容代理，默认监听 :4141
~/.profile             →  定义 `claude-c` shell 函数，用来串接两者
~/.claude-copilot/     →  独立的 CLAUDE_CONFIG_DIR，避免 Copilot 模式下
                          的状态（会话、计划、历史）与默认 `claude`
                          相互冲突
```

### 安装 —— 实际步骤

#### 第 1 步 —— 安装 Claude Code 本身

Claude Code CLI 已经在磁盘上：

```
~/.local/bin/claude → ~/.local/share/claude/versions/2.1.235
```

如果还没有安装，请使用官方安装器；这一步和 Copilot 没有特殊关系。

#### 第 2 步 —— 安装 `copilot-api`

这里使用 **`@jeffreycao/copilot-api`** 这个 fork。它增加了原生
Anthropic Messages 支持，暴露更新的上游模型（`claude-fable-5`、
`claude-opus-5`、`claude-sonnet-5`、`gpt-5.6-sol`、
`gpt-5.3-codex`、`kimi-k3`、`grok-4.6`），并内置用量面板。本机当前使用的是
`@jeffreycao/copilot-api@2.2.7`。

```bash
npm install -g @jeffreycao/copilot-api
which copilot-api
# /home/peter/.nvm/versions/node/v24.14.1/bin/copilot-api
```

安装后的执行文件仍然叫 `copilot-api`，所以本指南后续步骤和随附的
systemd unit 都不需要修改。如果你更偏好原版 `copilot-api`（ericc-ch），
它在线路协议上兼容；只需要替换安装命令。

#### 第 3 步 —— 用 GitHub 认证 `copilot-api`

```bash
copilot-api auth
```

这会打印一个 URL 和一个 **6 位字母设备验证码**。在浏览器中批准 OAuth
授权后，token 会写入：

```
~/.local/share/copilot-api/github_token
```

（权限为 `0600`。如果这个文件已经存在，后续运行会跳过 OAuth 流程并
复用该 token。）

> 第 3 步是可选的。如果没有 token 文件，`copilot-api start` 首次启动时
> 会自动执行同样的 OAuth 流程。

#### 第 4 步 —— 启动代理

```bash
copilot-api start                 # 默认端口 4141
# 或者打印一条可直接启动 `claude` 的命令，其中已经带上 Copilot 环境变量：
copilot-api start --claude-code
```

启动时，代理会记录 `Logged in as <your-gh-handle>`，并打印可路由的上游
模型列表。它还会在下面的地址提供实时用量面板：

```
http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

让代理保持运行即可。可以放在 `tmux`、`systemd --user`，或者单独的后台
终端里，看你的习惯。

如果需要无人值守运行，把仓库随附的
[`copilot-api.service`](copilot-api.service) 放到
`~/.config/systemd/user/`，再交给 `systemd --user` 在重启后保持代理运行：

```bash
cp copilot-api.service ~/.config/systemd/user/
# 如果 `which copilot-api` 输出不同，请修改 ExecStart 路径
systemctl --user daemon-reload
systemctl --user enable --now copilot-api.service
systemctl --user status copilot-api.service     # 确认正在运行
journalctl --user -u copilot-api.service -f      # 实时查看日志
```

这个 unit 声明了 `Restart=on-failure`，并设置 5 秒退避，所以短暂崩溃后
不需要人工干预。之后如果要停止或禁用：

```bash
systemctl --user stop copilot-api.service
systemctl --user disable copilot-api.service
```

#### 第 5 步 —— 为 Claude Code 单独划出配置目录

这是最容易被忽略的一步。默认的 `claude` 会把会话、计划文件、项目历史
和设置写入 `~/.claude/`。如果同一个执行文件指向不同后端，两边的状态会
混在一起：提示缓存的假设可能失效，工具权限可能变乱，会话选择器里也会
出现互相重叠的历史。解决办法是给 Copilot 模式单独一个根目录：

```bash
mkdir -p ~/.claude-copilot
```

`CLAUDE_CONFIG_DIR=~/.claude-copilot` 会隔离 Copilot 模式运行期间写入的
所有内容，包括 `sessions/`、`projects/`、`plans/`、`settings.json` 等，
不会碰到 `~/.claude/`。

#### 第 6 步 —— 在 `~/.profile` 中定义 `claude-c`

这是串接两边的函数。它会：

- 导出 `ANTHROPIC_BASE_URL=http://localhost:4141`，让 Claude Code
  连接本地代理，而不是 `api.anthropic.com`；
- 设置 `ANTHROPIC_AUTH_TOKEN=dummy`（代理会忽略它；真正的上游认证使用
  你的 GitHub OAuth token）；
- 把 Claude Code 的每个模型别名固定到一个具体的 Copilot 侧模型
  （`ANTHROPIC_MODEL`、`ANTHROPIC_DEFAULT_SONNET_MODEL`、
  `ANTHROPIC_SMALL_FAST_MODEL`、`ANTHROPIC_DEFAULT_HAIKU_MODEL`）；
  这就是按别名决定哪个模型消耗 Copilot 配额的地方；
- 设置 `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` 和
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`，避免 Claude Code 把配额
  花在非必要的后台请求上；
- 用子 shell `( ... )` 包住这些环境变量，避免它们泄漏回交互式 shell；
- 最后用 `exec` 启动 `claude --effort high`，避免多出一层包装进程，并让
  默认会话请求 high effort。

实际安装的函数如下：

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

# 反向配置：同一个执行文件，但连接 api.anthropic.com，按 Anthropic 额度计费
alias claude-d='unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL DISABLE_NON_ESSENTIAL_MODEL_CALLS CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC && /home/peter/.local/bin/claude'
```

> **注意：** 这两个 fast 通道别名必须指向当前网关列表里存在的模型。
> Copilot 已经下线了 `claude-haiku-4.5`，指向网关不再暴露的模型会让所有
> 后台调用都返回 `model_not_supported`。这套配置用的是
> `gemini-3.7-flash`；`gpt-5.6-luna` 和 `mai-code-1.1-flash` 是另外两个
> 便宜的选择。

加载 profile（`. ~/.profile` 或打开一个新 shell），确认
`copilot-api start` 正在运行，然后执行：

```bash
claude-c                  # Claude Code，计入 Copilot
claude-d                  # Claude Code，计入 Anthropic
```

### `claude-c.sh` —— 可直接 source 的脚本

仓库里带了这两个函数：[`claude-c.sh`](claude-c.sh)，不用再从 README 里
复制粘贴。文件本身不含任何凭据（`copilot-api` 用它自己保存的 GitHub
OAuth token 对上游认证），可以放心提交到版本库。

```bash
# 写在 ~/.profile 里，替代上面内联的函数
. /path/to/claude-c.sh
```

所有配置都是「source 之前可覆盖」的变量，因此换模型或换端口都不需要改
文件本身：

| 变量 | 默认值 |
| --- | --- |
| `CLAUDE_C_BIN` | `$HOME/.local/bin/claude`（找不到则回退到 `PATH` 上的 `claude`） |
| `CLAUDE_C_CONFIG_DIR` | `$HOME/.claude-copilot` |
| `CLAUDE_C_BASE_URL` | `http://localhost:4141` |
| `CLAUDE_C_EFFORT` | `high` |
| `CLAUDE_C_MODEL` | `claude-fable-5` |
| `CLAUDE_C_SONNET_MODEL` | `claude-sonnet-5` |
| `CLAUDE_C_FAST_MODEL` | `gemini-3.7-flash`（同时用于 small-fast 和 Haiku 两个别名） |

```bash
# 例如临时用便宜一点的模型，不改文件
CLAUDE_C_MODEL=claude-sonnet-5 claude-c
```

和上面内联版本有两处刻意的差别：`claude-d` 是函数而不是 alias（alias 在
非交互 shell 里不会展开），并且它用 `env -u` 而不是 `unset` 来剥离
Copilot 相关变量，所以无论这些变量有没有被导出都能正常工作。这个脚本需要
bash 或 zsh —— `claude-c` 里的连字符在 POSIX `sh` 里不是合法的函数名。

### 网关当前暴露的模型

`curl -s http://127.0.0.1:4141/v1/models` 才是准确来源——上游列表会在
没有通知的情况下变动。截至 2026-08-19（`copilot-api@2.2.7`），本机代理
可以路由到下面这些对话模型（另外还有 `text-embedding-3-small`、
`text-embedding-3-small-inference` 和 `text-embedding-ada-002`）：

| 模型 | 厂商 | 上下文 | 最大输出 | 价格档 | `reasoning_effort` |
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

模型元数据里带的两个提醒：

- `claude-opus-4-6` 已被标记为 `model_pending_deprecation`，计划下线日期
  是 **2026-09-01**；
- `claude-fable-5`、`claude-opus-5` 和 `gpt-5.6-sol` 仅限 Copilot
  **Pro+ / Business / Enterprise / Max**；免费档只有 `gpt-5.6-luna` 和
  `mai-code-1.1-flash` 可用。

注意模型 ID 的写法：从 `copilot-api@1.11.4` 开始，网关会把 Claude 的模型
ID 转成连字符形式，所以 Opus 4.6 在这里是 `claude-opus-4-6`，而 Copilot
上游叫它 `claude-opus-4.6`。其他厂商的 ID 仍然保留小数点。用模型 ID 时
最好直接从 `/v1/models` 里复制，不要手写。

每个条目的 `billing.token_prices` 里有精确的 token 单价。

### 模型和 thinking level

`claude-c` 默认从 `claude-fable-5` 启动，并请求 Claude Code 使用 high
effort：

```bash
claude-c
```

如果要启动时指定另一个模型，可以传 Claude Code 的 model 参数：

```bash
claude-c --model claude-sonnet-5
claude-c --model gemini-3.7-flash
```

进入 REPL 后，可以用 `/model` 在 Anthropic 兼容路由暴露的模型之间切换。
在这套配置里，实际常用的选择是 `claude-fable-5`、`claude-opus-5`、
`claude-sonnet-5` 和 `gemini-3.7-flash`。

Thinking level 可以在 REPL 里用 `/effort` 调整，例如：

```text
/effort medium
/effort high
```

也可以在启动时指定：

```bash
claude-c --effort medium
claude-c --effort high
```

Claude Code 会把 Copilot 模式的设置写在
`~/.claude-copilot/settings.json`；这套配置把 `effortLevel` 保持为
`high`。

需要注意一个代理层细节：代理会把 Anthropic Messages 请求里的 effort
静默地压到上游模型元数据声明的能力范围内。目前 Claude 5 系列
（`claude-fable-5`、`claude-opus-5`、`claude-sonnet-5`）声明了完整的
`low/medium/high/xhigh/max`，所以 `claude-c --effort high` 可以端到端
生效。其他模型要留意：`claude-opus-4-6` 没有 `xhigh`，`kimi-k3` 只声明
`low/high/max`，而 `gemini-3.7-flash` 和 `mai-code-1.1-flash` 最高只到
`high`。

`curl http://127.0.0.1:4141/v1/models` 看到的是本地代理转换后的
OpenAI 兼容视图。如果要查看 GitHub Copilot 原始的模型报告，需要先把
本地保存的 GitHub OAuth token 换成 Copilot token，然后直接请求
`https://api.githubcopilot.com/models`：

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

如果要查看本地代理转换后的模型列表：

```bash
curl -s http://127.0.0.1:4141/v1/models |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s); for (const m of j.data||[]) console.log(m.id, JSON.stringify(m.capabilities?.supports?.reasoning_effort ?? null));})'
```

如果只想快速检查 `claude-c` 当前使用的几个模型：

```bash
curl -s http://127.0.0.1:4141/v1/models |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s); for (const id of ["claude-fable-5","claude-sonnet-5","gemini-3.7-flash"]) { const m=(j.data||[]).find(x=>x.id===id); console.log(id, m?.capabilities?.supports?.reasoning_effort || null); }})'
```

如果要更新 `claude-c` 使用的模型，编辑 `~/.profile` 里的这些模型别名：

```bash
ANTHROPIC_MODEL=claude-fable-5
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
ANTHROPIC_SMALL_FAST_MODEL=gemini-3.7-flash
ANTHROPIC_DEFAULT_HAIKU_MODEL=gemini-3.7-flash
```

然后重新加载 shell 配置，或者打开一个新 shell：

```bash
. ~/.profile
```

---

## 为什么这样配置

- **体验熟悉**。如果你已经每天使用 Claude Code，`claude-c` 仍然是同一个
  REPL、同一套斜杠命令、同样的计划模式 UX 和同样的快捷键，不需要重新
  学一套工具。
- **按别名路由模型**。四个 `ANTHROPIC_*_MODEL` 环境变量让你决定 Opus
  对应最强模型、Haiku 对应最便宜模型，等等。之后只要改
  `~/.profile` 里的一行，就能调整映射。
- **状态隔离**。`CLAUDE_CONFIG_DIR=~/.claude-copilot` 会把 Copilot 模式
  的会话、计划和设置，与默认走 Anthropic 的 Claude Code 工作区分开。
  你可以在 `claude-c` 和 `claude-d` 之间来回切换，两边历史不会混用。
- **本地代理，行为可见**。`copilot-api` 跑在你自己的机器上；`--verbose`
  会显示每个请求、模型和 token 计数。调试、限速（`-r`）、切换账户类型
  （`-a business`）都很直接。`/usage-viewer` 面板也能实时查看配额消耗。

---

## 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `claude-c` 首次请求挂起 | `copilot-api start` 没有运行 | 在另一个终端或 tmux 中启动代理 |
| 连接 `:4141` 被拒绝 | 端口冲突 | `copilot-api start -p <other-port>`，并把 `ANTHROPIC_BASE_URL` 改到对应端口 |
| 会话列表混入 Copilot 和 Anthropic 聊天 | 没有设置 `CLAUDE_CONFIG_DIR` | 重新加载 `~/.profile`；在 `claude-c` 内用 `echo $CLAUDE_CONFIG_DIR` 确认 |
| 配额消耗比预期更快 | 后台遥测调用 | 确认已经导出 `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` 和 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` |
| `copilot-api auth` 反复要求登录 | token 文件权限错误或文件损坏 | `chmod 600 ~/.local/share/copilot-api/github_token`；如果文件损坏，删除后重新认证 |

随时可以查看当前 Copilot 用量：

```bash
copilot-api check-usage
```

或者打开实时用量面板：

```
http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

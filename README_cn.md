# 通过 Claude CLI 使用 GitHub Copilot 订阅

语言版本：[🇺🇸 English](README.md)。

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
~/.local/bin/claude → ~/.local/share/claude/versions/2.1.126
```

如果还没有安装，请使用官方安装器；这一步和 Copilot 没有特殊关系。

#### 第 2 步 —— 安装 `copilot-api`

这里使用 **`@jeffreycao/copilot-api`** 这个 fork。它增加了原生
Anthropic Messages 支持，暴露更新的上游模型（`gpt-5.4`、`gpt-5.5`、
`gpt-5.3-codex`、`gemini-3.1-pro-preview`、`grok-code-fast-1`、
`claude-opus-4.6-fast`），并内置用量面板：

```bash
npm install -g @jeffreycao/copilot-api
which copilot-api
# /home/user/.nvm/versions/node/v24.14.1/bin/copilot-api
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
- 最后用 `exec` 启动 `claude`，避免多出一层包装进程。

实际安装的函数如下：

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

# 反向配置：同一个执行文件，但连接 api.anthropic.com，按 Anthropic 额度计费
alias claude-d='unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL DISABLE_NON_ESSENTIAL_MODEL_CALLS CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC && /home/user/.local/bin/claude'
```

加载 profile（`. ~/.profile` 或打开一个新 shell），确认
`copilot-api start` 正在运行，然后执行：

```bash
claude-c                  # Claude Code，计入 Copilot
claude-d                  # Claude Code，计入 Anthropic
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

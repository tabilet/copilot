# 用 Claude CLI 跑你的 GitHub Copilot 订阅

语言版本：[🇺🇸 English](README.md)。

本方案把 **Claude Code CLI** 接到一个本地代理上；该代理负责在
Anthropic 协议与 GitHub Copilot 的 OpenAI 风格 API 之间做翻译。这样
你的 Claude REPL 会话最终消耗的是 **GitHub Copilot 订阅**额度，而
不是直接向 `api.anthropic.com` 付费。

> GitHub 也提供官方 `copilot` CLI —— 单一二进制、原生对接 Copilot、
> 通过 MCP 暴露工具，并自带一批智能体式技能（评审 PR、修复后跑 CI、
> 分诊 issue）。当工作偏 GitHub 形态时用它。下面这套方案则面向所有
> 想保留熟悉的 Claude Code REPL 体验的人。

---

## `claude-c` —— 通过 `copilot-api` 路由的 Claude Code

你得到的是标准的 `claude` REPL、斜杠命令、键位绑定 —— 但费用计入
Copilot。

### 组件结构

```
~/.local/bin/claude    →  Claude Code CLI（Anthropic 的二进制）
copilot-api            →  来自 npm 的 Node 工具；GitHub Copilot 的
                          OpenAI 兼容代理，默认监听 :4141
~/.profile             →  定义把两者粘合起来的 `claude-c` 函数
~/.claude-copilot/     →  独立的 CLAUDE_CONFIG_DIR，使 Copilot 模式
                          的状态（会话、计划、历史）不会与
                          原版 `claude` 冲突
```

### 安装 —— 实际发生的步骤

#### 第 1 步 —— 安装 Claude Code 本身

Claude Code CLI 已经在磁盘上：

```
~/.local/bin/claude → ~/.local/share/claude/versions/2.1.126
```

如果还没装，请用官方安装脚本安装；这一步与 Copilot 无关。

#### 第 2 步 —— 安装 `copilot-api`

我们使用 **`@jeffreycao/copilot-api`** 这个 fork，它原生支持
Anthropic Messages 协议，暴露更新的上游模型（`gpt-5.4`、`gpt-5.5`、
`gpt-5.3-codex`、`gemini-3.1-pro-preview`、`grok-code-fast-1`、
`claude-opus-4.6-fast`），并自带用量看板：

```bash
npm install -g @jeffreycao/copilot-api
which copilot-api
# /home/user/.nvm/versions/node/v24.14.1/bin/copilot-api
```

安装出来的可执行仍叫 `copilot-api`，所以本指南后续步骤与随附的
systemd unit 都无需改动。原版 `copilot-api`（ericc-ch）协议兼容；
若偏好原版，把这条 install 命令换掉即可。

#### 第 3 步 —— 让 `copilot-api` 通过 GitHub 鉴权

```bash
copilot-api auth
```

这会打印一个 URL 和一个 **6 位字母授权码**。在浏览器中批准 OAuth
授权。令牌将写入：

```
~/.local/share/copilot-api/github_token
```

（权限 `0600`。该文件存在时，后续运行会跳过 OAuth 流程并复用此
令牌。）

> 第 3 步是可选的 —— 若令牌文件不存在，`copilot-api start` 会在
> 首次启动时自动走相同的 OAuth 流程。

#### 第 4 步 —— 启动代理

```bash
copilot-api start                 # 默认端口 4141
# 或加上"打印一行可直接启动 Claude Code（已注入 Copilot 环境变量）的命令"的开关：
copilot-api start --claude-code
```

启动时代理会输出 `Logged in as <你的-gh-账号>`，并打印它能转发到
的上游模型清单。它还在以下地址提供一个实时用量看板：

```
http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

让代理保持运行（用 `tmux`、`systemd --user` 或后台终端，都行）。

如需无人值守的部署，把仓库自带的
[`copilot-api.service`](copilot-api.service) 拷贝到
`~/.config/systemd/user/`，让 `systemd --user` 跨重启把代理常驻：

```bash
cp copilot-api.service ~/.config/systemd/user/
# 若 `which copilot-api` 输出不同，请相应修改 ExecStart 中的路径
systemctl --user daemon-reload
systemctl --user enable --now copilot-api.service
systemctl --user status copilot-api.service     # 确认正在运行
journalctl --user -u copilot-api.service -f      # 实时跟踪日志
```

该 unit 设置了 `Restart=on-failure` 与 5 秒回退，临时崩溃无需人工
干预。后续若要停止或禁用：

```bash
systemctl --user stop copilot-api.service
systemctl --user disable copilot-api.service
```

#### 第 5 步 —— 为 Claude Code 划出独立的配置目录

这一步是最微妙的。原版 `claude` 会把会话、计划文件、项目历史和
设置写入 `~/.claude/`。如果同一个二进制指向不同的后端，两份状态
会混在一起（提示缓存假设被打破、工具权限混乱、会话选择器中
两份历史互相干扰）。解决办法是给 Copilot 模式独立的根目录：

```bash
mkdir -p ~/.claude-copilot
```

`CLAUDE_CONFIG_DIR=~/.claude-copilot` 会把 Copilot 模式运行期间
写入的所有内容（`sessions/`、`projects/`、`plans/`、
`settings.json` 等）隔离开，不会触碰 `~/.claude/`。

#### 第 6 步 —— 在 `~/.profile` 中定义 `claude-c`

这是粘合剂。该函数：

- 导出 `ANTHROPIC_BASE_URL=http://localhost:4141`，让 Claude Code
  与本地代理通话，而不是 `api.anthropic.com`；
- 设置 `ANTHROPIC_AUTH_TOKEN=dummy`（代理会忽略它；真正的鉴权由
  你的 GitHub OAuth 令牌在上游完成）；
- 把 Claude Code 的每一个模型别名固定到具体的 Copilot 端模型
  （`ANTHROPIC_MODEL`、`ANTHROPIC_DEFAULT_SONNET_MODEL`、
  `ANTHROPIC_SMALL_FAST_MODEL`、`ANTHROPIC_DEFAULT_HAIKU_MODEL`）
  —— 这就是你按别名决定哪个模型消耗 Copilot 配额的地方；
- 设置 `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` 和
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`，避免 Claude Code
  把额度花在遥测式的后台请求上；
- 整体包裹在子 shell `( ... )` 中，使 env 导出不会泄漏回交互
  shell；
- 最后用 `exec` 执行 `claude`，避免多一层包装进程。

实际安装的函数原文：

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

# 反向：相同二进制，但走 api.anthropic.com，按 Anthropic 计费
alias claude-d='unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL DISABLE_NON_ESSENTIAL_MODEL_CALLS CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC && /home/user/.local/bin/claude'
```

加载 profile（`. ~/.profile` 或开一个新 shell），确认
`copilot-api start` 正在运行，然后：

```bash
claude-c                  # Claude Code，Copilot 计费
claude-d                  # Claude Code，Anthropic 计费
```

---

## 这套方案的好处

- **熟悉**。如果你已经在日常使用 Claude Code，`claude-c` 就是同一个
  REPL、同一套斜杠命令、同样的计划模式 UX、同样的键位绑定。无需
  重新学习。
- **按别名做模型路由**。四个 `ANTHROPIC_*_MODEL` 环境变量让你决定
  Opus = 最强模型、Haiku = 最便宜模型，等等 —— 而且只需改
  `~/.profile` 中的一行就能更换映射。
- **状态隔离**。`CLAUDE_CONFIG_DIR=~/.claude-copilot` 把 Copilot
  模式的会话、计划和设置与原版 Anthropic 的 Claude Code 工作区
  分隔开。你可以来回切换（`claude-c` ↔ `claude-d`）而两份历史永远
  不会互相污染。
- **本地代理，全程可见**。`copilot-api` 跑在你自己的机器上；
  `--verbose` 会输出每个请求、模型和 token 计数。容易调试、容易
  限速（`-r`）、容易切换账户类型（`-a business`）。`/usage-viewer`
  看板还能实时看配额消耗情况。

---

## 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `claude-c` 首次请求挂起 | `copilot-api start` 未运行 | 在另一个终端 / tmux 中启动代理 |
| 连接 `:4141` 被拒绝 | 端口冲突 | `copilot-api start -p <其它端口>`，并把 `ANTHROPIC_BASE_URL` 改为对应端口 |
| 会话列表中 Copilot 与 Anthropic 聊天混在一起 | 没设置 `CLAUDE_CONFIG_DIR` | 重新加载 `~/.profile`；在 `claude-c` 内部用 `echo $CLAUDE_CONFIG_DIR` 确认 |
| 配额消耗比预期快 | 后台遥测调用 | 确认已导出 `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` 与 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` |
| `copilot-api auth` 反复要求登录 | 令牌文件权限错误或已损坏 | `chmod 600 ~/.local/share/copilot-api/github_token`；若文件损坏，删除后重新鉴权 |

随时可以查询当前 Copilot 用量：

```bash
copilot-api check-usage
```

……或者打开实时看板：

```
http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

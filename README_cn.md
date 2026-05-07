# 使用 GitHub Copilot 作为终端 CLI 的 LLM 后端

语言版本：[🇺🇸 English](README.md)。

有两个 CLI 工具可以让你在终端中驱动 LLM 会话，并将费用计入你的
**GitHub Copilot 订阅**，而不是直接向 Anthropic 或 OpenAI 付费：

| CLI | 可执行文件 | 后端 | 风格 |
|---|---|---|---|
| `copilot` | `~/.local/bin/copilot` | GitHub Copilot CLI（官方） | GitHub 原生、智能体式、技能驱动 |
| `claude-c` | `~/.profile` 中的 shell 函数 | Claude Code CLI 通过本地 OpenAI 兼容代理 | Claude Code 体验，模型路由由你掌控 |

两者最终都消耗你的 Copilot 配额。请根据任务挑选合适的工具。

---

## 1. `copilot` —— 官方 GitHub Copilot CLI

### 安装

该二进制是一个完整的自包含可执行文件。把它放到 `PATH` 上即可：

```bash
# ~/.local/bin/copilot 已经是一个 149 MB 的可执行文件
chmod +x ~/.local/bin/copilot
copilot --version
# GitHub Copilot CLI 1.0.42.
```

到此为止。没有代理、没有配置折腾、没有需要考虑的模型路由。

### 首次运行

```bash
copilot
```

首次调用会打印一个 URL 和一个 **6 位字母授权码**。在浏览器中打开
该 URL，粘贴授权码，并在 GitHub 上批准 OAuth 授权。完成后会进入
交互式设置，让你选择：

1. **LLM 模式** —— 默认使用哪个提供商/模型族（Claude、GPT、
   Gemini 等）。
2. **小模型** —— 用于后台调用（子代理、快速校验、补全）的
   廉价模型。

这些选择会被持久化，后续运行将直接进入会话。

---

## 2. `claude-c` —— 通过 `copilot-api` 路由的 Claude Code

这一种**有意保留 Claude Code CLI 本体**，只是重新接线，让它的
HTTP 流量终结于一个本地代理；该代理负责在 Anthropic 协议与
GitHub Copilot 的 OpenAI 风格 API 之间做翻译。你得到的是标准的
`claude` REPL、斜杠命令、键位绑定 —— 但费用计入 Copilot。

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

```bash
npm install -g copilot-api
which copilot-api
# /home/user/.nvm/versions/node/v24.14.1/bin/copilot-api
```

#### 第 3 步 —— 让 `copilot-api` 通过 GitHub 鉴权

```bash
copilot-api auth
```

这会打印一个 URL 和一个 **6 位字母授权码**，与上面 `copilot` CLI
的流程完全一致。在浏览器中批准 OAuth 授权。令牌将写入：

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
的上游模型清单 —— 包括 `claude-opus-4.6`、`claude-opus-4.7`、
`claude-sonnet-4.6`、`gemini-3-flash-preview`、`gpt-5.x` 等等。让它
保持运行（用 `tmux`、`systemd --user` 或后台终端，都行）。

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

## 何时用哪个

两者花的都是同一份 Copilot 配额，但使用感受截然不同。

### `claude-c` 的优势

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
  限速（`-r`）、容易切换账户类型（`-a business`）。

### `copilot` 的优势

- **零管路**。一个二进制、一个 OAuth 流程、一个交互式选择器。
  没有代理需要常驻、没有环境变量要管理、没有独立配置目录。
- **原生 GitHub 集成**。开箱即可推理 repo、PR、issue、Actions
  运行 —— 而且不需要 MCP 桥接，因为它本身就是 GitHub 的客户端。
- **内置技能与代理**。CLI 自带一批精选的技能/自动化和一个代理
  运行时，能为常见工程任务（评审-PR、修复-后跑-CI、分诊-issue）
  串联工具调用，而无需你自己接线。
- **官方支持**。更新通过 `copilot update` 落地；与 GitHub Copilot
  的契约从定义上就稳定 —— 因为两端都是 GitHub 出的。

### 经验法则

- 当工作是纯代码/文本、并且你想要熟悉的 Claude Code 体验时
  （计划、编辑、多步重构、深度文件树探索），用 **`claude-c`**。
- 当工作是 GitHub 形态的（涉及 PR、issue、Actions、仓库元数据），
  或你想调用 GitHub 的某个预置代理式技能时，用 **`copilot`**。

两者可以同时安装，互不冲突。

---

## 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `claude-c` 首次请求挂起 | `copilot-api start` 未运行 | 在另一个终端 / tmux 中启动代理 |
| 连接 `:4141` 被拒绝 | 端口冲突 | `copilot-api start -p <其它端口>`，并把 `ANTHROPIC_BASE_URL` 改为对应端口 |
| 会话列表中 Copilot 与 Anthropic 聊天混在一起 | 没设置 `CLAUDE_CONFIG_DIR` | 重新加载 `~/.profile`；在 `claude-c` 内部用 `echo $CLAUDE_CONFIG_DIR` 确认 |
| 配额消耗比预期快 | 后台遥测调用 | 确认已导出 `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` 与 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` |
| `copilot-api auth` 反复要求登录 | 令牌文件权限错误或已损坏 | `chmod 600 ~/.local/share/copilot-api/github_token`；若文件损坏，删除后重新鉴权 |
| `copilot` 每次启动都重新走鉴权 | 登录状态丢失 | 重新走交互式设置，再次选择 LLM 模式与小模型 |

随时可以查询当前 Copilot 用量：

```bash
copilot-api check-usage
```

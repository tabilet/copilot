# 用 GitHub Copilot 订阅驱动 DeepSeek Harness（`dsh`）

语言版本：[🇬🇧 English](DSH.md)。

这是 [`README.md`](README_cn.md) 的姊妹篇：那一篇讲 Claude Code CLI，
这一篇讲 **`dsh`**（DeepSeek Harness 启动器）——把它接到 **GitHub
Copilot 订阅** 上计费，而不是走 DeepSeek API，并且在终端里使用，
而不是浏览器。

两个互相独立的部分：

1. [把 Copilot 作为 LLM 提供方](#第-1-部分把-copilot-作为-llm-提供方)——
   对所有 profile 都适用，包括自带的 `web` 和 `headless`；
2. [终端聊天入口](#第-2-部分终端聊天入口)——`dsh-tui`，
   在 SSH 上获得类似 Claude Code 的 REPL。

另外还有 [`dsh-web.sh`](dsh-web.sh)：跑在你自己电脑上的启动器，
自动建立到服务器 web UI 的隧道并打开浏览器。

本文对应的版本：`@deepseek-ai/dsh@0.1.0-rc.7`、
`@lujianjun19/dsh-llm-github-copilot@0.3.6`、
`@deepseek-harness-tui/dsh-tui@0.8.4`。这套生态每天都在变。

---

## `dsh` 的组织方式

`dsh` 是 **profile** 的启动器。一个 profile 就是一个目录，里面有
`package.json`（插件依赖，以及有序的 `bundles` 列表）和
`cordis.patch.yml`（你自己的覆盖层）。运行时的插件树按下面的顺序
逐层打补丁：

```
dsh.profile.bundles 里每个 bundle 自带的 patch（按顺序）
  → 该 profile 的 cordis.patch.yml
    → home 级的 $DSH_HOME/cordis.patch.yml
      → 命令行上的 --patch 覆盖层
```

后面的层覆盖前面的层，所以放在 home 级的覆盖能作用于所有 profile。
磁盘布局：

```
~/.dsh/
├── cordis.patch.yml          作用于「所有」profile 的覆盖层
├── .credentials.yaml         凭据存储，所有 profile 共用
├── sessions/                 会话记录，按工作目录分组
└── profiles/
    ├── web/                  浏览器 UI  （首次使用自动初始化）
    ├── headless/             一次性执行（首次使用自动初始化）
    └── tui/                  终端聊天  （需要自己创建，见第 2 部分）
```

只有 `web` 和 `headless` 会用内置模板自动初始化，其他 profile 必须
通过 `dsh plugin` 创建。

不启动、只看组装结果——这是整套系统里最有用的排查命令：

```bash
dsh --profile <name> --dump-config          # 含你自己的层
dsh --profile <name> --dump-default-config  # 不含你自己的层
```

---

## 第 1 部分：把 Copilot 作为 LLM 提供方

原生 `dsh` 走 DeepSeek API。Copilot 的支持来自一个第三方适配器：
它用 GitHub 设备流登录，把 OAuth token 换成短期的 Copilot token，
到期自动续期，并从 `https://api.githubcopilot.com/models`
实时发现可用模型。

### 第 1 步 —— 按 profile 安装适配器

各个 profile 有各自独立的 `node_modules`，因此每个需要用 Copilot 的
profile 都要装一份：

```bash
dsh plugin --profile headless add @lujianjun19/dsh-llm-github-copilot
dsh plugin --profile web      add @lujianjun19/dsh-llm-github-copilot
```

安装时会自动把该 bundle 写进这个 profile 的 `dsh.profile.bundles`。

### 第 2 步 —— 把默认模型指向 Copilot

写在 `~/.dsh/cordis.patch.yml` 里，这样对现在和以后的所有 profile
都生效，不必每个 profile 重复一遍：

```yaml
- id: agent-default-model
  config:
    provider: github-copilot-official
    model: claude-sonnet-5
```

有两个地方很容易写错，而且错了以后报错都很有迷惑性：

**patch 条目的形状。** `id` 要写在条目的顶层，只有 `- insert:`
这一种形式可以不带 `id`。其他写法——比如把内容嵌在 `change:`
键下面——会让加载器直接拒绝整个文件：

```
dsh: [~/.dsh/profiles/<name>/cordis.patch.yml] patch: id is required for non-insert patches
```

正常启动时这行警告会被吞掉：整层被丢弃，默认模型仍然是 DeepSeek，
你最终看到的却是「缺少 DeepSeek API key」。用 `--dump-config`
可以看到这行警告，也能确认你的覆盖到底生效没有。

**提供方名字是 `github-copilot-official`。** 不是 `copilot`，
也不是 `github-copilot`——适配器故意加了后缀，以避开
`dsh-llm-pi-ai` 里同名的休眠路由。

### 第 3 步 —— 登录

交互式登录在 web UI 的聊天里完成（设备流需要浏览器）：

```
/copilot-login     # 打开链接，输入验证码，授权
/copilot-status    # 确认状态，并列出你的套餐能用的模型
```

齿轮图标 → **GitHub Copilot** 设置区做的是同一件事。

如果是 CI，或者一台你根本不会开浏览器的机器，改用环境变量：

```bash
export GITHUB_COPILOT_OAUTH_TOKEN=<token>
```

| 前缀 | 来源 | 是否可用 |
| --- | --- | --- |
| `gho_` | OAuth token（`gh auth login`） | 可以 |
| `ghu_` | GitHub App 用户 token（VS Code 客户端） | 可以 |
| `github_pat_` | 细粒度 PAT，需要 **Copilot** 权限 | 可以 |
| `ghp_` | 传统 classic PAT | 不可以 |

两种方式最终都会把凭据写进 `~/.dsh/.credentials.yaml`。它是
**DSH home 级、而不是 profile 级**的，所以登录一次，`web`、
`headless`、`tui` 以及以后新增的 profile 都能用。

### 第 4 步 —— 验证

```bash
dsh --profile headless "reply with exactly: copilot ok"
```

不要用「没报错」来判断，直接看会话记录里到底是谁服务的：

```bash
F=$(find ~/.dsh/sessions -name 'session.jsonl.zstd' -printf '%T@ %p\n' |
    sort -rn | head -1 | cut -d' ' -f2-)
zstd -dc "$F" | grep -oE '"(model|provider)":"[^"]+"' | sort | uniq -c
```

每一次 LLM 调用都应该是 `"provider":"github-copilot-official"`。

### 怎么选模型

模型 id 来自你自己账号的 Copilot 目录，写了已经下线的 id 会让每次
调用都失败并返回 `model_not_supported`。查看当前可用列表：

```bash
dsh --profile web    # 进入聊天后执行：/copilot-status
```

截至 2026-08-19，可选（picker-enabled）的对话模型是
`claude-fable-5`、`claude-opus-5`、`claude-opus-4.6`、
`claude-sonnet-5`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`、
`gpt-5.3-codex`、`kimi-k3`、`grok-4.6`、`gemini-3.7-flash`、
`mai-code-1.1-flash`。`gpt-4o` 这类老 id 还在目录里，但被标记为
`model_picker_enabled: false`。

注意上游的 id 保留小数点（`claude-opus-4.6`）。连字符写法
（`claude-opus-4-6`）是 [`README.md`](README_cn.md) 里那个
`copilot-api` 网关特有的，而这个适配器并不经过它。

### 用量可见性

适配器直连 `api.githubcopilot.com`，**不会**经过本地 `:4141` 上的
`copilot-api` 代理。因此即使两者消耗的是同一个 Copilot 订阅，
`dsh` 的用量也不会出现在那个代理的用量面板里。做预算时要记得。

---

## 从本地电脑访问 web UI

`dsh web` 监听的是服务器上的 `127.0.0.1:3080`，而需要访问它的浏览器
却在另一台机器上。[`dsh-web.sh`](dsh-web.sh) 就是用来补这一段的：
它跑在你自己的电脑上（不是服务器上），用一条 SSH 连接同时完成端口
转发和启动远端服务：

```bash
cp dsh-web.sh ~/.local/bin/dsh-web && chmod +x ~/.local/bin/dsh-web
export DSH_WEB_REMOTE=peter@your-server     # 写进 ~/.profile
dsh-web
```

它会把本地端口转发到服务器的 loopback，在同一条会话里启动
`dsh web`，等隧道通了以后把 URL 交给浏览器。Ctrl-C 关闭连接，远端
进程也随之结束。如果这个端口在本地被占用，它会把**两端一起**挪到
下一个空闲端口号——原因见下面的 authority 校验。

| 变量 | 默认值 |
| --- | --- |
| `DSH_WEB_REMOTE` | *（必填）* `user@host`，或 `~/.ssh/config` 里的别名 |
| `DSH_WEB_PORT` | `3080`，两端使用同一个端口 |
| `DSH_WEB_OPEN` | `1`；设为 `0` 则不打开浏览器 |
| `DSH_WEB_REPLACE` | `0`；设为 `1`（或用 `--replace`）会先停掉已占用远端端口的进程 |

在做任何事情之前，它会先问服务器那个端口是不是空的。如果上面已经有
一个服务在跑——最常见的情况是上次留下来没关的——它会把那个进程打印
出来然后退出：

```
dsh-web: port 3080 on peter@yixin is already in use by:
  534382 node /home/peter/.nvm/.../dsh web --port 3080
dsh-web: use --replace to stop it, or set DSH_WEB_PORT to another port
```

这个检查比看上去重要：没有它的话，隧道会先建立起来，远端的
`dsh web` 随后才因为 `EADDRINUSE` 挂掉，于是浏览器悄悄连到了**旧的**
那个进程；如果旧进程当初监听的是另一个端口，你看到的就是下一节说的
「一直转圈」。`--replace` 会停掉占用者并等端口释放再继续；它必须显式
指定，因为那个进程有可能是别人正在用的会话。

`--` 之后的参数会原样传给 `dsh web`：
`dsh-web myhost -- --trusted-host example.test`。

### authority 校验，以及「转圈转不停」

web UI 的静态文件对谁都放行，但 `/api` 会被限制在服务器**自身的
authority** 上。针对绑定在 `127.0.0.1:3080` 的服务器实测：

| 浏览器 origin | `POST /api` | `WS /api/events.host` |
| --- | --- | --- |
| `http://127.0.0.1:3080` | 通过 | `101` |
| `http://127.0.0.1:3081` | `403` | `403` |
| `http://localhost:3080` | `403` | `403` |

所以只要隧道的本地端口和服务器端口不一致，页面就会「打开了，然后
一直转圈」：HTML 和 JS 都能加载，但所有 API 调用和两个事件
WebSocket 全部返回 `403`。用 `http://localhost:PORT` 而不是
`http://127.0.0.1:PORT` 也是一样的结果——authority 不同，同样 403。

由此有两条规则：**端口 N 转发到端口 N**，以及**用打印出来的
`127.0.0.1` 地址**。另外，`--trusted-host` 救不了这种不一致：在
loopback 绑定下，实测加上 `127.0.0.1:3081` 或者不带端口的
`127.0.0.1`，校验依旧是 403。

这个脚本要绕开的另一个坑：`dsh` 装在 nvm 下面，而 nvm 的 PATH 设置写在
`~/.bashrc` 里，Ubuntu 自带的判断会让非交互式 shell 直接跳过它。
所以直接执行 `ssh host dsh web` 会报 `command not found`。脚本在找不到
`dsh` 时会显式 source 一次 `nvm.sh`。

---

## 第 2 部分：终端聊天入口

`dsh` 自带两个界面：`web`（`127.0.0.1:3080` 上的浏览器 UI）和
`headless`（一个任务、一个回答、然后退出）。两者都不是交互式的终端
REPL。启动器的帮助里出现过 `dsh --profile tui` 的例子，但 README
注明那只是假设性的例子——`@deepseek-ai` 下并没有发布 `tui` bundle。

终端入口以社区 bundle 的形式存在。截至 2026-08-19 的 npm 周下载量：

| 包 | 版本 | 周下载 | 说明 |
| --- | --- | --- | --- |
| `@deepseek-harness-tui/dsh-tui` | 0.8.4 | 16,959 | Claude Code 风格，基于 Ink |
| `@dopejs/dsh-tui` | 0.9.1 | 2,313 | plugin-native TUI |
| `@heluo0991/cute-dsh-tui` | 1.3.1 | 2,121 | 同一 Ink 内核的分支 |
| `@aiwayds/dsh-tui-pi` | 0.7.2 | 1,036 | pi 风格外观 |
| `@tomowang/dsh-tui` | 0.5.0 | 925 | out-of-tree TUI bundle |
| `dsh-claude-tui` | 0.1.3 | 734 | 用真实 PTY 采样做过校验 |

这些都是非官方的、刚发布几天的包，而且会在你的机器上以完整工具
权限运行 agent。这句话是实打实的注意事项，不是套话。下面用的是
其中采用率最高的一个。

### 第 1 步 —— 创建 profile

一条命令即可创建 profile 目录，并把终端入口和 Copilot 适配器
一起装进去：

```bash
dsh plugin --profile tui add \
    @deepseek-harness-tui/dsh-tui@0.8.4 \
    @lujianjun19/dsh-llm-github-copilot
```

它会输出 `initialized profile tui at ~/.dsh/profiles/tui`，并自动写好
bundle 顺序：`dsh-base`、TUI、然后是适配器。

要写死具体版本。如果 manifest 里已经是 `^0.8.1`，再执行 `@latest`
只会在这个范围内解析，更新的版本会被悄悄跳过。

### 第 2 步 —— 模型和凭据

如果第 1 部分已经做完，这里没有任何事情要做：
`~/.dsh/cordis.patch.yml` 已经把所有 profile 指向 Copilot，
`~/.dsh/.credentials.yaml` 里也已经有 token 了。

### 第 3 步 —— 运行

```bash
dsh --profile tui
```

加个别名少敲几个字，写进 `~/.profile`：

```bash
alias dsh-tui='dsh --profile tui'
```

启动横幅会显示版本、当前模型、effort 级别和工作目录；当 Copilot
路由生效时，状态栏结尾是 `· copilot`。进去以后：`/model` 换模型，
`/presets` 换 agent 预设，`/help` 看命令，`?` 看快捷键。

想在无人值守的情况下验证能否正常启动，给它一个 PTY：

```bash
script -qec "timeout 25 dsh --profile tui" /dev/null | head -40
```

### 会话是共享的

TUI 的会话根目录解析为
`DSH_TUI_SESSION_ROOT ?? ~/.dsh/sessions`——和 web UI 写入的是同一个
存储，按工作目录分组。你可以在浏览器里开一个会话，然后在同一个目录
下用终端接着聊，反过来也一样。

### 供应链保护

pnpm 11 会隔离刚发布不久的版本。写死一个「太新」的版本时，
它会记录一条豁免：

```
Added 2 entries to minimumReleaseAgeExclude in pnpm-workspace.yaml
```

如果希望它询问你，而不是直接豁免，在该 profile 的
`pnpm-workspace.yaml` 里加上：

```yaml
minimumReleaseAgeStrict: true
```

---

## 排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"` | 你的 patch 层被拒绝，默认模型还是 DeepSeek | 跑 `--dump-config`，看警告行，修正条目形状 |
| `patch: id is required for non-insert patches` | `id` 被嵌在条目里面，而不是写在顶层 | 改成 `- id: <id>` 加 `config:` |
| `model_not_supported` | 模型 id 不在你的 Copilot 目录里 | 用 `/copilot-status` 看实时列表 |
| `GitHub Copilot: no GitHub OAuth token` | 这台机器还没登录 | `/copilot-login`，或导出 `GITHUB_COPILOT_OAUTH_TOKEN` |
| 覆盖不生效，也没有警告 | 改的是 `cordis.yml` 而不是 `cordis.patch.yml` | `cordis.yml` 是生成的根文件，你的层是 patch 文件 |
| `copilot-api` 面板里看不到 `dsh` 的用量 | 适配器绕过了 `:4141` 代理 | 属于预期，见[用量可见性](#用量可见性) |
| 隧道通了，但界面是别人的会话 | 还有一个没关掉的 `dsh web` 占着端口 | `dsh-web --replace`，或 `ssh <host> "pkill -f '[d]sh web'"` |
| web UI 打开后一直转圈 | `/api` 被限制在服务器自身的 authority；隧道端口或主机名不一致 | 端口 N 转发到端口 N，并用 `http://127.0.0.1:N` 访问 |
| `dsh web` 好像「卡住」 | 它是前台服务进程，本来就不会返回 | 属于预期；Ctrl-C 结束 |

## 命令速查

```bash
dsh --profile tui                       # 终端聊天
dsh web                                 # 浏览器 UI，127.0.0.1:3080
dsh --profile headless "task"           # 一次性回答后退出
dsh --profile <name> --dump-config      # 组装后的插件树，含警告
dsh plugin --profile <name> add <pkg>   # 给某个 profile 装插件
```

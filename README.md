# Codex × DeepSeek Responses 修复代理

一个零依赖的本地反向代理，用来修掉 Codex 配合严格 Responses 上游（典型是
DeepSeek `api.deepseek.com/responses`）时的这个报错：

```text
422 Unprocessable Entity: Failed to deserialize the JSON body into the target type:
input: missing field `call_id` at line 1 column ...
```

## 问题是什么

Codex 在「侧边对话/子任务往主会话投递消息」、`create_thread`、`send_message_to_thread`、
heartbeat/cron 自动化这些场景下，会往会话里注入一条独立条目：

```json
{
  "type": "function_call_output",
  "id": "fco_...",
  "name": "create_thread",
  "namespace": "codex_app",
  "output": "<codex_delegation>...</codex_delegation>"
}
```

Codex 自己的协议允许 `call_id` 为空（序列化时直接省略这个键），但严格上游要求
`function_call_output.call_id` 必填，于是整包请求被拒。坏条目还会写进 rollout，
之后每一轮都会重放，线程看起来就「永久卡死」，只能 fork。

这是 Codex 与严格 Responses 上游之间的已知不兼容，不是配置写错了。DeepSeek 的
Rust 服务端在反序列化阶段直接拒包，所以报的是 `422 Unprocessable Entity`；Azure、
Kimi 等其它严格上游对同一类坏条目通常报 `400` 或 `tool_call_id is not found`。
上游 issue 见下一节。

## 相关已知 issue

以下 issue 截至 **2026-09-23** 全部仍为 open，没有进入任何 Codex release。
本仓库是客户端侧的 workaround；等上游修好后把 `base_url` 改回直连即可。

Codex 主仓库（openai/codex）：

| Issue | 状态 | 说明 |
| --- | --- | --- |
| [#42088](https://github.com/openai/codex/issues/42088) | open | 总根因：`function_call_output` 可以不带 `call_id`，严格上游直接拒包 |
| [#46193](https://github.com/openai/codex/issues/46193) | open | 配对校验只在重建历史时做，发送边界没有守卫；孤立输出是设计产物 |
| [#45450](https://github.com/openai/codex/issues/45450) | open | 只补 `call_id` 不够：没有配套 `function_call` 仍会被拒 |
| [#45227](https://github.com/openai/codex/issues/45227) | open | Windows + DeepSeek：坏条目写进 rollout 后整个线程永久失败 |
| [#45914](https://github.com/openai/codex/issues/45914) | open | `send_message_to_thread` 的 `function_call_output` 落盘时没有 `call_id` |
| [#45318](https://github.com/openai/codex/issues/45318) | open | 跨任务消息被记成无 `call_id` 的 `function_call_output`，整轮请求被拒 |
| [#42067](https://github.com/openai/codex/issues/42067) | open | 普通 resume / 跨线程发送同样会踩到缺 `call_id` 的注入条目 |
| [#41690](https://github.com/openai/codex/issues/41690) | open | Desktop 自动化 + DeepSeek Responses：`automation_update` 输出缺 `call_id` |
| [#44723](https://github.com/openai/codex/issues/44723) | open | heartbeat / cron 自动化注入无 `call_id` 条目，卡死目标会话 |
| [#44519](https://github.com/openai/codex/issues/44519) | open | Windows：线程心跳自动化同样触发该问题 |
| [#44779](https://github.com/openai/codex/issues/44779) | open | `tool_search` 也有同类 `call_id` 严格校验问题（本代理暂不处理） |

第三方网关 cc-switch（同类现象的复现与修复讨论）：

| Issue | 状态 | 说明 |
| --- | --- | --- |
| [cc-switch#6995](https://github.com/farion1231/cc-switch/issues/6995) | open | 心跳自动化注入的孤立输出导致 DeepSeek 400、会话永久卡死 |
| [cc-switch#7074](https://github.com/farion1231/cc-switch/issues/7074) | open | cron 自动化 `automation_update` 的同一问题 |
| [cc-switch#7551](https://github.com/farion1231/cc-switch/issues/7551) | open | `create_thread` 委派注入缺 `call_id`，DeepSeek 422，新任务首轮即失败 |
| [cc-switch#7127](https://github.com/farion1231/cc-switch/issues/7127) | open | 自动化经 cc-switch 转发给 DeepSeek 的同类问题 |

## 代理怎么修

请求经过代理时做三件事，其余内容（Header、Authorization、query、SSE 流）原样透传：

1. `call_id` 缺失/为空/匹配不到 `function_call` 的 `function_call_output`
   → 改写成一条普通 `message`（默认 `role=user`），保留原始文本，注入内容不丢。
2. 有 `function_call` 却没有对应输出的 → 补一条 `output: "aborted"`，
   与 Codex 自己重建历史时的做法一致。
3. 连续的「调用/输出」批次 → 统一成先全部 `function_call`、再全部输出，
   满足严格上游的批次顺序要求。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `deepseek_responses_fix_proxy.py` | 代理本体，Python 3.11+，无第三方依赖 |
| `deepseek.config.psd1` | 配置：`Upstream` / `Listen` / `Role` / `Verbose` / `LogFile` |
| `deepseek.ps1` | 便捷启动脚本，读取上面的配置，可用参数覆盖 |
| `start-proxy.cmd` | 双击 = 前台启动代理 |
| `restart-service.cmd` | 双击 = 停止并重新后台启动代理（改完配置或 key 后用） |
| `install-autostart.cmd` | 双击 = 安装开机自启（当前用户 Startup 快捷方式，无需管理员） |
| `uninstall-autostart.cmd` | 双击 = 卸载自启并停止代理进程 |

## 快速开始

### 1. 启动代理

双击 `start-proxy.cmd`，或在 PowerShell 里：

```powershell
.\deepseek.ps1              # 前台运行，Ctrl+C 停止
.\deepseek.ps1 -Background  # 后台运行
.\deepseek.ps1 -Upstream https://api.deepseek.com -Listen 127.0.0.1:18787
.\deepseek.ps1 -Role developer
```

### 2. 让 Codex 走代理

编辑 `~/.codex/config.toml`，只改 `base_url` 一行（`experimental_bearer_token`
或 `env_key` 保持原样，代理只透传 Authorization）：

```toml
[model_providers.deepseek]
name = "deepseek"
base_url = "http://127.0.0.1:18787/"
wire_api = "responses"
experimental_bearer_token = "..."
```

重启 Codex。已经被坏条目卡住的会话不需要 fork，重新打开重试即可：坏条目还在
rollout 里，但每次发送时都会被代理修掉。

### 3. 开机自启

双击 `install-autostart.cmd`：会在当前用户的启动文件夹里创建一个快捷方式，
用 `pythonw.exe` 无窗口启动代理，并立即在后台启动一次。整个过程不需要管理员权限。

双击 `uninstall-autostart.cmd` 即可卸载，并停止由本目录启动的代理进程。

改完 `deepseek.config.psd1`、换了 `Upstream`，或者更新了 `DEEPSEEK_API_KEY`
之后，双击 `restart-service.cmd` 就能让新配置生效：它会停掉正在运行的代理，
按当前配置重新后台启动，并确认监听端口已经起来。不需要重装自启，也不需要
重启 Codex。

## 配置项

`deepseek.config.psd1`：

```powershell
@{
    Upstream = 'https://api.deepseek.com'
    Listen   = '127.0.0.1:18787'
    Role     = 'user'          # user 或 developer
    Verbose  = $true
    LogFile  = ''              # 留空 = 本目录 proxy.log
}
```

代理命令行参数：

```text
--listen 127.0.0.1:18787       本地监听地址
--upstream https://api.deepseek.com
--role user|developer          孤立输出改写成哪种消息
--verbose                      记录每个请求的修复摘要
--log-file <path>              日志追加写入文件
--no-synth-missing             不补 aborted 输出
--no-normalize-batches         不做批次重排
--selftest                     离线自检，不联网
```

## 验证结果

- `--selftest`：离线断言通过。
- 本地 mock 上游端到端：畸形请求被修复后到达上游；SSE 不被缓冲
  （第一个事件 0.00s、第二个 1.00s 到达）；`Authorization` 与 query 原样转发；
  普通 JSON 接口不受影响。
- DeepSeek 实弹对照：同一个畸形 payload 直连返回 `422 missing field call_id`，
  经代理返回 `200`。

## 限制与注意

- 代理只修 `function_call` / `function_call_output` 这一类 schema 问题，
  不处理 `tool_search_call`（见
  [#44779](https://github.com/openai/codex/issues/44779)）、thinking 模式的
  reasoning 格式等其它严格校验。
- 不要只给孤立输出补一个假 `call_id`：上游会改报
  `No tool call found for tool output with call_id ...`（见
  [#45450](https://github.com/openai/codex/issues/45450)）。必须补配套的
  `function_call`，或者降级成普通 message —— 本代理选后者。
- 必须保持代理先于 Codex 运行；代理挂了 Codex 会连接失败。
- 只监听 `127.0.0.1`，不要改成 `0.0.0.0`：它会透传 Authorization，
  暴露到局域网等于开放中转。
- 密钥不要写进本仓库。推荐在 Codex 配置里用 `env_key = "DEEPSEEK_API_KEY"`
  从环境变量读取。

## License

MIT

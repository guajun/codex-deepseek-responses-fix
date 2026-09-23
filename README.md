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
  不处理 `tool_search_call`、thinking 模式的 reasoning 格式等其它严格校验。
- 必须保持代理先于 Codex 运行；代理挂了 Codex 会连接失败。
- 只监听 `127.0.0.1`，不要改成 `0.0.0.0`：它会透传 Authorization，
  暴露到局域网等于开放中转。
- 密钥不要写进本仓库。推荐在 Codex 配置里用 `env_key = "DEEPSEEK_API_KEY"`
  从环境变量读取。

## License

MIT

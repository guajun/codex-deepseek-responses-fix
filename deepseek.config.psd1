@{
    # DeepSeek Responses upstream. Keep the official endpoint, or point it at
    # a gateway/proxy if you use one. This is the only line most users edit.
    Upstream = 'https://api.deepseek.com'

    # Local listen address. Must match base_url in ~/.codex/config.toml.
    Listen = '127.0.0.1:8787'

    # Role used when an orphan function_call_output is rewritten into a
    # message: 'user' or 'developer'.
    Role = 'user'

    # Log a repair summary for every request.
    Verbose = $true

    # Log file. Empty string means "<repo>\proxy.log".
    LogFile = ''
}

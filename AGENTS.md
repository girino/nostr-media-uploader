# Local secret-handling rules

Do **not** read, print, grep, upload, or include in command output any local
credential-bearing file. This includes:

- `telegram_bot.yaml` and `telegram_bot.yaml*`
- `telegram_bot.conf`
- `firefox_cookies.txt*`
- `.nostr/`

Use the tracked `telegram_bot.yaml.example` when configuration structure is
needed. To validate a local configuration, use commands that return only a
success/failure result; never emit its contents or values. Treat service logs
as sensitive too: they can contain credential-bearing URLs and must be
redacted or avoided.

These local files must remain ignored by Git. Never force-add them.

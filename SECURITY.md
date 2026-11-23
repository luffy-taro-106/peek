# Security Policy

## Supported versions
Security fixes go into the latest release.

## Reporting a vulnerability
Please **don't open a public issue** for security problems. Instead use GitHub's
[private vulnerability reporting](https://github.com/luffy-taro-106/peek/security/advisories/new).
You'll get an answer within a few days.

## Security model (what Peek promises)
- The Claude Code hook server listens on **127.0.0.1 only** and never on your network.
- The hook is **fail-open**: if Peek isn't running or doesn't answer, Claude Code falls back to its own prompt. Peek never approves anything on its own.
- Installing hooks always writes a timestamped backup of `~/.claude/settings.json` first and leaves other hooks untouched.
- The `/debug/decide` endpoint used by tests exists only when Peek is started with `PEEK_DEBUG=1`.
- No analytics, telemetry or accounts. The only outbound requests go to Open-Meteo (weather, with rounded coordinates) and to artwork URLs provided by Spotify.

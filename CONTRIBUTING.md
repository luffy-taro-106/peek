# Contributing to Peek

Thanks for wanting to make Peek better! Whether it's a bug report, an idea, docs or code — it all helps.

## Ground rules
- Be kind. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- Open an issue before large changes so we can agree on the direction first.
- Keep Peek **private by default**: no analytics, no new network calls without a clear reason, and every new macOS permission must be requested only when the user opts into that feature.
- Claude Code integration must stay **fail-open**: if Peek is slow, crashed or not running, Claude Code must behave exactly as without Peek.

## Getting set up
```bash
git clone https://github.com/luffy-taro-106/peek.git
cd peek
make cert   # optional, keeps permissions across rebuilds
make run    # build, install to ~/Applications and launch
```
You need macOS 14+ on Apple Silicon and Xcode or the Command Line Tools. There's no Xcode project — it's a plain SwiftPM package, so any editor works.

## Making a change
1. Fork and create a branch: `git checkout -b feature/short-description`.
2. Keep changes focused; match the existing style (SwiftUI views in `*Views.swift`, one service per feature).
3. Run `make build` — it must compile without errors.
4. If you touched the UI, run `make previews` and include before/after screenshots in your PR.
5. If you touched Claude integration, test with *Settings › Claude › Send a test request* and with a real session.
6. Update `CHANGELOG.md` under **Unreleased**.
7. Open a pull request using the template.

## Project layout
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Reporting bugs
Use the **Bug report** issue template. Include your macOS version, Mac model, and if relevant the output of:
```bash
curl -s http://127.0.0.1:8799/state | python3 -m json.tool
```
(It contains session titles and project names — redact anything private before posting.)

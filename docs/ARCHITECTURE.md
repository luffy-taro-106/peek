# Architecture

Peek is a single SwiftPM executable (`Sources/Peek`) wrapped into an `.app` by `build.sh`.
It's a menu-bar (`LSUIElement`) app that draws a borderless, transparent panel over the notch.

```
                    ┌──────────────── AppDelegate ────────────────┐
                    │ owns every service, the window and hotkey   │
                    └──────┬──────────────────────────────────────┘
      ┌───────────┬────────┼─────────┬──────────────┬───────────────┐
 ClaudeHub   MusicService  Weather   CalendarService  PowerService
    ▲   ▲          ▲       Service         ▲               ▲
    │   │          │          ▲            │               │
HookServer  SessionDiscovery  │      EventKit       IOKit / IOBluetooth
(127.0.0.1)  (ps, lsof,     Open-Meteo              system_profiler
    ▲        transcripts)  + CoreLocation
    │
peek-hook  ◀── Claude Code hooks (~/.claude/settings.json)
```

## The notch window — `NotchWindow.swift`, `NotchViews.swift`, `DevicesViews.swift`
- `NotchWindowController` keeps a fixed 760×380 transparent `NSPanel` centred under the notch
  (`.statusBar + 1` level, on all Spaces). The visible black shape is drawn by SwiftUI.
- Mouse-move monitors decide whether the pointer is over the *visible* shape. Outside it the panel
  ignores the mouse, so the menu bar underneath keeps working. Hover opens, leaving closes, the pin
  keeps it open.
- `NotchState` holds `expanded`, `pinned`, the current tab and the size of the closed notch and its "wings".

## Claude Code — `ClaudeHub.swift`, `HookServer.swift`, `HookInstaller.swift`, `SessionDiscovery.swift`
Two sources feed one list of sessions:

1. **Hooks (precise, real time).** `HookInstaller` writes `~/.local/bin/peek-hook` (a bash + curl
   script) and registers it for Claude Code events. The script POSTs the hook's JSON to
   `HookServer` (`127.0.0.1:8799`, loopback only). For `PermissionRequest` the HTTP request stays open
   until you answer in the notch; the reply is printed on stdout in Claude Code's decision format
   (`allow` + `updatedInput` [+ `updatedPermissions`], or `deny` + `message`). Any error → no output →
   Claude shows its own prompt (fail-open).
2. **Discovery (complete).** `SessionDiscovery` scans running `claude` processes every 3 s, finds each
   one's working directory (`lsof`) and transcript (`~/.claude/projects/<cwd>/<session>.jsonl`, or the
   `--resume` id), and infers the state from the transcript's tail. This shows sessions started before
   Peek or without hooks. Fresh hook data always wins over a transcript guess.

Pending prompts are matched to their outcome by a fingerprint of `tool_name + tool_input`, so a gate is
released when Claude moves on (answered in the app, by a saved rule, or interrupted).

Chat titles come from the Claude desktop app's session store
(`~/Library/Application Support/Claude/claude-code-sessions`, matched by `cliSessionId`).

## Now Playing — `MusicService.swift`, `Helpers/`
macOS only serves the private MediaRemote framework to Apple-signed processes, so
`PeekMediaRemote.dylib` is loaded into `/usr/bin/perl` by `peek-mediaremote.pl`. It streams one JSON
line per change (title, artist, artwork, elapsed time, app) and sends play/pause/skip/seek commands.
If the bridge isn't available, Music and Spotify are read with AppleScript instead.

## Other services
- `WeatherService` — CoreLocation (or a chosen city) + the Open-Meteo forecast API, refreshed every 15 min.
- `CalendarService` — EventKit events for 3 days, meeting-link detection, reminders due today or overdue.
- `PowerService` — IOKit power-source notifications for the Mac battery; IOBluetooth connect
  notifications + `system_profiler SPBluetoothDataType` / IORegistry for device batteries.

## Screenshots
`Peek --render-previews <dir>` (`PreviewRenderer.swift`) renders the real views with built-in sample
data into PNGs — that's what `make previews` uses for the README. No user data is read.

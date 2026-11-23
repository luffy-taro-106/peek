# Changelog

All notable changes to Peek are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]
### Added
- **Show on** setting: put the notch on the main display (new default), the built-in screen, or the display with the pointer — for setups with an external monitor.

### Fixed
- Launching Peek while another copy is running now replaces the old copy instead of running two notches and two servers.

## [1.0.0] — 2026-11-23
### Added
- Notch overlay that opens on hover and closes when the pointer leaves; pin, ⌃⌥N shortcut and menu bar item.
- Claude Code: live list of every running session (desktop and terminal), discovered from processes and transcripts.
- Claude Code: answer prompts from the notch — Allow once, Always allow (Claude's suggested rule), Deny, multiple-choice questions and plan approvals; Stop and Open per session; fail-open hook.
- Now Playing from any app via a MediaRemote bridge, with AppleScript fallback for Music and Spotify.
- Calendar events with one-click Join for meeting links, and today's reminders.
- Weather from Open-Meteo with hourly and 6-day forecast.
- Mac battery with charging animation; Bluetooth device batteries (AirPods L/R/case and more) on connect.
- Stable local code signing (`make cert`) so permissions survive rebuilds.

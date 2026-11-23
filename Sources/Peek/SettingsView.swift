import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
            WeatherSettings().tabItem { Label("Weather", systemImage: "cloud.sun") }
            CalendarSettings().tabItem { Label("Calendar", systemImage: "calendar") }
            MusicSettings().tabItem { Label("Music", systemImage: "music.note") }
        }
        .frame(width: 560, height: 440)
    }
}

struct GeneralSettings: View {
    @AppStorage("hoverToExpand") private var hover = true
    @StateObject private var loginItemBox = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var loginErrorBox = Box<String?>(nil)
    var body: some View {
        Form {
            Section("Notch") {
                Toggle("Open the notch when the pointer rests on it", isOn: $hover)
                LabeledContent("Toggle the notch", value: "⌃⌥N")
                Text("Click the notch to keep it open. Click the pin to let it close when the pointer leaves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch Peek at login", isOn: $loginItemBox.v)
                    .onChange(of: loginItemBox.v) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginErrorBox.v = nil
                        } catch {
                            loginErrorBox.v = error.localizedDescription
                            loginItemBox.v = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let e = loginErrorBox.v { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClaudeSettings: View {
    @EnvironmentObject var hub: ClaudeHub
    @AppStorage("autoExpandOnApproval") private var autoExpand = true
    @AppStorage("approvalSound") private var sound = true
    @StateObject private var messageBox = Box<String?>(nil)
    @StateObject private var testingBox = Box(false)

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Local server", value: hub.serverStatus)
                LabeledContent("Claude Code hooks") {
                    Text(hub.hooksInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(hub.hooksInstalled ? .green : .orange)
                }
                HStack {
                    Button(hub.hooksInstalled ? "Reinstall hooks" : "Install hooks") {
                        run { try HookInstaller.install() }
                    }
                    if hub.hooksInstalled {
                        Button("Remove hooks") { run { try HookInstaller.uninstall() } }
                    }
                    Spacer()
                    Button(testingBox.v ? "Waiting for you in the notch…" : "Send a test request") { sendTest() }
                        .disabled(testingBox.v)
                }
                Text("Running sessions are found automatically, even ones started before Peek. Hooks add live tool updates and let you allow or deny from the notch. New sessions pick hooks up when they start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hub.otherHooksPresent {
                Section("Other notch apps") {
                    Text("Another notch app (NotchPilot) also has Claude Code hooks installed. If both run, Claude waits for both before continuing. Quit it or remove its hooks.")
                        .font(.callout)
                    Button("Remove NotchPilot hooks") { run { try HookInstaller.removeOtherNotchHooks() } }
                }
            }
            Section("Approvals") {
                Toggle("Open the notch when Claude needs approval", isOn: $autoExpand)
                Toggle("Play a sound", isOn: $sound)
            }
            if let m = messageBox.v { Section { Text(m).font(.caption) } }
        }
        .formStyle(.grouped)
        .onAppear { hub.refreshInstallState() }
    }

    private func run(_ action: () throws -> URL?) {
        do {
            let backup = try action()
            messageBox.v = backup.map { "Saved. Backup: \($0.path)" } ?? "Saved."
        } catch {
            messageBox.v = "Error: \(error.localizedDescription)"
        }
        hub.refreshInstallState()
    }

    private func sendTest() {
        let base = (try? String(contentsOf: HookServer.portFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "http://127.0.0.1:8799"
        guard let url = URL(string: base + "/hook/PermissionRequest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "session_id": "peek-test",
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path + "/peek-test",
            "tool_name": "Bash",
            "tool_input": ["command": "echo 'Hello from Peek'", "description": "Test request from Peek settings"],
        ])
        testingBox.v = true
        messageBox.v = "Answer the request in the notch…"
        URLSession.shared.dataTask(with: req) { data, _, error in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? "no reply"
            let verdict = text.contains("\"allow\"") ? "Allowed ✓" : text.contains("\"deny\"") ? "Denied ✓" : "Handed back to Claude"
            Task { @MainActor in
                testingBox.v = false
                messageBox.v = "Test finished: \(verdict)"
                hub.dismiss("peek-test")
            }
        }.resume()
    }
}

struct WeatherSettings: View {
    @EnvironmentObject var weather: WeatherService
    @AppStorage("weatherUnit") private var unit = "c"
    @AppStorage("weatherMode") private var mode = "auto"
    @AppStorage("manualCity") private var city = ""
    @StateObject private var queryBox = Box("")
    @StateObject private var resultsBox = Box<[PlaceResult]>([])

    var body: some View {
        Form {
            Section("Units") {
                Picker("Temperature", selection: $unit) {
                    Text("Celsius").tag("c")
                    Text("Fahrenheit").tag("f")
                }
                .pickerStyle(.segmented)
            }
            Section("Location") {
                Picker("Source", selection: $mode) {
                    Text("Current location").tag("auto")
                    Text("Chosen city").tag("manual")
                }
                .onChange(of: mode) { _, _ in weather.refresh() }
                if mode == "auto" {
                    HStack {
                        Text(weather.status ?? (weather.place.isEmpty ? "Locating…" : "Using \(weather.place)"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow location") { weather.requestPermission() }
                    }
                } else {
                    if !city.isEmpty { LabeledContent("City", value: city) }
                    TextField("Search a city", text: $queryBox.v)
                        .onSubmit { Task { resultsBox.v = await WeatherService.search(queryBox.v) } }
                    ForEach(resultsBox.v) { r in
                        Button { weather.setManual(r); resultsBox.v = []; queryBox.v = "" } label: {
                            VStack(alignment: .leading) {
                                Text(r.name)
                                Text(r.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                Button("Refresh now") { weather.refresh() }
                Text("Forecasts come from Open-Meteo (free, no account). Only rounded coordinates are sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct CalendarSettings: View {
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        Form {
            Section("Access") {
                row("Calendar", calendar.calendarStatus) { calendar.requestCalendar() }
                row("Reminders", calendar.remindersStatus) { calendar.requestReminders() }
                Button("Open Privacy settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
            Section {
                Text("Peek shows events from every calendar in the Calendar app (iCloud, Google, Exchange…) for the next 3 days, finds Zoom / Meet / Teams links, and lists today's and overdue reminders. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ name: String, _ status: EKAuthorizationStatus, _ request: @escaping () -> Void) -> some View {
        HStack {
            Text(name)
            Spacer()
            switch status {
            case .fullAccess: Text("Connected").foregroundStyle(.green)
            case .denied, .restricted: Text("Denied — allow in Privacy settings").foregroundStyle(.red)
            default: Button("Connect", action: request)
            }
        }
    }
}

struct MusicSettings: View {
    @EnvironmentObject var music: MusicService
    @AppStorage("musicSource") private var source = "auto"

    var body: some View {
        Form {
            Section("Player") {
                Picker("Follow", selection: $source) {
                    Text("Whatever is playing").tag("auto")
                    Text("Apple Music only").tag("music")
                    Text("Spotify only").tag("spotify")
                }
                .onChange(of: source) { _, _ in music.poll() }
                LabeledContent("Now", value: music.current.map { "\($0.title) — \($0.artist)" } ?? "Nothing playing")
            }
            Section {
                Text("The first time, macOS asks to let Peek control Music. If you said no, turn it on in System Settings › Privacy & Security › Automation.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Automation settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

import AppKit
import EventKit
import SwiftUI

struct AgendaEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: String
    let color: Color
    let location: String?
    let meetingURL: URL?
}

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let list: String
    let color: Color
    var isOverdue: Bool { (due ?? .distantFuture) < Calendar.current.startOfDay(for: Date()) }
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var calendarAccess = false
    @Published private(set) var remindersAccess = false
    @Published private(set) var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var remindersStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    var nextEvent: AgendaEvent? {
        let now = Date()
        return events.first { !$0.isAllDay && $0.end > now }
    }

    func start() {
        calendarAccess = calendarStatus == .fullAccess
        remindersAccess = remindersStatus == .fullAccess
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func requestCalendar() {
        store.requestFullAccessToEvents { granted, _ in
            Task { @MainActor in
                self.calendarAccess = granted
                self.calendarStatus = EKEventStore.authorizationStatus(for: .event)
                self.reload()
            }
        }
    }

    func requestReminders() {
        store.requestFullAccessToReminders { granted, _ in
            Task { @MainActor in
                self.remindersAccess = granted
                self.remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
                self.reload()
            }
        }
    }

    func reload() {
        let cs = EKEventStore.authorizationStatus(for: .event), rs = EKEventStore.authorizationStatus(for: .reminder)
        if cs != calendarStatus { calendarStatus = cs }
        if rs != remindersStatus { remindersStatus = rs }
        if calendarAccess != (cs == .fullAccess) { calendarAccess = cs == .fullAccess }
        if remindersAccess != (rs == .fullAccess) { remindersAccess = rs == .fullAccess }
        if calendarAccess { loadEvents() }
        if remindersAccess { loadReminders() }
    }

    private func loadEvents() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 3, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let now = Date()
        let fresh: [AgendaEvent] = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(30)
            .map { e in
                AgendaEvent(
                    id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                    title: e.title ?? "Untitled",
                    start: e.startDate,
                    end: e.endDate,
                    isAllDay: e.isAllDay,
                    calendar: e.calendar.title,
                    color: Color(nsColor: e.calendar.color ?? .systemBlue),
                    location: e.location,
                    meetingURL: Self.meetingURL(e)
                )
            }
        if fresh != events { events = fresh }
    }

    private func loadReminders() {
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        store.fetchReminders(matching: predicate) { found in
            let items: [ReminderItem] = (found ?? []).map { r in
                ReminderItem(
                    id: r.calendarItemIdentifier,
                    title: r.title ?? "Untitled",
                    due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                    list: r.calendar.title,
                    color: Color(nsColor: r.calendar.color ?? .systemOrange)
                )
            }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            Task { @MainActor in if self.reminders != items { self.reminders = items } }
        }
    }

    func complete(_ id: String) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        withAnimation { reminders.removeAll { $0.id == id } }
    }

    func addReminder(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, remindersAccess, let list = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = t
        r.calendar = list
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        try? store.save(r, commit: true)
        loadReminders()
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func openRemindersApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func meetingURL(_ e: EKEvent) -> URL? {
        let pattern = #"https?://[^\s<>"']*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|facetime\.apple\.com|gotomeeting\.com|chime\.aws|meet\.jit\.si)[^\s<>"']*"#
        let candidates = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        for text in candidates {
            if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               let url = URL(string: String(text[r])) {
                return url
            }
        }
        return nil
    }
}

extension CalendarService {
    func loadPreviewData() {
        calendarAccess = true; remindersAccess = true
        calendarStatus = .fullAccess; remindersStatus = .fullAccess
        let now = Date()
        func ev(_ t: String, _ inMin: Double, _ len: Double, _ c: Color, _ url: String? = nil, day: Double = 0) -> AgendaEvent {
            let start = now.addingTimeInterval(inMin * 60 + day * 86400)
            return AgendaEvent(id: t, title: t, start: start, end: start.addingTimeInterval(len * 60), isAllDay: false,
                               calendar: "Work", color: c, location: nil, meetingURL: url.flatMap(URL.init(string:)))
        }
        events = [
            ev("Design review", 12, 30, .blue, "https://meet.google.com/abc-defg-hij"),
            ev("1:1 with Sam", 75, 30, .orange, "https://zoom.us/j/123456789"),
            ev("Ship v1.2", 180, 60, .green),
            ev("Gym", 300, 60, .pink),
            ev("Team standup", 30, 15, .blue, "https://teams.microsoft.com/l/meetup-join/x", day: 1),
        ]
        reminders = [
            ReminderItem(id: "1", title: "Reply to Alex about the API", due: now, list: "Work", color: .orange),
            ReminderItem(id: "2", title: "Book flights", due: now.addingTimeInterval(-86400), list: "Personal", color: .blue),
            ReminderItem(id: "3", title: "Water the plants", due: now, list: "Home", color: .green),
        ]
    }
}

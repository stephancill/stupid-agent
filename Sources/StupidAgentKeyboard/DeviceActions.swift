#if os(iOS)
import AlarmKit
import EventKit
import StupidAgentCore
import SwiftUI

/// The keyboard assistant's tools on the device: Reminders and Calendar through EventKit, alarms and timers through
/// AlarmKit, and typing through the keyboard's text proxy. Permissions are granted in the app, which can prompt.
@MainActor
final class DeviceActions: AssistantActions {
    private let store = EKEventStore()
    private let insert: @MainActor (String) -> Void
    private let calendar: Calendar

    init(calendar: Calendar = .current, insert: @escaping @MainActor (String) -> Void) {
        self.calendar = calendar
        self.insert = insert
    }

    // MARK: Reminders

    func createReminder(title: String, due: LocalTime?, notes: String?) async throws -> String {
        try requireAccess(to: .reminder)
        guard let list = store.defaultCalendarForNewReminders() else { throw AssistantError("There's no default Reminders list.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = list
        if let due {
            let units: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = calendar.dateComponents(units, from: due.date)
            // Reminders only notifies for a due time with an alarm on it.
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        try store.save(reminder, commit: true)
        let when = due.map { " due \(LocalTime.format($0.date, hasTime: $0.hasTime, calendar: calendar))" } ?? ""
        return "Added the reminder \"\(title)\"\(when) to \(list.title)."
    }

    func listReminders() async throws -> String {
        try requireAccess(to: .reminder)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let calendar = calendar
        // Read into Sendable values on EventKit's queue; reminders themselves can't cross.
        let rows: [(due: Date?, line: String)] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { @Sendable reminders in
                let rows = (reminders ?? []).map { reminder -> (due: Date?, line: String) in
                    let components = reminder.dueDateComponents
                    let due = components.flatMap { calendar.date(from: $0) }
                    let hasTime = components?.hour != nil
                    let suffix = due.map { " (due \(LocalTime.format($0, hasTime: hasTime, calendar: calendar)))" } ?? ""
                    return (due, "- \(reminder.title ?? "Untitled")\(suffix)")
                }
                continuation.resume(returning: rows)
            }
        }
        guard !rows.isEmpty else { return "No incomplete reminders." }
        let sorted = rows.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        return sorted.prefix(50).map(\.line).joined(separator: "\n")
    }

    // MARK: Calendar

    func createEvent(title: String, start: LocalTime, end: LocalTime?, location: String?, notes: String?) async throws -> String {
        try requireAccess(to: .event)
        guard let target = store.defaultCalendarForNewEvents else { throw AssistantError("There's no default calendar.") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.location = location
        event.notes = notes
        event.calendar = target
        event.isAllDay = !start.hasTime
        event.startDate = start.date
        if let end, end.date > start.date {
            event.endDate = end.date
        } else {
            event.endDate = start.hasTime ? start.date.addingTimeInterval(3600) : start.date
        }
        try store.save(event, span: .thisEvent, commit: true)
        let range = start.hasTime
            ? "\(LocalTime.format(event.startDate, calendar: calendar)) to \(LocalTime.format(event.endDate, calendar: calendar))"
            : "all day \(LocalTime.format(start.date, hasTime: false, calendar: calendar))"
        return "Added \"\(title)\" \(range) to \(target.title)."
    }

    func listEvents(from start: Date, to end: Date) async throws -> String {
        try requireAccess(to: .event)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "No events in that range." }
        return events.prefix(50).map { event in
            let when = event.isAllDay
                ? "all day \(LocalTime.format(event.startDate, hasTime: false, calendar: calendar))"
                : "\(LocalTime.format(event.startDate, calendar: calendar)) to \(LocalTime.format(event.endDate, calendar: calendar))"
            let place = event.location.map { " at \($0)" } ?? ""
            return "- \(event.title ?? "Untitled"), \(when)\(place)"
        }.joined(separator: "\n")
    }

    private func requireAccess(to type: EKEntityType) throws {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else {
            let name = type == .reminder ? "Reminders" : "Calendars"
            throw AssistantError("No access to \(name). Ask the user to allow it in stupid agent → Settings → Keyboard.")
        }
    }

    // MARK: Alarms and timers

    func setAlarm(at date: Date, label: String?) async throws -> String {
        let id = try await scheduleAlarm(at: date, title: label ?? "Alarm")
        return "Set an alarm for \(LocalTime.format(date, calendar: calendar)) (id \(id))."
    }

    func setTimer(seconds: Int, label: String?) async throws -> String {
        // A fixed alarm at the end time: AlarmKit's countdown presentation needs a Live Activity widget.
        let date = Date().addingTimeInterval(TimeInterval(seconds))
        let id = try await scheduleAlarm(at: date, title: label ?? "Timer")
        return "Started a \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))) timer, ringing at \(LocalTime.format(date, calendar: calendar)) (id \(id))."
    }

    func listAlarms() async throws -> String {
        guard #available(iOS 26.0, *) else { throw AssistantError("Alarms need iOS 26 or later.") }
        let alarms = try AlarmManager.shared.alarms
        guard !alarms.isEmpty else { return "No alarms or timers." }
        let labels = AlarmLabels.load()
        return alarms.map { alarm in
            let title = labels[alarm.id.uuidString] ?? "Alarm"
            let when: String = switch alarm.schedule {
            case let .fixed(date)?: LocalTime.format(date, calendar: calendar)
            case let .relative(relative)?: String(format: "%02d:%02d", relative.time.hour, relative.time.minute)
            default: "unscheduled"
            }
            return "- \(title) at \(when) (id \(alarm.id.uuidString))"
        }.joined(separator: "\n")
    }

    func cancelAlarm(id: String) async throws -> String {
        guard #available(iOS 26.0, *) else { throw AssistantError("Alarms need iOS 26 or later.") }
        guard let uuid = UUID(uuidString: id) else { throw AssistantError("\(id) isn't an alarm id; get ids from list_alarms.") }
        try AlarmManager.shared.cancel(id: uuid)
        AlarmLabels.remove(id: uuid)
        return "Cancelled."
    }

    private func scheduleAlarm(at date: Date, title: String) async throws -> String {
        guard #available(iOS 26.0, *) else { throw AssistantError("Alarms need iOS 26 or later.") }
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw AssistantError("No access to alarms. Ask the user to allow them in stupid agent → Settings → Keyboard.")
        }
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource("\(title)"),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        )
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: AssistantAlarm(), tintColor: .orange)
        let id = UUID()
        _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attributes))
        AlarmLabels.set(title, id: id)
        return id.uuidString
    }

    // MARK: Text

    func insertText(_ text: String) async throws -> String {
        insert(text)
        return "Typed it."
    }
}

/// AlarmKit's metadata for the assistant's alarms; it carries nothing.
@available(iOS 26.0, *)
struct AssistantAlarm: AlarmMetadata {}

/// AlarmKit doesn't return an alarm's title, so the assistant keeps them by id for list_alarms.
enum AlarmLabels {
    private static let key = "assistantAlarmLabels"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupIdentifier) }

    static func load() -> [String: String] {
        defaults?.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func set(_ label: String, id: UUID) {
        var labels = load()
        labels[id.uuidString] = label
        defaults?.set(labels, forKey: key)
    }

    static func remove(id: UUID) {
        var labels = load()
        labels[id.uuidString] = nil
        defaults?.set(labels, forKey: key)
    }
}

#endif

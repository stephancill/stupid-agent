import Foundation
import PiAgent
import PiAI

/// A date the model gave, in the user's time zone: a day, or a day and a time.
public struct LocalTime: Sendable, Hashable {
    public var date: Date
    /// False for a date alone, such as an all-day event or a reminder due on a day.
    public var hasTime: Bool

    public init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }

    /// Reads `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS` as local time. A trailing zone (`Z` or an offset)
    /// is honored, since some models add one.
    public static func parse(_ text: String, calendar: Calendar = .current) -> LocalTime? {
        let value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        if value.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil, value.contains("T") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let withSeconds = value.range(of: #"T\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil
                ? value
                : value.replacingOccurrences(of: #"(T\d{2}:\d{2})"#, with: "$1:00", options: .regularExpression)
            return formatter.date(from: withSeconds).map { LocalTime(date: $0, hasTime: true) }
        }
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func group(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = group(1)
        components.month = group(2)
        components.day = group(3)
        let hasTime = group(4) != nil
        components.hour = group(4) ?? 0
        components.minute = group(5) ?? 0
        components.second = group(6) ?? 0
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return LocalTime(date: date, hasTime: hasTime)
    }

    /// The form the model reads and writes: `YYYY-MM-DDTHH:MM`, or `YYYY-MM-DD` without a time.
    public static func format(_ date: Date, hasTime: Bool = true, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard hasTime else { return day }
        return day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// What the keyboard assistant can do on the device. The keyboard implements it with EventKit, AlarmKit and the text
/// field; each method returns what the model is told, and throws to report a failure to it.
public protocol AssistantActions: Sendable {
    func createReminder(title: String, due: LocalTime?, notes: String?) async throws -> String
    func listReminders() async throws -> String
    func createEvent(title: String, start: LocalTime, end: LocalTime?, location: String?, notes: String?) async throws -> String
    func listEvents(from start: Date, to end: Date) async throws -> String
    func setAlarm(at date: Date, label: String?) async throws -> String
    func setTimer(seconds: Int, label: String?) async throws -> String
    func listAlarms() async throws -> String
    func cancelAlarm(id: String) async throws -> String
    func insertText(_ text: String) async throws -> String
}

public struct AssistantError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A voice request run against a fast model from the keyboard: the prompt, the tools and a single run.
public enum KeyboardAssistant {
    /// The model the keyboard uses on OpenRouter unless Settings name another: fast, cheap and reliable with tools.
    public static let defaultOpenRouterModel = "deepseek/deepseek-v4.1-flash"

    public static func systemPrompt(now: Date = Date(), calendar: Calendar = .current) -> String {
        let weekday = DateFormatter()
        weekday.calendar = calendar
        weekday.timeZone = calendar.timeZone
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.dateFormat = "EEEE"
        // Small models get weekdays wrong ("Friday" a week late), so the coming week is spelled out.
        let nextDays = (1 ... 7).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            return "\(weekday.string(from: day)) \(LocalTime.format(day, hasTime: false, calendar: calendar))"
        }
        return """
        You are a voice assistant in the user's iPhone keyboard. The user spoke a request; it was transcribed on the \
        device, so it may contain recognition errors. Do what they ask with your tools, then reply with one short \
        sentence saying what you did or answering the question. The reply is shown in the keyboard, not typed.

        - Act at once; there is no follow-up conversation. Make each change once, with everything it needs in one call. Pick sensible defaults rather than asking (morning is 9:00, \
        afternoon 15:00, evening 18:00, tonight 20:00; a bare hour means the next time that hour comes).
        - Use insert_text only when the user wants text written into the field, such as a message, a reply or a note. \
        Write it as the user would, without quotes or commentary. The field's current text is given when there is any.
        - Answer questions from what you know in one or two sentences.
        - Times are the user's local time. Now is \(weekday.string(from: now)) \(LocalTime.format(now, calendar: calendar)). \
        The next days are \(nextDays.joined(separator: ", ")).
        """
    }

    /// The user's request, with the text around the cursor when the field has any.
    public static func userMessage(request: String, fieldText: String?) -> String {
        guard let fieldText, !fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return request }
        return "\(request)\n\n<field>\n\(fieldText)\n</field>"
    }

    public static func tools(actions: any AssistantActions, calendar: Calendar = .current) -> [AgentTool] {
        let time: JSONValue = ["type": "string", "description": "Local date and time, YYYY-MM-DDTHH:MM"]
        let dateOrTime: JSONValue = ["type": "string", "description": "Local date and time, YYYY-MM-DDTHH:MM, or a date YYYY-MM-DD"]
        let string: JSONValue = ["type": "string"]
        let empty: JSONValue = ["type": "object", "properties": [:]]

        @Sendable func localTime(_ arguments: JSONObject, _ key: String) throws -> LocalTime? {
            guard let text = arguments[key]?.stringValue, !text.isEmpty else { return nil }
            guard let value = LocalTime.parse(text, calendar: calendar) else {
                throw AssistantError("\(key) must be YYYY-MM-DDTHH:MM or YYYY-MM-DD, not \(text).")
            }
            return value
        }
        @Sendable func text(_ arguments: JSONObject, _ key: String) -> String? {
            guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        @Sendable func requiredText(_ arguments: JSONObject, _ key: String) throws -> String {
            guard let value = text(arguments, key) else { throw AssistantError("\(key) is required.") }
            return value
        }
        func tool(_ name: String, _ label: String, _ description: String, _ parameters: JSONValue, _ run: @escaping @Sendable (JSONObject) async throws -> String) -> AgentTool {
            AgentTool(name: name, label: label, description: description, parameters: parameters) { _, arguments, _ in
                AgentToolResult(text: try await run(arguments))
            }
        }

        return [
            tool("create_reminder", "Add Reminder", "Add a reminder to the Reminders app. With a due time, the user is notified then.", [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What to be reminded of, short"],
                    "due": ["type": "string", "description": "Local date and time, YYYY-MM-DDTHH:MM, or a date YYYY-MM-DD. Omit for no due date."],
                    "notes": string,
                ],
                "required": ["title"],
            ]) { arguments in
                try await actions.createReminder(title: try requiredText(arguments, "title"), due: try localTime(arguments, "due"), notes: text(arguments, "notes"))
            },
            tool("list_reminders", "List Reminders", "List incomplete reminders, soonest due first.", empty) { _ in
                try await actions.listReminders()
            },
            tool("create_event", "Add Event", "Add an event to the user's calendar.", [
                "type": "object",
                "properties": [
                    "title": string,
                    "start": ["type": "string", "description": "Local date and time, YYYY-MM-DDTHH:MM, or a date YYYY-MM-DD for an all-day event"],
                    "end": ["type": "string", "description": "Same format as start. Omit for one hour (or one day for an all-day event)."],
                    "location": string,
                    "notes": string,
                ],
                "required": ["title", "start"],
            ]) { arguments in
                guard let start = try localTime(arguments, "start") else { throw AssistantError("start is required.") }
                return try await actions.createEvent(
                    title: try requiredText(arguments, "title"), start: start, end: try localTime(arguments, "end"),
                    location: text(arguments, "location"), notes: text(arguments, "notes")
                )
            },
            tool("list_events", "List Events", "List calendar events that overlap a range.", [
                "type": "object",
                "properties": [
                    "start": dateOrTime,
                    "end": ["type": "string", "description": "Same format; a date alone means the end of that day"],
                ],
                "required": ["start", "end"],
            ]) { arguments in
                guard let start = try localTime(arguments, "start"), let end = try localTime(arguments, "end") else {
                    throw AssistantError("start and end are required.")
                }
                let endDate = end.hasTime ? end.date : calendar.date(byAdding: .day, value: 1, to: end.date) ?? end.date
                return try await actions.listEvents(from: start.date, to: endDate)
            },
            tool("set_alarm", "Set Alarm", "Set an alarm that rings at a time, even in silent mode.", [
                "type": "object",
                "properties": ["time": time, "label": string],
                "required": ["time"],
            ]) { arguments in
                guard let at = try localTime(arguments, "time"), at.hasTime else { throw AssistantError("time must include a time of day.") }
                guard at.date > Date() else { throw AssistantError("\(LocalTime.format(at.date, calendar: calendar)) has passed; pick a time in the future.") }
                return try await actions.setAlarm(at: at.date, label: text(arguments, "label"))
            },
            tool("set_timer", "Start Timer", "Start a timer that rings after a duration.", [
                "type": "object",
                "properties": ["seconds": ["type": "integer", "minimum": 1], "label": string],
                "required": ["seconds"],
            ]) { arguments in
                guard let seconds = arguments["seconds"]?.intValue ?? arguments["seconds"]?.doubleValue.map({ Int($0) }), seconds > 0 else {
                    throw AssistantError("seconds must be a positive whole number.")
                }
                return try await actions.setTimer(seconds: seconds, label: text(arguments, "label"))
            },
            tool("list_alarms", "List Alarms", "List the alarms and timers this assistant set that haven't rung yet.", empty) { _ in
                try await actions.listAlarms()
            },
            tool("cancel_alarm", "Cancel Alarm", "Cancel an alarm or timer by its id from list_alarms.", [
                "type": "object",
                "properties": ["id": string],
                "required": ["id"],
            ]) { arguments in
                try await actions.cancelAlarm(id: try requiredText(arguments, "id"))
            },
            tool("insert_text", "Type", "Type text into the text field the user is in, at the cursor.", [
                "type": "object",
                "properties": ["text": string],
                "required": ["text"],
            ]) { arguments in
                guard let value = arguments["text"]?.stringValue, !value.isEmpty else { throw AssistantError("text is required.") }
                return try await actions.insertText(value)
            },
        ]
    }

    /// Runs one request to the end and returns the model's reply. Cancelling the task aborts the run.
    public static func run(
        request: String,
        fieldText: String?,
        model: Model,
        options: StreamOptions,
        actions: any AssistantActions,
        now: Date = Date(),
        calendar: Calendar = .current,
        streamFunction: @escaping StreamFunction = defaultStreamFunction
    ) async throws -> String {
        var options = options
        // Speed over depth: no thinking, and a reply is a sentence.
        options.reasoning = nil
        options.maxTokens = options.maxTokens ?? 1000
        let agent = Agent(
            model: model,
            systemPrompt: systemPrompt(now: now, calendar: calendar),
            tools: tools(actions: actions, calendar: calendar),
            thinkingLevel: .off,
            streamOptions: options,
            streamFunction: streamFunction
        )
        try await withTaskCancellationHandler {
            try await agent.prompt(userMessage(request: request, fieldText: fieldText))
        } onCancel: {
            Task { await agent.abort() }
        }
        try Task.checkCancellation()
        guard let last = await agent.state.messages.last?.assistant else { throw AssistantError("The model didn't answer.") }
        switch last.stopReason {
        case .error, .aborted:
            throw AssistantError(last.errorMessage ?? "The request failed.")
        default:
            return last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

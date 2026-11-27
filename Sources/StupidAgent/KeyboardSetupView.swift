// The app is iOS-only; the guard lets `swift test` build the package on macOS for the core tests.
#if os(iOS)
import AlarmKit
import AVFoundation
import EventKit
import Speech
import SwiftUI

/// Permissions and setup for the keyboard assistant. The keyboard can't show permission prompts, so the app asks.
struct KeyboardSetupView: View {
    @State private var statuses = PermissionStatuses.current()
    @State private var requestError: String?
    @State private var tryText = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                permissionRow("Microphone", granted: statuses.microphone) { await Permissions.requestMicrophone() }
                permissionRow("Speech Recognition", granted: statuses.speech) { await Permissions.requestSpeech() }
                permissionRow("Reminders", granted: statuses.reminders) { try await Permissions.requestReminders() }
                permissionRow("Calendars", granted: statuses.calendars) { try await Permissions.requestCalendars() }
                if #available(iOS 26.0, *) {
                    permissionRow("Alarms", granted: statuses.alarms) { try await Permissions.requestAlarms() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                if let requestError {
                    Text(requestError).foregroundStyle(.red)
                } else {
                    Text("The keyboard uses what you allow here. If you denied something before, change it in the Settings app.")
                }
            }

            Section {
                Text("In the Settings app, go to General → Keyboard → Keyboards → Add New Keyboard, choose stupid agent, then tap it and turn on Allow Full Access.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: {
                Text("Add the Keyboard")
            } footer: {
                Text("Full Access lets the keyboard reach your model and read the settings saved here.")
            }

            Section {
                TextField("Switch to the stupid agent keyboard here", text: $tryText, axis: .vertical)
                    .lineLimit(2 ... 6)
            } header: {
                Text("Try It")
            } footer: {
                Text("Tap Ask and say something like “remind me to call Mom tomorrow at 6”, “wake me up at 6:30”, “set a timer for 10 minutes” or “reply that I'm running late”. Listening stops when you pause.")
            }
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { statuses = PermissionStatuses.current() }
        }
    }

    private func permissionRow(_ title: String, granted: Bool?, request: @escaping @MainActor () async throws -> Void) -> some View {
        LabeledContent(title) {
            switch granted {
            case true?: Text("Allowed")
            case false?: Text("Denied")
            case nil:
                Button("Allow") {
                    Task {
                        do {
                            try await request()
                            requestError = nil
                        } catch {
                            requestError = "\(title): \(error.localizedDescription)"
                        }
                        statuses = PermissionStatuses.current()
                    }
                }
            }
        }
    }
}

/// Each permission the keyboard needs: allowed, denied (or restricted), or nil when not asked yet.
private struct PermissionStatuses {
    var microphone: Bool?
    var speech: Bool?
    var reminders: Bool?
    var calendars: Bool?
    var alarms: Bool?

    static func current() -> PermissionStatuses {
        let microphone: Bool? = switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: nil
        }
        let speech: Bool? = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: true
        case .notDetermined: nil
        default: false
        }
        return PermissionStatuses(microphone: microphone, speech: speech, reminders: eventKit(.reminder), calendars: eventKit(.event), alarms: alarmStatus())
    }

    private static func eventKit(_ type: EKEntityType) -> Bool? {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: true
        case .notDetermined: nil
        // Write-only access can't list, so the keyboard treats it as denied.
        default: false
        }
    }

    private static func alarmStatus() -> Bool? {
        guard #available(iOS 26.0, *) else { return false }
        return switch AlarmManager.shared.authorizationState {
        case .authorized: true
        case .denied: false
        default: nil
        }
    }
}

/// Permission prompts. Nonisolated so callbacks from system queues don't inherit the main actor.
private enum Permissions {
    static func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
    }

    static func requestSpeech() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable _ in continuation.resume() }
        }
    }

    static func requestReminders() async throws {
        _ = try await EKEventStore().requestFullAccessToReminders()
    }

    static func requestCalendars() async throws {
        _ = try await EKEventStore().requestFullAccessToEvents()
    }

    static func requestAlarms() async throws {
        guard #available(iOS 26.0, *) else { return }
        _ = try await AlarmManager.shared.requestAuthorization()
    }
}

#endif

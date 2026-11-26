#if os(iOS)
import AVFoundation
import OSLog
import PiAI
import Speech
import StupidAgentCore
import UIKit

private let log = Logger(subsystem: "net.stupidtech.StupidAgent.keyboard", category: "assistant")

/// A keyboard that takes a spoken request and hands it to a fast model with tools for reminders, events, alarms,
/// timers and typing, without leaving the app the user is in. Audio comes through a hidden web view (see
/// `WebAudioCapture`), speech becomes text with Apple's recognizer, and the reply shows in the keyboard.
@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private enum Phase: Equatable {
        case idle
        case listening
        /// Audio has stopped; waiting for the recognizer's final text.
        case transcribing
        case working
    }

    private let capture = WebAudioCapture()
    private let askButton = UIButton(configuration: .filled())
    private let nextKeyboardButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let replyLabel = UILabel()
    private let detailLabel = UILabel()

    private var phase = Phase.idle
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: WebAudioCapture.sampleRate, channels: 1, interleaved: true)!
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var transcript = ""
    private var lastTranscriptChange = Date()
    private var listenStarted = Date()
    private var silenceTimer: Timer?
    private var finalTimeout: Timer?
    private var runTask: Task<Void, Never>?

    /// After speech, this much quiet ends listening, as Siri does.
    private static let silence: TimeInterval = 1.4
    private static let longestRequest: TimeInterval = 30

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        capture.onReady = { [weak self] in self?.render() }
        capture.onAudio = { [weak self] data, rms in self?.append(data, rms: rms) }
        capture.onEnded = { [weak self] reason in self?.captureEnded(reason) }
        // The simulator test path needs no microphone, and WebKit in a keyboard is unreliable on some simulators.
        if Self.simulatorTestRequest == nil { capture.attach(to: view) }
        showIdle()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancel()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
    }

    // MARK: - Listening

    @objc private func askTapped() {
        switch phase {
        case .idle: startListening()
        case .listening: stopListening()
        case .transcribing, .working: cancel()
        }
    }

    private func startListening() {
        if let request = Self.simulatorTestRequest {
            transcript = request
            phase = .transcribing
            return submitTranscript()
        }
        guard hasFullAccess else {
            return showMessage("Turn on Allow Full Access", detail: "Settings → General → Keyboard → Keyboards → stupid agent.")
        }
        guard AVAudioApplication.shared.recordPermission == .granted, SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return showMessage("Allow the microphone and speech recognition", detail: "Open stupid agent → Settings → Keyboard.")
        }
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            return showMessage("Speech recognition is unavailable right now", detail: nil)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .search
        self.recognizer = recognizer
        self.request = request
        transcript = ""
        listenStarted = Date()
        lastTranscriptChange = Date()
        // @Sendable: the recognizer calls back on its own queue, so the closure mustn't inherit the main actor.
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in self?.recognized(text: text, isFinal: isFinal, error: failure) }
        }
        phase = .listening
        capture.start()
        showMessage("Listening…", detail: nil)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSilence() }
        }
        render()
    }

    private func checkSilence() {
        guard phase == .listening else { return }
        let quiet = !transcript.isEmpty && Date().timeIntervalSince(lastTranscriptChange) > Self.silence
        if quiet || Date().timeIntervalSince(listenStarted) > Self.longestRequest { stopListening() }
    }

    private func stopListening() {
        guard phase == .listening else { return }
        phase = .transcribing
        capture.stop()
    }

    private func captureEnded(_ reason: String) {
        log.info("capture ended: \(reason, privacy: .public)")
        silenceTimer?.invalidate()
        silenceTimer = nil
        if phase == .listening { phase = .transcribing }
        guard phase == .transcribing else { return }
        request?.endAudio()
        if reason != "stopped", transcript.isEmpty {
            return finishWithError("The microphone stopped (\(reason)).")
        }
        // The final result usually follows endAudio at once; don't wait on it for long.
        finalTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.submitTranscript() }
        }
        render()
    }

    private func append(_ data: Data, rms: Float) {
        guard phase == .listening, let request else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        request.append(buffer)
        askButton.alpha = 0.7 + CGFloat(min(rms * 6, 0.3))
    }

    private func recognized(text: String?, isFinal: Bool, error: String?) {
        guard phase == .listening || phase == .transcribing else { return }
        if let text, text != transcript {
            transcript = text
            lastTranscriptChange = Date()
            // The newest words matter while listening, so a long request loses its start.
            if phase == .listening { showMessage(text, detail: "Listening…", keepEnd: true) }
        }
        if isFinal {
            submitTranscript()
        } else if let error {
            log.error("recognition error: \(error, privacy: .public)")
            if transcript.isEmpty {
                capture.stop()
                finishWithError(phase == .transcribing ? "Didn't catch that." : error)
            } else {
                submitTranscript()
            }
        }
    }

    // MARK: - Running

    private func submitTranscript() {
        guard phase == .listening || phase == .transcribing else { return }
        if phase == .listening { capture.stop() }
        endRecognition()
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return finishWithError("Didn't catch that.") }

        let store: SettingsStore
        do {
            store = try SettingsStore.shared()
        } catch {
            return finishWithError(error.localizedDescription)
        }
        let settings = store.load()
        let apiKey = store.apiKey()
        guard settings.isComplete(apiKey: apiKey) else {
            return finishWithError("Set up a model in stupid agent first.")
        }

        phase = .working
        showMessage("“\(spoken)”", detail: "Working…")
        render()
        let fieldText = [textDocumentProxy.documentContextBeforeInput, textDocumentProxy.selectedText, textDocumentProxy.documentContextAfterInput]
            .compactMap { $0 }.joined()
        let actions = DeviceActions { [weak self] text in self?.textDocumentProxy.insertText(text) }
        let options = StreamOptions(apiKey: apiKey, headers: settings.requestHeaders, timeout: 30)
        let started = Date()
        runTask = Task { [weak self] in
            do {
                let reply = try await KeyboardAssistant.run(request: spoken, fieldText: fieldText, model: settings.assistantModel, options: options, actions: actions)
                log.info("answered in \(Date().timeIntervalSince(started), privacy: .public)s")
                self?.finish(reply: reply.isEmpty ? "Done." : reply, spoken: spoken)
            } catch is CancellationError {
                self?.showIdle()
            } catch {
                guard self?.phase == .working else { return }
                self?.finishWithError(error.localizedDescription)
            }
        }
    }

    private func finish(reply: String, spoken: String) {
        guard phase == .working else { return }
        runTask = nil
        phase = .idle
        showMessage(reply, detail: "“\(spoken)”")
        render()
    }

    private func finishWithError(_ message: String) {
        endRecognition()
        runTask = nil
        phase = .idle
        showMessage(message, detail: nil, isError: true)
        render()
    }

    private func cancel() {
        let wasActive = phase != .idle
        runTask?.cancel()
        runTask = nil
        capture.stop()
        endRecognition()
        phase = .idle
        if wasActive { showIdle() }
        render()
    }

    private func endRecognition() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        finalTimeout?.invalidate()
        finalTimeout = nil
        recognition?.cancel()
        recognition = nil
        request = nil
    }

    // MARK: - Keys

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    // MARK: - UI

    private func configureView() {
        let height = view.heightAnchor.constraint(equalToConstant: 216)
        height.priority = .defaultHigh
        height.isActive = true

        replyLabel.font = .preferredFont(forTextStyle: .body)
        replyLabel.adjustsFontForContentSizeCategory = true
        replyLabel.numberOfLines = 4
        replyLabel.textAlignment = .center

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.textAlignment = .center

        askButton.addTarget(self, action: #selector(askTapped), for: .touchUpInside)

        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.tintColor = .label
        nextKeyboardButton.accessibilityLabel = "Next Keyboard"
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .label
        deleteButton.accessibilityLabel = "Delete"
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        returnButton.setImage(UIImage(systemName: "return"), for: .normal)
        returnButton.tintColor = .label
        returnButton.accessibilityLabel = "Return"
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        let keys = UIStackView(arrangedSubviews: [nextKeyboardButton, UIView(), returnButton, deleteButton])
        keys.spacing = 8
        for key in [nextKeyboardButton, returnButton, deleteButton] {
            key.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }

        for subview in [replyLabel, detailLabel, askButton, keys] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            replyLabel.topAnchor.constraint(equalTo: margins.topAnchor, constant: 4),
            replyLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            replyLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            detailLabel.topAnchor.constraint(equalTo: replyLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            askButton.topAnchor.constraint(greaterThanOrEqualTo: detailLabel.bottomAnchor, constant: 8),
            askButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            askButton.widthAnchor.constraint(equalTo: margins.widthAnchor, multiplier: 0.6),
            askButton.heightAnchor.constraint(equalToConstant: 52),
            askButton.bottomAnchor.constraint(equalTo: keys.topAnchor, constant: -8),

            keys.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            keys.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            keys.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func render() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 8
        switch phase {
        case .idle:
            askButton.alpha = 1
            configuration.title = capture.isReady || Self.simulatorTestRequest != nil ? "Ask" : "Loading…"
            configuration.image = UIImage(systemName: "mic.fill")
            configuration.baseBackgroundColor = .systemBlue
        case .listening:
            configuration.title = "Done"
            configuration.image = UIImage(systemName: "waveform")
            configuration.baseBackgroundColor = .systemRed
        case .transcribing, .working:
            askButton.alpha = 1
            configuration.title = "Cancel"
            configuration.image = UIImage(systemName: "xmark")
            configuration.baseBackgroundColor = .systemGray
        }
        askButton.configuration = configuration
        askButton.isEnabled = capture.isReady || phase != .idle || Self.simulatorTestRequest != nil
    }

    /// Simulator builds only: a request stored under `keyboardTestRequest` in the App Group's defaults is sent by Ask
    /// in place of speech, so everything after the microphone can be tested where there is none.
    private static var simulatorTestRequest: String? {
        #if targetEnvironment(simulator)
        UserDefaults(suiteName: appGroupIdentifier)?.string(forKey: "keyboardTestRequest")
        #else
        nil
        #endif
    }

    private func showIdle() {
        showMessage("Ask for a reminder, an alarm, a timer or an event, or to write something.", detail: nil)
    }

    private func showMessage(_ text: String, detail: String?, isError: Bool = false, keepEnd: Bool = false) {
        replyLabel.text = text
        replyLabel.lineBreakMode = keepEnd ? .byTruncatingHead : .byTruncatingTail
        replyLabel.textColor = isError ? .systemRed : .label
        detailLabel.text = detail
    }
}

#endif

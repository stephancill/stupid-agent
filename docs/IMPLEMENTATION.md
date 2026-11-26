# Implementation notes

## Agent core

- **Source:** swift pi, a package dependency pinned in `Package.resolved`. It was vendored while stupid-app built only local sources; stupid-app 0.0.27 resolves package dependencies.
- **Session:** `AgentSession` owns one swift pi `Agent`:
  - its system prompt is `systemPrompt(workspaceName:)`
  - its tools are `fileTools(workspace:)`
  - its transcript is the conversation's
- **Messages:** the agent's event stream is the only source of `AgentSession.messages`. The run finishes, and the conversation is saved, when the `agentEnd` event is handled. An earlier version replaced `messages` with the agent's state after `prompt()` returned. Events still queued then were appended again, which duplicated replies.
- **Title:** a new conversation takes its title from the first message as soon as it is sent. Beside the run, `TitleGenerator` asks the same model for a title of at most six words (thinking off, 100 tokens). The answer's first line, without quotes, markdown or a closing period, replaces the first-message title unless the title changed meanwhile, and is saved. A failed or empty answer keeps the first-message title, since a title isn't worth an error.
- **Sending while running:** a message sent while the agent runs goes to `Agent.steer`. It is read after the current tool calls, before the next request.
- **Retry:** drops the failed responses at the end of the agent's transcript (keeping its leading system message), then calls `continueRun()`.
- **Stop:** `Agent.abort()`. It also declines a pending file-change request.

## Web and JavaScript tools

- **Source:** swift pi's `webTools` (`web_search`, `web_fetch`) and `javaScriptTool`, added to the session's tools beside the file and sqlite tools (`AgentSession.tools`).
- **web_search:** asks Exa or Parallel through their keyless MCP servers, the ones opencode uses. Settings → Tools picks the provider (`ModelSettings.webSearchProvider`, Exa by default); there is no fallback between them.
- **javascript:** runs in an offscreen web view with read-only workspace access, so its runs need no approval. File changes still go through `write`/`edit`.
- **Cards:** "Search the web for <query>", "Fetch <host/path>" and "Run JavaScript", with the result as the card's text.
- **Verified:** with OpenRouter (`openai/gpt-4o-mini`) on the simulator, web_search found the latest Swift release and javascript worked out the days since it.

## File changes

- When "Ask Before Changing Files" is on, `beforeToolCall` blocks `write` and `edit` calls until the user answers a centered alert (`FileChangeRequest`).
- Requests from parallel calls queue one at a time.
- A declined change returns an error result telling the model the user declined.

## Workspace

- The app's Documents folder. `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` make it visible in Files under On My iPhone → stupid agent.
- On first launch the app writes `Welcome.md`, so the folder appears in Files and the agent has something to read.
- swift pi's `Workspace` rejects paths outside the folder.
- Conversations are stored outside the workspace, in Application Support/Conversations: one JSON file per conversation plus `index.json`. Dates use JSONEncoder's default encoding, because ISO 8601 dropped fractional seconds and saved conversations didn't read back equal.

## Other apps' containers

- **Off by default:** Settings → Workspace → "Access Other Apps" (`ModelSettings.allowOtherApps`). When on, the agent's tools are swift pi's file tools plus `apps`; when off, the tool set is exactly the workspace tools. `AgentSession.update` sets the new tools, so the switch applies to open conversations.
- **Reach:** `SandboxBridge` is a clean-room implementation of the worse_query technique: it replaces the App Group's `Library/Caches` with a symlink to a target, asks containermanagerd for a sandbox token through `container_query_*`, and consumes it with `sandbox_extension_consume`. The grant lasts for the process.
- **Prerequisites:** the App Group `group.net.stupidtech.StupidAgent` in `App.entitlements` and `stupid-app.yml` (`APP_GROUPS`), associated with the bundle ID in the Developer Portal. The association is a manual portal step, so a profile made before it doesn't authorize the entitlement and `signing setup` has to be rerun after it.
- **Platforms:** iOS 26 and 27 on a real device. Simulator builds report the feature unavailable, because containermanager there is the host's.
- **Paths:** `/apps/<bundle id>/…` for app data containers and `/app-groups/<group id>/…` for App Groups. `apps` lists them. A container path is resolved and granted, then the same swift pi tool runs with the container as its `Workspace`, so workspace containment is unchanged and file-tool behavior is identical.
- **SQLite:** the `sqlite` tool reads a database from the workspace or a container. It opens read-only (with an `immutable=1` fallback for a WAL database whose sidecars can't be opened), sets `PRAGMA query_only`, rejects non-read-only statements and multiple statements, and stops runaway queries with a progress-handler step budget. Results are JSON rows with a row limit and a 64KB cap; blobs are described, not returned.
- **Discovery:** `SandboxContainers` finds App Groups by listing `/var/mobile/Containers/Shared/AppGroup` (the parent grant works on iOS 27) and finds Application containers by resolving the volume's inodes to paths with `fsgetpath` (the parent isn't listable), reading `com.apple.containermanager.identifier` from each candidate. `fsgetpath` is serialized by a kernel lock, so the scan can't be parallelized; threads only contend.
- **Background index:** discovery runs as a background index (`startIndexing`), not lazily, so the slow scan doesn't block the agent. `containers()` returns whatever is resolved so far (partial results), and `indexStatus` (on `AppContainerAccess`) reports `unavailable`/`indexing(found, scanned, total)`/`ready`. The `apps` tool notes "still indexing" with the percentage; `ContainerIndex` (an `@Observable` owned by `AppModel`) drives the "App Index" section in Settings, which shows the found count, a background "checking for recently-installed apps" sweep, last-indexed time and a Reindex button. The index starts at launch and when the user turns "Access Other Apps" on.
- **Scan cost and cache:** the scan covers inodes `1…newest` (the newest inode, from a freshly created temp file, bounds anything that already exists; capped by a safety ceiling). App containers get their inode at install time and inodes only increase, so existing apps cluster at low inodes and are found in the first ~1% — the rest of the sweep is empty space, only worth covering because a recently-installed app would have a high inode. The result is cached in `UserDefaults` per root as the found paths plus a high-water inode; a later launch scans only the tail above it, reuses the cached paths (dropping any whose directory is gone), and picks up newly-installed apps. So the full scan is a one-time cost per install of this app; later launches are near-instant.
- **Approvals:** writes still go through "Ask Before Changing Files", and the alert says the file is in another app's container.
- **Shared container:** every grant removes the App Group's `Library/Caches` and leaves it empty, so that directory is reserved for this feature. The group's user defaults (`Library/Preferences`) hold the settings shared with the keyboard.
- **Distribution:** private API and a sandbox escape. This can't ship on the App Store.


## Keyboard assistant

- **What:** a custom keyboard (`StupidAgentKeyboard`, bundle `net.stupidtech.StupidAgent.keyboard`) with an Ask button. The user speaks; a fast model with device tools acts and its one-sentence reply shows in the keyboard. No app switch.
- **Audio:** `WebAudioCapture`, from github.com/stephancill/ios-keyboard-dictation, adapted to Swift 6 (the media-permission delegate is the async form, so it matches the SDK's `@MainActor @Sendable` handler). A hidden `WKWebView` runs `getUserMedia` in WebKit's processes and posts 16 kHz Int16 PCM, because `AVAudioEngine` in the keyboard process gets the extension killed.
- **Speech:** `SFSpeechRecognizer` (device locale, punctuation, partial results). The result handler is `@Sendable` and hops to the main actor with plain values; a closure that inherited the main actor would trap when the recognizer calls it on its queue. Listening stops after 1.4 s without new words once something was heard, at 30 s, or on Done. After the audio ends, the final result is awaited for at most 1.5 s, then the last partial is used.
- **Run:** `KeyboardAssistant.run` builds a swift pi `Agent` with `KeyboardAssistant.systemPrompt` and `tools(actions:)`, thinking off and 1000 max tokens, prompts it once and returns the last assistant text; an error or abort throws. Cancelling the Swift task aborts the agent. The user message carries the field's text (before, selected, after the cursor) in a `<field>` block so replies have context.
- **Prompt:** act at once without follow-up questions, defaults for vague times, `insert_text` only for text meant for the field, and now plus the next seven days spelled out with weekdays. Without the list, Gemini 2.5 Flash Lite put "Friday" a week late.
- **Tools:** `create_reminder`, `list_reminders`, `create_event`, `list_events`, `set_alarm`, `set_timer`, `list_alarms`, `cancel_alarm`, `insert_text`. Dates are local `YYYY-MM-DDTHH:MM` or `YYYY-MM-DD` (`LocalTime`; seconds, a space or an explicit zone are accepted). Argument errors and past alarm times throw, so the model sees them.
- **Device side:** `DeviceActions` (main actor). Reminders and events go to the default list and calendar through EventKit and need full access. A reminder with a due time gets an `EKAlarm` so it notifies. Alarms are AlarmKit (iOS 26) fixed-date alarms; a timer is a fixed alarm at now + duration, because AlarmKit's countdown presentation needs a Live Activity widget the app doesn't have. AlarmKit doesn't return titles, so labels are kept by id in the App Group defaults for `list_alarms`.
- **Model:** `ModelSettings.assistantModelId` ("Keyboard Model" in Settings) on the chat's server and key. Empty means `openai/gpt-6-luna` on OpenRouter and the chat model elsewhere. On OpenRouter the assistant's `Model` is marked `reasoning` so swift pi sends `reasoning: {effort: "none"}` (it sends nothing for a non-reasoning model, and models that reason by default then do: GPT-6 Luna took 2.8 s a request instead of 1.2 s).
- **Choosing it:** benchmarks through OpenRouter with these tools, this prompt and swift pi's request shape (schema keys sorted), reasoning off. Eight requests (reminder, alarm, timer, event on a weekday, today's calendar, a reply into the field, cancel an alarm, a question): GPT-6 Luna was right on all eight at ~$0.00017 a request. DeepSeek V4.1 Flash was faster (~0.8 s a call) but in 2–3 of 10 runs left the due time off a reminder and then added it again in a second call, making a duplicate; that showed up in the simulator. Claude Haiku 5.5 missed once in 18; Gemini 3.1 Flash Lite was right but cost more; Mistral Small 2603 put "Friday" a day late; Gemini 2.5 Flash Lite returned 502s after tool results.
- **Permissions:** a keyboard can't prompt, so Settings → Keyboard (`KeyboardSetupView`) requests the microphone, speech recognition, Reminders, Calendars and (iOS 26) alarms, and shows how to add the keyboard and turn on Full Access, which the keyboard needs for the network and the App Group. Both `Info.plist`s carry the usage descriptions. The keyboard checks and explains what's missing instead of failing silently.
- **Keys:** globe (when the system asks for one), return and delete, so a typed reply can be sent and fixed without switching keyboards.
- **Verified on an iOS 27.2 simulator** (x86Sim on Linux, driven with stupidsim; built and installed with `stupid-app run --simulator`): Settings → Keyboard and its permission prompts; the keyboard in Settings → Keyboards with Allow Full Access; and in the keyboard, with the real model, a reminder, an event, reading tomorrow's calendar and the reminders back, typing a message into the field, a reply with the field's text as context, and a timer refused with the "allow alarms" message. EventKit works from the keyboard with access granted in the app.
- **Not verifiable there, still open on a device:** the microphone and speech (no audio input; WebKit's content process in a keyboard crashes on x86Sim and the keyboard is killed after ~30 s, while without the web view it stays up), AlarmKit (no alarm daemon in that simulator, so authorization is denied without a prompt), and whether AlarmKit schedules from an extension.
- **Simulator test hook:** in simulator builds only, a request stored under `keyboardTestRequest` in the App Group's defaults is sent by Ask in place of speech, and the web view isn't attached. Device builds compile it out.
- **x86Sim workarounds used for that test, none in the app:** "Add New Keyboard" didn't list third-party keyboards although PlugInKit had the extension, so it was enabled with `defaults write -g AppleKeyboards`; there's no App Group container for an ad-hoc signed app, so the keyboard got a copy of the app's settings plist in its own container; and HTTPS from the simulator fails behind the cloud session's egress proxy, so the keyboard's copy pointed at a local plain-HTTP relay to OpenRouter.

## Settings

- **Shared with the keyboard:** `SettingsStore.shared()` keeps settings in the App Group's user defaults (`group.net.stupidtech.StupidAgent`) and the key in the Keychain with the App Group as its access group, so the keyboard reads both. `migrate()` runs at launch: settings, and the key, saved by earlier versions in standard defaults and the app's own Keychain group move over; the shared key is written before the old copy is deleted. A failed migration shows in Settings. The keyboard extension has the same App Group entitlement (`Keyboard.entitlements`) and capability in `stupid-app.yml`; the group must be associated with the extension's bundle ID in the Developer Portal before `signing setup`.
- `ModelSettings` is stored in user defaults. The API key goes in the Keychain (`net.stupidtech.StupidAgent`, account `apiKey`, after first unlock, this device only).
- **Simulator exception:** stupid-app ad-hoc signs simulator builds without Keychain access, so Keychain writes fail with -34018 (`errSecMissingEntitlement`). Under `targetEnvironment(simulator)` the key is stored in user defaults. Device builds only use the Keychain.
- **Save order:** the key is stored before the settings, so a failed key write changes nothing.
- **Keys:** OpenAI, OpenRouter, Groq and DeepSeek need one; Ollama, LM Studio and Custom don't.
- **OpenRouter:** requests carry `HTTP-Referer` and `X-Title` so OpenRouter shows the app's name.
- **Local servers:** ATS allows local networking (`NSAllowsLocalNetworking`), with a local network usage description, for models on a computer on the same network.
- **Form loading:** the settings form loads the saved settings once. `onAppear` runs again when the model picker pops back and used to discard edits. The provider picker sets the base URL through its binding only when the user picks; an `onChange` used to also fire while the saved settings loaded.

## Conversation list

- **Rows:** laid out like Messages: a gray avatar with the brain, the title (semibold) with the time and a chevron (the navigation link's own chevron is hidden), and two lines of the last message. The time reads as Messages shows it: the time today, "Yesterday", the weekday within a week, else the date. The list is plain, with separators starting at the text and none above the first row.
- **Search and compose:** as in Messages on iOS 26, the search field and the compose button share the bottom toolbar (`DefaultToolbarItem(kind: .search, placement: .bottomBar)` beside the button). Search matches titles and previews, not whole transcripts, and shows "No Results" when nothing matches. Before iOS 26 the field sits under the title and compose in the top bar.
- **Previews:** `ConversationSummary.preview` is the agent's last reply (its Markdown rendered to plain text), else the user's last message, on one line, up to 200 characters. It's kept in `index.json`. Entries saved before previews get one from their conversation the first time the list reads them, and the index is rewritten.

## Chat screen

- The chat is stupid chatkit's (`NetworkChatView` driven by `AdapterChatViewModel`), through `AgentChatAdapter`.
- **Mapping:** `chatEntries(...)` turns the transcript into entries, and the adapter maps them to `ChatMessage`s:
  - a user message is an own bubble
  - each agent response is one Markdown bubble, with its thinking ("Thought") and tool calls as `.message` embeds; a tool call's embed shows its title (`Read notes.md`, `· Failed`, `· Stopped`) over its output. `ls` of the workspace root reads "List", not "List ."
  - a response with both thinking and text puts the thinking in a bubble of its own ahead of the text, since the kit draws embeds after a bubble's text and the model thought first
  - an error is a notice bubble from the agent with a Retry button (`ChatButtonPressing`); the kit draws system-sender notices as captions without buttons
  - "Stopped" is a system caption
- **Updates:** the adapter is `ChatLiveUpdating`. It observes the session with `withObservationTracking` and calls `onChange`; there is no polling.
- **Typing:** while the agent works and nothing of its reply shows yet, it appears as typing (`ChatTyping`).
- **Sending:** `send` hands the text to the session and returns nil. The session shows the message as sending (`queued`) until the agent takes it in: at once for a new prompt, after the current tool calls for one that steers a run. A message sent after the agent last checked for steering starts the next run when the current one ends.
- **Model menu:** the adapter adopts chatkit's `ChatComposerMenus`. A brain icon at the end of the composer's text row opens a menu headed by the current model id, with the recent models (`ModelSettings.recentModelIds`, up to six, most recent first, checkmark on the current) and "Choose Model…". That opens `ModelPickerView`: the server's `GET /models`, searchable, and any typed id ("Use …"). Choosing switches the app-wide model (`AppModel.selectModel`), the same setting Settings changes, so every conversation uses it from its next request. Switching keeps the model being left in the recents, including one set before recents were kept. Settings saved before `recentModelIds` existed decode with defaults (`ModelSettings.init(from:)`).
- **Stop:** the adapter adopts chatkit's `ChatStoppable` (`isBusy` = `session.isRunning`, `stop()` = `session.stop()`), so while the agent works the composer's send button becomes a stop button in its place; tapping it stops the run. (`observe()` already tracks `isRunning`, so the change reaches the composer through `onChange`.)
- **Toolbar:** the screen adds alerts for file changes and failed sends.
- **Kit settings:** the kit's `ChatKit` launch settings (network icon, events) are left at their defaults.

## Verified

- `swift test`: core tests, including end-to-end sessions with a scripted provider and real file tools (write, and approval denial).
- On an iOS 27 simulator against a local mock OpenAI-compatible server:
  - the settings flow, including loading and picking a model
  - the chatkit screen: a tool call (`ls`) and its answer
  - the file-change alert: a write after Allow, and a declined write shown as Failed
  - a failed request ("Could not connect to the server.") with Retry, retried after the server came back
- On the same simulator against OpenRouter (`openrouter/free`): list, read and write with a real model, the file-change alert, and streamed reasoning.

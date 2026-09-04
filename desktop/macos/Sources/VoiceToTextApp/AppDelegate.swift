import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RecordingOrigin {
        case panel
        case globeKey
    }

    private struct RecordingSession {
        let id = UUID()
        let origin: RecordingOrigin
        let insertionTarget: InputInserter.Target?
        var stopRequested = false
        var latestText = ""
    }

    private enum SessionState {
        case idle
        case starting(RecordingSession)
        case recording(RecordingSession)
        case finishing(RecordingSession)
        case inserting(RecordingSession)
    }

    private var statusItem: NSStatusItem!
    private var mainWindow: MainWindowController!
    private var config = AppConfig.load()
    private let history = HistoryStore()
    private let recorder = AudioRecorder()
    private let inserter = InputInserter()
    private let hotKey = HotKeyManager()
    private var asr: AliyunASRClient!
    private var sessionState: SessionState = .idle
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var permissionRetryTimer: Timer?
    private var transcriptUpdateWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureApplicationTracking()

        mainWindow = MainWindowController()
        mainWindow.setHistory(history.all)
        mainWindow.onQuit = { [weak self] in self?.quit() }
        mainWindow.onToggleRecording = { [weak self] in self?.togglePanelRecording() }
        mainWindow.onDismiss = { [weak self] in self?.cancelPanelSessionIfNeeded() }
        mainWindow.onCopy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        recorder.onAudio = { [weak self] sessionID, data in
            self?.asr?.sendPCM(data, sessionID: sessionID)
        }
        recorder.onError = { [weak self] sessionID, message in
            DispatchQueue.main.async {
                self?.failActiveSession(message, sessionID: sessionID)
            }
        }
        configureASR()
        configureGlobeKey()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        retryGlobeKeyIfAuthorized()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionRetryTimer?.invalidate()
        transcriptUpdateWorkItem?.cancel()
        hotKey.stop()
        recorder.stop()
        asr?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "Voice to Text")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Voice to Text — hold Globe to dictate"
            button.action = #selector(openMainWindow)
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }
    }

    private func configureApplicationTracking() {
        if let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = current
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.lastExternalApplication = application
        }
    }

    private func configureASR() {
        asr = AliyunASRClient(config: config)
        asr.onPartial = { [weak self] sessionID, text in
            self?.receivePartialTranscript(text, sessionID: sessionID)
        }
        asr.onFinal = { [weak self] sessionID, text in
            self?.completeActiveSession(with: text, sessionID: sessionID)
        }
        asr.onError = { [weak self] sessionID, message in
            self?.failActiveSession(message, sessionID: sessionID)
        }
    }

    private func configureGlobeKey() {
        hotKey.onKeyDown = { [weak self] in
            self?.beginGlobeSession()
        }
        hotKey.onKeyUp = { [weak self] in
            self?.requestGlobeStop()
        }

        switch hotKey.startGlobeKey() {
        case .started:
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            updateReadyStatus()
        case .permissionsRequired:
            mainWindow.setStatus("Enable Input Monitoring for Globe key")
            openInputMonitoringSettings()
            beginPermissionRetry()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.mainWindow.show(anchoredTo: self.statusItem.button)
            }
        case .unavailable:
            mainWindow.setStatus("Could not start Globe key listener — try relaunching")
            beginPermissionRetry()
        }
    }

    private func beginGlobeSession() {
        guard case .idle = sessionState else { return }
        let application = currentInsertionApplication()
        let target = inserter.captureTarget(application: application)
        if !inserter.hasPostPermission {
            inserter.requestAccessibilityPermission()
        }
        beginSession(origin: .globeKey, target: target)
    }

    private func requestGlobeStop() {
        switch sessionState {
        case .starting(var session) where session.origin == .globeKey:
            session.stopRequested = true
            sessionState = .starting(session)
        case .recording(let session) where session.origin == .globeKey:
            finishRecording(session)
        default:
            break
        }
    }

    private func togglePanelRecording() {
        switch sessionState {
        case .idle:
            beginSession(origin: .panel, target: nil)
        case .starting(var session) where session.origin == .panel:
            session.stopRequested = true
            sessionState = .starting(session)
            mainWindow.setStatus("Stopping…")
        case .recording(let session) where session.origin == .panel:
            finishRecording(session)
        default:
            break
        }
    }

    private func beginSession(origin: RecordingOrigin, target: InputInserter.Target?) {
        guard case .idle = sessionState else { return }
        let session = RecordingSession(origin: origin, insertionTarget: target)
        sessionState = .starting(session)
        cancelPendingTranscriptUpdate()

        switch origin {
        case .panel:
            mainWindow.setText("")
            mainWindow.setPreparing()
            mainWindow.show(anchoredTo: statusItem.button)
            mainWindow.setStatus("Connecting…")
        case .globeKey:
            mainWindow.setText("")
            mainWindow.setPreparing()
            mainWindow.show(anchoredTo: statusItem.button)
            mainWindow.setStatus("Connecting…")
        }

        guard asr.start(sessionID: session.id) else {
            sessionState = .idle
            mainWindow.setRecording(false)
            mainWindow.setStatus("API key is not configured")
            return
        }

        recorder.start(sessionID: session.id) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                guard case .starting(let current) = self.sessionState,
                      current.id == session.id else {
                    if case .success = result { self.recorder.stop() }
                    return
                }

                switch result {
                case .success:
                    self.sessionState = .recording(current)
                    if current.origin == .panel {
                        self.mainWindow.setRecording(true)
                        self.mainWindow.setStatus("Listening — click Stop when finished")
                    } else {
                        self.mainWindow.setRecording(true)
                        self.mainWindow.setStatus("Listening — release Globe to finish")
                    }
                    if current.stopRequested { self.finishRecording(current) }
                case .failure(let error):
                    self.asr.cancel()
                    self.failActiveSession(error.localizedDescription, sessionID: current.id)
                }
            }
        }
    }

    private func finishRecording(_ session: RecordingSession) {
        guard case .recording(let current) = sessionState,
              current.id == session.id else { return }
        sessionState = .finishing(current)
        recorder.stop()
        asr.finish()
        if current.origin == .panel {
            mainWindow.setFinishing()
            mainWindow.setStatus("Finishing transcription…")
        } else {
            mainWindow.setFinishing()
            mainWindow.setStatus("Finishing transcription…")
        }
    }

    private func receivePartialTranscript(_ text: String, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        let session: RecordingSession
        switch sessionState {
        case .starting(var current):
            current.latestText = text
            sessionState = .starting(current)
            session = current
        case .recording(var current):
            current.latestText = text
            sessionState = .recording(current)
            session = current
        case .finishing(var current):
            current.latestText = text
            sessionState = .finishing(current)
            session = current
        case .idle, .inserting:
            return
        }

        if session.origin == .globeKey {
            mainWindow.setText(text)
            return
        }
        scheduleTranscriptDisplay(text, sessionID: session.id)
    }

    private func scheduleTranscriptDisplay(_ text: String, sessionID: UUID) {
        transcriptUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeSessionID == sessionID,
                  self.activeOrigin == .panel,
                  self.mainWindow.isVisible else { return }
            self.mainWindow.setText(text)
        }
        transcriptUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func completeActiveSession(with finalText: String, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        let session: RecordingSession
        switch sessionState {
        case .starting(let current), .recording(let current), .finishing(let current):
            session = current
        case .idle, .inserting:
            return
        }

        cancelPendingTranscriptUpdate()
        recorder.stop()
        mainWindow.setRecording(false)
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty, history.add(text: text) != nil {
            mainWindow.setHistory(history.all)
        }

        switch session.origin {
        case .panel:
            sessionState = .idle
            mainWindow.setText(text)
            mainWindow.setStatus(text.isEmpty ? "No speech recognized" : "Transcription ready")
        case .globeKey:
            guard !text.isEmpty else {
                sessionState = .idle
                mainWindow.setText("")
                mainWindow.setStatus("No speech recognized")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    guard let self, self.activeSessionID == nil else { return }
                    self.mainWindow.hide()
                }
                return
            }
            sessionState = .inserting(session)
            mainWindow.setText(text)
            mainWindow.setStatus("Inserting…")
            // The menu popover must not remain active while the text is sent.
            // Close it first so the target application can receive focus.
            mainWindow.hide()
            performAutomaticInsertion(text, session: session)
        }
    }

    private func performAutomaticInsertion(_ text: String, session: RecordingSession) {
        let started = inserter.insert(text, into: session.insertionTarget) { [weak self] succeeded in
            guard let self else { return }
            DispatchQueue.main.async {
                guard case .inserting(let current) = self.sessionState,
                      current.id == session.id else { return }
                self.sessionState = .idle
                if succeeded {
                    self.mainWindow.setStatus("Inserted into the current field")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        guard let self, self.activeSessionID == nil else { return }
                        self.mainWindow.hide()
                    }
                } else {
                    self.showInsertionFailure(text)
                }
            }
        }

        if !started {
            sessionState = .idle
            showInsertionFailure(text)
        }
    }

    private func showInsertionFailure(_ text: String) {
        mainWindow.setText(text)
        mainWindow.setStatus("Automatic insert failed — text preserved")
        mainWindow.show(anchoredTo: statusItem.button)
    }

    private func failActiveSession(_ message: String, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        let origin = activeOrigin
        sessionState = .idle
        cancelPendingTranscriptUpdate()
        recorder.stop()
        asr.cancel()
        mainWindow.setRecording(false)
        mainWindow.setStatus(message)
        if origin == .globeKey {
            mainWindow.setStatus(message)
            mainWindow.show(anchoredTo: statusItem.button)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.activeSessionID == nil else { return }
                self.mainWindow.hide()
            }
        } else {
            mainWindow.hide()
        }
    }

    private func cancelPanelSessionIfNeeded() {
        guard activeOrigin == .panel else { return }
        sessionState = .idle
        cancelPendingTranscriptUpdate()
        recorder.stop()
        asr.cancel()
        mainWindow.setRecording(false)
        updateReadyStatus()
    }

    private func cancelPendingTranscriptUpdate() {
        transcriptUpdateWorkItem?.cancel()
        transcriptUpdateWorkItem = nil
    }

    private var activeSessionID: UUID? {
        switch sessionState {
        case .starting(let session), .recording(let session),
             .finishing(let session), .inserting(let session):
            return session.id
        case .idle:
            return nil
        }
    }

    private var activeOrigin: RecordingOrigin? {
        switch sessionState {
        case .starting(let session), .recording(let session),
             .finishing(let session), .inserting(let session):
            return session.origin
        case .idle:
            return nil
        }
    }

    private func currentInsertionApplication() -> NSRunningApplication? {
        if let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = current
            return current
        }
        return lastExternalApplication
    }

    private func updateReadyStatus() {
        mainWindow.setStatus(inserter.hasPostPermission
            ? "Ready — hold Globe to dictate"
            : "Ready — allow Accessibility to auto-insert")
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func beginPermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.retryGlobeKeyIfAuthorized()
        }
    }

    private func retryGlobeKeyIfAuthorized() {
        guard mainWindow != nil, !hotKey.isRunning,
              hotKey.hasRequiredPermissions else { return }
        if case .started = hotKey.startGlobeKey(requestPermissions: false) {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            updateReadyStatus()
        }
    }

    @objc private func openMainWindow() {
        retryGlobeKeyIfAuthorized()
        guard activeOrigin != .globeKey else { return }
        if mainWindow.isVisible {
            mainWindow.hide()
        } else {
            mainWindow.show(anchoredTo: statusItem.button)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

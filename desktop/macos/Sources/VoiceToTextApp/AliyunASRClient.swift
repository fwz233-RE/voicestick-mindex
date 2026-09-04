import Foundation

final class AliyunASRClient {
    var onPartial: ((UUID, String) -> Void)?
    var onFinal: ((UUID, String) -> Void)?
    var onError: ((UUID, String) -> Void)?

    private enum State { case idle, connecting, starting, streaming, finishing }
    private let config: AppConfig
    private let queue = DispatchQueue(label: "VoiceToText.AliyunASR")
    private var socket: URLSessionWebSocketTask?
    private var state: State = .idle
    private var sessionID: UUID?
    private var taskID = ""
    private struct TranscriptSegment {
        var key: String
        var text: String
        var isFinal: Bool
    }

    private var bufferedAudio: [Data] = []
    private var transcriptSegments: [TranscriptSegment] = []
    private var latestText = ""

    init(config: AppConfig) { self.config = config }

    @discardableResult
    func start(sessionID: UUID) -> Bool {
        guard !config.aliyunAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notifyError("Enter an Aliyun DashScope API key in the source configuration.", sessionID: sessionID)
            return false
        }
        queue.async { [weak self] in self?.begin(sessionID: sessionID) }
        return true
    }

    func sendPCM(_ data: Data, sessionID: UUID) {
        queue.async { [weak self] in
            guard let self, self.sessionID == sessionID, !data.isEmpty else { return }
            switch self.state {
            case .starting, .connecting: self.bufferedAudio.append(data)
            case .streaming: self.sendBinary(data)
            case .idle, .finishing: break
            }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.state == .starting || self.state == .connecting {
                self.bufferedAudio.append(Data())
            } else if self.state == .streaming {
                self.sendFinish()
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.socket?.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            self.bufferedAudio.removeAll()
            self.transcriptSegments.removeAll()
            self.latestText = ""
            self.sessionID = nil
            self.state = .idle
        }
    }

    private func begin(sessionID: UUID) {
        socket?.cancel(with: .goingAway, reason: nil)
        bufferedAudio.removeAll()
        transcriptSegments.removeAll()
        latestText = ""
        self.sessionID = sessionID
        taskID = UUID().uuidString
        state = .connecting
        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/") else {
            fail("Invalid Aliyun WebSocket URL.")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("bearer \(config.aliyunAPIKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveLoop(for: task)
        state = .starting
        sendJSON([
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition",
                "model": "fun-asr-realtime",
                "parameters": [
                    "sample_rate": 16_000,
                    "format": "pcm",
                    "heartbeat": true,
                    "semantic_punctuation_enabled": false,
                    "max_sentence_silence": 1_300
                ],
                "input": [:]
            ]
        ])
    }

    private func sendBinary(_ data: Data) {
        guard let task = socket else { fail("Aliyun WebSocket is not connected."); return }
        task.send(.data(data)) { [weak self, weak task] error in
            guard let error else { return }
            self?.queue.async {
                guard let self, let task, self.socket === task else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func flushAudio() {
        let chunks = bufferedAudio
        bufferedAudio.removeAll()
        for chunk in chunks {
            if chunk.isEmpty { sendFinish() } else { sendBinary(chunk) }
        }
    }

    private func sendFinish() {
        guard state == .streaming || state == .starting else { return }
        state = .finishing
        sendJSON([
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [:]]
        ])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task = socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            fail("Could not create the Aliyun recognition request.")
            return
        }
        task.send(.string(text)) { [weak self, weak task] error in
            guard let error else { return }
            self?.queue.async {
                guard let self, let task, self.socket === task else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func receiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop(for: task)
                case .failure(let error):
                    if self.state != .idle { self.fail(error.localizedDescription) }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let value): data = value
        @unknown default: data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String else { return }

        switch event {
        case "task-started":
            guard state == .starting else { return }
            state = .streaming
            flushAudio()
        case "result-generated":
            if let sentence = sentence(from: object), !sentence.text.isEmpty {
                updateTranscript(with: sentence)
                let completeText = joinedTranscript()
                latestText = completeText
                guard let sessionID else { return }
                DispatchQueue.main.async { [weak self] in self?.onPartial?(sessionID, completeText) }
            }
        case "task-finished":
            // A task-finished payload may repeat only the final sentence. The
            // authoritative result is the complete segment list accumulated
            // throughout this manually controlled recording session.
            if transcriptSegments.isEmpty,
               let sentence = sentence(from: object), !sentence.text.isEmpty {
                updateTranscript(with: sentence, forceFinal: true)
            }
            let text = joinedTranscript().isEmpty ? latestText : joinedTranscript()
            latestText = text
            let completedSessionID = sessionID
            sessionID = nil
            state = .idle
            socket = nil
            if let completedSessionID {
                DispatchQueue.main.async { [weak self] in self?.onFinal?(completedSessionID, text) }
            }
        case "task-failed":
            fail((header["error_message"] as? String) ?? (header["message"] as? String) ?? "Aliyun recognition failed.")
        default: break
        }
    }

    private struct SentenceUpdate {
        let key: String?
        let text: String
        let isFinal: Bool
    }

    private func sentence(from object: [String: Any]) -> SentenceUpdate? {
        guard let payload = object["payload"] as? [String: Any],
              let output = payload["output"] as? [String: Any],
              let sentence = output["sentence"] as? [String: Any],
              let text = sentence["text"] as? String else { return nil }

        let key: String?
        if let sentenceID = sentence["sentence_id"] {
            key = "id:\(sentenceID)"
        } else if let beginTime = sentence["begin_time"] {
            key = "begin:\(beginTime)"
        } else {
            key = nil
        }
        // DashScope marks a sentence as final by providing a non-null end_time.
        // There is no reliable sentence_end Boolean in this protocol.
        let endTime = sentence["end_time"]
        let isFinal = endTime != nil && !(endTime is NSNull)
        return SentenceUpdate(key: key, text: text, isFinal: isFinal)
    }

    private func updateTranscript(with update: SentenceUpdate, forceFinal: Bool = false) {
        let isFinal = forceFinal || update.isFinal

        if let key = update.key,
           let index = transcriptSegments.firstIndex(where: { $0.key == key }) {
            transcriptSegments[index].text = update.text
            transcriptSegments[index].isFinal = transcriptSegments[index].isFinal || isFinal
            return
        }

        if let key = update.key,
           let index = transcriptSegments.indices.last,
           !transcriptSegments[index].isFinal,
           transcriptSegments[index].key.hasPrefix("local:") {
            transcriptSegments[index].key = key
            transcriptSegments[index].text = update.text
            transcriptSegments[index].isFinal = isFinal
            return
        }

        // Some result messages omit a sentence identifier. While a sentence is
        // still being recognized, updates replace only that unfinished segment;
        // once sentence_end arrives it is frozen and later speech is appended.
        if update.key == nil,
           let index = transcriptSegments.indices.last,
           !transcriptSegments[index].isFinal {
            transcriptSegments[index].text = update.text
            transcriptSegments[index].isFinal = isFinal
            return
        }

        transcriptSegments.append(TranscriptSegment(
            key: update.key ?? "local:\(UUID().uuidString)",
            text: update.text,
            isFinal: isFinal
        ))
    }

    private func joinedTranscript() -> String {
        transcriptSegments.reduce(into: "") { result, segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if needsSpace(between: result, and: text) { result.append(" ") }
            result.append(text)
        }
    }

    private func needsSpace(between previous: String, and next: String) -> Bool {
        guard let left = previous.unicodeScalars.last,
              let right = next.unicodeScalars.first else { return false }
        return left.isASCII && right.isASCII
            && CharacterSet.alphanumerics.contains(left)
            && CharacterSet.alphanumerics.contains(right)
    }

    private func fail(_ message: String) {
        let failedSessionID = sessionID
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        bufferedAudio.removeAll()
        transcriptSegments.removeAll()
        latestText = ""
        sessionID = nil
        state = .idle
        if let failedSessionID {
            notifyError(message, sessionID: failedSessionID)
        }
    }

    private func notifyError(_ message: String, sessionID: UUID) {
        DispatchQueue.main.async { [weak self] in self?.onError?(sessionID, message) }
    }
}

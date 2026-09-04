import AVFoundation
import Foundation

final class AudioRecorder {
    var onAudio: ((UUID, Data) -> Void)?
    var onError: ((UUID, String) -> Void)?

    private let engine = AVAudioEngine()
    private let converterLock = NSLock()
    private var converter: AVAudioConverter?
    private var activeSessionID: UUID?
    private var isRecording = false
    private var tapInstalled = false
    private var conversionErrorReported = false

    func start(sessionID: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    completion(.failure(AudioRecorderError.microphonePermissionDenied))
                    return
                }
                do {
                    try self.startEngine(sessionID: sessionID)
                    completion(.success(()))
                } catch {
                    self.stop()
                    completion(.failure(error))
                }
            }
        }
    }

    /// Cleanup is intentionally unconditional. A tap can be installed even when
    /// AVAudioEngine.start() fails, so `isRecording` alone is not sufficient.
    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        isRecording = false
        conversionErrorReported = false
        converterLock.lock()
        converter = nil
        activeSessionID = nil
        converterLock.unlock()
    }

    private func startEngine(sessionID: UUID) throws {
        stop()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.audioFormatUnavailable
        }

        converterLock.lock()
        converter = newConverter
        activeSessionID = sessionID
        converterLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer, outputFormat: outputFormat, sessionID: sessionID)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            stop()
            throw error
        }
    }

    private func convertAndSend(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat,
        sessionID: UUID
    ) {
        guard buffer.frameLength > 0 else { return }

        converterLock.lock()
        defer { converterLock.unlock() }
        guard let converter, activeSessionID == sessionID else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio))) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            reportConversionErrorOnce(sessionID: sessionID)
            return
        }
        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil,
              output.frameLength > 0,
              let channelData = output.int16ChannelData else {
            reportConversionErrorOnce(sessionID: sessionID)
            return
        }
        let data = Data(bytes: channelData[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        onAudio?(sessionID, data)
    }

    private func reportConversionErrorOnce(sessionID: UUID) {
        guard !conversionErrorReported else { return }
        conversionErrorReported = true
        onError?(sessionID, AudioRecorderError.conversionFailed.localizedDescription)
    }
}

enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case audioFormatUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone permission was denied."
        case .noInputDevice: return "No microphone input device is available."
        case .audioFormatUnavailable: return "Could not create the audio converter."
        case .conversionFailed: return "Microphone audio conversion failed."
        }
    }
}

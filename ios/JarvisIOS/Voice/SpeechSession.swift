@preconcurrency import AVFoundation
@preconcurrency import Speech
import Combine
import Foundation

public enum SpeechPermissionStatus: Equatable, Sendable {
    case undetermined
    case authorized
    case denied
    case restricted

    public var needsSettings: Bool {
        self == .denied || self == .restricted
    }
}

public enum SpeechSessionFailure: Error, Equatable, Sendable {
    case permissionDenied
    case recognizerUnavailable
    case audioUnavailable
    case alreadyListening
    case notListening
    case emptyTranscript
    case recognitionFailed
    case interrupted
}

public enum SpeechSessionState: Equatable, Sendable {
    case idle
    case requestingPermission
    case listening
    case transcribing
    case reviewRequired
    case completed
    case failed(SpeechSessionFailure)
    case interrupted
}

public struct SpeechRecognitionResult: Equatable, Sendable {
    public let text: String
    public let confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

public struct SpeechTranscriptResult: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let requiresReview: Bool
    public let executableText: String?

    public init(text: String, confidence: Float, minimumConfidence: Float) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfidence = confidence.isFinite
            ? min(max(confidence, 0), 1)
            : 0
        self.text = normalized
        self.confidence = normalizedConfidence
        requiresReview = normalizedConfidence < minimumConfidence
        executableText = requiresReview || normalized.isEmpty ? nil : normalized
    }
}

public protocol SpeechPermissionAuthorizing: AnyObject, Sendable {
    func currentStatus() async -> SpeechPermissionStatus
    func requestAuthorization() async -> SpeechPermissionStatus
}

public protocol SpeechRecognizing: AnyObject, Sendable {
    func prepare() throws
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> SpeechRecognitionResult
    func cancel()
}

public protocol SpeechAudioCapturing: AnyObject, Sendable {
    var isRunning: Bool { get }
    func start(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws
    func stop()
}

@MainActor
public final class SpeechSession: ObservableObject {
    @Published public private(set) var state: SpeechSessionState = .idle
    @Published public private(set) var permissionStatus: SpeechPermissionStatus = .undetermined
    @Published public private(set) var lastResult: SpeechTranscriptResult?

    private let recognizer: any SpeechRecognizing
    private let audioCapture: any SpeechAudioCapturing
    private let permissionAuthorizer: any SpeechPermissionAuthorizing
    private let minimumConfidence: Float
    private var lifecycleGeneration: UInt64 = 0

    public init(
        recognizer: any SpeechRecognizing = AppleSpeechRecognizer(),
        audioCapture: any SpeechAudioCapturing = AVAudioEngineSpeechCapture(),
        permissionAuthorizer: any SpeechPermissionAuthorizing = SystemSpeechPermissionAuthorizer(),
        minimumConfidence: Float = 0.70
    ) {
        self.recognizer = recognizer
        self.audioCapture = audioCapture
        self.permissionAuthorizer = permissionAuthorizer
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
    }

    public func start() async throws {
        guard !state.isActive else {
            throw SpeechSessionFailure.alreadyListening
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lastResult = nil

        var authorization = await permissionAuthorizer.currentStatus()
        permissionStatus = authorization
        guard generation == lifecycleGeneration else {
            throw SpeechSessionFailure.interrupted
        }

        if authorization == .undetermined {
            state = .requestingPermission
            authorization = await permissionAuthorizer.requestAuthorization()
            permissionStatus = authorization
            guard generation == lifecycleGeneration else {
                throw SpeechSessionFailure.interrupted
            }
        }

        guard authorization == .authorized else {
            state = .failed(.permissionDenied)
            throw SpeechSessionFailure.permissionDenied
        }

        do {
            try recognizer.prepare()
            let recognizer = recognizer
            try audioCapture.start { buffer in
                recognizer.append(buffer)
            }
            guard generation == lifecycleGeneration else {
                audioCapture.stop()
                recognizer.cancel()
                throw SpeechSessionFailure.interrupted
            }
            state = .listening
        } catch {
            audioCapture.stop()
            recognizer.cancel()
            let failure = normalizedFailure(error, fallback: .audioUnavailable)
            state = failure == .interrupted ? .interrupted : .failed(failure)
            throw failure
        }
    }

    /// Returns the structured transcript used by the app's safety gate.
    /// Callers may submit only `executableText`; low-confidence text is display-only.
    public func stopResult() async throws -> SpeechTranscriptResult {
        guard state == .listening else {
            throw SpeechSessionFailure.notListening
        }

        let generation = lifecycleGeneration
        state = .transcribing
        audioCapture.stop()

        do {
            let recognition = try await recognizer.finish()
            guard generation == lifecycleGeneration else {
                throw SpeechSessionFailure.interrupted
            }
            let result = SpeechTranscriptResult(
                text: recognition.text,
                confidence: recognition.confidence,
                minimumConfidence: minimumConfidence
            )
            guard !result.text.isEmpty else {
                throw SpeechSessionFailure.emptyTranscript
            }

            lastResult = result
            state = result.requiresReview ? .reviewRequired : .completed
            return result
        } catch {
            recognizer.cancel()
            let failure = normalizedFailure(error, fallback: .recognitionFailed)
            state = failure == .interrupted ? .interrupted : .failed(failure)
            throw failure
        }
    }

    /// Compatibility API for callers that only render the visible transcript.
    /// This string is not an execution authorization; use `stopResult()` for submission.
    public func stop() async throws -> String {
        (try await stopResult()).text
    }

    public func appWillResignActive() {
        let wasActive = state.isActive || audioCapture.isRunning
        lifecycleGeneration &+= 1
        audioCapture.stop()
        guard wasActive else { return }
        recognizer.cancel()
        state = .interrupted
    }

    public func cancel() {
        lifecycleGeneration &+= 1
        let wasActive = state.isActive || audioCapture.isRunning
        audioCapture.stop()
        recognizer.cancel()
        if wasActive {
            state = .interrupted
        }
    }

    private func normalizedFailure(
        _ error: any Error,
        fallback: SpeechSessionFailure
    ) -> SpeechSessionFailure {
        (error as? SpeechSessionFailure) ?? fallback
    }
}

private extension SpeechSessionState {
    var isActive: Bool {
        switch self {
        case .requestingPermission, .listening, .transcribing:
            true
        default:
            false
        }
    }

    var isCapturing: Bool {
        switch self {
        case .listening, .transcribing:
            true
        default:
            false
        }
    }
}

public final class SystemSpeechPermissionAuthorizer: SpeechPermissionAuthorizing,
    @unchecked Sendable
{
    public init() {}

    public func currentStatus() async -> SpeechPermissionStatus {
        Self.combinedStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            speech: SFSpeechRecognizer.authorizationStatus()
        )
    }

    public func requestAuthorization() async -> SpeechPermissionStatus {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        return await currentStatus()
    }

    private static func combinedStatus(
        microphone: AVAuthorizationStatus,
        speech: SFSpeechRecognizerAuthorizationStatus
    ) -> SpeechPermissionStatus {
        if microphone == .denied || speech == .denied {
            return .denied
        }
        if microphone == .restricted || speech == .restricted {
            return .restricted
        }
        if microphone == .authorized, speech == .authorized {
            return .authorized
        }
        return .undetermined
    }
}

public final class AVAudioEngineSpeechCapture: SpeechAudioCapturing, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let lock = NSLock()
    private var tapInstalled = false

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public var isRunning: Bool {
        lock.withCriticalSection { tapInstalled || engine.isRunning }
    }

    public func start(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        let canStart = lock.withCriticalSection { !tapInstalled && !engine.isRunning }
        guard canStart else { throw SpeechSessionFailure.alreadyListening }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            throw SpeechSessionFailure.audioUnavailable
        }
        #endif

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateAudioSession()
            throw SpeechSessionFailure.audioUnavailable
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { buffer, _ in
            bufferHandler(buffer)
        }
        lock.withCriticalSection { tapInstalled = true }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw SpeechSessionFailure.audioUnavailable
        }
    }

    public func stop() {
        let shouldRemoveTap = lock.withCriticalSection { () -> Bool in
            let installed = tapInstalled
            tapInstalled = false
            return installed
        }
        engine.stop()
        if shouldRemoveTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.reset()
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        #endif
    }
}

public final class AppleSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<SpeechRecognitionResult, any Error>?
    private var terminalResult: Result<SpeechRecognitionResult, SpeechSessionFailure>?

    public init(locale: Locale = Locale(identifier: "zh-CN")) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    public func prepare() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechSessionFailure.recognizerUnavailable
        }

        cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        lock.withCriticalSection {
            self.request = request
            terminalResult = nil
        }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.receive(result: result, error: error)
        }
        lock.withCriticalSection { self.task = task }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        let request = lock.withCriticalSection { self.request }
        request?.append(buffer)
    }

    public func finish() async throws -> SpeechRecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            let pending: (
                request: SFSpeechAudioBufferRecognitionRequest?,
                terminal: Result<SpeechRecognitionResult, SpeechSessionFailure>?
            ) = lock.withCriticalSection {
                if let terminalResult {
                    self.terminalResult = nil
                    return (nil, terminalResult)
                }
                self.continuation = continuation
                return (request, nil)
            }

            if let terminal = pending.terminal {
                continuation.resume(with: terminal.mapError { $0 as any Error })
            } else if let request = pending.request {
                request.endAudio()
            } else {
                lock.withCriticalSection { self.continuation = nil }
                continuation.resume(throwing: SpeechSessionFailure.notListening)
            }
        }
    }

    public func cancel() {
        let pending: (
            task: SFSpeechRecognitionTask?,
            request: SFSpeechAudioBufferRecognitionRequest?,
            continuation: CheckedContinuation<SpeechRecognitionResult, any Error>?
        ) = lock.withCriticalSection {
            let pending = (task, request, continuation)
            task = nil
            request = nil
            continuation = nil
            terminalResult = nil
            return pending
        }
        pending.request?.endAudio()
        pending.task?.cancel()
        pending.continuation?.resume(throwing: SpeechSessionFailure.interrupted)
    }

    private func receive(result: SFSpeechRecognitionResult?, error: (any Error)?) {
        if error != nil {
            complete(.failure(.recognitionFailed))
            return
        }
        guard let result, result.isFinal else { return }

        let segments = result.bestTranscription.segments
        let confidence: Float
        if segments.isEmpty {
            confidence = 0
        } else {
            confidence = segments.reduce(Float.zero) { partial, segment in
                partial + segment.confidence
            } / Float(segments.count)
        }
        complete(
            .success(
                SpeechRecognitionResult(
                    text: result.bestTranscription.formattedString,
                    confidence: confidence
                )
            )
        )
    }

    private func complete(
        _ result: Result<SpeechRecognitionResult, SpeechSessionFailure>
    ) {
        let continuation = lock.withCriticalSection {
            let continuation = self.continuation
            if continuation == nil {
                terminalResult = result
            }
            self.continuation = nil
            request = nil
            task = nil
            return continuation
        }
        continuation?.resume(with: result.mapError { $0 as any Error })
    }
}

private extension NSLock {
    func withCriticalSection<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

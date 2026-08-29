import AVFAudio
import XCTest
@testable import JarvisVoice

final class SpeechSessionTests: XCTestCase {
    @MainActor
    func testInitializationDoesNotRequestPermissionsOrStartCapture() {
        let permissions = FakeSpeechPermissionAuthorizer(status: .undetermined)
        let recognizer = FakeSpeechRecognizer()
        let audio = FakeSpeechAudioCapture()

        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: permissions
        )

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertEqual(recognizer.prepareCount, 0)
        XCTAssertEqual(audio.startCount, 0)
    }

    @MainActor
    func testStartRequestsUndeterminedPermissionsThenShowsListening() async throws {
        let permissions = FakeSpeechPermissionAuthorizer(status: .undetermined)
        let recognizer = FakeSpeechRecognizer()
        let audio = FakeSpeechAudioCapture()
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: permissions
        )

        try await session.start()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(recognizer.prepareCount, 1)
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(session.permissionStatus, .authorized)
        XCTAssertEqual(session.state, .listening)
    }

    @MainActor
    func testDeniedPermissionNeverStartsRecognitionOrAudioAndShowsFailure() async {
        let permissions = FakeSpeechPermissionAuthorizer(status: .denied)
        let recognizer = FakeSpeechRecognizer()
        let audio = FakeSpeechAudioCapture()
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: permissions
        )

        do {
            try await session.start()
            XCTFail("Expected denied permission to stop voice start")
        } catch {
            XCTAssertEqual(error as? SpeechSessionFailure, .permissionDenied)
        }

        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertEqual(recognizer.prepareCount, 0)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertEqual(session.permissionStatus, .denied)
        XCTAssertEqual(session.state, .failed(.permissionDenied))
    }

    @MainActor
    func testLowConfidenceTranscriptRequiresReviewAndHasNoExecutableText() async throws {
        let recognizer = FakeSpeechRecognizer(
            result: SpeechRecognitionResult(text: "给宋小宝发微信", confidence: 0.42)
        )
        let audio = FakeSpeechAudioCapture()
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: FakeSpeechPermissionAuthorizer(status: .authorized),
            minimumConfidence: 0.70
        )
        try await session.start()

        let result = try await session.stopResult()

        XCTAssertEqual(result.text, "给宋小宝发微信")
        XCTAssertEqual(result.confidence, 0.42, accuracy: 0.001)
        XCTAssertTrue(result.requiresReview)
        XCTAssertNil(result.executableText)
        XCTAssertEqual(session.lastResult, result)
        XCTAssertEqual(session.state, .reviewRequired)
        XCTAssertFalse(audio.isRunning)
    }

    @MainActor
    func testHighConfidenceTranscriptNormalizesWhitespaceAndIsExecutable() async throws {
        let recognizer = FakeSpeechRecognizer(
            result: SpeechRecognitionResult(text: "  今天有什么安排？\n", confidence: 0.91)
        )
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: FakeSpeechAudioCapture(),
            permissionAuthorizer: FakeSpeechPermissionAuthorizer(status: .authorized),
            minimumConfidence: 0.70
        )
        try await session.start()

        let result = try await session.stopResult()

        XCTAssertEqual(result.text, "今天有什么安排？")
        XCTAssertEqual(result.executableText, "今天有什么安排？")
        XCTAssertFalse(result.requiresReview)
        XCTAssertEqual(session.state, .completed)
    }

    @MainActor
    func testStopStringReturnsVisibleTranscriptForCompatibility() async throws {
        let session = SpeechSession(
            recognizer: FakeSpeechRecognizer(
                result: SpeechRecognitionResult(text: "可见文本", confidence: 0.55)
            ),
            audioCapture: FakeSpeechAudioCapture(),
            permissionAuthorizer: FakeSpeechPermissionAuthorizer(status: .authorized)
        )
        try await session.start()

        let text: String = try await session.stop()

        XCTAssertEqual(text, "可见文本")
        XCTAssertNil(session.lastResult?.executableText)
    }

    @MainActor
    func testResignActiveStopsAudioCancelsRecognitionAndMarksInterrupted() async throws {
        let recognizer = FakeSpeechRecognizer()
        let audio = FakeSpeechAudioCapture()
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: FakeSpeechPermissionAuthorizer(status: .authorized)
        )
        try await session.start()

        session.appWillResignActive()

        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(recognizer.cancelCount, 1)
        XCTAssertEqual(session.state, .interrupted)
    }

    @MainActor
    func testResignActiveWhilePermissionIsPendingNeverStartsAudio() async {
        let permissions = FakeSpeechPermissionAuthorizer(
            status: .undetermined,
            pausesAuthorizationRequest: true
        )
        let recognizer = FakeSpeechRecognizer()
        let audio = FakeSpeechAudioCapture()
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: permissions
        )

        let startTask = Task { try await session.start() }
        let didRequestPermission = await waitUntil {
            permissions.requestCount == 1
        }
        XCTAssertTrue(didRequestPermission)
        XCTAssertEqual(session.state, .requestingPermission)

        session.appWillResignActive()
        permissions.resolveAuthorization(.authorized)

        do {
            try await startTask.value
            XCTFail("Expected pending start to be interrupted")
        } catch {
            XCTAssertEqual(error as? SpeechSessionFailure, .interrupted)
        }
        XCTAssertEqual(recognizer.prepareCount, 0)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(session.state, .interrupted)
    }

    @MainActor
    func testRecognitionFailureStillReleasesAudioAndShowsFailure() async throws {
        let recognizer = FakeSpeechRecognizer(finishError: .recognitionFailed)
        let audio = FakeSpeechAudioCapture()
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: FakeSpeechPermissionAuthorizer(status: .authorized)
        )
        try await session.start()

        do {
            _ = try await session.stopResult()
            XCTFail("Expected recognition failure")
        } catch {
            XCTAssertEqual(error as? SpeechSessionFailure, .recognitionFailed)
        }

        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(session.state, .failed(.recognitionFailed))
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private final class FakeSpeechPermissionAuthorizer: SpeechPermissionAuthorizing,
    @unchecked Sendable
{
    private(set) var requestCount = 0
    private var status: SpeechPermissionStatus
    private let pausesAuthorizationRequest: Bool
    private var authorizationContinuation: CheckedContinuation<SpeechPermissionStatus, Never>?

    init(
        status: SpeechPermissionStatus,
        pausesAuthorizationRequest: Bool = false
    ) {
        self.status = status
        self.pausesAuthorizationRequest = pausesAuthorizationRequest
    }

    func currentStatus() async -> SpeechPermissionStatus {
        status
    }

    func requestAuthorization() async -> SpeechPermissionStatus {
        requestCount += 1
        if pausesAuthorizationRequest {
            return await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
        }
        status = .authorized
        return status
    }

    func resolveAuthorization(_ status: SpeechPermissionStatus) {
        self.status = status
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume(returning: status)
    }
}

private final class FakeSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private let result: SpeechRecognitionResult
    private let finishError: SpeechSessionFailure?

    init(
        result: SpeechRecognitionResult = .init(text: "你好，Jarvis", confidence: 0.95),
        finishError: SpeechSessionFailure? = nil
    ) {
        self.result = result
        self.finishError = finishError
    }

    func prepare() throws {
        prepareCount += 1
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws -> SpeechRecognitionResult {
        if let finishError { throw finishError }
        return result
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class FakeSpeechAudioCapture: SpeechAudioCapturing, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

import AVFAudio
import JarvisProtocol
import XCTest
@testable import JarvisIOS

final class VoiceEntryTests: XCTestCase {
    @MainActor
    func testLowConfidenceSpeechBecomesDraftAndNeverCallsBridge() async throws {
        let client = RecordingVoiceBridgeClient()
        let permissions = VoiceTestPermissionAuthorizer(status: .authorized)
        let session = SpeechSession(
            recognizer: VoiceTestRecognizer(
                result: .init(text: "给宋小宝发微信", confidence: 0.42)
            ),
            audioCapture: VoiceTestAudioCapture(),
            permissionAuthorizer: permissions,
            minimumConfidence: 0.70
        )
        let model = AppModel(
            client: client,
            deviceID: "voice-test-iphone",
            phase: .idle,
            device: connectedDevice,
            speechSession: session
        )

        model.toggleVoice()
        let didStartListening = await waitUntil { model.phase == .listening }
        XCTAssertTrue(didStartListening)
        model.toggleVoice()
        let didCreateReviewDraft = await waitUntil {
            model.phase == .idle && model.composerText == "给宋小宝发微信"
        }
        XCTAssertTrue(didCreateReviewDraft)

        let submitCount = await client.submitCount()
        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(model.notice, "识别结果需要确认，编辑后再发送")
        XCTAssertEqual(permissions.requestCount, 0)
    }

    @MainActor
    func testListenDeepLinkOnlyReadiesConversationAndNeverStartsRecording() async {
        let permissions = VoiceTestPermissionAuthorizer(status: .undetermined)
        let audio = VoiceTestAudioCapture()
        let session = SpeechSession(
            recognizer: VoiceTestRecognizer(),
            audioCapture: audio,
            permissionAuthorizer: permissions
        )
        let model = AppModel(
            phase: .idle,
            device: connectedDevice,
            speechSession: session
        )

        model.open(url: URL(string: "jarvis://listen")!)
        await Task.yield()

        XCTAssertEqual(model.selectedTab, .conversation)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.notice, "语音入口已就绪，点击开始说话")
        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertEqual(audio.startCount, 0)
    }

    @MainActor
    func testResignActiveStopsListeningWithoutSubmittingTranscript() async throws {
        let client = RecordingVoiceBridgeClient()
        let audio = VoiceTestAudioCapture()
        let recognizer = VoiceTestRecognizer(
            result: .init(text: "不应提交", confidence: 0.99)
        )
        let session = SpeechSession(
            recognizer: recognizer,
            audioCapture: audio,
            permissionAuthorizer: VoiceTestPermissionAuthorizer(status: .authorized)
        )
        let model = AppModel(
            client: client,
            phase: .idle,
            device: connectedDevice,
            speechSession: session
        )
        model.toggleVoice()
        let didStartListening = await waitUntil { model.phase == .listening }
        XCTAssertTrue(didStartListening)

        model.appWillResignActive()
        await Task.yield()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.notice, "应用离开前台，录音已停止")
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(recognizer.cancelCount, 1)
        let submitCount = await client.submitCount()
        XCTAssertEqual(submitCount, 0)
    }

    @MainActor
    private var connectedDevice: DeviceSnapshot {
        DeviceSnapshot(
            computerName: "测试电脑",
            isConnected: true,
            isCertificatePinned: true,
            modelStatus: "本地模型就绪",
            networkStatus: "同一 Wi-Fi"
        )
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

private actor RecordingVoiceBridgeClient: JarvisBridgeClient {
    private var submitted: [BridgeRequest] = []

    func submit(_ request: BridgeRequest) async throws -> BridgeResponse {
        submitted.append(request)
        return try BridgeResponse(
            version: 1,
            requestID: request.requestID,
            state: .completed,
            risk: .low,
            payload: [:]
        )
    }

    func confirm(
        _ requestID: String,
        confirmation: BridgeRequest
    ) async throws -> BridgeResponse {
        try BridgeResponse(
            version: 1,
            requestID: requestID,
            state: .completed,
            risk: .confirmationRequired,
            payload: [:]
        )
    }

    func submitCount() -> Int {
        submitted.count
    }
}

private final class VoiceTestPermissionAuthorizer: SpeechPermissionAuthorizing,
    @unchecked Sendable
{
    private(set) var requestCount = 0
    private var status: SpeechPermissionStatus

    init(status: SpeechPermissionStatus) {
        self.status = status
    }

    func currentStatus() async -> SpeechPermissionStatus {
        status
    }

    func requestAuthorization() async -> SpeechPermissionStatus {
        requestCount += 1
        status = .authorized
        return status
    }
}

private final class VoiceTestRecognizer: SpeechRecognizing, @unchecked Sendable {
    private(set) var cancelCount = 0
    private let result: SpeechRecognitionResult

    init(
        result: SpeechRecognitionResult = .init(text: "你好", confidence: 0.95)
    ) {
        self.result = result
    }

    func prepare() throws {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> SpeechRecognitionResult { result }
    func cancel() { cancelCount += 1 }
}

private final class VoiceTestAudioCapture: SpeechAudioCapturing, @unchecked Sendable {
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

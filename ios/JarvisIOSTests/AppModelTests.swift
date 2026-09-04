import Foundation
import JarvisCore
import JarvisProtocol
import XCTest
@testable import JarvisIOS

final class AppModelTests: XCTestCase {
    @MainActor
    func testProductionLaunchWithoutSavedBridgeIsExplicitlyUnpaired() {
        let model = AppModel.launchConfigured(arguments: [], bridgeBootstrap: { nil })

        XCTAssertFalse(model.device.isPaired)
        XCTAssertEqual(model.device.connectionStatus, "需要配对")
        XCTAssertFalse(model.submit(text: "不能静默丢弃"))
        XCTAssertEqual(model.notice, "请先完成同一 Wi-Fi 配对")
    }

    @MainActor
    func testProductionLaunchInjectsLoadedBridgeClient() async throws {
        let client = ControllableBridgeClient(
            initialConnectionState: .connected(
                endpoint: .discovered(try discoveryMessage()),
                deviceID: "saved-iphone"
            )
        )
        let model = AppModel.launchConfigured(
            arguments: [],
            bridgeBootstrap: {
                ConfiguredBridgeRuntime(client: client, deviceID: "saved-iphone")
            }
        )

        let connected = await waitUntil { model.device.isConnected }
        XCTAssertTrue(connected)
        XCTAssertTrue(model.device.isPaired)
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor
    func testUnpairedConnectionStateShowsPairingRequiredAndRejectsSubmissions() async throws {
        let client = ControllableBridgeClient(
            initialConnectionState: .unpaired(endpoint: .discovered(try discoveryMessage()))
        )
        let model = makeModel(client: client)

        let synced = await waitUntil { model.statusTitle == "等待完成配对" }
        XCTAssertTrue(synced)
        XCTAssertFalse(model.device.isPaired)
        XCTAssertEqual(model.device.connectionStatus, "需要配对")
        XCTAssertFalse(model.submit(text: "帮我发一条消息"))
        XCTAssertEqual(model.notice, "请先完成同一 Wi-Fi 配对")
    }

    @MainActor
    func testConnectedConnectionStateShowsPairedDeviceDetails() async throws {
        let client = ControllableBridgeClient(
            initialConnectionState: .connected(
                endpoint: .discovered(try discoveryMessage()),
                deviceID: "unit-test-iphone"
            )
        )
        let model = makeModel(client: client, phase: .offline, device: .offline)

        let synced = await waitUntil { model.phase == .idle }
        XCTAssertTrue(synced)
        XCTAssertTrue(model.device.isPaired)
        XCTAssertTrue(model.device.isConnected)
        XCTAssertEqual(model.device.computerName, "工作室 Windows")
        XCTAssertEqual(model.device.connectionStatus, "已连接")
    }

    @MainActor
    func testPairedConnectionStateIsReadyForFirstAuthenticatedRequest() async throws {
        let client = ControllableBridgeClient(
            initialConnectionState: .paired(
                endpoint: .discovered(try discoveryMessage()),
                deviceID: "saved-iphone"
            )
        )
        let model = makeModel(client: client, phase: .offline, device: .offline)

        let synced = await waitUntil {
            model.device.isPaired && model.device.isConnected && model.phase == .idle
        }
        XCTAssertTrue(synced)
        XCTAssertEqual(model.device.connectionStatus, "已配对，等待请求连接")
        XCTAssertTrue(model.submit(text: "首次认证请求"))
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
    }

    @MainActor
    func testSubmitTextUsesBridgeChatRequestAndAppliesItsResponse() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(model.submit(text: "你好，Jarvis"))
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
        let requests = await client.submittedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.kind, .chat)
        XCTAssertEqual(request.payload, ["text": .string("你好，Jarvis")])
        XCTAssertEqual(model.phase, .thinking)

        await client.completeSubmit(
            requestID: request.requestID,
            with: try response(
                requestID: request.requestID,
                state: .completed,
                risk: .low,
                payload: ["summary": .string("Bridge 回答")]
            )
        )

        let didComplete = await waitUntil { model.phase == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(model.messages.last?.text, "Bridge 回答")
    }

    @MainActor
    func testOlderOutOfOrderSuccessCannotOverwriteNewerOperation() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(model.submit(text: "第一条"))
        let didSubmitFirst = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmitFirst)
        let firstRequests = await client.submittedRequests()
        let first = try XCTUnwrap(firstRequests.first)

        model.updateConnection(.offline)
        model.updateConnection(connectedDevice)
        XCTAssertTrue(model.submit(text: "第二条"))
        let didSubmitSecond = await waitForSubmitCount(2, client: client)
        XCTAssertTrue(didSubmitSecond)
        let secondRequests = await client.submittedRequests()
        let second = try XCTUnwrap(secondRequests.last)

        await client.completeSubmit(
            requestID: second.requestID,
            with: try response(
                requestID: second.requestID,
                state: .completed,
                risk: .low,
                payload: ["summary": .string("新结果")]
            )
        )
        let didCompleteSecond = await waitUntil { model.phase == .completed }
        XCTAssertTrue(didCompleteSecond)

        await client.completeSubmit(
            requestID: first.requestID,
            with: try response(
                requestID: first.requestID,
                state: .completed,
                risk: .low,
                payload: ["summary": .string("旧结果")]
            )
        )
        await settleAsyncWork()

        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(model.messages.last?.text, "新结果")
        XCTAssertFalse(model.messages.contains { $0.text == "旧结果" })
    }

    @MainActor
    func testStaleErrorCannotReplaceNewerCompletion() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(model.submit(text: "第一条"))
        let didSubmitFirst = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmitFirst)
        let firstRequests = await client.submittedRequests()
        let first = try XCTUnwrap(firstRequests.first)

        model.updateConnection(.offline)
        model.updateConnection(connectedDevice)
        XCTAssertTrue(model.submit(text: "第二条"))
        let didSubmitSecond = await waitForSubmitCount(2, client: client)
        XCTAssertTrue(didSubmitSecond)
        let secondRequests = await client.submittedRequests()
        let second = try XCTUnwrap(secondRequests.last)

        await client.completeSubmit(
            requestID: second.requestID,
            with: try response(
                requestID: second.requestID,
                state: .completed,
                risk: .low,
                payload: ["summary": .string("保留的新结果")]
            )
        )
        let didCompleteSecond = await waitUntil { model.phase == .completed }
        XCTAssertTrue(didCompleteSecond)

        await client.failSubmit(
            requestID: first.requestID,
            with: URLError(.timedOut)
        )
        await settleAsyncWork()

        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(model.messages.last?.text, "保留的新结果")
        XCTAssertNotEqual(model.notice, "请求未完成")
    }

    @MainActor
    func testSubmitAndVoiceAreRejectedWhileConfirmationIsExecuting() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)
        let proposal = RemoteToolProposal.sendWeChatMessage(
            recipient: "宋小宝",
            message: "明天上午十点见。"
        )

        XCTAssertTrue(model.submit(proposal: proposal))
        let didSubmitTool = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmitTool)
        let toolRequests = await client.submittedRequests()
        let toolRequest = try XCTUnwrap(toolRequests.first)
        await client.completeSubmit(
            requestID: toolRequest.requestID,
            with: try awaitingConfirmationResponse(for: toolRequest.requestID)
        )
        let didReachPreview = await waitUntil { model.pendingAction != nil }
        XCTAssertTrue(didReachPreview)
        let preview = try XCTUnwrap(model.pendingAction)

        model.allow(preview)
        let didConfirm = await waitForConfirmationCount(1, client: client)
        XCTAssertTrue(didConfirm)
        XCTAssertEqual(model.phase, .executing)

        XCTAssertFalse(model.submit(text: "并发消息"))
        model.toggleVoice()
        XCTAssertEqual(model.phase, .executing)
        let submitCount = await client.submittedRequests().count
        let confirmationCount = await client.confirmations().count
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(confirmationCount, 1)

        let confirmations = await client.confirmations()
        let confirmation = try XCTUnwrap(confirmations.first)
        await client.completeConfirmation(
            requestID: confirmation.request.requestID,
            with: try response(
                requestID: preview.requestID,
                state: .completed,
                risk: .confirmationRequired,
                payload: ["summary": .string("已发送")]
            )
        )
        let didComplete = await waitUntil { model.phase == .completed }
        XCTAssertTrue(didComplete)
    }

    @MainActor
    func testTypedToolProposalAwaitsPreviewThenConfirmsThroughBridge() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)
        let proposal = RemoteToolProposal.sendWeChatMessage(
            recipient: "宋小宝",
            message: "明天上午十点见。"
        )

        XCTAssertTrue(model.submit(proposal: proposal))
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
        let submitted = await client.submittedRequests()
        let request = try XCTUnwrap(submitted.first)
        XCTAssertEqual(request.kind, .tool)
        XCTAssertEqual(
            request.payload,
            [
                "tool": .string("send_wechat_message"),
                "arguments": .object([
                    "contact": .string("宋小宝"),
                    "message": .string("明天上午十点见。"),
                ]),
            ]
        )

        await client.completeSubmit(
            requestID: request.requestID,
            with: try awaitingConfirmationResponse(for: request.requestID)
        )
        let didReachPreview = await waitUntil { model.pendingAction != nil }
        XCTAssertTrue(didReachPreview)
        let preview = try XCTUnwrap(model.pendingAction)
        XCTAssertEqual(preview.title, "发送微信消息")
        XCTAssertEqual(preview.summary, "发送前请你确认")
        XCTAssertEqual(preview.action, "发送消息")
        XCTAssertEqual(preview.target, "微信")
        XCTAssertEqual(preview.recipient, "宋小宝")
        XCTAssertEqual(preview.message, "明天上午十点见。")

        model.allow(preview)
        let didConfirm = await waitForConfirmationCount(1, client: client)
        XCTAssertTrue(didConfirm)
        let confirmations = await client.confirmations()
        let confirmation = try XCTUnwrap(confirmations.first)
        XCTAssertEqual(confirmation.targetRequestID, request.requestID)
        XCTAssertEqual(confirmation.request.kind, .confirm)
        XCTAssertEqual(
            confirmation.request.payload,
            ["target_request_id": .string(request.requestID)]
        )

        await client.completeConfirmation(
            requestID: confirmation.request.requestID,
            with: try response(
                requestID: request.requestID,
                state: .completed,
                risk: .confirmationRequired,
                payload: ["summary": .string("消息已发送")]
            )
        )
        let didComplete = await waitUntil { model.phase == .completed }
        XCTAssertTrue(didComplete)
    }

    @MainActor
    func testCancellingToolPreviewSendsDeclineThroughBridge() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(
            model.submit(
                proposal: .sendWeChatMessage(
                    recipient: "宋小宝",
                    message: "这条消息不要发送。"
                )
            )
        )
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
        let submitted = await client.submittedRequests()
        let request = try XCTUnwrap(submitted.first)
        await client.completeSubmit(
            requestID: request.requestID,
            with: try awaitingConfirmationResponse(
                for: request.requestID,
                message: "这条消息不要发送。"
            )
        )
        let didReachPreview = await waitUntil { model.pendingAction != nil }
        XCTAssertTrue(didReachPreview)
        let preview = try XCTUnwrap(model.pendingAction)

        model.cancelPreview(preview)
        let didCancel = await waitForCancellationCount(1, client: client)
        XCTAssertTrue(didCancel)
        let cancellations = await client.cancellations()
        let cancellation = try XCTUnwrap(cancellations.first)
        XCTAssertEqual(cancellation.targetRequestID, request.requestID)
        XCTAssertEqual(cancellation.request.kind, .cancel)

        await client.completeCancellation(
            requestID: cancellation.request.requestID,
            with: try response(
                requestID: request.requestID,
                state: .cancelled,
                risk: .confirmationRequired,
                payload: ["summary": .string("已取消")]
            )
        )
        let settled = await waitUntil { model.phase == .idle }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.notice, "已取消，未执行")
    }

    @MainActor
    func testBlockedRiskRejectionPresentsRefusalPreviewWithoutApproval() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(
            model.submit(
                proposal: .sendWeChatMessage(
                    recipient: "宋小宝",
                    message: "替我支付这笔款项。"
                )
            )
        )
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
        let submitted = await client.submittedRequests()
        let request = try XCTUnwrap(submitted.first)

        await client.failSubmit(
            requestID: request.requestID,
            with: BridgeError.requestRejected(
                try rejection(
                    requestID: request.requestID,
                    reason: .paymentBlocked,
                    message: "涉及付款，已拒绝执行。"
                )
            )
        )

        let didReachPreview = await waitUntil { model.pendingAction != nil }
        XCTAssertTrue(didReachPreview)
        let preview = try XCTUnwrap(model.pendingAction)
        XCTAssertFalse(preview.allowsApproval)
        XCTAssertEqual(preview.refusalReason, .paymentBlocked)
        XCTAssertEqual(model.statusTitle, "无法执行该操作")

        model.allow(preview)
        await settleAsyncWork()
        let confirmationCount = await client.confirmations().count
        XCTAssertEqual(confirmationCount, 0)

        model.cancelPreview(preview)
        let settled = await waitUntil { model.phase == .failed }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.notice, "涉及付款，Jarvis 不会代你确认或付款。")
    }

    @MainActor
    func testBlockedRejectionDuringConfirmationReplacesExecutingStateWithRefusalPreview() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(
            model.submit(
                proposal: .sendWeChatMessage(
                    recipient: "宋小宝",
                    message: "替我输入这个支付密码。"
                )
            )
        )
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
        let submitted = await client.submittedRequests()
        let request = try XCTUnwrap(submitted.first)
        await client.completeSubmit(
            requestID: request.requestID,
            with: try awaitingConfirmationResponse(for: request.requestID)
        )
        let didReachPreview = await waitUntil { model.pendingAction != nil }
        XCTAssertTrue(didReachPreview)
        let preview = try XCTUnwrap(model.pendingAction)

        model.allow(preview)
        let didConfirm = await waitForConfirmationCount(1, client: client)
        XCTAssertTrue(didConfirm)
        XCTAssertEqual(model.phase, .executing)

        let confirmations = await client.confirmations()
        let confirmation = try XCTUnwrap(confirmations.first)
        await client.failConfirmation(
            requestID: confirmation.request.requestID,
            with: BridgeError.requestRejected(
                try rejection(
                    requestID: request.requestID,
                    reason: .passwordEntryBlocked,
                    message: "涉及密码输入，已拒绝执行。"
                )
            )
        )

        let didShowBlockedPreview = await waitUntil {
            model.pendingAction?.refusalReason == .passwordEntryBlocked
        }
        XCTAssertTrue(didShowBlockedPreview)
        let blocked = try XCTUnwrap(model.pendingAction)
        XCTAssertFalse(blocked.allowsApproval)
        XCTAssertEqual(model.statusTitle, "无法执行该操作")
        XCTAssertNotEqual(model.phase, .executing)
    }

    @MainActor
    func testFileDeletionBlockedRejectionUsesBlockedPreview() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(
            model.submit(
                proposal: .sendWeChatMessage(
                    recipient: "宋小宝",
                    message: "把桌面文件删掉。"
                )
            )
        )
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
        let submittedRequests = await client.submittedRequests()
        let request = try XCTUnwrap(submittedRequests.first)

        await client.failSubmit(
            requestID: request.requestID,
            with: BridgeError.requestRejected(
                try rejection(
                    requestID: request.requestID,
                    reason: .fileDeletionBlocked,
                    message: "涉及删除文件，已拒绝执行。"
                )
            )
        )

        let didReachPreview = await waitUntil {
            model.pendingAction?.refusalReason == .fileDeletionBlocked
        }
        XCTAssertTrue(didReachPreview)
        XCTAssertEqual(model.pendingAction?.summary, "涉及删除文件，Jarvis 不会代你确认或删除。")
    }

    @MainActor
    func testPasswordEntryBlockedRejectionUsesBlockedPreview() async throws {
        let client = ControllableBridgeClient()
        let model = makeModel(client: client)

        XCTAssertTrue(
            model.submit(
                proposal: .sendWeChatMessage(
                    recipient: "宋小宝",
                    message: "替我输入银行卡密码。"
                )
            )
        )
        let didSubmit = await waitForSubmitCount(1, client: client)
        XCTAssertTrue(didSubmit)
        let submittedRequests = await client.submittedRequests()
        let request = try XCTUnwrap(submittedRequests.first)

        await client.failSubmit(
            requestID: request.requestID,
            with: BridgeError.requestRejected(
                try rejection(
                    requestID: request.requestID,
                    reason: .passwordEntryBlocked,
                    message: "涉及密码输入，已拒绝执行。"
                )
            )
        )

        let didReachPreview = await waitUntil {
            model.pendingAction?.refusalReason == .passwordEntryBlocked
        }
        XCTAssertTrue(didReachPreview)
        XCTAssertEqual(model.pendingAction?.summary, "涉及密码输入，Jarvis 不会代你输入或确认。")
    }

    @MainActor
    private func makeModel(
        client: ControllableBridgeClient,
        phase: AppModel.Phase = .idle,
        device: DeviceSnapshot? = nil
    ) -> AppModel {
        AppModel(
            client: client,
            deviceID: "unit-test-iphone",
            phase: phase,
            device: device ?? connectedDevice
        )
    }

    @MainActor
    private var connectedDevice: DeviceSnapshot {
        DeviceSnapshot(
            computerName: "测试电脑",
            isConnected: true,
            isPaired: true,
            isCertificatePinned: true,
            connectionStatus: "已连接",
            pairingStatus: "已配对",
            modelStatus: "本地模型就绪",
            networkStatus: "同一 Wi-Fi"
        )
    }

    private func response(
        requestID: String,
        state: TaskState,
        risk: Risk,
        payload: [String: JSONValue]
    ) throws -> BridgeResponse {
        try BridgeResponse(
            version: 1,
            requestID: requestID,
            state: state,
            risk: risk,
            payload: payload
        )
    }

    private func awaitingConfirmationResponse(
        for requestID: String,
        message: String = "明天上午十点见。"
    ) throws -> BridgeResponse {
        try response(
            requestID: requestID,
            state: .awaitingConfirmation,
            risk: .confirmationRequired,
            payload: [
                "task_id": .string("task-preview-1"),
                "title": .string("发送微信消息"),
                "summary": .string("发送前请你确认"),
                "action": .string("发送消息"),
                "target": .string("微信"),
                "arguments": .object([
                    "contact": .string("宋小宝"),
                    "message": .string(message),
                ]),
            ]
        )
    }

    private func rejection(
        requestID: String,
        reason: RejectionReason,
        message: String
    ) throws -> TaskRejection {
        try TaskRejection(
            version: 1,
            requestID: requestID,
            taskID: "task-preview-1",
            reason: reason,
            message: message,
            retryable: false
        )
    }

    private func discoveryMessage() throws -> DiscoveryMessage {
        try DiscoveryMessage(
            version: 1,
            bridgeID: "bridge-1",
            bridgeURL: "https://jarvis.local",
            certificateFingerprint: String(repeating: "a", count: 64),
            displayName: "工作室 Windows",
            requiresPairing: true
        )
    }

    @MainActor
    private func waitForSubmitCount(
        _ expected: Int,
        client: ControllableBridgeClient
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if await client.submittedRequests().count >= expected { return true }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForConfirmationCount(
        _ expected: Int,
        client: ControllableBridgeClient
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if await client.confirmations().count >= expected { return true }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForCancellationCount(
        _ expected: Int,
        client: ControllableBridgeClient
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if await client.cancellations().count >= expected { return true }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func settleAsyncWork() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }
}

private actor ControllableBridgeClient: JarvisBridgeClient {
    struct ConfirmationCall: Sendable {
        let targetRequestID: String
        let request: BridgeRequest
    }

    struct CancellationCall: Sendable {
        let targetRequestID: String
        let request: BridgeRequest
    }

    private var submits: [BridgeRequest] = []
    private var confirmationCalls: [ConfirmationCall] = []
    private var cancellationCalls: [CancellationCall] = []
    private let initialConnectionState: BridgeConnectionState
    private var submitContinuations: [
        String: CheckedContinuation<BridgeResponse, any Error>
    ] = [:]
    private var confirmationContinuations: [
        String: CheckedContinuation<BridgeResponse, any Error>
    ] = [:]
    private var cancellationContinuations: [
        String: CheckedContinuation<BridgeResponse, any Error>
    ] = [:]

    init(
        initialConnectionState: BridgeConnectionState = .connected(
            endpoint: .manual(
                baseURL: URL(string: "https://127.0.0.1")!,
                certificateFingerprint: String(repeating: "a", count: 64)
            ),
            deviceID: "unit-test-iphone"
        )
    ) {
        self.initialConnectionState = initialConnectionState
    }

    func connectionState() async -> BridgeConnectionState {
        initialConnectionState
    }

    func submit(_ request: BridgeRequest) async throws -> BridgeResponse {
        submits.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            submitContinuations[request.requestID] = continuation
        }
    }

    func confirm(
        _ requestID: String,
        confirmation: BridgeRequest
    ) async throws -> BridgeResponse {
        confirmationCalls.append(
            ConfirmationCall(targetRequestID: requestID, request: confirmation)
        )
        return try await withCheckedThrowingContinuation { continuation in
            confirmationContinuations[confirmation.requestID] = continuation
        }
    }

    func submittedRequests() -> [BridgeRequest] {
        submits
    }

    func confirmations() -> [ConfirmationCall] {
        confirmationCalls
    }

    func cancel(
        _ requestID: String,
        cancellation: BridgeRequest
    ) async throws -> BridgeResponse {
        cancellationCalls.append(
            CancellationCall(targetRequestID: requestID, request: cancellation)
        )
        return try await withCheckedThrowingContinuation { continuation in
            cancellationContinuations[cancellation.requestID] = continuation
        }
    }

    func cancellations() -> [CancellationCall] {
        cancellationCalls
    }

    func completeSubmit(requestID: String, with response: BridgeResponse) {
        submitContinuations.removeValue(forKey: requestID)?.resume(returning: response)
    }

    func failSubmit(requestID: String, with error: any Error) {
        submitContinuations.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    func completeConfirmation(requestID: String, with response: BridgeResponse) {
        confirmationContinuations.removeValue(forKey: requestID)?.resume(returning: response)
    }

    func failConfirmation(requestID: String, with error: any Error) {
        confirmationContinuations.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    func completeCancellation(requestID: String, with response: BridgeResponse) {
        cancellationContinuations.removeValue(forKey: requestID)?.resume(returning: response)
    }
}

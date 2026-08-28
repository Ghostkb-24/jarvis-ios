import Foundation
import JarvisProtocol
import XCTest
@testable import JarvisIOS

@MainActor
final class AppModelTests: XCTestCase {
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

    func testCancellingToolPreviewDoesNotCallBridgeConfirmation() async throws {
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
        await settleAsyncWork()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.notice, "已取消，未执行")
        let confirmationCount = await client.confirmations().count
        XCTAssertEqual(confirmationCount, 0)
    }

    private func makeModel(client: ControllableBridgeClient) -> AppModel {
        AppModel(
            client: client,
            deviceID: "unit-test-iphone",
            phase: .idle,
            device: connectedDevice
        )
    }

    private var connectedDevice: DeviceSnapshot {
        DeviceSnapshot(
            computerName: "测试电脑",
            isConnected: true,
            isCertificatePinned: true,
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
                "arguments": .object([
                    "contact": .string("宋小宝"),
                    "message": .string(message),
                ]),
            ]
        )
    }

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

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

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

    private var submits: [BridgeRequest] = []
    private var confirmationCalls: [ConfirmationCall] = []
    private var submitContinuations: [
        String: CheckedContinuation<BridgeResponse, any Error>
    ] = [:]
    private var confirmationContinuations: [
        String: CheckedContinuation<BridgeResponse, any Error>
    ] = [:]

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

    func completeSubmit(requestID: String, with response: BridgeResponse) {
        submitContinuations.removeValue(forKey: requestID)?.resume(returning: response)
    }

    func failSubmit(requestID: String, with error: any Error) {
        submitContinuations.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    func completeConfirmation(requestID: String, with response: BridgeResponse) {
        confirmationContinuations.removeValue(forKey: requestID)?.resume(returning: response)
    }
}

import Combine
import Foundation
import JarvisCore
import JarvisProtocol
import WidgetKit

protocol JarvisBridgeClient: Sendable {
    func submit(_ request: BridgeRequest) async throws -> BridgeResponse
    func confirm(_ requestID: String, confirmation: BridgeRequest) async throws -> BridgeResponse
}

extension BridgeClient: JarvisBridgeClient {}

struct ActionPreview: Identifiable, Equatable, Sendable {
    let requestID: String
    let recipient: String
    let message: String

    var id: String { requestID }
}

struct ConversationMessage: Identifiable, Equatable, Sendable {
    enum Author: Equatable, Sendable {
        case user
        case jarvis
    }

    let id: UUID
    let author: Author
    let text: String

    init(id: UUID = UUID(), author: Author, text: String) {
        self.id = id
        self.author = author
        self.text = text
    }
}

struct JarvisTaskSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let status: String
    let symbol: String

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: String,
        symbol: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.symbol = symbol
    }
}

struct DeviceSnapshot: Equatable, Sendable {
    let computerName: String
    let isConnected: Bool
    let isCertificatePinned: Bool
    let modelStatus: String
    let networkStatus: String

    static let offline = DeviceSnapshot(
        computerName: "Windows 电脑",
        isConnected: false,
        isCertificatePinned: false,
        modelStatus: "本地模型不可用",
        networkStatus: "等待同一 Wi-Fi 连接"
    )
}

enum AppTab: Hashable, Sendable {
    case conversation
    case tasks
    case devices
}

protocol WidgetSnapshotWriting {
    func save(_ device: DeviceSnapshot)
}

struct AppGroupWidgetSnapshotWriter: WidgetSnapshotWriting {
    static let suiteName = "group.com.jarvisassistant.shared"
    static let snapshotKey = "jarvis.widget.status.v1"

    private struct StatusSnapshot: Codable {
        let connectionStatus: String
        let modelStatus: String
        let updatedAt: Date
    }

    func save(_ device: DeviceSnapshot) {
        let snapshot = StatusSnapshot(
            connectionStatus: device.isConnected ? "connected" : "offline",
            modelStatus: device.modelStatus,
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: Self.suiteName)?.set(data, forKey: Self.snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "com.jarvisassistant.ios.widget.status")
    }
}

public enum RemoteToolProposal: Equatable, Sendable {
    case sendWeChatMessage(recipient: String, message: String)

    var requestPayload: [String: JSONValue]? {
        switch self {
        case let .sendWeChatMessage(recipient, message):
            let normalizedRecipient = recipient.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                !normalizedRecipient.isEmpty,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return [
                "tool": .string("send_wechat_message"),
                "arguments": .object([
                    "contact": .string(normalizedRecipient),
                    "message": .string(message),
                ]),
            ]
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case thinking
        case awaitingConfirmation(ActionPreview)
        case executing
        case completed
        case failed
        case offline
        case resultUnknown

        var title: String {
            switch self {
            case .idle:
                "可以开始对话"
            case .listening:
                "正在聆听"
            case .transcribing:
                "正在识别"
            case .thinking:
                "正在思考"
            case .awaitingConfirmation:
                "等待你的确认"
            case .executing:
                "正在执行"
            case .completed:
                "已完成"
            case .failed:
                "操作失败"
            case .offline:
                "电脑离线"
            case .resultUnknown:
                "结果待确认"
            }
        }

        var detail: String {
            switch self {
            case .idle:
                "点击语音核心，或在下方输入消息"
            case .listening:
                "我在听，说完后再次点击"
            case .transcribing:
                "正在把语音转换为文字"
            case .thinking:
                "正在通过本地 Jarvis 处理请求"
            case .awaitingConfirmation:
                "请核对目标和完整内容后再继续"
            case .executing:
                "电脑正在执行已允许的操作"
            case .completed:
                "操作已安全完成"
            case .failed:
                "没有执行操作，请查看任务详情"
            case .offline:
                "请求草稿会保留，重新连接后可再次发送"
            case .resultUnknown:
                "不要重复发送，请检查目标应用"
            }
        }

        var acceptsNewOperation: Bool {
            switch self {
            case .idle, .completed, .failed, .resultUnknown:
                true
            default:
                false
            }
        }

        var blocksCompetingInput: Bool {
            switch self {
            case .thinking, .awaitingConfirmation, .executing:
                true
            default:
                false
            }
        }

        func allowsTransition(to next: Phase) -> Bool {
            if self == next { return true }
            if case .offline = next { return true }

            switch (self, next) {
            case (.offline, .idle),
                 (.offline, .listening),
                 (.idle, .listening),
                 (.idle, .failed),
                 (.idle, .thinking),
                 (.listening, .transcribing),
                 (.listening, .idle),
                 (.transcribing, .thinking),
                 (.transcribing, .idle),
                 (.transcribing, .failed),
                 (.thinking, .awaitingConfirmation),
                 (.thinking, .executing),
                 (.thinking, .completed),
                 (.thinking, .failed),
                 (.thinking, .idle),
                 (.thinking, .resultUnknown),
                 (.awaitingConfirmation, .executing),
                 (.awaitingConfirmation, .idle),
                 (.awaitingConfirmation, .failed),
                 (.awaitingConfirmation, .resultUnknown),
                 (.executing, .completed),
                 (.executing, .failed),
                 (.executing, .idle),
                 (.executing, .resultUnknown),
                 (.completed, .idle),
                 (.completed, .listening),
                 (.completed, .thinking),
                 (.failed, .idle),
                 (.failed, .listening),
                 (.failed, .thinking),
                 (.resultUnknown, .idle),
                 (.resultUnknown, .listening),
                 (.resultUnknown, .thinking):
                true
            default:
                false
            }
        }
    }

    @Published var selectedTab: AppTab = .conversation
    @Published var composerText = ""
    @Published private(set) var phase: Phase
    @Published private(set) var messages: [ConversationMessage]
    @Published private(set) var tasks: [JarvisTaskSummary]
    @Published private(set) var device: DeviceSnapshot
    @Published private(set) var notice: String?
    @Published private(set) var testingClientCallCount = 0
    @Published private(set) var speechPermissionStatus: SpeechPermissionStatus = .undetermined
    @Published private(set) var isRequestingSpeechPermission = false

    let isUITesting: Bool

    private let client: (any JarvisBridgeClient)?
    private let deviceID: String
    private let speechSession: SpeechSession?
    private let widgetSnapshotWriter: (any WidgetSnapshotWriting)?
    private var operationGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var voiceGeneration: UInt64 = 0
    private var voiceAutoSubmissionGeneration: UInt64?

    init(
        client: (any JarvisBridgeClient)? = nil,
        deviceID: String = "unpaired-iphone",
        phase: Phase = .offline,
        messages: [ConversationMessage] = [],
        tasks: [JarvisTaskSummary] = [],
        device: DeviceSnapshot = .offline,
        isUITesting: Bool = false,
        speechSession: SpeechSession? = nil,
        widgetSnapshotWriter: (any WidgetSnapshotWriting)? = nil
    ) {
        self.client = client
        self.deviceID = deviceID
        self.phase = phase
        self.messages = messages
        self.tasks = tasks
        self.device = device
        self.isUITesting = isUITesting
        self.speechSession = speechSession
        self.widgetSnapshotWriter = widgetSnapshotWriter
        speechPermissionStatus = speechSession?.permissionStatus ?? .undetermined
        widgetSnapshotWriter?.save(device)
    }

    var isConnected: Bool { device.isConnected }

    var pendingAction: ActionPreview? {
        guard case let .awaitingConfirmation(preview) = phase else { return nil }
        return preview
    }

    static func launchConfigured(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        let isUITesting = arguments.contains("-ui-testing")
        guard isUITesting else {
            return AppModel(
                speechSession: SpeechSession(),
                widgetSnapshotWriter: AppGroupWidgetSnapshotWriter()
            )
        }

        let fixture = fixtureName(in: arguments)
        let connectedDevice = DeviceSnapshot(
            computerName: "工作室 Windows",
            isConnected: true,
            isCertificatePinned: true,
            modelStatus: "本地模型就绪",
            networkStatus: "同一 Wi-Fi · 加密连接"
        )
        let fixtureClient = FixtureBridgeClient()
        let sampleMessages = [
            ConversationMessage(author: .user, text: "今天有哪些重要任务？"),
            ConversationMessage(author: .jarvis, text: "下午有一项方案确认，我会在执行前再次请你核对。"),
        ]
        let sampleTasks = [
            JarvisTaskSummary(
                title: "整理今日安排",
                detail: "本地对话",
                status: "已完成",
                symbol: "checkmark.circle.fill"
            ),
            JarvisTaskSummary(
                title: "发送微信消息",
                detail: "跨应用操作",
                status: "等待确认",
                symbol: "exclamationmark.shield.fill"
            ),
        ]

        switch fixture {
        case "connected":
            return AppModel(
                client: fixtureClient,
                deviceID: "ui-test-iphone",
                phase: .idle,
                messages: sampleMessages,
                tasks: sampleTasks,
                device: connectedDevice,
                isUITesting: true
            )
        case "confirmation":
            let preview = ActionPreview(
                requestID: "ui-confirm-1",
                recipient: "宋小宝",
                message: "明天上午十点在工作室见，记得带上最终版方案。"
            )
            return AppModel(
                client: fixtureClient,
                deviceID: "ui-test-iphone",
                phase: .awaitingConfirmation(preview),
                messages: sampleMessages,
                tasks: sampleTasks,
                device: connectedDevice,
                isUITesting: true
            )
        case "result-unknown":
            return AppModel(
                client: fixtureClient,
                deviceID: "ui-test-iphone",
                phase: .resultUnknown,
                messages: sampleMessages,
                tasks: sampleTasks,
                device: connectedDevice,
                isUITesting: true
            )
        default:
            return AppModel(
                phase: .offline,
                messages: sampleMessages,
                tasks: sampleTasks,
                device: .offline,
                isUITesting: true
            )
        }
    }

    func updateConnection(_ snapshot: DeviceSnapshot) {
        device = snapshot
        widgetSnapshotWriter?.save(snapshot)
        if snapshot.isConnected {
            if phase == .offline {
                _ = transition(to: .idle)
                notice = nil
            }
        } else {
            invalidateActiveOperation()
            stopVoiceWithoutSubmission()
            _ = transition(to: .offline)
            notice = "电脑连接已断开，进行中的响应将被忽略"
        }
    }

    func toggleVoice() {
        guard let speechSession else {
            toggleFixtureVoice()
            return
        }

        if isRequestingSpeechPermission {
            notice = "正在等待麦克风和语音识别权限"
            return
        }

        switch phase {
        case .listening:
            notice = nil
            guard transition(to: .transcribing) else { return }
            let generation = voiceGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await speechSession.stopResult()
                    self.applySpeechResult(result, ownedBy: generation)
                } catch {
                    self.receiveSpeechFailure(error, ownedBy: generation)
                }
            }
        case .offline:
            beginVoiceStart(with: speechSession)
        case .thinking, .awaitingConfirmation, .executing:
            notice = "当前请求尚未结束，请先处理当前状态"
        default:
            guard phase.acceptsNewOperation else {
                notice = "当前状态无法开始语音输入"
                return
            }
            beginVoiceStart(with: speechSession)
        }
    }

    func open(url: URL) {
        guard
            url.scheme?.lowercased() == "jarvis",
            url.host?.lowercased() == "listen"
        else {
            return
        }
        prepareListeningEntry()
    }

    func consumeListeningEntryIfNeeded() {
        guard ListeningEntryStore.consumeListeningEntry() else { return }
        prepareListeningEntry()
    }

    private func prepareListeningEntry() {
        selectedTab = .conversation
        notice = "语音入口已就绪，点击开始说话"
    }

    func appWillResignActive() {
        let wasRequestingPermission = isRequestingSpeechPermission
        let hadPendingVoice = wasRequestingPermission
            || phase == .listening
            || phase == .transcribing
        if hadPendingVoice {
            voiceGeneration &+= 1
            voiceAutoSubmissionGeneration = nil
            isRequestingSpeechPermission = false
        }
        speechSession?.appWillResignActive()
        if hadPendingVoice {
            if phase == .listening || phase == .transcribing {
                _ = transition(to: isConnected ? .idle : .offline)
            }
            notice = wasRequestingPermission || phase == .offline
                ? "应用离开前台，语音输入已停止"
                : "应用离开前台，录音已停止"
        }
    }

    func appDidEnterBackground() {
        let hadPendingVoice = isRequestingSpeechPermission
            || phase == .listening
            || phase == .transcribing
        voiceGeneration &+= 1
        voiceAutoSubmissionGeneration = nil
        isRequestingSpeechPermission = false
        speechSession?.cancel()
        if phase == .listening || phase == .transcribing {
            _ = transition(to: isConnected ? .idle : .offline)
        }
        if hadPendingVoice {
            notice = "应用进入后台，语音输入已停止"
        }
    }

    private func toggleFixtureVoice() {
        switch phase {
        case .listening:
            notice = nil
            _ = transition(to: .transcribing)
        case .offline:
            notice = "电脑离线，语音草稿不会自动发送"
        case .thinking, .awaitingConfirmation, .executing:
            notice = "当前请求尚未结束，请先处理当前状态"
        default:
            guard transition(to: .listening) else {
                notice = "当前状态无法开始语音输入"
                return
            }
            notice = nil
        }
    }

    private func beginVoiceStart(with speechSession: SpeechSession) {
        voiceGeneration &+= 1
        let generation = voiceGeneration
        voiceAutoSubmissionGeneration = isConnected && client != nil ? generation : nil
        isRequestingSpeechPermission = true
        notice = "正在请求麦克风和语音识别权限"

        Task { [weak self] in
            guard let self else { return }
            guard generation == self.voiceGeneration else { return }
            do {
                try await speechSession.start()
                guard generation == self.voiceGeneration else {
                    speechSession.appWillResignActive()
                    return
                }
                self.isRequestingSpeechPermission = false
                self.speechPermissionStatus = speechSession.permissionStatus
                guard self.transition(to: .listening) else {
                    speechSession.appWillResignActive()
                    self.notice = "当前状态无法开始语音输入"
                    return
                }
                self.notice = nil
            } catch {
                self.receiveSpeechFailure(error, ownedBy: generation)
            }
        }
    }

    private func applySpeechResult(
        _ result: SpeechTranscriptResult,
        ownedBy generation: UInt64
    ) {
        guard generation == voiceGeneration else { return }
        speechPermissionStatus = speechSession?.permissionStatus ?? speechPermissionStatus
        let mayAutoSubmit = voiceAutoSubmissionGeneration == generation && isConnected
        voiceAutoSubmissionGeneration = nil
        guard transition(to: isConnected ? .idle : .offline) else { return }

        guard mayAutoSubmit else {
            composerText = result.text
            if result.requiresReview {
                notice = "识别结果需要确认，编辑后再发送"
            } else if client == nil {
                notice = "语音已保存为草稿，当前无法发送"
            } else if isConnected {
                notice = "语音已保存为草稿，请确认后发送"
            } else {
                notice = "电脑离线，语音已保存为草稿，未发送"
            }
            return
        }

        guard let executableText = result.executableText else {
            composerText = result.text
            notice = "识别结果需要确认，编辑后再发送"
            return
        }
        notice = nil
        guard submit(text: executableText) else {
            composerText = executableText
            if !isConnected {
                notice = "电脑离线，语音已保存为草稿，未发送"
            } else if let failureNotice = notice, !failureNotice.isEmpty {
                notice = "\(failureNotice)，语音已保存为草稿"
            } else {
                notice = "语音已保存为草稿，当前无法发送"
            }
            return
        }
    }

    private func receiveSpeechFailure(
        _ error: any Error,
        ownedBy generation: UInt64
    ) {
        guard generation == voiceGeneration else { return }
        voiceAutoSubmissionGeneration = nil
        isRequestingSpeechPermission = false
        speechPermissionStatus = speechSession?.permissionStatus ?? speechPermissionStatus
        if phase != .idle {
            _ = transition(to: .idle)
        }
        _ = transition(to: .failed)

        switch error as? SpeechSessionFailure {
        case .permissionDenied:
            notice = "需要麦克风和语音识别权限才能开始"
        case .emptyTranscript:
            notice = "没有识别到语音，请重试"
        case .interrupted:
            notice = "录音已停止"
        default:
            notice = "语音识别失败，未发送任何内容"
        }
    }

    private func stopVoiceWithoutSubmission() {
        guard
            isRequestingSpeechPermission
                || phase == .listening
                || phase == .transcribing
        else {
            return
        }
        voiceGeneration &+= 1
        voiceAutoSubmissionGeneration = nil
        isRequestingSpeechPermission = false
        speechSession?.cancel()
    }

    func submitComposer() {
        let text = composerText
        if submit(text: text) {
            composerText = ""
        }
    }

    @discardableResult
    public func submit(text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard !isRequestingSpeechPermission else {
            notice = "请先完成语音权限选择"
            return false
        }
        guard phase.acceptsNewOperation else {
            notice = "当前请求尚未结束，请先处理当前状态"
            return false
        }
        guard let client, isConnected else {
            _ = transition(to: .offline)
            notice = "请求草稿已保留"
            return false
        }

        let request: BridgeRequest
        do {
            request = try makeRequest(
                kind: .chat,
                payload: ["text": .string(normalized)]
            )
        } catch {
            notice = "无法创建安全请求"
            return false
        }
        return startSubmission(
            request,
            client: client,
            userMessage: normalized
        )
    }

    @discardableResult
    public func submit(proposal: RemoteToolProposal) -> Bool {
        guard !isRequestingSpeechPermission else {
            notice = "请先完成语音权限选择"
            return false
        }
        guard phase.acceptsNewOperation else {
            notice = "当前请求尚未结束，请先处理当前状态"
            return false
        }
        guard let client, isConnected else {
            _ = transition(to: .offline)
            notice = "电脑离线，操作提案未发送"
            return false
        }
        guard let payload = proposal.requestPayload else {
            notice = "操作目标或内容不能为空"
            return false
        }

        let request: BridgeRequest
        do {
            request = try makeRequest(kind: .tool, payload: payload)
        } catch {
            notice = "无法创建安全操作请求"
            return false
        }
        return startSubmission(request, client: client, userMessage: nil)
    }

    func allow(_ preview: ActionPreview) {
        guard pendingAction == preview else { return }
        guard let client, isConnected else {
            invalidateActiveOperation()
            _ = transition(to: .offline)
            return
        }

        let confirmation: BridgeRequest
        do {
            confirmation = try makeRequest(
                kind: .confirm,
                payload: ["target_request_id": .string(preview.requestID)]
            )
        } catch {
            notice = "无法创建确认请求"
            return
        }
        guard let generation = beginConfirmationOperation() else { return }

        notice = nil
        testingClientCallCount += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.confirm(
                    preview.requestID,
                    confirmation: confirmation
                )
                self.apply(response, ownedBy: generation)
            } catch BridgeError.resultUnknown {
                self.receiveResultUnknown(ownedBy: generation)
            } catch {
                self.receiveFailure(
                    "确认请求未完成",
                    ownedBy: generation
                )
            }
        }
    }

    func cancelPreview(_ preview: ActionPreview) {
        guard pendingAction == preview else { return }
        invalidateActiveOperation()
        _ = transition(to: .idle)
        notice = "已取消，未执行"
    }

    private func startSubmission(
        _ request: BridgeRequest,
        client: any JarvisBridgeClient,
        userMessage: String?
    ) -> Bool {
        guard let generation = beginRemoteOperation() else { return false }
        notice = nil
        if let userMessage {
            messages.append(ConversationMessage(author: .user, text: userMessage))
        }
        testingClientCallCount += 1

        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.submit(request)
                self.apply(response, ownedBy: generation)
            } catch BridgeError.resultUnknown {
                self.receiveResultUnknown(ownedBy: generation)
            } catch {
                self.receiveFailure("请求未完成", ownedBy: generation)
            }
        }
        return true
    }

    private func apply(_ response: BridgeResponse, ownedBy generation: UInt64) {
        guard activeGeneration == generation else { return }

        switch response.state {
        case .preparing:
            _ = transition(to: .thinking, ownedBy: generation)
        case .awaitingConfirmation:
            guard let preview = actionPreview(from: response) else {
                _ = transition(to: .failed, ownedBy: generation)
                notice = "动作预览不完整，未执行操作"
                finishOperation(generation)
                return
            }
            _ = transition(to: .awaitingConfirmation(preview), ownedBy: generation)
        case .executing:
            _ = transition(to: .executing, ownedBy: generation)
        case .completed:
            guard transition(to: .completed, ownedBy: generation) else { return }
            if let summary = stringValue(response.payload["summary"]), !summary.isEmpty {
                messages.append(ConversationMessage(author: .jarvis, text: summary))
            }
            finishOperation(generation)
        case .failed:
            guard transition(to: .failed, ownedBy: generation) else { return }
            notice = stringValue(response.payload["summary"])
            finishOperation(generation)
        case .cancelled:
            guard transition(to: .idle, ownedBy: generation) else { return }
            notice = "已取消，未执行"
            finishOperation(generation)
        case .resultUnknown:
            guard transition(to: .resultUnknown, ownedBy: generation) else { return }
            finishOperation(generation)
        }
    }

    private func beginRemoteOperation() -> UInt64? {
        guard phase.acceptsNewOperation else { return nil }
        return beginOperation(transitioningTo: .thinking)
    }

    private func beginConfirmationOperation() -> UInt64? {
        guard case .awaitingConfirmation = phase else { return nil }
        return beginOperation(transitioningTo: .executing)
    }

    private func beginOperation(transitioningTo next: Phase) -> UInt64? {
        operationGeneration &+= 1
        let generation = operationGeneration
        activeGeneration = generation
        guard transition(to: next, ownedBy: generation) else {
            activeGeneration = nil
            return nil
        }
        return generation
    }

    @discardableResult
    private func transition(
        to next: Phase,
        ownedBy generation: UInt64? = nil
    ) -> Bool {
        if let generation, activeGeneration != generation { return false }
        guard phase.allowsTransition(to: next) else { return false }
        phase = next
        return true
    }

    private func receiveResultUnknown(ownedBy generation: UInt64) {
        guard activeGeneration == generation else { return }
        guard transition(to: .resultUnknown, ownedBy: generation) else { return }
        finishOperation(generation)
    }

    private func receiveFailure(_ message: String, ownedBy generation: UInt64) {
        guard activeGeneration == generation else { return }
        guard transition(to: .failed, ownedBy: generation) else { return }
        notice = message
        finishOperation(generation)
    }

    private func finishOperation(_ generation: UInt64) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
    }

    private func invalidateActiveOperation() {
        operationGeneration &+= 1
        activeGeneration = nil
    }

    private func actionPreview(from response: BridgeResponse) -> ActionPreview? {
        guard case let .object(arguments)? = response.payload["arguments"] else {
            return nil
        }
        let recipient = stringValue(arguments["contact"])
            ?? stringValue(arguments["recipient"])
        guard let recipient, let message = stringValue(arguments["message"]) else {
            return nil
        }
        return ActionPreview(
            requestID: response.requestID,
            recipient: recipient,
            message: message
        )
    }

    private func makeRequest(
        kind: RequestKind,
        payload: [String: JSONValue]
    ) throws -> BridgeRequest {
        try BridgeRequest(
            version: 1,
            requestID: UUID().uuidString.lowercased(),
            deviceID: deviceID,
            issuedAt: ISO8601DateFormatter().string(from: Date()),
            idempotencyKey: UUID().uuidString.lowercased(),
            kind: kind,
            payload: payload
        )
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        guard case let .string(text)? = value else { return nil }
        return text
    }

    private static func fixtureName(in arguments: [String]) -> String {
        guard let flagIndex = arguments.firstIndex(of: "-fixture") else { return "offline" }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else { return "offline" }
        return arguments[valueIndex]
    }
}

private actor FixtureBridgeClient: JarvisBridgeClient {
    func submit(_ request: BridgeRequest) async throws -> BridgeResponse {
        try BridgeResponse(
            version: 1,
            requestID: request.requestID,
            state: .completed,
            risk: .low,
            payload: ["summary": .string("测试请求已完成")]
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
            payload: ["summary": .string("测试操作已完成")]
        )
    }

}

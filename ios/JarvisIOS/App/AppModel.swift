import Combine
import Foundation
import JarvisCore
import JarvisProtocol

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

@MainActor
final class AppModel: ObservableObject {
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
    }

    @Published var selectedTab: AppTab = .conversation
    @Published var composerText = ""
    @Published private(set) var phase: Phase
    @Published private(set) var messages: [ConversationMessage]
    @Published private(set) var tasks: [JarvisTaskSummary]
    @Published private(set) var device: DeviceSnapshot
    @Published private(set) var notice: String?
    @Published private(set) var testingClientCallCount = 0

    let isUITesting: Bool

    private let client: (any JarvisBridgeClient)?
    private let deviceID: String

    init(
        client: (any JarvisBridgeClient)? = nil,
        deviceID: String = "unpaired-iphone",
        phase: Phase = .offline,
        messages: [ConversationMessage] = [],
        tasks: [JarvisTaskSummary] = [],
        device: DeviceSnapshot = .offline,
        isUITesting: Bool = false
    ) {
        self.client = client
        self.deviceID = deviceID
        self.phase = phase
        self.messages = messages
        self.tasks = tasks
        self.device = device
        self.isUITesting = isUITesting
    }

    var isConnected: Bool { device.isConnected }

    var pendingAction: ActionPreview? {
        guard case let .awaitingConfirmation(preview) = phase else { return nil }
        return preview
    }

    static func launchConfigured(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        let isUITesting = arguments.contains("-ui-testing")
        guard isUITesting else {
            return AppModel()
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

    func toggleVoice() {
        notice = nil
        switch phase {
        case .listening:
            phase = .transcribing
        case .offline:
            notice = "电脑离线，语音草稿不会自动发送"
        default:
            phase = .listening
        }
    }

    func submitComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let client, isConnected else {
            phase = .offline
            notice = "请求草稿已保留"
            return
        }

        notice = nil
        messages.append(ConversationMessage(author: .user, text: text))
        composerText = ""
        phase = .thinking

        let request: BridgeRequest
        do {
            request = try makeRequest(kind: .chat, payload: ["text": .string(text)])
        } catch {
            phase = .failed
            notice = "无法创建安全请求"
            return
        }

        testingClientCallCount += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.submit(request)
                self.apply(response)
            } catch BridgeError.resultUnknown {
                self.phase = .resultUnknown
            } catch {
                self.phase = .failed
                self.notice = "请求未完成"
            }
        }
    }

    func allow(_ preview: ActionPreview) {
        guard pendingAction == preview else { return }
        guard let client, isConnected else {
            phase = .offline
            return
        }

        phase = .executing
        let confirmation: BridgeRequest
        do {
            confirmation = try makeRequest(
                kind: .confirm,
                payload: ["target_request_id": .string(preview.requestID)]
            )
        } catch {
            phase = .failed
            notice = "无法创建确认请求"
            return
        }

        testingClientCallCount += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.confirm(
                    preview.requestID,
                    confirmation: confirmation
                )
                self.apply(response)
            } catch BridgeError.resultUnknown {
                self.phase = .resultUnknown
            } catch {
                self.phase = .failed
                self.notice = "确认请求未完成"
            }
        }
    }

    func cancelPreview(_ preview: ActionPreview) {
        guard pendingAction == preview else { return }
        phase = .idle
        notice = "已取消，未执行"
    }

    private func apply(_ response: BridgeResponse) {
        switch response.state {
        case .preparing:
            phase = .thinking
        case .awaitingConfirmation:
            guard let preview = actionPreview(from: response) else {
                phase = .failed
                notice = "动作预览不完整，未执行操作"
                return
            }
            phase = .awaitingConfirmation(preview)
        case .executing:
            phase = .executing
        case .completed:
            phase = .completed
            if let summary = stringValue(response.payload["summary"]), !summary.isEmpty {
                messages.append(ConversationMessage(author: .jarvis, text: summary))
            }
        case .failed:
            phase = .failed
            notice = stringValue(response.payload["summary"])
        case .cancelled:
            phase = .idle
            notice = "已取消，未执行"
        case .resultUnknown:
            phase = .resultUnknown
        }
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

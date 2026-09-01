# Jarvis iPhone 局域网控制闭环设计

## 目标

让 iPhone 版 Jarvis 在同一 Wi‑Fi 下稳定连接电脑端 Jarvis，完成语音/文字指令发送、执行状态回传和跨应用操作确认；本阶段不引入外网中继、支付、删除文件或密码输入自动化。

## 架构

- iPhone SwiftUI 客户端复用现有 `VoiceOrb`、`ConversationView`、`ActionPreviewSheet` 和设备页，新增连接状态与配对入口。
- 电脑端提供局域网 HTTP/WebSocket bridge；手机使用 Bonjour/手动 IP 发现，首次连接通过一次性配对码建立设备身份，后续请求使用 Keychain 保存的设备密钥签名。
- 指令生命周期为 `submitted → preview/awaiting_confirmation → running → succeeded/failed`。跨应用操作必须在 iPhone 上显示预览并等待用户确认；付款、删除文件、密码输入保持拒绝策略。
- 连接断开时本地保留未完成请求和明确错误，不自动重试有副作用的执行请求；安全重试仅限查询或状态同步。

## 数据流与接口

1. 用户点按语音胶囊或输入文字。
2. `SpeechSession` 输出可见文本，`AppModel` 创建请求 ID 并提交给 `BridgeClient`。
3. bridge 返回任务预览；客户端按风险策略决定直接执行或展示确认卡片。
4. 用户确认后发送带请求 ID 的确认；客户端订阅任务事件并更新控制台。
5. 每个请求在超时、断线或服务端拒绝时进入可解释的终态，避免重复执行。

## 组件边界

- `BridgeClient`：发现、配对、签名请求、连接恢复和事件解码；不决定 UI。
- `AppModel`：维护连接/任务状态，向视图提供可观察模型；不直接操作系统应用。
- `ActionPreviewSheet`：展示风险、目标应用和参数，提供确认/取消；不绕过策略。
- 电脑端 bridge adapter：将移动协议映射到现有 orchestrator/tool proposal，不改变既有确认规则。

## 测试与验收

- Swift Package 测试覆盖签名、配对、请求去重、断线恢复和终态映射。
- iOS 单元测试覆盖 AppModel 的状态转换及高风险拒绝策略。
- UI 测试覆盖未配对、已连接、跨应用待确认、取消和执行失败五条路径。
- Codemagic unsigned workflow 必须通过 XcodeGen preflight、Swift tests 和 iPhone 16 Simulator tests；本阶段不上传 TestFlight。

## 非目标

外网远程、账号体系、后台常驻录音、支付、删除文件、密码输入和自动 TestFlight 发布不在本阶段范围内。

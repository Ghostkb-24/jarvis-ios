import XCTest

final class ConversationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testConnectedShellShowsConnectionVoiceComposerAndThreeTabs() {
        launch(fixture: "connected")

        XCTAssertTrue(app.staticTexts["connection.status"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["connection.status"].label, "已连接")
        XCTAssertTrue(app.buttons["开始说话"].exists)
        XCTAssertTrue(app.textFields["输入消息"].exists)
        XCTAssertTrue(app.staticTexts["Windows 主机可用"].exists)
        XCTAssertTrue(app.staticTexts["本地模型就绪"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertTrue(app.tabBars.buttons["对话"].exists)
        XCTAssertTrue(app.tabBars.buttons["任务"].exists)
        XCTAssertTrue(app.tabBars.buttons["设备"].exists)
    }

    func testOfflineFixtureKeepsDraftAndExplainsConnectionState() {
        launch(fixture: "offline")

        XCTAssertTrue(app.staticTexts["connection.status"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["connection.status"].label, "电脑离线")
        XCTAssertEqual(app.staticTexts["phase.status"].label, "电脑离线")
        XCTAssertTrue(app.staticTexts["请求草稿会保留，重新连接后可再次发送"].exists)
    }

    func testUnpairedFixtureGuidesUserToPairFirst() {
        launch(fixture: "unpaired")

        XCTAssertTrue(app.staticTexts["connection.status"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["connection.status"].label, "需要配对")
        XCTAssertEqual(app.staticTexts["phase.status"].label, "等待完成配对")
        XCTAssertTrue(app.staticTexts["请先在设备页完成同一 Wi-Fi 配对"].exists)
        XCTAssertTrue(app.buttons["查看配对说明"].exists)
    }

    func testConfirmationShowsRecipientAndFullMessageBeforeAllowing() {
        launch(fixture: "confirmation")

        XCTAssertTrue(
            app.descendants(matching: .any)["confirmation.preview"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["发送微信消息"].exists)
        XCTAssertTrue(app.staticTexts["发送前请你确认"].exists)
        XCTAssertTrue(app.staticTexts["目标应用"].exists)
        XCTAssertTrue(app.staticTexts["微信"].exists)
        XCTAssertTrue(app.staticTexts["收件人：宋小宝"].exists)
        XCTAssertTrue(app.staticTexts["明天上午十点在工作室见，记得带上最终版方案。"].exists)
        XCTAssertTrue(app.buttons["允许并发送"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["取消操作"].exists)
    }

    func testCancellingConfirmationDismissesWithoutSending() {
        launch(fixture: "confirmation")

        let preview = app.descendants(matching: .any)["confirmation.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 2))
        app.buttons["取消操作"].tap()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 2), .completed)
        XCTAssertTrue(app.staticTexts["已取消，未执行"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["测试客户端调用次数：1"].exists)
    }

    func testFailureFixtureShowsBridgeRejectionState() {
        launch(fixture: "failed")

        XCTAssertTrue(app.staticTexts["phase.status"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["phase.status"].label, "操作失败")
        XCTAssertTrue(app.staticTexts["Bridge 拒绝了这次请求"].exists)
    }

    func testSucceededFixtureShowsCompletionState() {
        launch(fixture: "succeeded")

        XCTAssertTrue(app.staticTexts["phase.status"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["phase.status"].label, "已完成")
        XCTAssertTrue(app.staticTexts["测试请求已安全完成"].exists)
    }

    func testBlockedRefusalHidesApprovalControl() {
        launch(fixture: "blocked-payment")

        XCTAssertTrue(
            app.descendants(matching: .any)["confirmation.preview"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["无法执行该操作"].exists)
        XCTAssertTrue(app.staticTexts["涉及付款，Jarvis 不会代你确认或付款。"].exists)
        XCTAssertFalse(app.buttons["允许并发送"].exists)
        XCTAssertTrue(app.buttons["知道了"].exists)
    }

    func testFileDeletionRefusalHidesApprovalControl() {
        launch(fixture: "blocked-file-deletion")

        XCTAssertTrue(
            app.descendants(matching: .any)["confirmation.preview"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["涉及删除文件，Jarvis 不会代你确认或删除。"].exists)
        XCTAssertFalse(app.buttons["允许并发送"].exists)
        XCTAssertTrue(app.buttons["知道了"].exists)
    }

    func testPasswordRefusalHidesApprovalControl() {
        launch(fixture: "blocked-password")

        XCTAssertTrue(
            app.descendants(matching: .any)["confirmation.preview"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["涉及密码输入，Jarvis 不会代你输入或确认。"].exists)
        XCTAssertFalse(app.buttons["允许并发送"].exists)
        XCTAssertTrue(app.buttons["知道了"].exists)
    }

    private func launch(fixture: String) {
        app.launchArguments = ["-ui-testing", "-fixture", fixture]
        app.launch()
    }
}

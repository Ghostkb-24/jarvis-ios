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
        XCTAssertEqual(app.staticTexts["connection.status"].label, "电脑已连接")
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

    func testConfirmationShowsRecipientAndFullMessageBeforeAllowing() {
        launch(fixture: "confirmation")

        XCTAssertTrue(
            app.descendants(matching: .any)["confirmation.preview"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["收件人：宋小宝"].exists)
        XCTAssertTrue(app.staticTexts["明天上午十点在工作室见，记得带上最终版方案。"].exists)
        XCTAssertTrue(app.buttons["允许并发送"].exists)
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
        XCTAssertTrue(app.staticTexts["测试客户端调用次数：0"].exists)
    }

    func testResultUnknownWarnsAgainstDuplicateSend() {
        launch(fixture: "result-unknown")

        XCTAssertTrue(app.staticTexts["phase.status"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["phase.status"].label, "结果待确认")
        XCTAssertTrue(app.staticTexts["不要重复发送，请检查目标应用"].exists)
    }

    private func launch(fixture: String) {
        app.launchArguments = ["-ui-testing", "-fixture", fixture]
        app.launch()
    }
}

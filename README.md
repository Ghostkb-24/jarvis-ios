# Jarvis Desktop Assistant

一个面向 Windows 11 的本地优先桌面助手。默认使用 Ollama 和 `qwen2.5:3b`，可选配置 OpenAI 作为复杂任务回退。模型只能提出结构化白名单工具调用，不能生成并执行任意命令。

## 当前能力

- 左上角透明迷你侧栏、右上角紧凑任务控制台、任务栏上方语音胶囊。
- 系统托盘和 `Ctrl+Alt+Space` 按键录音。
- Ollama 本地优先；低置信度或本地失败时提示是否使用 OpenAI。
- 打开白名单应用、打开网页、搜索/打开允许目录中的文件、剪贴板、音量工具接口。
- 中风险动作必须确认，未知或禁止动作直接拒绝。
- SQLite 设置与脱敏审计日志；OpenAI Key 通过 Windows Credential Manager 保存。

## 开发环境

```powershell
py -3.12 -m pip install -e ".[dev]"
$env:PYTHONPATH = "src"
py -3.12 -m pytest -v
py -3.12 -m ruff check src tests
```

## 启动

1. 安装并启动 Ollama。
2. 确认本地模型存在：`ollama pull qwen2.5:3b`。
3. 安装依赖后运行：

```powershell
py -3.12 -m jarvis_assistant
```

关闭主窗口不会结束助手；请从系统托盘菜单选择“退出”。

## 隐私与权限

- 录音只保存在内存中，默认不写入磁盘。
- 未经用户确认，不会把请求切换到 OpenAI。
- 文件正文、屏幕截图、剪贴板内容、凭据和原始私人路径默认不发送到云端。
- 不支持任意 PowerShell、Shell 或 Python 执行。
- 当前版本禁止删除文件、发送消息、安装软件、输入密码和付款。
- 音量工具通过 Windows Core Audio 调整系统主音量，并在执行前后限制到 `0`–`100` 的安全范围。

## OpenAI Key

程序不会从配置文件或 SQLite 读取明文 Key。后续可在设置窗口中保存 Key，实际值写入 Windows Credential Manager。没有 Key 时，助手只使用 Ollama。

## 冒烟测试契约

`scripts/smoke_test.ps1` 必须满足以下条件：

- 运行前保存剪贴板与系统音量，结束时在 `finally` 中恢复。
- 只在系统临时目录下创建唯一测试目录，并在验证解析路径仍位于临时目录后删除。
- 只允许打开记事本和 `https://example.com`，不启动其他应用或网页。
- 文件工具只能访问本次创建的临时测试目录。
- 每项检查输出一行 `PASS` 或 `FAIL`。
- 全部成功时最后输出 `SMOKE TEST PASSED`；任何失败都以非零代码退出。

默认自动化测试不会打开真实应用、浏览器或修改真实音量。执行冒烟脚本代表允许上述有限、可恢复的本机操作。

## 打包

```powershell
py -3.12 -m PyInstaller --clean jarvis-assistant.spec
```

输出位于 `dist/JarvisDesktopAssistant/JarvisDesktopAssistant.exe`。Ollama 模型和 OpenAI 凭据不会打包进程序。

## 常见问题

- **Ollama 不可用**：确认 Ollama 正在运行，并访问 `http://127.0.0.1:11434`。
- **快捷键无响应**：确认已安装 `pynput`，并检查是否与其他软件的快捷键冲突。
- **麦克风无法启动**：在 Windows 隐私设置中允许桌面应用访问麦克风。
- **首次语音识别较慢**：faster-whisper 首次使用需要准备本地模型。

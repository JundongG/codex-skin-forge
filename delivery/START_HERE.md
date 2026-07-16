# 客户专属 Codex 皮肤安装入口

这是为本客户单独制作的第三方 Windows Codex 视觉皮肤。包内主视觉、文案和签名已经固化，并在 `ASSET_DECLARATION.md` 与 `package-manifest.json` 中记录哈希。

## 最省事的安装方法

1. 把 ZIP 完整解压到“下载”或“桌面”等普通用户目录，不要在 ZIP 预览窗口里运行。
2. 在客户自己的 Codex 中打开解压后的文件夹。
3. 把 `INSTALL_PROMPT.txt` 的内容发给 Codex。
4. Codex 完成预检和安装后会显示 `HANDOFF_STARTED`；此时按提示完全关闭 Codex。
5. 隐藏助手只会等待，不会强制结束 Codex。退出完成后，它会以本机随机回环端口启动官方 Codex，并加载客户专属视觉。
6. 重新打开后，把 `VERIFY_PROMPT.txt` 发给 Codex完成截图和界面验收。

## 安装会做什么

- 校验包内全部 SHA-256、客户主题和主视觉哈希。
- 检查 Microsoft Store Codex 是否存在。
- 从本机 Codex 安装目录复制其自带的 Node.js 到当前用户的 `%LOCALAPPDATA%\CodexNoirGold`，并验证 OpenJS 签名和版本。
- 安装客户主题与本地视觉引擎，创建“专属皮肤”和“恢复原版”快捷方式。
- 启动官方 Codex 时将调试接口限定到 `127.0.0.1` 的随机端口，只向 `app://` 页面注入视觉层。

安装不联网下载依赖，不修改 Codex 的 WindowsApps 文件、签名、账号或聊天数据。

## 手动命令

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\preflight.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\start-assisted-install.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -ScreenshotPath .\acceptance.png
powershell -ExecutionPolicy Bypass -File .\scripts\diagnostics.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

“恢复原版”会移除当前会话的视觉注入并重新打开正常 Codex。调试端口会在该皮肤 Codex 窗口关闭后完全消失。

## 安全边界

- 不读取聊天记录、项目内容、账号、API Key 或认证文件。
- 不使用网络、MCP、外部模型或远程安装管道。
- 装饰层不能接收鼠标事件，不会覆盖正常操作。
- 不要把本服务描述为 OpenAI 官方主题或官方合作服务。

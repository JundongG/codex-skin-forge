# 远程安装 SOP

## 交付前

1. 收集客户图片、品牌元素、文案、签名和期望风格。
2. 如果只有想法，先生成或设计主视觉；如果有照片，完成扩图、构图、调色和装饰。
3. 输出 PNG/JPEG，最低 1200×600，建议 1600×760；主体优先放右侧，左侧保留文字安全区。
4. 发预览图给客户确认，并确认肖像、品牌和生成素材的使用权。
5. 用 `create-client-package.ps1 -ConfirmAssetRights` 生成客户 ZIP。
6. 运行 `test-release.ps1` 验证最终 ZIP，保存 `.sha256`。

## 远程发送

把 ZIP 和 `.zip.sha256` 通过约定渠道一起发给客户，最好再通过另一个可信渠道发送哈希文本。客户解压前先运行：

```powershell
$expected = ((Get-Content .\Codex-Skin-Forge-*.zip.sha256 -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash .\Codex-Skin-Forge-*.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'ZIP SHA-256 不匹配，停止安装。' }
```

让客户完整解压，然后在自己的 Codex 中打开解压目录。不要让客户提供账号、聊天记录、项目文件或密钥。

## 客户 Codex 安装

客户把包内 `INSTALL_PROMPT.txt` 发给 Codex。Codex依次：

1. 阅读说明、素材声明、清单和脚本。
2. 运行 `scripts/preflight.ps1`，汇报主题、哈希、Codex 版本和安全边界。
3. 运行 `scripts/start-assisted-install.ps1`。
4. 看到 `HANDOFF_STARTED` 后提示客户完全关闭 Codex，不主动结束进程。
5. 隐藏助手等待退出，启动带随机回环 CDP 的官方 Codex并注入客户主题。

如果等待超时、签名错误或验证失败，停止安装并读取 `%LOCALAPPDATA%\CodexNoirGold\latest-result.json`。不要改用联网脚本或手工修改 Codex 文件。

## 验收

重新打开后，让客户把 `VERIFY_PROMPT.txt` 发给 Codex。保存本地验收截图，检查客户视觉、首页、任务页、设置、代码块、diff、按钮点击和缩放。

## 恢复与卸载

- 临时恢复：双击桌面的“恢复原版”快捷方式，或运行已安装的 `engine\restore.ps1 -RestartNormal`。
- 卸载：运行客户包的 `scripts\uninstall.ps1`，或已安装目录 `%LOCALAPPDATA%\CodexNoirGold\uninstall.ps1`。默认删除可能包含客户图片的旧备份；只有确需保留时使用 `-KeepBackups`。
- 卸载只删除本产品文件和快捷方式，不删除 Codex、聊天、项目或账号数据。

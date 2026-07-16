# Codex Skin Forge

[![CI](https://github.com/JundongG/codex-skin-forge/actions/workflows/ci.yml/badge.svg)](https://github.com/JundongG/codex-skin-forge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-C89B5B.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D4.svg)](docs/TEST-MATRIX.md)

一个用于设计、打包、安装、验证和恢复 Windows Codex 桌面端客户专属视觉皮肤的非官方开源工具箱。

> Unofficial Windows toolkit for customer-specific Codex desktop skins. It packages local visual assets, installs without modifying Codex application files, verifies the result, and provides a rollback path.

项目借鉴了 [Fei-Away/Codex-Dream-Skin](https://github.com/Fei-Away/Codex-Dream-Skin) 的本机 CDP 注入思路，但 Windows 引擎、安装器和黑金视觉层均为独立实现，不分发该仓库代码，也不再依赖 Codex++。

仓库内的 `Noir Gold / 曜金黑` 是首个参考主题；项目本身并不限定风格。每位客户可以使用自己的主视觉、品牌文案和签名生成独立 ZIP，再由客户电脑上的 Codex 完成预检和本地安装。

## 现在具备的能力

- 客户主视觉为必填项，只接受 PNG/JPEG，最低 1200×600，建议 1600×760。
- 客户只给想法时，先生成或设计成正式主图，再进入打包流程。
- 模板占位符、缺图、低分辨率、素材授权未确认时，构建直接失败。
- 客户 ZIP 不下载依赖，不修改 WindowsApps、`app.asar` 或 Codex 签名文件。
- 安装时从客户自己的 Codex 中复制 OpenJS 签名的 Node.js，校验签名和版本后使用。
- 官方 Codex 只以 `127.0.0.1` 随机端口开启本地 CDP；注入目标限定为 `app://` 页面。
- 装饰层强制 `pointer-events: none`，不遮挡输入、按钮或窗口操作。
- 安装交接不会强制结束正在运行的 Codex；客户手动关闭后，隐藏助手再启动皮肤会话。
- 支持会话验证、截图验收、诊断、恢复原版和卸载。

## 从客户需求到交付包

先准备客户视觉成品。推荐把人物或核心主体放在画面右侧，左侧留出标题安全区；客户照片需要完成裁切、扩图、调色和装饰，只有想法时则先生成/设计并让客户确认。

生成客户包：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\create-client-package.ps1 `
  -ClientId "client-name" `
  -ClientName "客户名称" `
  -HeroImage "C:\path\to\customer-hero.png" `
  -Tagline "客户专属文案" `
  -Signature "客户签名" `
  -ConfirmAssetRights
```

输出位于 `release/`：

```text
Codex-Skin-Forge-Noir-Gold-client-name-0.3.1.zip
Codex-Skin-Forge-Noir-Gold-client-name-0.3.1.zip.sha256
```

完整自动化检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\build-and-verify.ps1
```

## 客户安装体验

客户解压 ZIP，在自己的 Codex 中打开文件夹，把 `INSTALL_PROMPT.txt` 发给 Codex。Codex 运行预检和安装脚本；看到 `HANDOFF_STARTED` 后提示客户完全关闭 Codex。隐藏助手等待退出，随后用客户自己的官方 Codex 启动专属皮肤。

接单时先使用[客户需求表](docs/CLIENT-BRIEF-TEMPLATE.md)；视觉制作见[客户主视觉流程](docs/CLIENT-VISUAL-WORKFLOW.md)。安装与技术细节见[远程安装 SOP](docs/remote-install-sop.md)、[高级版架构](docs/ADVANCED-ARCHITECTURE.md)和[测试矩阵](docs/TEST-MATRIX.md)。

## 目录

- `advanced/noir-gold`：客户主题模板、黑金 CSS 和渲染注入模板。
- `engine`：独立 CDP 引擎、启动、验证、恢复和诊断。
- `delivery`：进入客户 ZIP 的说明、提示词和安装脚本。
- `scripts`：客户包生成、源码检查和 ZIP 验证。
- `tests`：端到端构建验证，不会安装或启动 Codex。
- `themes`：官方主题分享字符串的早期低风险参考，不参与高级版客户包。

## 边界

- 本项目是第三方本地界面美化，不是 OpenAI 官方主题或合作服务。
- Codex、OpenAI 及其相关标志属于各自权利人；本项目不使用 OpenAI 官方 Logo 作为自身品牌。
- 当前只面向 Windows 10/11 的 Microsoft Store Codex。
- Codex 更新可能改变 DOM，正式交付前必须在目标版本完成视觉回归。
- 客户图片、肖像、品牌和生成素材的使用权由交付前的素材确认流程保证。
- 皮肤不读取聊天记录、账号、项目文件、API Key 或认证信息。

## 开源参与

- 提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要公开提交漏洞细节。
- 代码采用 [MIT License](LICENSE)；客户图片和其他视觉素材遵循 [ASSET_POLICY.md](ASSET_POLICY.md)，不自动包含在 MIT 授权内。
- 架构来源和商标说明见 [NOTICE.md](NOTICE.md)。

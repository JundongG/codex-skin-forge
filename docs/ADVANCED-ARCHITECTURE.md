# 高级版架构

## 目标

交付物不是一套固定人物背景，而是一台“客户皮肤生产线”：客户提供照片时完成扩图、裁切、调色和排版；客户只提供想法时先生成或设计主视觉；确认后，再将图片、客户名、文案和签名固化为独立 ZIP。

## 运行链路

```text
客户需求/图片
  -> 设计并确认 1600x760 主视觉
  -> create-client-package.ps1
  -> 客户专属 ZIP + SHA-256
  -> 客户 Codex 执行预检/安装
  -> 客户手动关闭 Codex
  -> 隐藏助手启动官方 Codex（127.0.0.1 随机 CDP 端口）
  -> 独立 Node 引擎只连接 app:// 页面
  -> 注入客户 CSS、文案和图片
  -> 本地截图与布局验收
```

## 为什么采用本机 CDP

[Codex-Dream-Skin](https://github.com/Fei-Away/Codex-Dream-Skin) 的 Windows 实现证明了外部 CDP 注入可以在不修改应用包的前提下实现深度视觉定制。当前项目只借鉴这一架构方向，重新实现引擎、客户打包和安全交接，并补齐原仓库未提供的客户自动打包链路。

与修改 `app.asar` 或制作 Codex 托管副本相比，本方案：

- 不碰 WindowsApps 内容和应用签名；
- 恢复时只移除当前渲染注入；
- 客户继续使用自己的官方 Codex、账号和更新渠道；
- ZIP 不需要携带 Codex、Node 或第三方运行时源码。

## 安全模型

- CDP 地址显式绑定 `127.0.0.1`，端口每次随机选择。
- 目标列表只接受 URL 以 `app://` 开头的页面，并再次校验 WebSocket 必须是同一随机端口上的 `ws://127.0.0.1`。
- 客户包不执行网络下载。
- Node 从客户自己的 Codex 中复制，要求 Authenticode 有效、签名者包含 OpenJS Foundation、主版本不低于 22。
- 记录的注入器 PID 只有在可执行路径、注入器脚本、`--watch` 和会话 ID 同时匹配时才允许停止。
- 安装、启动、恢复和卸载通过当前用户命名互斥锁串行化，重复点击不会产生并发修改或多个等待助手。
- 升级会事务性备份引擎、主题、复制运行时、卸载器和安装记录；任何提交前失败都会恢复旧版本。
- 包内校验要求文件集合与 `SHA256SUMS.txt` 完全一致，拒绝额外文件、重复路径、重解析点和弱化后的安全声明。
- 启动交接只等待客户手动关闭 Codex；普通启动路径不调用强制结束。
- 视觉装饰 DOM 设置 `aria-hidden` 与 `pointer-events: none`。
- 诊断只报告版本、PID、端口、主题 ID 和布局状态，不读取界面文本或会话内容。

## 客户包结构

```text
START_HERE.md
INSTALL_PROMPT.txt
VERIFY_PROMPT.txt
ASSET_DECLARATION.md
LICENSE
NOTICE.md
ASSET_POLICY.md
package-manifest.json
SHA256SUMS.txt
client/
  theme.json
  noir-gold.css
  renderer-inject.js
  assets/customer-hero.png
engine/
  injector.mjs
  common.ps1
  start.ps1
  start-worker.ps1
  verify.ps1
  restore.ps1
  diagnostics.ps1
scripts/
  preflight.ps1
  install.ps1
  start-assisted-install.ps1
  verify.ps1
  diagnostics.ps1
  uninstall.ps1
```

客户包中不允许出现模板占位图片、`CLIENT_*` 标记、Codex 程序、Node 二进制或第三方仓库副本。

## 安装位置与恢复

当前用户安装位置：`%LOCALAPPDATA%\CodexNoirGold`。

- `engine`：本地 CDP 引擎。
- `theme`：该客户专属主题与图片。
- `runtime`：从本机 Codex 复制并验证的 Node。
- `backups`：升级前本产品自身的旧版本，不包含 Codex 文件。
- `install.json`：安装审计记录和快捷方式路径。

“恢复原版”先停止经过命令行复核的注入器并移除 CSS/DOM。恢复时优先只关闭本次会话记录的 Codex 主进程；只有用户明确使用 `-ForceClose` 才会强制结束 Codex 包进程。由于 Chromium 的调试开关属于启动参数，关闭该次 Codex 窗口后端口才会完全结束；重新从官方快捷方式启动就是原版会话。

卸载默认删除 `backups`，避免旧客户图片残留；`-KeepBackups` 是需要显式选择的例外。

## 兼容性边界

CSS 依赖当前 Codex 的若干语义选择器，例如侧边栏、主画布、输入框和首页建议卡。Codex 更新后若这些选择器改变，皮肤会降级为部分样式而不应阻断正常操作。每个目标版本仍需完成首页、任务页、设置、代码、diff、缩放和恢复测试。

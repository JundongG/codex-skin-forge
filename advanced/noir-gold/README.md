# Noir Gold / 曜金黑高级版 0.3.1

CDP 注入型 Codex 桌面皮肤。它不修改 `WindowsApps`、`app.asar` 或官方签名；所有装饰层均为 `pointer-events: none`，原生侧栏、建议卡、项目选择和输入框保持可交互。

## 文件

- `theme.template.json`：客户品牌文案、版本和主视觉资源模板。
- `assets/PLACE_CUSTOMER_HERO_HERE.txt`：明确要求交付前放入客户专属图片。
- `noir-gold.css`：视觉层。
- `renderer-inject.js`：幂等 DOM 集成与完整清理。

通用开发占位图不会进入客户交付包。客户提供照片时先做横向延展、裁切、文字安全区和装饰设计；客户只给想法时先生成专属主视觉。打包脚本在没有客户图片时必须失败。

图库或宣传图中的人物、明星、IP 形象不随本项目交付。商业客户素材必须单独确认肖像权、商标与字体授权。

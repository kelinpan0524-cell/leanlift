# AGENTS.md — 薄肌训练计时器

开源的 Flutter Android App：防分心的力量训练计时器与记录工具，围绕"薄肌计划"设计。
（原始 PRD 为本地个人文档，不随仓库发布；仓库内文档即现状权威描述。）

## 形态约束（不要违背）

- **无服务器**：全部功能手机本地运行，SQLite 本地存储、本地计算。
- **联网只有三件事**：飞书日历读写（手机直连飞书开放接口）、AI 功能（计划拆解、AI 教练对话与分析；用户自配 OpenAI 兼容 API）、应用自更新检查（GitHub Releases：公开仓库免令牌；私有部署可配只读令牌。域名白名单仅 github.com / *.githubusercontent.com）。
- **局域网只读桥**（2026-10-17 起，`lib/services/local_bridge.dart` + `tools/mcp-bridge/`）：手机在**自家 Wi-Fi 内**开只读 HTTP 服务，电脑上的 AI 经 MCP 代理读训练数据。它不访问互联网、不经任何云端，故不增加上面三件事；边界是**只读、不常驻（每次手动开 + 空闲 10 分钟自动关）、配对码换令牌、数据不出局域网**。改它时守住这四条。
- 本期只出 Android APK；不写 iOS 特定代码路径（Flutter 跨端天然保留）。**iOS 由社区按根目录 `AI-BUILD-GUIDE.md` 自行适配**，该手册是写给用户手里的 AI 编程助手的操作指南（含编译/fork/iOS 适配/用户须知），改代码时如影响其准确性需同步更新。
- lark-cli 只在开发期使用（配置飞书应用、验证），不进入 App 运行链路。

## 发布与应用内更新（2026-09 起）

- **合并到 main = 自动出包**：`.github/workflows/ci.yml` 检查通过后构建签名 APK（构建号 = CI run number，即 versionCode）并发布 Release，tag 形如 `b17`。**不要重跑已发过 Release 的 workflow run**（tag 冲突会失败，需先删 Release）。
- **签名**：CI 用 GitHub 机密里的签名（KEYSTORE_BASE64 等 4 个，与本地调试签名同源），CI 包与本地包可互相覆盖安装。**丢失该机密 = 以后所有装机都要卸载重装（丢训练数据）**，换 keystore 前必须想清楚。
- **App 内更新**：启动静默检查（失败无声，仅设置入口红点，禁止弹窗打断训练）；设置页「应用更新」卡片手动检查/下载/安装；Android 8+ 首次需授权"安装未知应用"。
- **release job 只在 push main 时跑**；PR 只跑 analyze/test。App 端更新判断依据 tag 里的构建号，本地手工出包时 pubspec 的 `+N` 不代表 CI 构建号。

## 常用命令

```bash
flutter pub get                          # 装依赖
flutter analyze                          # 静态检查（交付前必须 0 error）
flutter test                             # 单元测试（渐进超负荷引擎、计时逻辑必须有覆盖）
flutter build apk --release              # 出包 build/app/outputs/flutter-apk/
flutter run                              # 真机/模拟器调试
```

## 目录结构

- `lib/models/` 数据模型（freezed 风格手写，不引入代码生成，减少构建链脆弱性）
- `lib/db/` SQLite（sqflite）：schema、DAO、migration
- `lib/engine/` 纯 Dart 业务引擎：渐进超负荷判定、今日训练生成、1RM 估算、休息时长规则
- `lib/services/` 外部服务：AI 客户端、飞书日历客户端、专注模式、通知
- `lib/ui/` 页面（今日/训练中/计划/历史/数据/设置）与通用组件
- `lib/l10n/` 文案常量（中文为主）
- `test/` 单元测试

## 红线

- 秘密永不进仓库：API key、飞书 app_secret/refresh_token、keystore。设置值只存手机本地。
- 真实训练数据不入库（本仓库）。
- 一任务一分支，PR 合并，commit message 加 `[ZCode]` 前缀。
- 训练中 UI 禁止弹窗打断；交互三要素（当前动作/本组目标/倒计时）以外的信息一律收起。

## 设计基线（冻结后不得随意改）

- 深色主题、高对比；训练中计时数字为屏幕最大元素
- 核心操作全部在拇指可达区（屏幕下半 1/3），完成组按钮高度 ≥ 88dp
- 重量微调：+/- 预设步长按钮（0.5/1.25/2.5/5kg）为主；点重量数字或休息页「直接输入重量」弹数字键盘直输（2026-09-24 Arono 放开原「不弹键盘」限制：仅用户主动点按唤起、随时可取消，不算打断）
- 完成一组：震动 + 视觉确认，无需读屏
- 适配折叠屏：大屏展开态用双栏（训练信息左、操作右），断点 600dp/840dp

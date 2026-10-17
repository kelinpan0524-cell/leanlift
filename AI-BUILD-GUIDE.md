# AI-BUILD-GUIDE — 交给 AI 的操作手册

> **这份文档是写给 AI 编程助手看的**（ZCode / Claude Code / Cursor / Copilot 等均可）。
> 如果你是人类用户：把整个仓库（或它的 fork）连同这份文档一起交给你的 AI 助手，
> 告诉它「按 AI-BUILD-GUIDE.md 帮我完成任务 X」，X 见下面四个任务。
> AI 助手：接到包含本文件的仓库后，先完整读完本文件再动手，严格遵守「红线」一节。

---

## 0. 项目是什么（AI 必读背景）

**薄肌训练计时器**：个人开源的 Flutter Android App，防分心的力量训练计时与记录工具。
无服务器、无账号、无广告；训练数据 100% 存手机本地 SQLite。

技术栈：Flutter 3.35+ / Dart / sqflite / flutter_local_notifications / MethodChannel 原生 Kotlin。

### 架构速览

```
lib/
  models/      数据模型（手写 freezed 风格，无代码生成）
  db/          SQLite schema、DAO、migration（sqflite）
  engine/      纯 Dart 业务引擎：渐进超负荷判定、今日训练生成、1RM 估算（全平台通用，无平台分支）
  services/    外部服务：AI 客户端、飞书日历、专注模式、通知、应用内更新
  ui/          页面（今日/训练中/计划/历史/数据/设置）
  l10n/        中文文案常量
android/       Android 原生：MainActivity.kt（308 行，原生通道实现）
```

### 红线（AI 在任何任务中都必须遵守）

1. **不引入服务器**：全部功能本地运行；联网只允许三件事——飞书日历官方接口、用户自配的 AI API、GitHub Releases 更新检查。不许加统计 SDK、崩溃上报、云端账号。
2. **秘密永不进仓库**：API key、令牌、签名文件。用户凭据只存手机本地（本项目现状即如此，不要破坏）。
3. **真实训练数据永不进仓库**（贡献者提交前自查）。
4. **训练中 UI 禁止弹窗打断**；交互只保留三要素：当前动作、本组目标、倒计时。
5. 交付标准：`flutter analyze` 0 问题、`flutter test` 全过。

---

## 任务 A：直接安装官方 Release（最简单，优先推荐给普通用户）

适用：用户只是想用 Android 版，不想碰代码。

1. 打开 https://github.com/kelinpan0524-cell/leanlift/releases
2. 下载最新 tag（形如 `b17`）下的 `app-release.apk`
3. 手机上直接安装。Android 8+ 会提示「未知来源应用」，按引导允许即可
4. 装好即用：内置薄肌计划，不注册不登录

**必须告知用户**（原话转达）：
- 训练数据只存在这台手机里，**卸载 App = 数据全丢**，没有云端备份。请定期用
  「数据页 → 导出」生成 CSV/JSON 备份
- 这是个人开源项目，训练建议是通用经验不是医疗建议，身体不适请就医

---

## 任务 B：自己编译 Android 版

适用：想改代码、或不想下官方包的人。

### 环境要求

- Flutter 3.35+（`flutter --version` 确认）
- JDK 17、Android SDK 35
- 一台 Android 8.0+ 真机（开 USB 调试）或模拟器
- **路径避免中文和空格**（部分工具链在中文路径下会异常）

### 步骤

```bash
git clone https://github.com/kelinpan0524-cell/leanlift.git
cd leanlift
flutter pub get
flutter analyze          # 必须输出 "No issues found!"
flutter test             # 必须全过
flutter run              # 真机/模拟器调试，验收核心流程
flutter build apk --release
# 产物: build/app/outputs/flutter-apk/app-release.apk
```

### 验收清单

- [ ] 「今日」页能开始训练
- [ ] 完成一组有震动 + 视觉确认
- [ ] 组间倒计时锁屏后照常走，到点有通知
- [ ] 首次会依次申请：通知权限、勿扰权限、精确闹钟、忽略电池优化——全部是训练功能所需，逐项允许
- [ ] 设置 → 训练 → 心率设备：扫描/连接手环需要「附近的设备」权限（Android 12+）或定位权限（11 及以下，仅用于扫描），首次使用时才申请

### 调试签名说明

本地 `flutter build apk` 用的是 Android 默认调试签名，与官方 Release 签名**不同**。
签名不同的包不能覆盖安装：从官方包换到自编译包（或反过来）要先卸载再装，
**卸载会清掉训练数据，先导出备份**。自编译自用则无所谓，每次都互相覆盖。

---

## 任务 C：Fork 后自己维护一份

适用：想改出自己的版本、或不想依赖原仓库的人。

```bash
# 在 GitHub 网页上点 Fork（默认公开，够用；fork 成私有仓则见任务 A 之外的令牌说明）
git clone https://github.com/<你的用户名>/leanlift.git
cd leanlift
```

### 要改的两个地方

1. **更新源指向自己的仓库**：`lib/services/update_service.dart` 里的
   `static const _repo = 'kelinpan0524-cell/leanlift'` 改成你的 `<用户名>/<仓库名>`。
   公开 fork 免令牌；私有 fork 需在 App 设置页贴一个只读令牌（详见
   [docs/update-setup.md](docs/update-setup.md) 文末）。
2. **CI 签名（可选）**：`.github/workflows/ci.yml` 的 release 依赖原仓库的
   GitHub 机密（签名四件套）。fork 后没有这些机密，出包 job 会失败——两种选择：
   - 只本地编译（删掉 workflow 里的 release job，或无视其失败）
   - 生成自己的签名密钥配到 fork 的 Secrets 里（keystore/base64 等 4 个）
   **注意**：签名一旦更换就不能覆盖安装旧包，换签名前先导出训练数据。

### 改包名（可选）

仅当你需要与官方版**共存安装**在同一台手机时才改：
`android/app/build.gradle` 的 `applicationId`（现为 `com.arono.baoji_timer`）。
两份数据各自独立，互不相通。

### 提 PR 回官方仓库（可选）

欢迎贡献，但注意红线：不带秘密、不带真实训练数据、`flutter analyze` 0 问题 +
`flutter test` 全过后再提交。更新 PR 请带对应单元测试。

---

## 任务 D：自行适配 iOS（本仓库只出 Android，iOS 靠这份指南 DIY）

适用：有 Mac 的用户，想在自己的 iPhone 上跑。
**成本认知（先告知用户）**：免费 Apple ID 签名 7 天过期，每过 7 天要连 Mac 重装一次
（数据不丢）；付费开发者账号（688 元/年）签名 365 天。
两种都是 Xcode 直装到自己的手机，不上架 App Store。

### D1. 生成 iOS 工程

```bash
cd leanlift
flutter create --platforms=ios .
flutter pub get
```

### D2. Xcode 签名配置

1. 用 Xcode 打开 `ios/Runner.xcworkspace`
2. 选中 Runner target → Signing & Capabilities：
   - Team 选自己的 Apple ID（Xcode → Settings → Accounts 先登录）
   - Bundle Identifier 改成独一无二的（如 `com.你的名字.baojitimer`，
     默认的 `com.example.baojiTimer` 无法用于真机签名）
3. iPhone 数据线连 Mac，信任设备后，`flutter run` 选该设备

### D3. 代码适配点（核心工作量，按文件给方案）

Flutter 层 90% 代码（UI / db / engine / AI / 飞书 / 导出）是跨端的，直接能用。
需要处理的是三个 Android 专属服务的 iOS 分支：

#### (1) `lib/services/update_service.dart` — 应用内更新，iOS 必须禁用

- 原理：iOS 沙盒禁止 App 自己下载安装新版本，原生通道 `baoji/updater`
  （installApk 等 3 个方法）只有 Android 实现。
- 做法：所有对 `UpdateService` 的调用和「应用更新」设置入口，用
  `Platform.isAndroid` 包起来；iOS 分支隐藏入口。`silentCheck()` 在 iOS 上
  直接 return，否则启动时会因通道缺失报错（虽然被静默捕获，但仍应短路）。
- fork 用户：iOS 版本更新 = 重新 `flutter run` 覆盖安装（数据保留）。

#### (2) `lib/services/focus_service.dart` — 专注模式，iOS 功能降级

Android 原生通道 `baoji/focus` 提供：勿扰开关（dnd*）、分心应用检测
（usage* / recentUsage）、精确闹钟（canExactAlarm）、电池优化
（ignoringBattery / requestIgnoreBattery）、震动（vibrate）、启动器应用列表
（launcherApps*）。iOS 的等价与缺失：

| Android 功能 | iOS 可行性 | 方案 |
|---|---|---|
| 训练中开勿扰 | ❌ 无公开 API | 删掉该入口；靠用户手动开系统专注模式 |
| 切去别的 App 被提醒拉回 | ❌ 无使用统计 API | 删掉检测，改为回前台时提示 |
| 忽略电池优化 | ❌ 无此概念 | 删掉入口 |
| 精确闹钟 | ✅ 本地通知即可 | flutter_local_notifications 的 iOS 通知即系统级触发 |
| 震动 | ✅ | `HapticFeedback`（flutter/services 自带）或补一个 iOS 通道 |
| 应用列表（选分心应用） | ❌ | 相关 UI 一并隐藏 |

做法：`focus_service.dart` 内所有 MethodChannel 调用加平台判断，iOS 返回
「不支持」的默认值；设置页相关卡片按平台隐藏。**宁可功能少，不要留死按钮。**

#### (3) `lib/services/notify_service.dart` — 通知，小改即用

现在只有 `AndroidInitializationSettings` / `AndroidNotificationDetails` 分支。
补 iOS 侧：

```dart
// 初始化补：
DarwinInitializationSettings(...)   // 组进 InitializationSettings 的 iOS 参数
// 通知详情补：
DarwinNotificationDetails(...)      // 组进 NotificationDetails 的 iOS 参数
```

iOS 首次启动会弹通知授权，属正常流程。`AndroidScheduleMode.exactAllowWhileIdle`
是 Android 参数，iOS 走默认即可（插件已处理）。

#### (4) 屏幕常亮 ✅ 无需改

`wakelock_plus` 跨端，开箱即用。

#### (5) `lib/services/heart_rate_service.dart` — BLE 心率，iOS 补两个小改动

原理：走标准蓝牙心率 profile（0x180D/0x2A37，免配对），`flutter_blue_plus`
跨端。服务里 `_ensureReady()` 与 `connectSaved()` 有 `Platform.isAndroid`
闸——iOS 上心率设备页会提示"暂不支持"，不会崩。

iOS 适配做法：

1. `ios/Runner/Info.plist` 加 `NSBluetoothAlwaysUsageDescription`
   （文案说明用途，如"连接你的心率手环以记录训练心率"），否则一点扫描就闪退；
2. 去掉上述两处平台闸。其余（扫描/订阅通知/解析/落库）Flutter 层跨端直接能用。

#### (6) `lib/services/local_bridge.dart` — 局域网只读桥，iOS 需声明本地网络用途

原理：手机在自家 Wi-Fi 内开一个只读 HTTP 服务，电脑上的 AI 通过
`tools/mcp-bridge/`（Node，无依赖）经 MCP 读训练数据。默认关闭，用户在
设置 → 连接与智能 → 局域网连接 里手动开启。**面向用户的逐步教程在
`docs/MCP_GUIDE.md`（中英双语）**，改这个功能时记得一并更新。

iOS 适配做法：

1. `ios/Runner/Info.plist` 加 `NSLocalNetworkUsageDescription`
   （文案说明用途，如"让你电脑上的 AI 助手在同一 Wi-Fi 下读取训练记录"）。
   iOS 14+ 首次开启本功能会弹「本地网络」授权；**不授权则电脑连不上手机**，
   这不是 bug，去 设置 → 隐私与安全性 → 本地网络 里打开即可；
2. 其余（监听、配对码换令牌、空闲自动关）Flutter 层跨端免改。

Android 侧无需额外权限（`INTERNET` 已声明）。**但要注意**：Android 17
（API 37）起局域网访问改为运行时权限（`ACCESS_LOCAL_NETWORK`），届时若把
`targetSdk` 提到 37，需要补声明与申请，否则该功能在 Android 上会被系统拦下。

### D4. 验收清单（iOS）

- [ ] 编译通过，真机安装成功
- [ ] 「今日」页能开始训练，完成一组有震动/触感反馈
- [ ] 组间倒计时：切后台/锁屏后到点，本地通知正常弹出
- [ ] 设置页不再出现「应用更新」和 Android 专属的权限引导
- [ ] 飞书日历、AI 计划拆解（自配 Key）正常——这两个是纯 HTTP，跨端免改
- [ ] 局域网连接（可选）：开启后手机显示地址 + 6 位配对码，电脑上
      `node tools/mcp-bridge/baoji-mcp.mjs pair --host <手机IP> --port <端口> --code <码>`
      能配对成功，配合 `serve` 接进 AI 客户端后能读到训练数据

### D5. 已知限制（必须告知 iOS 用户）

- **免费 Apple ID：签名 7 天过期**。到期 App 打不开（数据还在），连 Mac 重新
  `flutter run` 一次即恢复。嫌麻烦要么买开发者账号（688 元/年），要么放弃
- **训练数据迁移不了**：Android 上的记录在 Android 本地。可在 Android 版导出
  JSON/CSV，将来若做了导入功能再迁；目前 iOS 是全新开始
- **iOS 没有「防分心」的硬约束**（不能自动勿扰、不能检测你切去了哪个 App），
  防分心靠自觉 + 训练中界面本身极简
- **不要上架 App Store**除非你愿意：走正式审核、砍应用内更新、处理中国区 ICP
  备案等，个人自用不值得

---

## 附：每次交付前的通用检查（AI 执行）

```bash
flutter analyze   # No issues found!
flutter test      # All tests passed!
```

改了 Dart 代码必须重跑；只改文档/原生配置时说明跳过原因。
向上游提 PR 前：`git ls-files | grep -iE "xls|jks|keystore"` 应无输出。

<div align="center">

<img src="docs/assets/icon.png" width="110" alt="LeanLift 薄肌训练计时器" />

# 薄肌训练计时器 · LeanLift

**完全跑在你手机上的力量训练计时与记录**

无服务器 · 数据不出本机 · 中英双语 · 极简防分心

**简体中文** | [English](README_EN.md)

[![Release](https://img.shields.io/github/v/release/kelinpan0524-cell/leanlift?color=4ADE80)](https://github.com/kelinpan0524-cell/leanlift/releases)
[![Platform](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)](https://github.com/kelinpan0524-cell/leanlift/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.35%2B-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![数据-100%本地](https://img.shields.io/badge/%E6%95%B0%E6%8D%AE-100%25%E6%9C%AC%E5%9C%B0-4ADE80)](#-隐私设计)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

灵感来自 [@邵艾伦](https://x.com/AlanShao111) 的薄肌理论——作为他的学弟，把「薄肌计划」做成了一个拿来就能练的开源 App。🏋️

</div>

---

## 为什么不是又一个健身 App

薄肌靠的是低体脂 + 每周三练 + 渐进超负荷，比练更难的是**坚持记录、练时不分心**。市面健身 App 弹窗广告、社交干扰太多；开源自托管方案又要自己架服务器。LeanLift 的答案是把一切装进你的手机：

| | **LeanLift** | 云端 / 自托管健身平台 |
|---|---|---|
| 🔌 服务器 | **不需要**，装完即用 | 自建服务器或依赖他人服务 |
| 📦 数据归属 | **100% 留在本机** SQLite | 存在别人的数据库里 |
| 👤 账号注册 | **没有**，无登录无统计 | 要注册 / 自建账号系统 |
| 🔌 断网离线 | **全部功能可用**（联网仅日历/AI/更新，且全可选） | 核心功能依赖网络 |
| 🧹 训练界面 | **只剩三要素**：当前动作、本组目标、倒计时 | 广告、动态、会员弹窗 |
| 💰 费用 | **免费开源**（MIT） | 订阅制 / 服务器账单 |

> 联网只有三件事且全部可选：飞书日历读写（手机直连官方接口）、AI 功能（你自己的 API Key，直连你选的服务商）、检查更新（GitHub Releases）。

## 界面速览

<p align="center">
  <img src="docs/assets/screens/s2_lift.png" width="250" alt="训练中：大字组数与目标" />
  <img src="docs/assets/screens/s3_rest.png" width="250" alt="组间休息：下一组动作与次数" />
  <img src="docs/assets/screens/s4_history.png" width="250" alt="历史：每动作一张组表" />
</p>
<p align="center">
  <img src="docs/assets/screens/s1_home.png" width="250" alt="今日页" />
  <img src="docs/assets/screens/s5_rir.png" width="250" alt="余力没填写提醒" />
  <img src="docs/assets/screens/s6_heatmap.png" width="250" alt="肌群恢复度热力图" />
</p>

## ✨ 功能亮点

### 🏋️ 训练中：防分心是第一原则
- 全屏大按钮逐组记录：重量 ±0.5 / 1.25 / 2.5 / 5kg 步进微调（不弹键盘），次数点选，RIR、热身/正式/力竭随手标记；轻重量高次数（12/15+）点「自定义」直接键入
- 完成一组：震动 + 视觉确认，不用读屏就知道记上了
- 组间自动倒计时（复合动作 180s / 辅助动作 120s，可调）：锁屏、后台照常走，到点通知栏 + 精确闹钟叫你，休息不会悄悄溜走
- 上次成绩就在眼前、破 PR 当场报；自动开启勿扰，切去别的 App 会被提醒拉回来
- 改杠铃重量时短暂显示「每边挂几片」，几秒自动收起——算片不用动脑
- 平板支撑、悬挂、农夫行走按秒记录：独立的工作计时数着这组撑了多少秒，和组间休息的表分开走，上周 40 秒、这周 55 秒，历史页直接对比
- 箭步蹲、单臂划船这类单侧动作记总数、显示「每边 N 次」：12 次就是每边 6 次，目标恒为偶数，不会出现「每边 7 次」
- 屏幕常亮：训练中倒计时不会中途灭屏，一按暂停就灭屏省电；设置里可开关
- 练完忘停表（挂机几小时）保存前会问一句，一键截到最后一条记录，时长不虚高

### 📖 动作图文解析（187 个动作）
- 内置 187 个常见动作（含臀腿专项、商业健身房器械与弹力带居家系列），每个都带要点讲解：怎么做 + 常见错误（如卧推「肩胛松开耸肩、杠铃落点漂向脖子」），中英双语
- 177 个动作配「起始 / 结束姿势」真人示范照，上第一组前扫一眼就知道姿势该长什么样；14 个核心动作（卧推、深蹲类、硬拉类、引体、腿举等）配**无声示范短视频**循环播放
- **训练中也能看**：训练页点「📖 动作解析」随时翻出来，划掉继续练，计时不受影响

### 📈 渐进超负荷引擎
- 内置薄肌计划开箱即用（四大项 + 每周三练），另有 PPL / 五分化 / 功能性 / 居家哑铃四个模板，或让 AI 排
- **目标旁写着「为什么」**：每个目标重量/次数旁都有引擎给的达标说明——如「上轮 3 组全到 8 次 → 本轮加重 2.5kg」，加多少、为什么加，不是黑盒数字
- 加/减重量自动判定：全部正式组达到次数上限且末组有余力 → 建议加重；有组破下限 → 建议减 5%——照着点就行，不用自己算
- 自重动作（俯卧撑、引体向上）没有重量列，直接记次数；次数到天花板后引擎建议加组数，而不是让你无限堆次数
- **超级组**：相邻两三个动作配对交替练（A1→B1→A2→B2…），一个动作的休息正好塞进另一个动作；AI 拆计划时提到「超级组/配对」自动配好，计划编辑页一键设置/解除，转换休息与轮末完整休息各按所属动作分开计时
- 每组记录自动保存「当时目标」，历史页直接看**目标 vs 实际**——哪组没跟上、差多少，一目了然
- 自动估算 1RM；容量、组数、强度趋势（周 / 月粒度）不用拉表自己算

### 🤖 AI 功能（自配 Key，数据不出你手）
- 粘贴现成计划原文 → AI 逐字转成结构化计划，省去手动录入几十个动作
- 或一句大白话（如「每周四练，练背、胸、腿，增肌」）→ AI 直接设计完整计划
- **对话式排计划**（AI 教练）：像聊天一样说需求、随时改（「周三没空，挪一天」），AI 每轮给完整计划，满意后点「预览并保存为计划」，仍逐动作人工确认才落库
- **AI 教练**：自动附上近 8 周真实训练记录与自评趋势，一键阶段复盘或随时问答；内置教练人设与安全边界，请求失败明示原因可重试
- 兼容 OpenAI 接口，局域网 Ollama 等自建模型也能用；设置里一键「测试连接」，配没配对一试便知

### 🔗 让电脑上的 AI 读你的训练记录（局域网 MCP）
- 手机在自家 Wi-Fi 内开一个**只读**接口，电脑上的 AI（Claude Desktop / Cursor）经 MCP 直接读训练数据
- 于是可以问「我这次卧推是不是停滞了」「下周该练什么」，AI 拿的是你手机里的真实记录，不是让你复制粘贴
- **配对一次就够**：手机记住已配对的电脑（只存令牌的不可逆摘要），以后重开开关不用重配
- 只读 · 默认不常驻（手动开 + 空闲 10 分钟自动关；自家 Wi-Fi 可开「常驻」，只在记住的那个局域网生效）· 数据不出局域网、不经任何云端
- 逐步教程（手机端 + 电脑端，含常见问题）：[docs/MCP_GUIDE.md](docs/MCP_GUIDE.md)

### 📊 数据分析
- 训练日历、周 / 月训练趋势（容量 · 组数 · 平均强度三指标）、上下肢分布——这段时间练勤了还是摸鱼，一翻便知
- 主力动作 1RM 曲线（按容量自动选前 4，每日最佳、日期轴），进步看得见
- 历史明细表格化：每个动作一张「组 / 重量 / 次数 / 余力」小表 + 当时的目标
- 训练结束三档自评（差 / 一般 / 好），历史与 AI 分析包可见——状态好坏和成绩对得上
- 正 / 背面肌群容量热力图与恢复度估算：今天能不能再练胸，看恢复度再定
- **肌群「未练点名」**：数据页直接列出这段时间没练到的肌群（肩三周没出现在计划里，一眼可见）；计划编辑页实时预览这套计划命中哪些肌群，排计划时不留死角
- 体重 / 腰围 / 体脂记录（录入防呆）；开始训练时若今天还没记体重会顺手问一声，可跳过、可在设置关闭，趋势图不断档
- CSV / JSON 全量导出；一键生成「AI 分析包」喂给任何 AI 做训练总结
- 每次训练结束自动在本机留一份全量快照（保留最近 7 个备份日 + 4 个周桶，可关），数据与备份页可预览并一键恢复；手动导出超 14 天会在数据页轻提醒

### ⏰ 坚持练的提醒
- 练前提醒：训练日到了你设的时刻还没练，本地通知叫一声（不配飞书也有兜底）
- 错过训练日自动顺延：该练的日子过了没练，下次打开 App 计划自动往后推一天（每错一天推一天）并提示，训练节奏不乱；可在设置关闭
- 休息提示音四层（开始/半程/最后 3 秒），支持「仅耳机」模式——只在你耳朵里响，不外放扰人

### 📅 飞书日历联动
训练计划直接进你天天看的日历：训练日自动写入（含提前提醒），练完回填训练摘要，断网先排队、联网自动补写。配置见 [docs/feishu-calendar.md](docs/feishu-calendar.md)。

### 🌐 界面语言
- 内置中文 / English 双语，**设置 → 语言**随时切换（默认跟随系统语言）

## 📥 下载安装

1. 到 [Releases](https://github.com/kelinpan0524-cell/leanlift/releases) 下载最新 APK 安装（Android 8.0+）
2. 装好即用：内置薄肌计划，不注册、不登录、不要权限
3. 想要 App 内一键更新？见 [docs/update-setup.md](docs/update-setup.md)（首次授权一次即可，无需令牌）

## 🍎 iPhone 用户 & 想自己折腾的人

官方只出 Android 版。想自己编译、fork 维护一份、或在 Mac 上自行适配 iOS 的，
看 [AI-BUILD-GUIDE.md](AI-BUILD-GUIDE.md)——一份写给 AI 编程助手的操作手册，
把它连同仓库丢给你的 AI（ZCode / Claude Code / Cursor 均可），说「按手册帮我做」就行。

## 🔒 隐私设计

- **无服务器**：全部功能手机本地运行，训练数据存本地 SQLite
- **联网只有三件事**（全部可选）：飞书日历读写、AI 功能（你的 Key 直连你的服务商）、检查更新（GitHub Releases）
- 局域网 MCP 桥**不额外联网**：只在你自己的 Wi-Fi 内应答，不经任何云端（教程见 [docs/MCP_GUIDE.md](docs/MCP_GUIDE.md)）
- AI Key / 飞书凭证只存手机本地，永不上传、永不进仓库
- 无广告、无统计 SDK、无崩溃上报

## 🛠️ 开发

```bash
flutter pub get
flutter analyze      # 0 问题
flutter test         # 单元测试（渐进超负荷引擎、计时逻辑）
flutter build apk --release
# 产物: build/app/outputs/flutter-apk/app-release.apk
```

环境要求：Flutter 3.35+ / JDK 17 / Android SDK 35 / minSdk 26。

- 训练状态机与 UI 解耦（全局 SessionController + 墙钟计时），折叠/展开不丢训练状态；<600dp 单栏，≥840dp 双栏
- `scripts/mock_ai_server.py`：本地 mock AI 服务器，没有真实 Key 也能端到端验证 AI 生成链路
- 合并到 main 自动构建签名 APK 并发布 Release（tag = `b<构建号>`，构建号即 versionCode）
- 目录结构见 [AGENTS.md](AGENTS.md)，设计规范见 [docs/design-spec.md](docs/design-spec.md)

## 🙏 致谢

- **邵艾伦** —— 薄肌理论启蒙与本项目的直接灵感来源
- 动作示意图来自 [free-exercise-db](https://github.com/yuhonas/free-exercise-db)（Unlicense，公有领域）
- 14 个动作示范视频来自 [wger](https://github.com/wger-project/wger) 社区（CC BY-SA 4.0，作者 Goulart，已转码为无声 480p）
- 人体肌肉热力图的 SVG 路径数据来自 [vulovix/body-muscles](https://github.com/vulovix/body-muscles)（Apache License 2.0），本项目按训练强度重新着色渲染

## 📄 许可证

[MIT](LICENSE) © 2026 kelinpan (Arono)

肌肉热力图 SVG 路径数据部分遵循 [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)；动作示范视频部分遵循 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。

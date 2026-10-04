<div align="center">

<img src="docs/assets/icon.png" width="110" alt="LeanLift" />

# LeanLift · 薄肌训练计时器

**A strength training timer & log that runs entirely on your phone**

No server · Your data never leaves the device · Chinese & English · Minimal, distraction-free

[简体中文](README.md) | **English**

[![Release](https://img.shields.io/github/v/release/kelinpan0524-cell/leanlift?color=4ADE80)](https://github.com/kelinpan0524-cell/leanlift/releases)
[![Platform](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)](https://github.com/kelinpan0524-cell/leanlift/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.35%2B-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Data-100% local](https://img.shields.io/badge/data-100%25%20local-4ADE80)](#-privacy-by-design)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Inspired by Alan Shao's lean-physique theory — built into an open-source app you can train with today.🏋️

</div>

---

## Why not another fitness app

A lean physique comes from low body fat, training 3× a week, and progressive overload — the hard part is **logging consistently and staying focused mid-set**. Mainstream apps bury you in ads and social feeds; self-hosted platforms make you run a server. LeanLift keeps everything on your phone:

| | **LeanLift** | Cloud / self-hosted platforms |
|---|---|---|
| 🔌 Server | **None** — works out of the box | Your own server, or someone else's |
| 📦 Data ownership | **100% on-device** SQLite | Lives in someone else's database |
| 👤 Accounts | **None** — no sign-up, no analytics | Registration / account systems |
| 🔌 Offline | **Everything works offline** (calendar/AI/update are optional add-ons) | Core features need the network |
| 🧹 Training screen | **Three elements only**: current exercise, set target, countdown | Ads, feeds, pop-ups |
| 💰 Cost | **Free & open source** (MIT) | Subscriptions / server bills |

> Only three things ever touch the network, all optional: Feishu/Lark calendar sync (direct to the official API), AI features (your own API key, direct to your provider), and update checks (GitHub Releases).

## Screenshots

<p align="center">
  <img src="docs/assets/screens/s2_lift.png" width="250" alt="Mid-set: big set counter and target" />
  <img src="docs/assets/screens/s3_rest.png" width="250" alt="Rest: next set with exercise and reps" />
  <img src="docs/assets/screens/s4_history.png" width="250" alt="History: a table per exercise" />
</p>
<p align="center">
  <img src="docs/assets/screens/s1_home.png" width="250" alt="Today" />
  <img src="docs/assets/screens/s5_rir.png" width="250" alt="RIR not filled reminder" />
  <img src="docs/assets/screens/s6_heatmap.png" width="250" alt="Muscle recovery heatmap" />
</p>

## ✨ Highlights

### 🏋️ Mid-workout: distraction-free by design
- Full-screen, thumb-sized controls: weight stepping (±0.5 / 1.25 / 2.5 / 5kg, no keyboard), rep picking, RIR, warm-up/working/failure tags; tap "Custom" for high-rep sets
- Automatic rest countdown (180s compound / 120s assistance, adjustable) that keeps running on lock screens, with notification-bar + exact-alarm reminders
- Last-session comparison and automatic PR detection; Do-Not-Disturb turns itself on, and switching apps mid-set gets you nudged back
- Completing a set: haptic + visual confirmation, no screen-reading needed
- Barbell exercises briefly show plates-per-side when you change weight, then fade away
- Forgot to stop the timer? A guard asks before saving and trims the session to your last set

### 📖 Illustrated exercise guides (157 exercises)
- 157 built-in exercises, **every one with form cues** (how-to + common mistakes), bilingual
- 145 exercises come with start/end demonstration photos; 14 core lifts (bench, squat and deadlift families, pull-ups, leg press, …) include **silent demo videos** on loop
- **Available mid-workout**: tap "📖 Form Guide" on the training screen anytime — swipe it away and keep lifting, the timer never stops

### 📈 Progressive overload engine
- The Baoji (lean-physique) plan works out of the box, plus PPL / bro-split / functional / home-dumbbell templates — or let the AI design one
- Automatic load adjustments: hit the rep ceiling on every working set with reps in reserve → add weight; miss the floor → back off 5%
- Every set logs its target at completion — history shows **target vs actual**
- Automatic 1RM estimation; volume, set-count and intensity trends (weekly / monthly)

### 🤖 AI features (your key, your data)
- Paste an existing plan and the AI converts it into a structured one
- Or describe it in plain words ("4 days a week, back/chest/legs, hypertrophy") and get a complete plan
- **Conversational planning**: chat with the AI coach, refine as you go, then preview and save — every exercise still confirmed by you before it lands
- **AI coach**: attaches your last 8 weeks of real training data and self-ratings for one-tap reviews or Q&A; clear failure messages, never fakes AI with local rules
- OpenAI-compatible — local Ollama works too; one-tap connection test in settings

### 📊 Analytics
- Training calendar; weekly/monthly trends across volume · sets · average intensity; upper/lower split
- Top-lift 1RM curves (auto-picked by volume, daily best, date axis)
- Table-based history: per-exercise "set / weight / reps / RIR" tables with the targets of the day
- Post-workout impression (rough / okay / great) feeding history and the AI pack
- Front/back muscle volume heatmaps and recovery estimates
- Weight / waist / body-fat tracking with sanity-checked input
- Full CSV / JSON export; one-tap "AI analysis pack" for any AI

### ⏰ Staying consistent
- Pre-workout reminder: a local notification if you have not trained by your chosen time on a training day
- Auto-shift missed days: if a training day passes without a workout, the plan shifts one day later per missed day the next time you open the app, with a note; toggleable in settings
- Four-layer rest audio cues with a headphones-only mode

### 📅 Feishu/Lark calendar sync
Training days land on your calendar (with reminders), summaries backfill after the session, offline writes queue up. See [docs/feishu-calendar.md](docs/feishu-calendar.md).

### 🌐 Languages
- Chinese / English built in — switch anytime in **Settings → Language** (follows the system by default)

## 📥 Download & install

1. Grab the latest APK from [Releases](https://github.com/kelinpan0524-cell/leanlift/releases) (Android 8.0+)
2. Install and go: the Baoji plan is built in — no sign-up, no login, no permissions
3. Want in-app one-tap updates? See [docs/update-setup.md](docs/update-setup.md) (one-time authorization, no token needed)

## 🍎 iPhone users & tinkerers

Android-only officially. To build it yourself, maintain a fork, or adapt it for iOS on a Mac, read [AI-BUILD-GUIDE.md](AI-BUILD-GUIDE.md) — a handbook written for AI coding assistants. Drop it into your repo, tell your AI (ZCode / Claude Code / Cursor) "follow the guide", and go.

## 🔒 Privacy by design

- **No server**: everything runs on-device; training data lives in local SQLite
- **Only three network touchpoints** (all optional): Feishu/Lark calendar, AI features (your key, your provider), update checks (GitHub Releases)
- AI keys / calendar credentials stay on your phone — never uploaded, never committed
- No ads, no analytics SDK, no crash reporting

## 🛠️ Development

```bash
flutter pub get
flutter analyze      # 0 issues
flutter test         # unit tests (progressive overload engine, timing logic)
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

Requirements: Flutter 3.35+ / JDK 17 / Android SDK 35 / minSdk 26.

- Training state machine decoupled from the UI (global SessionController + wall-clock timers) — folding/unfolding never loses state; single column <600dp, two columns ≥840dp
- `scripts/mock_ai_server.py`: a local mock AI server for end-to-end testing without a real key
- Merging to main auto-builds a signed APK and publishes a Release (tag = `b<build number>`)
- See [AGENTS.md](AGENTS.md) for the layout and [docs/design-spec.md](docs/design-spec.md) for the design spec

## 🙏 Credits

- **Alan Shao** — the lean-physique theory behind this project
- Exercise photos from [free-exercise-db](https://github.com/yuhonas/free-exercise-db) (Unlicense, public domain)
- 14 demo videos from the [wger](https://github.com/wger-project/wger) community (CC BY-SA 4.0, by Goulart; re-encoded silent 480p)
- Muscle heatmap SVG paths from [vulovix/body-muscles](https://github.com/vulovix/body-muscles) (Apache License 2.0), recolored by training intensity

## 📄 License

[MIT](LICENSE) © 2026 kelinpan (Arono)

Muscle heatmap SVG data is under [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0); demo videos are under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

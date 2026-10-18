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
- Full-screen, thumb-sized controls: step weight by ±0.5 / 1.25 / 2.5 / 5kg (no keyboard), tap reps in, tag RIR and warm-up/working/failure on the fly; high-rep sets (12/15+) take the "Custom" key-in
- Completing a set: haptic + visual confirmation — you know it logged without reading the screen
- The rest countdown runs itself (180s compound / 120s assistance, adjustable): it keeps ticking through lock screen and background, and a notification-bar + exact alarm calls you back — rest never slips away silently
- Last session's numbers stay in view and PRs announce themselves; Do-Not-Disturb turns on automatically, and drifting into another app gets you nudged back
- Changing barbell weight briefly flashes plates-per-side, then fades — no mental plate math
- Timed holds — planks, hangs, farmer's walks — log by the second: a dedicated work timer counts how long you held, separate from the rest clock, so last week's 40s vs this week's 55s sits right there in history
- Unilateral lifts like lunges and single-arm rows log total reps and show "N per side": 12 total means 6 per side — targets are always even, so "7 per side" can never happen
- Screen stays awake mid-workout so the countdown never blacks out; it sleeps the moment you pause, with a switch in settings
- Forgot to stop the timer? A guard asks before saving and trims the session to your last set — no inflated duration

### 📖 Illustrated exercise guides (187 exercises)
- 187 built-in exercises (glute/leg specials, commercial-gym machines, band-at-home series), each with form cues: how-to + common mistakes (e.g. bench press: "shoulders shrug, bar drifts toward the neck"), bilingual
- 177 exercises come with start/end demonstration photos — one glance before your first set shows you the setup; 14 core lifts (bench, squat and deadlift families, pull-ups, leg press, …) add **silent demo videos** on loop
- **Available mid-workout**: tap "📖 Form Guide" on the training screen anytime — swipe it away and keep lifting, the timer never stops

### 📈 Progressive overload engine
- The Baoji (lean-physique) plan works out of the box (the big four lifts, 3×/week), plus PPL / bro-split / functional / home-dumbbell templates — or let the AI design one
- **Every target says why**: each target weight/rep count carries the engine's reason — "all 3 sets hit 8 last time → +2.5kg this round" — never a black-box number
- Load changes are judged for you: hit the rep ceiling on every working set with reps in reserve → add weight; miss the floor → back off 5% — just accept, no math
- Bodyweight moves (push-ups, pull-ups) skip the weight column — log reps directly; once reps hit the ceiling the engine suggests adding a set instead of endless reps
- **Supersets**: pair 2–3 neighboring exercises and alternate (A1→B1→A2→B2…) — one lift's rest fills another's work; the AI wires them up automatically when your plan mentions supersets, the plan editor toggles them in one tap, and transition rest vs full round rest are timed separately
- Every set logs its target at completion — history shows **target vs actual**, so you can see which set fell short and by how much
- Automatic 1RM estimation; volume, set-count and intensity trends (weekly / monthly) without spreadsheet math

### 🤖 AI features (your key, your data)
- Paste an existing plan and the AI converts it into a structured one — no hand-entering dozens of exercises
- Or describe it in plain words ("4 days a week, back/chest/legs, hypertrophy") and get a complete plan
- **Conversational planning**: chat your needs and refine as you go ("can't make Wednesday, move it") — each round returns a full plan, preview and save when happy, with every exercise still confirmed by you before it lands
- **AI coach**: attaches your last 8 weeks of real training data and self-ratings for one-tap phase reviews or Q&A anytime; a built-in coach persona with safety guardrails, and failures say why so you can retry
- OpenAI-compatible — local Ollama works too; one-tap "test connection" in settings

### 🔗 Let an AI on your computer read your logs (LAN MCP)
- The phone serves a **read-only** endpoint on your own Wi-Fi; an AI on your computer (Claude Desktop / Cursor) reads it through MCP
- So you can ask "is my bench stalling?" or "what should I train next week?" and the AI sees your real records — no copy-pasting
- **Pair once**: the phone remembers paired computers (only an irreversible digest of the token), so re-opening the switch needs no re-pairing
- Read-only · not persistent by default (you enable it; auto-stops after 10 idle minutes; optional keep-alive, home Wi-Fi only, bound to the remembered network) · data never leaves your local network
- Step-by-step guide (phone + computer, with troubleshooting): [docs/MCP_GUIDE.md](docs/MCP_GUIDE.md)

### 📊 Analytics
- Training calendar; weekly/monthly trends across volume · sets · average intensity; upper/lower split — whether you showed up this month is visible at a glance
- Top-lift 1RM curves (auto-picked by volume, daily best, date axis) — progress you can point at
- Table-based history: per-exercise "set / weight / reps / RIR" tables with the targets of the day
- Post-workout impression (rough / okay / great) feeding history and the AI pack — how you felt, next to how you performed
- Front/back muscle volume heatmaps and recovery estimates — check recovery before deciding to hit chest again
- **Neglected-muscle callouts**: the data page lists the muscle groups this stretch of training missed (shoulders absent for three weeks, visible at once); the plan editor previews in real time which muscles a plan hits, so gaps never sneak in
- Weight / waist / body-fat tracking with sanity-checked input; if today's weight isn't logged, the app asks when you start a workout — skippable and switchable off in settings, so the trend line never gaps
- Full CSV / JSON export; one-tap "AI analysis pack" for any AI
- An on-device full snapshot after every workout (latest for each of the 7 most recent backup dates + 4 weekly buckets; can be switched off), with preview and one-tap restore in Data & Backup; a quiet nudge on the Stats page after 14 days without a manual export

### ⏰ Staying consistent
- Pre-workout reminder: a local notification if you have not trained by your chosen time on a training day — a fallback even without the calendar sync
- Missed days auto-shift: skip a scheduled day and the plan slides one day later per missed day the next time you open the app, with a note — your rhythm stays intact; toggleable in settings
- Four-layer rest audio cues (start / midpoint / last 3 seconds) with a headphones-only mode — sounds in your ears, not across the gym

### 📅 Feishu/Lark calendar sync
Training days land on the calendar you already live in (with reminders), summaries backfill after the session, and offline writes queue up to flush later. See [docs/feishu-calendar.md](docs/feishu-calendar.md).

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
- The LAN MCP bridge adds **no** network access: it only answers inside your own Wi-Fi ([guide](docs/MCP_GUIDE.md))
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

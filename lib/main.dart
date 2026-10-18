import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app.dart';
import 'l10n/lang.dart';
import 'services/update_service.dart';
import 'ui/onboarding_page.dart';
import 'ui/shell.dart';
import 'ui/splash_page.dart';
import 'ui/theme.dart';
import 'ui/weekly_recap_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final container = AppContainer(prefs: prefs);
  await container.init();
  runApp(BaojiApp(
      container: container,
      onboarded: prefs.getBool('onboarded') == true));
  // 启动后静默检查更新：失败无声；有新版只在"设置"入口亮红点（不弹窗，
  // 遵守训练专注红线）。
  unawaited(UpdateService(container.settings).silentCheck());
}

class BaojiApp extends StatefulWidget {
  const BaojiApp({super.key, required this.container, required this.onboarded});

  final AppContainer container;
  final bool onboarded;

  @override
  State<BaojiApp> createState() => _BaojiAppState();
}

class _BaojiAppState extends State<BaojiApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // 周复盘通知点击 → 打开周复盘页。通知可能在 App 冷启动阶段到达
    // （容器先于导航树存在），先挂起，首帧后再消费。
    widget.container.onWeeklyRecapRequested = _openPendingWeeklyRecap;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openPendingWeeklyRecap();
    });
  }

  @override
  void dispose() {
    widget.container.onWeeklyRecapRequested = null;
    super.dispose();
  }

  void _openPendingWeeklyRecap() {
    if (!mounted) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    if (!widget.container.takePendingWeeklyRecap()) return;
    nav.push(
      MaterialPageRoute(builder: (_) => const WeeklyRecapPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      container: widget.container,
      // Builder 注册对 Settings 的依赖：语言切换（settings.notifyListeners）
      // 时整棵 MaterialApp 重建，locale / 文案即时生效。
      child: Builder(builder: (context) {
        final settings = AppScope.of(context).settings;
        return MaterialApp(
          navigatorKey: _navigatorKey,
          // 周复盘页需要知道「被别的路由盖住」以中止在途 AI 请求
          navigatorObservers: <NavigatorObserver>[weeklyRecapRouteObserver],
          title: tx('薄肌训练计时器', en: 'Baoji Timer'),
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          // 跟随系统时传 null，由本地化解析按系统语言挑 zh/en
          locale: switch (settings.langPref) {
            LangPref.zh => const Locale('zh'),
            LangPref.en => const Locale('en'),
            LangPref.system => null,
          },
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // 生效语言在这里同步给全局静态 Lang（通知/服务等非 Widget 代码读取）。
          // builder 上下文里没有 Localizations，直接用设置解析（系统语言取平台派发器）。
          builder: (context, child) {
            Lang.setResolved(
                Lang.resolve(settings.langPref, settings.systemLocale) == 'en');
            return child!;
          },
          // 开机动画先行，播完交叉淡出到首页/引导页
          home: SplashGate(
            child: widget.onboarded
                ? const HomeShell()
                : const OnboardingPage(),
          ),
        );
      }),
    );
  }
}

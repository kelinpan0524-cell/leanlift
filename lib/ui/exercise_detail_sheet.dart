import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../engine/engine.dart';
import '../l10n/lang.dart';
import '../l10n/names.dart';
import '../presets/exercise_library.dart';
import '../presets/exercise_media.dart';
import '../presets/exercise_video.dart';
import 'widgets/common.dart';
import 'theme.dart';

/// 动作解析弹层（2026-09-27 Arono 需求：图文并茂、训练中也能看）。
///
/// 内容 = 起止姿势示意图（free-exercise-db，Unlicense 公有领域）
/// + 动作要点（本项目中文原创）。训练中经由用户主动点按入口打开，
/// 与「直接输入重量」同口径——收起式信息、随时划掉、不打断计时，
/// 不违反训练中禁弹窗红线。
///
/// P2-C：额外承载「器械设置」编辑入口（座椅/靠背等长期备注），
/// 按动作稳定键跨计划/训练复用；[exerciseKey] 传会话行自带的键，
/// 空串时按 [name] 现算。
Future<void> showExerciseDetailSheet(
  BuildContext context, {
  required String name,
  ExerciseMeta? meta,
  String exerciseKey = '',
}) {
  final m = meta ?? libraryMetaByName(name);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          20 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        children: [
          Text(exname(name),
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          if (m != null) ...[
            const SizedBox(height: 4),
            Text(
              tx(
                '主练 ${mname(m.muscles.main)}'
                '${m.muscles.secondary.isEmpty ? '' : ' · 兼练 ${m.muscles.secondary.map(mname).join('/')}'}'
                ' · ${m.isCompound ? '复合动作' : '单关节动作'}'
                '${m.gear.isEmpty ? '' : ' · ${gearname(m.gear)}'}',
                en: 'Main ${mname(m.muscles.main)}'
                    '${m.muscles.secondary.isEmpty ? '' : ' · Secondary ${m.muscles.secondary.map(mname).join('/')}'}'
                    ' · ${m.isCompound ? 'Compound' : 'Isolation'}'
                    '${m.gear.isEmpty ? '' : ' · ${gearname(m.gear)}'}',
              ),
              style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
            ),
          ],
          SetupNoteEditor(name: name, exerciseKey: exerciseKey),
          ...exerciseMediaSection(name, m),
          ...exerciseVideoSection(name),
        ],
      ),
    ),
  );
}

/// 器械设置只读行（P2-C）：训练起始页/第一组前展示已保存的备注。
/// 空备注直接返回零尺寸，不占任何纵向空间。
class SetupNoteView extends StatelessWidget {
  const SetupNoteView({super.key, required this.note, this.compact = false});

  final String note;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = note.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: compact ? 3 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.tune, size: 14, color: AppTheme.accent),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              tx('器械设置：$text', en: 'Setup: $text'),
              key: const Key('setupNoteText'),
              maxLines: compact ? 2 : null,
              overflow: compact ? TextOverflow.ellipsis : null,
              style: TextStyle(
                color: AppTheme.accent,
                fontSize: compact ? 12.5 : 14,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「器械设置」编辑段（P2-C）：动作详情弹层内联展开，保存即写库。
/// 键口径与历史/备注查询一致（显式稳定键优先，空键按动作名现算）。
class SetupNoteEditor extends StatefulWidget {
  const SetupNoteEditor({
    super.key,
    required this.name,
    this.exerciseKey = '',
  });

  final String name;
  final String exerciseKey;

  @override
  State<SetupNoteEditor> createState() => _SetupNoteEditorState();
}

class _SetupNoteEditorState extends State<SetupNoteEditor> {
  final _ctrl = TextEditingController();
  bool _loadStarted = false;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  String _note = '';

  String get _key => exerciseIdentityKeyOf(widget.name, widget.exerciseKey);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadStarted) return;
    _loadStarted = true;
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = _key;
    final c = app(context);
    final note = key.isEmpty ? null : await c.db.exerciseNote(key);
    if (!mounted) return;
    setState(() {
      _note = note?.setupNote ?? '';
      _loading = false;
    });
  }

  void _beginEdit() {
    _ctrl.text = _note;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    FocusScope.of(context).unfocus();
    setState(() => _editing = false);
  }

  Future<void> _save() async {
    if (_saving) return;
    final c = app(context);
    final text = _ctrl.text.trim();
    setState(() => _saving = true);
    await c.session.saveSetupNote(_key, text);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _note = text;
      _editing = false;
      _saving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_key.isEmpty) return const SizedBox.shrink();
    final hasNote = _note.trim().isNotEmpty;
    return Container(
      key: const Key('setupNoteEditor'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.cardHi,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 16, color: AppTheme.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tx('器械设置', en: 'Equipment Setup'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!_editing && !_loading)
                TextButton(
                  key: const Key('setupNoteEditButton'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: AppTheme.primary,
                  ),
                  onPressed: _beginEdit,
                  child: Text(
                    hasNote ? tx('编辑', en: 'Edit') : tx('添加', en: 'Add'),
                  ),
                ),
            ],
          ),
          if (_editing) ...[
            const SizedBox(height: 4),
            TextField(
              key: const Key('setupNoteField'),
              controller: _ctrl,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              maxLength: 120,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: tx('例如：座椅 4 档、靠背 2 档、脚垫最前',
                    en: 'e.g. seat notch 4, backrest 2, feet forward'),
                hintStyle:
                    const TextStyle(color: AppTheme.textDim, fontSize: 13),
                counterText: '',
                isDense: true,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : _cancelEdit,
                  child: Text(tx('取消', en: 'Cancel')),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  key: const Key('setupNoteSaveButton'),
                  onPressed: _saving ? null : _save,
                  child: Text(tx('保存', en: 'Save')),
                ),
              ],
            ),
          ] else if (!_loading && hasNote)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _note,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            )
          else if (!_loading)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                tx('记下座椅/靠背等固定设置，下次练这个动作直接看到。',
                    en: 'Save seat/backrest settings so they show up next time.'),
                style: const TextStyle(
                  color: AppTheme.textDim,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 示范视频段（2026-09-27，wger.de 社区 CC BY-SA 4.0）：
/// 无声短视频，点按播放/暂停，循环；无视频的动作不渲染本段。
List<Widget> exerciseVideoSection(String name) {
  final v = exerciseVideoOf(name);
  if (v == null) return const [];
  return [
    const SizedBox(height: 14),
    Text(tx('动作演示', en: 'Demo Video'),
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    const SizedBox(height: 6),
    ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: _DemoVideoPlayer(asset: v.file),
      ),
    ),
    const SizedBox(height: 4),
    Text(
      tx('视频来自 wger.de 社区（CC BY-SA 4.0，作者 ${v.author}）· 已转码为无声 480p',
          en: 'Video from the wger.de community (CC BY-SA 4.0, by ${v.author}) · re-encoded silent 480p'),
      style: const TextStyle(color: AppTheme.textDim, fontSize: 11),
    ),
  ];
}

/// 内嵌视频播放器：asset 播放、静音循环、点按切换播放/暂停。
/// 播放器初始化失败（解码兼容等）时降级为一行提示，不阻塞弹层。
class _DemoVideoPlayer extends StatefulWidget {
  const _DemoVideoPlayer({required this.asset});

  final String asset;

  @override
  State<_DemoVideoPlayer> createState() => _DemoVideoPlayerState();
}

class _DemoVideoPlayerState extends State<_DemoVideoPlayer> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.asset(widget.asset);
    _controller = c;
    c.initialize().then((_) {
      if (!mounted) return;
      c.setLooping(true);
      setState(() {});
      c.play();
    }).catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed || c == null || !c.value.isInitialized) {
      return Container(
        color: AppTheme.cardHi,
        alignment: Alignment.center,
        child: _failed
            ? Text(tx('该设备无法播放此视频', en: 'This device cannot play this video'),
                style: const TextStyle(color: AppTheme.textDim, fontSize: 12))
            : const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => c.value.isPlaying ? c.pause() : c.play());
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(child: VideoPlayer(c)),
          // 播放中不显示按钮；暂停时给个轻提示（无声视频，点画面即恢复）
          if (!c.value.isPlaying)
            const Icon(Icons.play_circle_outline,
                size: 44, color: Colors.white70),
        ],
      ),
    );
  }
}

/// 示意图 + 要点段（动作库详情弹层与训练中解析弹层共用）。
/// 图：0 = 起始姿势，1 = 结束姿势，横版照统一裁 4:3 圆角展示。
List<Widget> exerciseMediaSection(String name, ExerciseMeta? m) {
  final images = exerciseImageAssets(name);
  final cue = m?.cue ?? '';
  return [
    if (images.isNotEmpty) ...[
      const SizedBox(height: 14),
      Row(
        children: [
          for (var i = 0; i < images.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Image.asset(
                          images[i],
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: AppTheme.cardHi,
                            alignment: Alignment.center,
                            child: Icon(Icons.image_not_supported_outlined,
                                size: 28, color: AppTheme.textDim),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      i == 0
                          ? tx('起始姿势', en: 'Start')
                          : tx('结束姿势', en: 'End'),
                      style:
                          const TextStyle(color: AppTheme.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ],
    if (cue.isNotEmpty) ...[
      const SizedBox(height: 14),
      Text(tx('动作要点', en: 'Form Cues'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(cuen(name, cue),
          style: const TextStyle(fontSize: 14, height: 1.5)),
    ],
    if (images.isEmpty && cue.isEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          tx('这个动作（多为 AI 计划新增）还没有图文解析，可在动作库里换用内置动作获得解析。',
              en: 'No illustrated guide yet for this exercise (likely added by an AI plan) — swap to a built-in one in the library.'),
          style: const TextStyle(color: AppTheme.textDim, fontSize: 13),
        ),
      ),
  ];
}

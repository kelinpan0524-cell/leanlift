import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../engine/engine.dart';
import '../engine/weight_unit.dart' show unitLabel;
import '../presets/exercise_library.dart';
import 'plan_repository.dart';
import 'settings.dart';

/// OpenAI 兼容 chat/completions 客户端：手机直连，key 只存本地。
class AiService {
  /// [httpClient] 仅测试注入（http/testing MockClient）；生产为 null，
  /// 走顶层 http.post（IOClient）。
  AiService(this._settings, {http.Client? httpClient}) {
    // 赋值放构造体而非初始化列表：私有字段接公开具名参数，
    // 初始化列表写法会触发 prefer_initializing_formals lint
    _httpClient = httpClient;
  }

  final Settings _settings;
  late final http.Client? _httpClient;

  // ---------- 动作词表（内置 + 用户沉淀合并集，2026-09-29） ----------
  // 用户沉淀动作 = exercise_meta 表里内置词表之外的新行（AI 生成保存、
  // 编辑器手动添加沉淀而来）。词表与六级匹配此前只读内置静态清单，
  // 沉淀动作永远进不了 AI 参考、名字也匹配不上——AI 会换名重造同一
  // 动作、已确认过的还会再标「待确认」。合并后三处提示词、匹配级联
  // 与 metaMap 全部与动作挑选页同口径。由 AppContainer 在计划仓库
  // 加载/变化后灌入（测试可直接赋值）。
  List<ExerciseMeta> _sedimentLibrary = const [];

  set sedimentLibrary(List<ExerciseMeta> v) {
    _sedimentLibrary = v;
    _sortedMetaCache = null; // 匹配快照随词表失效，下次用时重建
  }

  /// 内置库在前（保持既有顺序）、沉淀追加在后。
  List<ExerciseMeta> get mergedLibrary =>
      [...kExerciseLibrary, ..._sedimentLibrary];

  Map<String, ExerciseMeta> metaMap() => {
        for (final m in mergedLibrary) m.name: m,
      };

  /// 参考词表（按肌群分组紧凑渲染，三处提示词共用）：
  /// 「胸：卧推(杠铃)、…；腿：…」。比平铺好检索——180+ 条时模型能按目标肌群
  /// 直接去对应分组挑动作；分组开销仅每肌群 2 个字符。2026-09-29 起名字后
  /// 带器械标注（gear 为空的沉淀动作不带括号）——出差/器械受限场景 AI 能按
  /// 「可用器械」挑动作（弹力带/自重/哑铃…）。
  static String exerciseReference(List<ExerciseMeta> library) {
    final buf = StringBuffer();
    for (final region in kMuscleRegions) {
      final names = [
        for (final m in library)
          if (m.muscles.main == region)
            m.gear.isEmpty ? m.name : '${m.name}(${m.gear})',
      ];
      if (names.isEmpty) continue;
      buf.write('$region：${names.join('、')}；');
    }
    return buf.toString();
  }

  /// AI 教练人设（system prompt）。身份设定三原则：
  /// ① 数据为准——只对训练数据说话，没有的不编造；
  /// ② 大白话、给数字——建议具体到加重/组次/休息秒数；
  /// ③ 安全边界——不诊断伤病、不给"忍痛练"方案。
  static const String kCoachPersona = '你是「薄肌教练」——「薄肌训练计时器」App 内置的私人力量训练教练。\n\n'
      '身份与口径：\n'
      '- 用户是业余增肌训练者，跟随「薄肌计划」（每周 3-5 练，推/拉/腿三分化，四大项渐进超负荷），目标是增肌。\n'
      '- 你看到的「训练数据」是 App 从手机本地导出的真实记录，一切结论以数据为准；数据里没有的不要编造，可以直接问用户。\n'
      '- 恢复度、容量等指标是 App 的启发式估算（按训练容量与 48 小时衰减），不是生理测量，表述时保持"参考"口径。\n\n'
      '回答风格：\n'
      '- 中文大白话，结论先行，直接给可执行动作；少堆术语，必要术语用一句话解释。\n'
      '- 可以用 Markdown 排版（加粗、要点列表、表格）组织回答，App 内会渲染成排版样式。\n'
      '- 建议具体到数字：加重多少 kg、几组几次、组间休息多少秒、弱项补什么动作。\n'
      '- 用要点列表保持紧凑，通常 300 字以内（用户明确要求展开除外）。\n\n'
      '边界：\n'
      '- 不做医疗诊断。用户描述疼痛、麻木、关节异响等伤症状况时，先建议就医或休息，并降低受累部位训练量，绝不给"忍痛练"方案。\n'
      '- 不推荐违禁药物；补剂只谈有共识证据的（蛋白粉、肌酸等），并提示遵说明使用。';

  /// 一键阶段复盘的指令（数据包已作为上下文注入，这里只写分析要求）。
  static const String kAnalysisInstruction =
      '请基于上面的训练数据做一次阶段复盘，用要点列表输出（可用表格做对比）：\n'
      '1. 进步与退步：主力动作的力量/容量趋势，点名停滞或退步的动作；\n'
      '2. 训练频率与容量是否足以支撑渐进超负荷；\n'
      '3. 肌群均衡度：哪个肌群容量偏低；\n'
      '4. 组间休息：对比"计划休息 vs 实际休息"，指出过长或过短的动作'
      '（参考：复合动作 90-180 秒、辅助 60-90 秒、大重量力量组 3-5 分钟）；\n'
      '5. 未来 2-4 周的 3-5 条具体调整建议。\n'
      '总长控制在 600 字以内。';

  /// 最近一次「一键阶段复盘」的 AI 回复（复盘指令后紧跟的 assistant 轮）。
  /// 没发过复盘、或复盘指令是最后一轮（回复未回）时返回 null。
  static AiMessage? lastRecapReply(List<AiMessage> turns) {
    for (var i = turns.length - 2; i >= 0; i--) {
      final u = turns[i];
      if (u.role == 'user' && u.content == kAnalysisInstruction) {
        final r = turns[i + 1];
        return r.role == 'assistant' ? r : null;
      }
    }
    return null;
  }

  /// 复盘回复拼成 Markdown 存档：标题带绝对日期，正文保持 AI 原文。
  static String buildRecapMarkdown(DateTime now, String title, String reply) {
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return '# $title $date\n\n$reply\n';
  }

  /// 组装教练对话消息：人设 + 排计划契约（合并为首个 system 段）+
  /// 数据上下文 + 历史 + 本轮用户输入。数据包作独立 system 段注入；
  /// chat/completions 无状态，历史每轮重发。
  ///
  /// 2026-09-26 Arono 需求：排计划契约并入**每一次**对话（原来是「排计划模式」
  /// 开关才叠加）——任何轮次里 AI 给出完整计划 JSON 都能被提取成可保存的
  /// 计划，写进 App 不再依赖用户找到并打开隐藏开关。契约本身按
  /// 「用户想排/改计划时」条件生效，纯问答轮次行为不变。
  List<AiMessage> buildCoachMessages(
    String dataPack, {
    List<AiMessage> history = const [],
    String userText = '',
  }) {
    return [
      // 重量单位说明（2026-10-17）：数据包/存储口径全 kg，App 显示单位可切 lb——
      // AI 建议的加重数字需按用户正在看的单位给，避免对不上界面
      AiMessage('system',
          '$kCoachPersona\n\n${planChatContract()}\n\n重量单位口径：训练数据里的所有重量数字一律是 kg（存储口径）；'
              '用户 App 界面当前显示单位是 ${unitLabel()}。给加重/目标重量建议时，'
              '请用用户界面正在显示的单位表述（必要时自行换算，lb 可取 2.5 的整数倍），并说明换算结果。'),
      AiMessage('system',
          '以下是用户 App 导出的真实训练数据。开头的「当前计划与日程」是用户此刻的真实计划状态：'
              '使用中计划、今天/明天练什么、未来 7 天日程；日期均为绝对日期，'
              '你不知道今天几号，所有日期判断以此段为准，给训练安排类建议时优先参考它，'
              '不要反问用户今天星期几：\n\n$dataPack'),
      ...history,
      AiMessage('user', userText),
    ];
  }

  /// 排计划契约（叠加在教练人设之上，随 buildCoachMessages 进每次对话）。
  /// 关键设计：用户想排/改计划时，每次输出**完整最新版**计划的严格 JSON
  /// （```json 围栏），App 端用 extractJsonPayload + parseResponse 提取清洗
  /// ——与计划页「描述生成」完全同一套 JSON 契约与容错，不另起炉灶。
  /// 2026-09-29 起为实例方法：词表含用户沉淀动作（mergedLibrary），
  /// 并按肌群分组渲染，模型按目标肌群直接去对应分组挑动作。
  String planChatContract() {
    final lib = exerciseReference(mergedLibrary);
    return '【排计划规则】当用户想让你安排或调整训练计划（排新计划、换动作、改组次、'
        '加减训练日、调下一阶段）时，规则：\n'
        '1. 信息不足时先用 1-2 个问题问清（每周练几天、健身房还是居家、有哪些器械、目标是增肌还是力量）；'
        '描述已经足够就直接给计划，不要挤牙膏式反问。\n'
        '2. 每次给出或修改计划：先用不超过 3 句话讲设计思路，再输出完整最新版计划——'
        '严格 JSON 数组，包在 ```json 代码块里，每个元素是一个训练日：\n'
        '[{"weekday":1-7(周一=1),"title":"训练日名称","exercises":[{"name":"规范中文动作名",'
        '"sets":组数,"reps_min":最少次数,"reps_max":最多次数,"rest_sec":组间休息秒数,'
        '"kind":"compound或assistance","main_muscle":"胸/肩/背/手臂/腿/核心 之一","superset":true(可选)}]}]\n'
        '3. 用户要调整（换动作/改组次/加减训练日/改频率）时，重新输出调整后的**完整**计划 JSON，'
        '不是只给改动项。\n'
        '4. 每周 3-5 个训练日（用户明确指定则照办）；同一肌群两次训练至少间隔 48 小时；'
        '容量安排符合渐进超负荷原则；热身组不写入；rest_sec：复合动作 150-180、辅助动作 90-120。\n'
        '5. 可以参考训练数据里用户的水平与弱项安排，但计划本身仍按上面的 JSON 输出。\n'
        '6. 动作必须优先从参考词表里选（按目标肌群去对应分组挑，名字照抄词表原文）；'
        '词表确实没有合适的才用规范中文短名。参考词表（按肌群分组）：$lib\n'
        '7. 超级组：仅当用户提到"超级组/配对/交替练"时才用——配对的第一个动作加 "superset": true'
        '（与下一个动作配对，连标两个=三动作连组）；优先拮抗肌配对；配对动作组数一致；'
        '配对中除最后一个动作外 rest_sec 给 20-30（转换休息），最后一个动作正常休息。\n'
        '8. 出差/旅行/酒店健身房/器械受限（2026-09-29）：先问清当地有什么器械'
        '（哑铃？弹力带？可调杠铃？只有自重？），再按实际条件给计划——动作按词表括号里的'
        '器械标注挑（弹力带/自重/哑铃优先），不要给当地做不了的动作；'
        '当天就想练的话提醒用户：计划气泡下点「作为今日临时训练直接开练」即可，'
        '不动长期计划。多天出差可继续在本对话里按天安排，你记得前面聊过的器械条件。';
  }

  /// 连接测试：发一条最小请求，返回 (耗时 ms, 模型回复)。
  /// 成功/失败都由调用方（设置页「测试连接」）直接展示给用户。
  Future<(int elapsedMs, String reply)> testConnection() async {
    final sw = Stopwatch()..start();
    final reply = await chat(const [
      AiMessage('user', '连接测试：请只回复「连接正常」四个字。'),
    ]);
    sw.stop();
    return (sw.elapsedMilliseconds, reply);
  }

  /// Base URL 归一（可见于测试）：去首尾空白、去结尾斜杠、
  /// 去用户误粘的 /chat/completions 尾巴——把完整接口地址当 Base URL
  /// 填，与缺 /v1 并列是 404 的两大来源。
  @visibleForTesting
  static String normalizeBaseUrl(String raw) {
    var base = raw.trim().replaceAll(RegExp(r'/+$'), '');
    base = base.replaceAll(RegExp(r'/chat/completions$'), '');
    return base;
  }

  /// 从服务商错误响应体里提取人类可读原因（OpenAI 兼容形态的
  /// error.message / message），提取不到返回 null。404 也可能是
  /// 「模型名不存在」这类 body 里才写明的原因，透传给用户更好排查。
  @visibleForTesting
  static String? extractApiError(String body) {
    try {
      final v = jsonDecode(body);
      if (v is! Map) return null;
      final err = v['error'];
      if (err is Map && err['message'] is String) return err['message'] as String;
      if (err is String) return err;
      if (v['message'] is String) return v['message'] as String;
    } catch (_) {}
    return null;
  }

  /// 多轮对话通用入口：messages 原样发给 /chat/completions。
  /// 所有 AI 功能（计划拆解/描述生成/教练对话/分析）统一走这里，
  /// 错误统一归一为 AiException 中文文案。
  Future<String> chat(List<AiMessage> messages) async {
    if (!_settings.aiConfigured) {
      throw const AiException('未配置 AI 接口，请在设置里填入 Base URL 和 API Key');
    }
    final base = normalizeBaseUrl(_settings.aiBaseUrl);
    final schemeError = baseUrlSchemeError(base);
    if (schemeError != null) {
      throw AiException(schemeError);
    }
    // 404 自愈：Base URL 只有域名没有路径（如 https://api.moonshot.cn）时，
    // 多数 OpenAI 兼容服务商的真实端点在 /v1 下——先按原样请求，404 才
    // 自动补 /v1 重试一次。DeepSeek 等根路径可用的服务商第一发就通，
    // 不会多发请求。
    final parsed = Uri.tryParse(base);
    final pathEmpty =
        parsed == null || parsed.path.isEmpty || parsed.path == '/';
    final bases = pathEmpty ? [base, '$base/v1'] : [base];
    final post = _httpClient?.post ?? http.post;
    Future<http.Response> send(String b) => post(
          Uri.parse('$b/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${_settings.aiApiKey}',
          },
          body: jsonEncode({
            'model': _settings.aiModel,
            'messages': [
              for (final m in messages)
                {'role': m.role, 'content': m.content}
            ],
            'temperature': 0.2,
          }),
        ).timeout(const Duration(seconds: 90));
    try {
      var resp = await send(bases.first);
      if (resp.statusCode == 404 && bases.length > 1) {
        resp = await send(bases.last);
      }
      if (resp.statusCode != 200) {
        final detail = extractApiError(utf8.decode(resp.bodyBytes));
        final brief = detail == null
            ? ''
            : '（${detail.length > 80 ? '${detail.substring(0, 80)}…' : detail}）';
        final friendly = switch (resp.statusCode) {
          401 => 'API Key 无效$brief',
          403 => '无访问权限或地区受限$brief',
          404 => pathEmpty
              ? 'AI 接口返回 404，自动补 /v1 也没找到$brief。'
                  '请检查 Base URL（要填到版本路径，如 https://api.moonshot.cn/v1，'
                  '结尾不带 /chat/completions）和模型名是否写对'
              : 'AI 接口返回 404$brief。多半是 Base URL 的路径不对'
                  '（要填到版本路径，如 https://api.moonshot.cn/v1）或模型名写错',
          429 => '额度不足或被限流，稍后再试$brief',
          _ => 'AI 接口返回 ${resp.statusCode}$brief',
        };
        throw AiException(friendly);
      }
      final dynamic decoded;
      try {
        decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      } on FormatException {
        throw const AiException('AI 返回的不是有效 JSON（网关错误页？），请检查 Base URL');
      }
      final data = decoded as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw const AiException('AI 返回为空');
      }
      final msg = (choices.first as Map)['message'] as Map;
      // 推理类模型可能把文本放 reasoning_content、content 置 null
      final content = (msg['content'] as String?)?.trim() ?? '';
      if (content.isEmpty) {
        throw const AiException('模型没有输出内容（可能被截断或仅推理输出），请换模型或重试');
      }
      return content;
    } on TimeoutException {
      throw const AiException('AI 请求超时，请检查网络或稍后再试');
    } on http.ClientException catch (e) {
      throw AiException('无法连接 AI 接口：${e.message}');
    }
  }

  /// 把用户粘贴的计划文本拆解为结构化计划。
  /// 动作名尽量匹配内置词表；肌群映射走词表 + 关键词兜底。
  Future<List<AiDaySpec>> parsePlan(String text) async {
    if (!_settings.aiConfigured) {
      throw const AiException('未配置 AI 接口，请在设置里填入 Base URL 和 API Key');
    }
    final prompt = _buildPrompt(text);
    final content = await chat([AiMessage('user', prompt)]);
    return parseResponse(content);
  }

  /// 自然语言描述 → 教练设计一份计划（输出与原文导入相同的 JSON 契约）。
  String buildDesignerPrompt(String description) {
    final lib = exerciseReference(mergedLibrary);
    return '''
你是专业力量训练教练。根据用户的自然语言描述，设计一份每周力量训练计划，输出严格 JSON：
1. 只输出 JSON 数组，不要输出任何其他文字或 markdown 代码块标记。
2. 每个元素是一个训练日：{"weekday": 1-7(周一=1), "title": "训练日名称", "exercises": [...]}
3. 每个 exercise：{"name": "规范中文动作名", "sets": 组数, "reps_min": 最少次数, "reps_max": 最多次数, "rest_sec": 组间休息秒数, "kind": "compound或assistance", "main_muscle": "胸/肩/背/手臂/腿/核心 之一", "superset": true(可选)}
4. 每周 3-5 个训练日；同一肌群两次训练至少间隔 48 小时；容量安排符合渐进超负荷原则；热身组不写入；rest_sec：复合动作 150-180，辅助动作 90-120。
5. 动作必须优先从参考词表里选（按目标肌群去对应分组挑，名字照抄词表原文）；词表确实没有合适的才用规范中文短名。参考词表（按肌群分组）：$lib
6. 用户未说明的部分按增肌最佳实践补全；描述过简时按"每周 3 练、全身均衡"处理；用户明确指定的动作/器械/次数/每周训练天数都尊重用户（如"每周 6 练"或"只要 2 天"照办）。
7. 超级组：仅当用户提到"超级组/配对/交替练"时才使用，不要主动加——在配对的第一个动作上加 "superset": true 表示与下一个动作配成超级组（连标两个=三动作连组）；优先拮抗肌配对（如二头弯举+三头臂屈伸、卧推+划船）；配对动作组数保持一致；配对中除最后一个动作外 rest_sec 给 20-30（转换休息），最后一个动作保持正常组间休息。

用户描述：$description
''';
  }

  /// 自然语言生成计划（不落库），返回后由 UI 预览、用户确认再保存。
  Future<List<AiDaySpec>> designPlanFromDescription(String description) async {
    if (!_settings.aiConfigured) {
      throw const AiException('未配置 AI 接口，请在设置里填入 Base URL 和 API Key');
    }
    final content = await chat([AiMessage('user', buildDesignerPrompt(description))]);
    return parseResponse(content);
  }

  String _buildPrompt(String planText) {
    final lib = exerciseReference(mergedLibrary);
    return '''
你是力量训练计划解析器。把下面的训练计划文本转换为严格 JSON。要求：
1. 只输出 JSON 数组，不要输出任何其他文字或 markdown 代码块标记。
2. 每个元素是一个训练日：{"weekday": 1-7(周一=1), "title": "训练日名称", "exercises": [...]}
3. 每个 exercise：{"name": "动作名", "sets": 组数, "reps_min": 最少次数, "reps_max": 最多次数, "rest_sec": 组间休息秒数, "kind": "compound或assistance", "main_muscle": "主发力肌群，从 胸/肩/背/手臂/腿/核心 里选一个", "superset": true(可选)}
4. "3×5-8" 表示 sets=3, reps_min=5, reps_max=8；"3组8-12次" 同理。
5. 动作名使用规范中文，词表里有的动作优先用词表原文（参考词表按肌群分组：$lib）。次数字段缺失时用常见默认：复合动作 5-8、辅助动作 8-12；休息缺失时复合 180、辅助 120。
6. 训练计划原文可能提到具体星期，如"周一"对应 weekday=1。
7. 原文里的"超级组/配对/交替"（如"超级组：二头弯举+三头下压"或"A1 B1 A2 B2 交替"）：在配对的第一个动作上加 "superset": true 表示与下一个动作配对；配对中除最后一个动作外 rest_sec 给 20-30（转换休息），最后一个动作按原文或默认。

计划原文：
$planText
''';
  }

  /// Base URL 协议校验（可见于测试）：返回给用户的错误文案，合法返回 null。
  /// 缺 scheme（如 Ollama 官方写法 localhost:11434）单独提示——此时
  /// Uri.tryParse 会把 'localhost' 当 scheme、host 为空，若直接走
  /// "公网必须 https" 分支会误导用户加 https 前缀，反而连不上明文本地服务。
  @visibleForTesting
  static String? baseUrlSchemeError(String base) {
    if (!base.contains('://')) {
      return '地址缺少 http:// 或 https:// 前缀，请补全（局域网自建模型可用 http://）';
    }
    if (!base.startsWith('https://')) {
      // 公网必须 https（Key 在请求头，明文会被中间人截获）；
      // 局域网/本机自建模型（Ollama、LM Studio 等）允许 http。
      // 白名单按数值 IPv4 判定：'10.evil.com' 这类域名形状不能绕过。
      final host = Uri.tryParse(base)?.host ?? '';
      final isPrivate = isLocalHost(host);
      if (!isPrivate) {
        return '公网地址必须 https://（局域网自建模型可用 http）';
      }
    }
    return null;
  }

  /// 局域网 http 白名单：localhost 精确匹配 + 数值 IPv4 私有段。
  /// '10.evil.com' 这类域名形状不放行。
  @visibleForTesting
  static bool isLocalHost(String host) {
    if (host == 'localhost' || host == '::1' || host == '0.0.0.0') return true;
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(host);
    if (m == null) return false; // 非数值 IP（域名）一律要求 https
    final octets = [
      for (var i = 1; i <= 4; i++) int.parse(m.group(i)!),
    ];
    if (octets.any((o) => o > 255)) return false;
    final a = octets[0], b = octets[1];
    return a == 10 ||
        a == 127 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 169 && b == 254);
  }

  /// 数字字段安全转换：弱模型常把数字输出成字符串/全角字符。
  static int _asInt(Object? v, int def) {
    if (v is num) return v.toInt();
    if (v is String) {
      final normalized = v.replaceAll('０', '0')
          .replaceAll('１', '1').replaceAll('２', '2')
          .replaceAll('３', '3').replaceAll('４', '4')
          .replaceAll('５', '5').replaceAll('６', '6')
          .replaceAll('７', '7').replaceAll('８', '8')
          .replaceAll('９', '9').trim();
      return int.tryParse(normalized) ?? def;
    }
    return def;
  }

  /// 布尔字段安全转换（超级组 superset 标记）：容忍 true/1/"true"/"是"
  /// 等弱模型形态；缺失与其他乱值一律 false。
  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == 'true' || s == '1' || s == '是' || s == 'yes';
    }
    return false;
  }

  /// AI 输出集中清洗（可见于测试）：weekday 越界丢日、数字安全转换、
  /// sets/reps/rest 钳制、reps 倒挂交换、同 weekday 合并、
  /// 动作名六级匹配级联（调研条目 12）。
  /// jsonDecode 与字段强转的异常统一归一为 AiException，
  /// 让 UI 侧走中文友好文案而不是英文原始报错。
  @visibleForTesting
  List<AiDaySpec> parseResponse(String content) {
    final list = extractJsonPayload(content);
    final specs = <AiDaySpec>[];
    final byWeekday = <int, int>{}; // weekday -> specs 下标（同日合并）
    try {
      // pass 1：提取有效日结构（清洗规则与旧版一致）
      final days = <(int, String, List<Map<String, dynamic>>)>[];
      for (final item in list) {
        if (item is! Map) continue;
        final day = Map<String, dynamic>.from(item);
        final weekday = _asInt(day['weekday'], 0);
        if (weekday < 1 || weekday > 7) continue; // 越界日丢弃
        final rawTitle = day['title'];
        final title = rawTitle is String ? rawTitle : '训练日';
        final rawList = day['exercises'];
        if (rawList is! List) continue;
        final exItems = [
          for (final raw in rawList)
            if (raw is Map) Map<String, dynamic>.from(raw),
        ];
        days.add((weekday, title, exItems));
      }
      // pass 2：动作名六级匹配（覆盖率按整批计算，先收集全部原始名）
      final rawNames = [
        for (final d in days)
          for (final ex in d.$3)
            if (ex['name'] is String && (ex['name'] as String).trim().isNotEmpty)
              ex['name'] as String,
      ];
      final matches = matchExerciseNames(rawNames);
      var mi = 0;
      // pass 3：组装 specs（数字清洗 + 同 weekday 合并）
      for (final d in days) {
        final (weekday, title, exItems) = d;
        final exList = <AiExerciseSpec>[];
        for (final ex in exItems) {
          final rawNameValue = ex['name'];
          // 空名跳过（与 pass2 的收集条件一致，不消耗匹配下标）
          final rawTrim =
              rawNameValue is String ? rawNameValue.trim() : '';
          if (rawTrim.isEmpty) continue;
          final match = matches[mi++];
          final name = match.name;
          var sets = _asInt(ex['sets'], 3).clamp(1, 20);
          var repsMin = _asInt(ex['reps_min'], 5).clamp(1, 50);
          var repsMax = _asInt(ex['reps_max'], 8).clamp(1, 50);
          if (repsMin > repsMax) {
            final t = repsMin;
            repsMin = repsMax;
            repsMax = t;
          }
          // 缺失或 0 都视为缺失：让 saveAiPlan 的 defaultRestSec
          // 按用户休息偏好兜底，DB 不落 rest_sec=0 脏数据
          final rs = _asInt(ex['rest_sec'], 0);
          final rawKind = ex['kind'];
          final rawMuscle = ex['main_muscle'];
          exList.add(AiExerciseSpec(
            name: name,
            rawName: rawNameValue is String ? rawNameValue : name,
            needsConfirm: match.needsConfirm,
            candidates: match.candidates,
            sets: sets,
            repsMin: repsMin,
            repsMax: repsMax,
            restSec: rs <= 0 ? null : rs.clamp(0, 600),
            kind: rawKind is String ? rawKind : null,
            mainMuscle: rawMuscle is String ? rawMuscle : null,
            startsSuperset: _asBool(ex['superset']),
          ));
        }
        // 超级组悬挂清洗：一天最后一个动作标了 superset=true（没有下一个
        // 可配对）→ 忽略，避免预览页显示悬空的配对徽标。
        if (exList.isNotEmpty && exList.last.startsSuperset) {
          exList[exList.length - 1] =
              exList.last.copyWith(startsSuperset: false);
        }
        if (exList.isEmpty) continue;
        final existing = byWeekday[weekday];
        if (existing == null) {
          byWeekday[weekday] = specs.length;
          specs.add(AiDaySpec(weekday, title, exList));
        } else {
          // 同 weekday 的两个训练日合并到一天（保持"一周一天"不变量）
          final old = specs[existing];
          specs[existing] = AiDaySpec(old.weekday, old.title, [
            ...old.exercises,
            ...exList,
          ]);
        }
      }
      if (specs.isEmpty) throw const AiException('没有解析出任何训练日，请检查文本');
      return specs;
    } on AiException {
      rethrow;
    } catch (_) {
      // 字段强转的 TypeError 等统一归一，避免英文原始报错透传到 UI
      throw const AiException('AI 返回格式无法解析，请重试或换模型');
    }
  }

  /// 从教练回复文本提取计划（对话式排计划用）：复用 parseResponse 的
  /// 三层 JSON 容错与集中清洗。提取不到（AI 在问澄清、讲思路的轮次）
  /// 返回 null 而不是抛错——由 UI 决定是否挂「保存为计划」入口。
  List<AiDaySpec>? tryExtractPlan(String reply) {
    try {
      return parseResponse(reply);
    } on AiException {
      return null;
    }
  }

  // ================= JSON 三层容错（调研条目 12） =================

  /// ① 直接解析整段 → ② 剥 ```json 代码围栏 → ③ 括号配平扫描。
  /// LLM 输出裹代码围栏/夹带前后散文是最常见翻车点，三层逐级放宽；
  /// 三层都取不到合法 JSON 数组才抛 AiException。
  @visibleForTesting
  List<dynamic> extractJsonPayload(String content) {
    final text = content.trim();
    // ① 直接解析
    final direct = _decodeArray(text);
    if (direct != null) return direct;
    // ② 代码围栏（可能有多段，逐段尝试）
    for (final m in RegExp(r'```(?:json)?\s*([\s\S]*?)```').allMatches(text)) {
      final inner = _decodeArray(m.group(1)!.trim());
      if (inner != null) return inner;
    }
    // ③ 括号配平扫描：字符串感知（忽略字符串内的括号），取第一个配平的数组
    final sliced = _balancedSlice(text);
    if (sliced != null) {
      final v = _decodeArray(sliced);
      if (v != null) return v;
    }
    throw const AiException('AI 返回格式无法解析，请重试或换模型');
  }

  List<dynamic>? _decodeArray(String s) {
    if (!s.startsWith('[')) return null;
    try {
      final v = jsonDecode(s);
      return v is List ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 括号配平扫描：从第一个 `[` 起扫描，字符串（含转义）内的括号不计数，
  /// depth 归零即认为找到完整数组边界。
  String? _balancedSlice(String text) {
    final start = text.indexOf('[');
    if (start < 0) return null;
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == r'\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
      } else if (ch == '[') {
        depth++;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  // ================= 动作名六级匹配级联（调研条目 12） =================
  //
  // L1 精确英文（英文别名表，大小写/连写归一）
  // L2 精确中文（词表全名相等）
  // L3 同义词表（中文口语别名 → 规范名）
  // L4 词序无关（去标点空白后字符多重集相等：「卧推杠铃」→「杠铃卧推」）
  // L5 强包含（输入含完整词表名；反向包含保留 A3-2 的 ≥3 字门槛）
  // L6 模糊匹配（编辑距离 score<0.15 且整批确定级覆盖率 ≥0.5 才自动命中，
  //    否则给 top5 候选进预览页人工确认——workout-timer 的自动命中口径）

  /// 同义词/英文别名表（→ 词表规范名）。只收无歧义映射；「卧推」「划船」
  /// 「深蹲」「弯举」「推肩」这类泛称刻意不放——歧义交给预览页人工确认，
  /// 保持 A3-2 收紧语义（泛称不被吸到最长变体）。
  @visibleForTesting
  static const kExerciseAliases = <String, String>{
    // 中文别名
    '平板卧推': '杠铃卧推',
    '杠铃推胸': '杠铃卧推',
    '上斜卧推': '上斜杠铃卧推',
    '引体': '引体向上',
    '正手引体': '引体向上',
    '引体向上（正手）': '引体向上',
    '引体向上(正手)': '引体向上',
    '背阔肌下拉': '高位下拉',
    '倒蹬': '腿举（倒蹬机）',
    '腿举': '腿举（倒蹬机）',
    '蝴蝶机': '坐姿夹胸（蝴蝶机）',
    '蝴蝶机夹胸': '坐姿夹胸（蝴蝶机）',
    '高脚杯深蹲': '哑铃高脚杯深蹲',
    '农夫行走': '哑铃农夫行走',
    '农夫走': '哑铃农夫行走',
    '侧平举': '哑铃侧平举',
    '前平举': '哑铃前平举',
    '罗马尼亚硬拉': '罗马尼亚硬拉',
    '臀推': '杠铃臀桥',
    '仰卧起坐': '卷腹',
    '波比': '波比跳',
    '立卧撑': '波比跳',
    '登山者': '登山跑',
    '登山式': '登山跑',
    '俄罗斯旋转': '俄罗斯转体',
    '壶铃摇摆': '壶铃摆荡',
    '单臂划船': '哑铃单臂划船',
    '飞鸟': '哑铃飞鸟',
    '提踵': '站姿提踵',
    '腿弯举': '腿弯举（腘绳肌）',
    '腿屈伸': '腿屈伸（股四头）',
    '哈克蹲': '哈克深蹲',
    '保加利亚蹲': '保加利亚分腿蹲',
    // 英文别名（键统一小写）
    'bench press': '杠铃卧推',
    'incline bench press': '上斜杠铃卧推',
    'push up': '俯卧撑',
    'push-up': '俯卧撑',
    'pushup': '俯卧撑',
    'pull up': '引体向上',
    'pull-up': '引体向上',
    'pullup': '引体向上',
    'chin up': '引体向上',
    'deadlift': '杠铃硬拉',
    'overhead press': '站姿推举',
    'ohp': '站姿推举',
    'lateral raise': '哑铃侧平举',
    'lat pulldown': '高位下拉',
    'barbell row': '杠铃划船',
    'leg press': '腿举（倒蹬机）',
    'leg curl': '腿弯举（腘绳肌）',
    'leg extension': '腿屈伸（股四头）',
    'calf raise': '站姿提踵',
    'hip thrust': '杠铃臀桥',
    'goblet squat': '哑铃高脚杯深蹲',
    'farmer walk': '哑铃农夫行走',
    'farmers walk': '哑铃农夫行走',
    'burpee': '波比跳',
    'burpees': '波比跳',
    'plank': '平板支撑',
    'russian twist': '俄罗斯转体',
    'mountain climber': '登山跑',
    'mountain climbers': '登山跑',
    'kettlebell swing': '壶铃摆荡',
    'dip': '双杠臂屈伸',
    'dips': '双杠臂屈伸',
    'bulgarian split squat': '保加利亚分腿蹲',
    'rdl': '罗马尼亚硬拉',
    'crunch': '卷腹',
    'sit up': '卷腹',
    'sit-up': '卷腹',
    'situp': '卷腹',
  };

  /// 一条动作名的匹配结果。
  /// （文件内声明于 AiService 之外，见文件末尾的 ExerciseMatch 类。）

  /// 批量匹配：先逐名跑 L1-L5（确定级），用确定级命中率算整批覆盖率，
  /// 未命中的再走 L6（模糊级受覆盖率门控）。
  @visibleForTesting
  List<ExerciseMatch> matchExerciseNames(List<String> raws) {
    final base = <ExerciseMatch?>[
      for (final raw in raws) _matchLevel1to5(raw),
    ];
    final determined = base.whereType<ExerciseMatch>().length;
    final coverage = raws.isEmpty ? 0.0 : determined / raws.length;
    return [
      for (var i = 0; i < raws.length; i++)
        base[i] ?? _fuzzyMatch(raws[i], coverage),
    ];
  }

  ExerciseMatch _hit(String name, int level) => ExerciseMatch(
        name: name,
        level: level,
        needsConfirm: false,
        candidates: const [],
        score: 0,
      );

  ExerciseMatch? _matchLevel1to5(String raw) {
    final key = raw.trim();
    if (key.isEmpty) return null;
    final lower = key.toLowerCase();
    final alias = kExerciseAliases[lower] ?? kExerciseAliases[key];
    if (alias != null) {
      // 纯 ASCII 视为 L1（英文精确），否则 L3（同义词表）
      return _hit(alias, RegExp(r'^[a-z0-9\s\-+()]+$').hasMatch(lower) ? 1 : 3);
    }
    for (final m in _sortedMeta) {
      if (m.name == key) return _hit(m.name, 2);
    }
    // L4 词序无关：去标点/空白后字符多重集相等
    final norm = _stripForOrder(key);
    if (norm.length >= 2) {
      for (final m in _sortedMeta) {
        if (_sameCharMultiset(norm, _stripForOrder(m.name))) {
          return _hit(m.name, 4);
        }
      }
    }
    // L5 强包含：输入含完整词表名（含变体注记），或词表核心名含输入
    // （≥3 字门槛，A3-2 收紧语义：泛称不落成长变体）
    ExerciseMeta? best;
    var bestDiff = -1;
    for (final m in _sortedMeta) {
      final core = m.name.replaceAll(RegExp(r'[（(].*[)）]'), '');
      final hit = key.contains(core) ||
          (core.contains(key) && key.length >= 3);
      if (!hit) continue;
      final diff = (core.length - key.length).abs();
      if (best == null || diff < bestDiff) {
        best = m;
        bestDiff = diff;
      }
    }
    if (best != null) return _hit(best.name, 5);
    return null;
  }

  ExerciseMatch _fuzzyMatch(String raw, double coverage) {
    final key = raw.trim();
    final scored = <(String, double)>[];
    for (final m in _sortedMeta) {
      final a = _stripForOrder(key);
      final b = _stripForOrder(m.name);
      final d = a.isEmpty ? b.length : _levenshtein(a, b);
      scored.add((m.name, d / (a.isEmpty ? 1 : a.length)));
    }
    scored.sort((x, y) => x.$2.compareTo(y.$2));
    final top = scored.take(5).map((e) => e.$1).toList();
    final bestScore = scored.isEmpty ? 1.0 : scored.first.$2;
    if (bestScore < 0.15 && coverage >= 0.5) {
      return ExerciseMatch(
        name: scored.first.$1,
        level: 6,
        needsConfirm: false,
        candidates: const [],
        score: bestScore,
      );
    }
    return ExerciseMatch(
      name: key,
      level: 0,
      needsConfirm: true,
      candidates: top,
      score: bestScore,
    );
  }

  /// 词序无关比较用的归一：去空白与中英文标点。
  String _stripForOrder(String s) =>
      s.replaceAll(RegExp(r'[\s，。、,.\-—（）()\[\]【】/×xX·:：]'), '');

  bool _sameCharMultiset(String a, String b) {
    if (a.length != b.length) return false;
    final counts = <String, int>{};
    for (var i = 0; i < a.length; i++) {
      counts[a[i]] = (counts[a[i]] ?? 0) + 1;
      counts[b[i]] = (counts[b[i]] ?? 0) - 1;
    }
    return counts.values.every((v) => v == 0);
  }

  /// 经典 Levenshtein DP（输入都是短动作名，O(n·m) 足够）。
  int _levenshtein(String a, String b) {
    final prev = List<int>.generate(b.length + 1, (i) => i);
    final cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = [
          prev[j] + 1,
          cur[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      for (var j = 0; j <= b.length; j++) {
        prev[j] = cur[j];
      }
    }
    return prev[b.length];
  }

  /// 词表快照。长度降序仅影响同长度差的并列候选谁先命中
  /// （更具体的变体优先）；「卧推」等短泛称不再因降序被吸成长变体。
  /// 基于「内置 + 沉淀」合并集，沉淀词表更新时置 null 重建。
  List<ExerciseMeta>? _sortedMetaCache;

  List<ExerciseMeta> get _sortedMeta => _sortedMetaCache ??=([
        ...mergedLibrary,
      ]..sort((a, b) => b.name.length.compareTo(a.name.length)));
}

class AiException implements Exception {
  final String message;
  const AiException(this.message);
  @override
  String toString() => message;
}

/// 一条对话消息（role: system/user/assistant，OpenAI 兼容口径）。
class AiMessage {
  final String role;
  final String content;
  const AiMessage(this.role, this.content);
}

/// AI 教练对话线程（2026-09-29 多对话支持：出差期间可在一个线程里连续
/// 安排多日训练，需要翻旧计划时切换回旧线程）。
class AiChatThread {
  AiChatThread({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  final String title;
  final int updatedAt; // epoch ms
  final List<AiMessage> messages;

  /// 标题兜底：还没发过消息的线程显示「新对话」。
  String get displayTitle =>
      title.isEmpty ? '新对话' : title;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt,
        'messages': [
          for (final m in messages) {'role': m.role, 'content': m.content},
        ],
      };

  static AiChatThread fromJson(Map<String, dynamic> j) => AiChatThread(
        id: (j['id'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
        messages: [
          for (final m in (j['messages'] as List? ?? const []))
            AiMessage((m as Map)['role'] as String? ?? 'user',
                m['content'] as String? ?? ''),
        ],
      );
}

/// 解析持久化的线程数组（Settings.aiChatHistoryJson）。
/// **兼容旧格式**：2026-09-29 之前是单会话平面数组
/// `[{'role':..,'content':..},..]`——检测到旧格式自动包成一个「历史对话」
/// 线程（id 固定 legacy），老用户无感迁移；解码异常整体丢弃返回空。
List<AiChatThread> parseAiChatThreads(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    if (decoded.isEmpty) return const [];
    final first = decoded.first;
    if (first is Map && first.containsKey('messages')) {
      // 新格式：线程数组
      return [
        for (final t in decoded)
          AiChatThread.fromJson(Map<String, dynamic>.from(t as Map)),
      ];
    }
    // 旧格式：平面消息数组 → 包成一个线程
    final msgs = [
      for (final m in decoded)
        if (m is Map)
          AiMessage(m['role'] as String? ?? 'user', m['content'] as String? ?? ''),
    ];
    if (msgs.isEmpty) return const [];
    return [
      AiChatThread(
        id: 'legacy',
        title: _threadTitleOf(msgs),
        updatedAt: 0,
        messages: msgs,
      ),
    ];
  } catch (_) {
    return const [];
  }
}

/// 由首条用户消息生成线程标题（前 16 字，去换行）。
String _threadTitleOf(List<AiMessage> msgs) {
  for (final m in msgs) {
    if (m.role == 'user' && m.content.trim().isNotEmpty) {
      final t = m.content.trim().replaceAll('\n', ' ');
      return t.length > 16 ? t.substring(0, 16) : t;
    }
  }
  return '';
}

/// 线程序列化（写回 Settings.aiChatHistoryJson）：
/// 按 updatedAt 降序保留最近 [maxThreads] 个（LRU 淘汰）。
String encodeAiChatThreads(List<AiChatThread> threads, {int maxThreads = 20}) {
  final sorted = [...threads]
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return jsonEncode([
    for (final t in sorted.take(maxThreads)) t.toJson(),
  ]);
}

/// 一条动作名的匹配结果（六级级联，见 matchExerciseNames 注释）。
class ExerciseMatch {
  final String name;
  final int level; // 1..6 = 命中级；0 = 未自动命中（保留原名待确认）
  final bool needsConfirm;
  final List<String> candidates; // top5（按编辑距离升序）
  final double score; // 编辑距离率（越小越像）

  const ExerciseMatch({
    required this.name,
    required this.level,
    required this.needsConfirm,
    required this.candidates,
    required this.score,
  });
}

/// 智能建议（免费、本地规则生成，不调 AI）：
/// 基于近几次数据的异常提示，用于数据页展示，也拼进 AI 分析包。
List<String> localInsights(Map<String, List<SetEntry>> setsByName) {
  final out = <String>[];
  setsByName.forEach((name, sets) {
    final daily = dailyBest1Rm(sets.where((s) => s.kind == SetKind.working).toList());
    if (daily.length >= 2) {
      final last = daily.last;
      final prev = daily[daily.length - 2];
      if (last < prev * 0.9) {
        out.add('$name 最近表现比上次下降超过 10%，考虑是否休息不足或动作变形');
      }
    }
    if (daily.length >= 4) {
      final window = daily.sublist(daily.length - 4);
      if (window.last <= window.first && window.every((v) => v <= window.first * 1.01)) {
        out.add('$name 连续 3 次未进步，建议检查组间休息时长与睡眠恢复');
      }
    }
  });
  return out;
}

/// 按天取最佳 1RM 序列（时间升序）。
@visibleForTesting
List<double> dailyBest1Rm(List<SetEntry> sets) {
  final byDay = <int, double>{};
  for (final s in sets) {
    final d = s.doneAt ~/ 86400000;
    final rm = estimate1RM(s.weightKg, s.reps);
    if (rm > (byDay[d] ?? 0)) byDay[d] = rm;
  }
  final keys = byDay.keys.toList()..sort();
  return keys.map((k) => byDay[k]!).toList();
}

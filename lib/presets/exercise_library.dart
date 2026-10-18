import '../engine/exercise_identity.dart' show exerciseKeyOf;
import '../models/models.dart';


/// 内置动作库：覆盖健身房（杠铃/器械）、居家（哑铃/弹力带/自重）、功能性训练。
/// equipment: gym=健身房 / home=居家 / both=皆可
/// cue: 动作要点讲解（中文，空=无）；gear: 细分器械
///      （杠铃/哑铃/龙门架绳索/固定器械/弹力带/自重/壶铃/其他器械，空=未标注）
/// 供：动作库浏览页、编辑器联想、AI 拆解提示词、计划模板。
const kExerciseLibrary = <ExerciseMeta>[
  // ============ 胸（健身房） ============
  ExerciseMeta('杠铃卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'gym', '仰卧收紧肩胛、双脚踩实，杠铃落胸口中下沿，小臂垂直地面推起至肘微屈不锁死。常见错误：肩胛松开耸肩、杠铃落点漂向脖子、双脚离地借力。', '杠铃'),
  ExerciseMeta('上斜杠铃卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'gym', '上斜凳调 30 度左右，肩胛收紧下沉，杠铃落锁骨上方一点；推起时肘部略内收不外飘。常见错误：凳子调太陡变成推肩、杠铃撞锁骨反弹借力。', '杠铃'),
  ExerciseMeta('上斜哑铃卧推', MuscleGroups(main: '胸', secondary: ['肩']), true, 'both', '背靠稳上斜凳，哑铃从胸口两侧沿弧线上推至接近相碰；下放大臂到与地面平行或略低，充分拉伸胸上沿。常见错误：肘部外飘变成肩前束主导、下放太浅。', '哑铃'),
  ExerciseMeta('哑铃卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'both', '平凳仰卧收紧肩胛，哑铃落胸口两侧中线，垂直上推，顶端不碰撞哑铃。常见错误：肩胛松开、推成夹肘窄距。', '哑铃'),
  ExerciseMeta('坐姿夹胸（蝴蝶机）', MuscleGroups(main: '胸', secondary: []), false, 'gym', '座高调到把手与胸同高，肘部微屈角度固定，靠胸肌收缩把把手向中间合拢，顶峰停一秒。常见错误：重量过大靠手臂硬掰、耸肩借力。', '固定器械'),
  ExerciseMeta('绳索夹胸', MuscleGroups(main: '胸', secondary: []), false, 'gym', '龙门架滑轮调高位或与胸同高，身体前倾站稳，肘微屈靠胸肌把绳索向身前下方夹拢。常见错误：变成屈伸手臂动作、躯干大幅摆动借力。', '龙门架绳索'),
  ExerciseMeta('双杠臂屈伸（挺胸）', MuscleGroups(main: '胸', secondary: ['手臂']), true, 'both', '双杠撑起身体后上身前倾挺胸，屈肘下降到胸口有拉伸感再推起；前倾越多越练胸，越竖直越练三头。常见错误：耸肩含胸、降得过深压肩。', '自重'),
  // ============ 胸（居家） ============
  ExerciseMeta('俯卧撑', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'home', '双手略宽于肩，从头到脚一条直线，屈肘让胸口贴近地面再推起。常见错误：塌腰撅臀、头先下探、手臂外展成 T 字加重肩部负担。', '自重'),
  ExerciseMeta('上斜俯卧撑', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'home', '手撑凳子或台阶、脚在地面，身体保持直线做俯卧撑；支撑面越高越省力，做不了平地俯卧撑时用它过渡。常见错误：塌腰、只低头胸口不降。', '自重'),
  ExerciseMeta('下斜俯卧撑（脚垫高）', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'home', '脚垫凳上、手撑地，重心前移主打胸上沿与肩前束，身体仍保持一条直线。常见错误：塌腰、头主动往下顶地。', '自重'),
  ExerciseMeta('上斜杠铃卧推（轻）', MuscleGroups(main: '胸', secondary: ['肩']), true, 'gym', '与上斜卧推同姿势，用轻重量高次数打磨动作轨迹与胸上沿发力感，离心放慢 2-3 秒。常见错误：贪快利用底部反弹、轨迹忽内忽外。', '杠铃'),
  ExerciseMeta('哑铃飞鸟', MuscleGroups(main: '胸', secondary: []), false, 'both', '平凳仰卧肘部微屈固定角度，哑铃沿弧线向两侧打开至胸口充分拉伸，再像抱一只大桶一样合拢。常见错误：肘角不断变化变成卧推、下放过深砸肩。', '哑铃'),
  ExerciseMeta('弹力带夹胸', MuscleGroups(main: '胸', secondary: []), false, 'home', '带子绕过上背或固定在身后等高点，肘部微屈角度不变，双手向前向内夹拢至胸前相触。常见错误：屈伸手臂变成手臂动作、身体后仰借力。', '弹力带'),

  // ============ 背（健身房） ============
  ExerciseMeta('引体向上', MuscleGroups(main: '背', secondary: ['手臂']), true, 'both', '正手握略宽于肩，肩胛先下沉启动，背阔发力把胸口拉向单杠，下巴过杠即可。常见错误：只用手臂拽不收肩胛、蹬腿甩身借力。', '自重'),
  ExerciseMeta('负重引体向上', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '腰间挂杠铃片或穿负重带，轨迹与自重引体一致；重量以能标准完成 5-8 次为准。常见错误：重量过大轨迹变形、离心阶段自由落体。', '自重'),
  ExerciseMeta('高位下拉', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '坐姿大腿压稳滚垫，正手宽握，肩胛下沉后靠背阔把杠拉到锁骨上方，肘部垂直向下走。常见错误：身体过度后仰变成划船、用二头拽杠。', '龙门架绳索'),
  ExerciseMeta('杠铃划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '屈髋俯身约 45 度、背部挺直，杠铃贴大腿拉向下腹，肘部贴身向后顶。常见错误：弓腰、站起来甩杠借力、拉向胸口变成肩后束动作。', '杠铃'),
  ExerciseMeta('坐姿划船', MuscleGroups(main: '背', secondary: ['手臂']), false, 'gym', '坐姿蹬稳踏板、胸椎挺直，肘贴身把把手拉向腹部，顶峰夹背一秒。常见错误：躯干大幅前后摇晃借力、耸肩。', '龙门架绳索'),
  ExerciseMeta('杠铃硬拉', MuscleGroups(main: '背', secondary: ['腿', '核心']), true, 'gym', '杠铃贴小腿，屈髋俯身握杠，背挺直胸抬高，脚跟发力把杠贴身拉起站直、臀部顶紧。常见错误：弓背起杠、杠离身体太远用腰扛、顶端过度后仰。', '杠铃'),
  ExerciseMeta('直臂下压', MuscleGroups(main: '背', secondary: []), false, 'gym', '站姿略俯身，肘部微屈固定，靠背阔把绳索从身前高位压到大腿侧面。常见错误：屈肘变成三头下压、躯干晃动。', '龙门架绳索'),
  ExerciseMeta('T杠划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '骑跨或站定俯身，胸口朝前背挺直，肘部贴身把把手拉向胸腹之间。常见错误：弓腰、用爆发力甩起。', '杠铃'),
  // ============ 背（居家） ============
  ExerciseMeta('哑铃单臂划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'both', '一手一脚撑凳、背与地面平行，哑铃贴身拉向髋部，肘贴肋走。常见错误：扭转躯干借力、拉向胸口变成肩后束动作。', '哑铃'),
  ExerciseMeta('弹力带下拉', MuscleGroups(main: '背', secondary: ['手臂']), true, 'home', '带子固定在高处（门锚或单杠），跪姿或坐姿，肩胛下沉把带子拉到锁骨位置，模拟高位下拉。常见错误：身体后仰、只屈肘不收背。', '弹力带'),
  ExerciseMeta('弹力带坐姿划船', MuscleGroups(main: '背', secondary: ['手臂']), false, 'home', '带子绕住脚掌、双腿伸直坐地，胸口挺直把带子拉向腹部，肘贴身。常见错误：弓背、躯干大幅摇摆。', '弹力带'),
  ExerciseMeta('超人式', MuscleGroups(main: '背', secondary: ['核心']), false, 'home', '俯卧手脚同时抬离地面，下背与臀部收缩，顶点停 1-2 秒再缓慢放下。常见错误：抬头过猛挤压颈椎、抬得过高靠腰弹。', '自重'),
  ExerciseMeta('反向雪天使', MuscleGroups(main: '背', secondary: ['肩']), false, 'home', '俯卧额头轻点地，双臂贴身两侧掌心朝上，沿地面滑动画半圆举过头顶成 Y 字再滑回，手臂全程不离地。常见错误：耸肩、手臂飞离地面变成别的动作。', '自重'),

  // ============ 肩（健身房） ============
  ExerciseMeta('站姿推举', MuscleGroups(main: '肩', secondary: ['手臂', '核心']), true, 'gym', '杠铃从锁骨位起，核心臀腿绷紧，垂直向上推过头顶至杠在耳侧，头微后让杠走直线。常见错误：过度挺腰、杠绕大弧离脸太远、全程憋气。', '杠铃'),
  ExerciseMeta('坐姿哑铃推举', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'both', '坐姿背靠凳，哑铃举在耳侧、肘略前于躯干，向上推至接近相碰。常见错误：腰背离凳形成拱桥、推到头顶偏后位置。', '哑铃'),
  ExerciseMeta('史密斯机推肩', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'gym', '坐在史密斯机下，杠落在下巴前方，沿轨道垂直上推；轨道已固定平衡，更要主动控制离心速度。常见错误：身体往前躲杠、底部弹射。', '固定器械'),
  ExerciseMeta('哑铃侧平举', MuscleGroups(main: '肩', secondary: []), false, 'both', '双臂垂于身侧微屈肘，肩中束发力把哑铃向两侧抬至与肩同高，肘腕手基本一个平面。常见错误：耸肩变上提、甩动借力、抬得过高。', '哑铃'),
  ExerciseMeta('俯身飞鸟（后束）', MuscleGroups(main: '肩', secondary: ['背']), false, 'both', '屈髋俯身上背接近水平，肘微屈，靠肩后束把哑铃向两侧展开、拇指朝下。常见错误：身体一点点站起来、用背阔划船代偿。', '哑铃'),
  ExerciseMeta('面拉', MuscleGroups(main: '肩', secondary: ['背']), false, 'gym', '绳索调到与脸同高，双手对握向后拉至眉心并外旋，大小臂各成 L 形，顶峰停一秒。常见错误：拉向胸口、耸肩。', '龙门架绳索'),
  ExerciseMeta('哑铃前平举', MuscleGroups(main: '肩', secondary: []), false, 'both', '肘微屈，肩前束把哑铃沿体前抬至与肩同高，左右可交替。常见错误：甩腰借力、抬过头顶。', '哑铃'),
  ExerciseMeta('杠铃耸肩', MuscleGroups(main: '肩', secondary: []), false, 'gym', '双臂伸直握杠，肩峰垂直向上耸向耳朵方向，顶点停一秒再缓慢下放。常见错误：绕环转肩（伤肩）、弯肘硬拽。', '杠铃'),
  // ============ 肩（居家） ============
  ExerciseMeta('弹力带侧平举', MuscleGroups(main: '肩', secondary: []), false, 'home', '脚踩住带子，同哑铃侧平举轨迹外展至肩平；带子张力越到顶端越大，回放要慢。常见错误：身体侧倾借力、耸肩。', '弹力带'),
  ExerciseMeta('派克俯卧撑', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'home', '身体折成倒 V、臀部高抬，头朝地面方向下降到头顶接近地面再推起，主打肩前束与肩袖稳定。常见错误：胸口下压变成普通俯卧撑、肘外飘。', '自重'),
  ExerciseMeta('弹力带面拉', MuscleGroups(main: '肩', secondary: ['背']), false, 'home', '带子固定在与脸同高，对握向后拉至眉心并外旋，大小臂成双 L；肩袖热身与改善圆肩的利器。常见错误：阻力太大导致耸肩、只后拉不做外旋。', '弹力带'),

  // ============ 手臂 ============
  ExerciseMeta('杠铃弯举', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '肘贴身固定，肱二头收缩把杠弯举至肩前，离心阶段放慢。常见错误：腰部摆动甩杠、肘部前移变成推、行程减半。', '杠铃'),
  ExerciseMeta('哑铃锤式弯举', MuscleGroups(main: '手臂', secondary: []), false, 'both', '掌心相对对握哑铃，肘固定沿体侧把哑铃举至胸前，主打肱肌与前臂。常见错误：晃身借力、手腕弯折。', '哑铃'),
  ExerciseMeta('哑铃弯举', MuscleGroups(main: '手臂', secondary: []), false, 'both', '掌心向前旋后握，肘贴身把哑铃举至肩前，顶端刻意挤压二头。常见错误：肘部前后漂移、靠甩动起铃。', '哑铃'),
  ExerciseMeta('绳索下压', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '肘贴身固定，三头收缩把绳索下压至手臂完全伸直，顶端可外旋双手分绳加深挤压。常见错误：肘部外张、身体下压借力。', '龙门架绳索'),
  ExerciseMeta('哑铃颈后臂屈伸', MuscleGroups(main: '手臂', secondary: []), false, 'both', '双手托一只哑铃举过头顶，肘朝前固定，屈肘让哑铃向颈后下放至三头充分拉伸再伸直。常见错误：肘外张、弓腰、下放过猛。', '哑铃'),
  ExerciseMeta('窄距卧推', MuscleGroups(main: '手臂', secondary: ['胸']), true, 'gym', '握距与肩同宽或略窄，杠铃落胸口中线偏下，肘贴身推起主打三头。常见错误：握太窄压腕、肘外飘变成普通卧推。', '杠铃'),
  ExerciseMeta('弹力带弯举', MuscleGroups(main: '手臂', secondary: []), false, 'home', '双脚踩住带子，沿杠铃弯举轨迹弯举；顶端张力最大，回放要慢。常见错误：身体后仰、肘部前移。', '弹力带'),
  ExerciseMeta('凳上臂屈伸', MuscleGroups(main: '手臂', secondary: []), false, 'home', '双手撑凳背对前方，肘向后屈至约 90 度再推起，腿伸直或搭另一凳加难。常见错误：肩耸起、臀部离凳太远肩部受压。', '自重'),
  ExerciseMeta('双杠臂屈伸', MuscleGroups(main: '手臂', secondary: ['胸']), true, 'both', '身体竖直撑双杠，肘贴身后屈至约 90 度再推起，主打三头。常见错误：身体前倾过多变成练胸、下降过猛。', '自重'),
  ExerciseMeta('负重双杠臂屈伸', MuscleGroups(main: '手臂', secondary: ['胸']), true, 'gym', '腰间挂杠铃片或穿负重带，双杠撑起后屈肘下降到约 90 度再推起；重量以能标准完成 5-8 次为准。常见错误：重量过大下降过深压肩、靠身体摆荡借力。', '自重'),

  // ============ 腿（健身房） ============
  ExerciseMeta('杠铃深蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '杠压上背斜方肌，核心绷紧屈髋屈膝下蹲至大腿平行或更低，膝盖与脚尖同向，脚跟发力站起。常见错误：膝内扣、弓腰、重心跑到脚尖。', '杠铃'),
  ExerciseMeta('腿举（倒蹬机）', MuscleGroups(main: '腿', secondary: []), true, 'gym', '背臀贴稳靠垫，双脚与肩同宽踩踏板，屈膝降到约 90 度再蹬起，顶端不锁死。常见错误：腰部离开靠垫、膝内扣、下放过深。', '固定器械'),
  ExerciseMeta('保加利亚分腿蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'both', '后脚背搭凳、前脚向前站出足够距离，垂直下蹲至前腿大腿平行，重心压在前腿。常见错误：重心后坐、前膝内扣、躯干过度前倾。', '哑铃'),
  ExerciseMeta('哈克深蹲', MuscleGroups(main: '腿', secondary: []), true, 'gym', '背靠稳哈克机靠垫、肩托抵住斜方肌，沿轨道下蹲再站起；对下背友好、容易上强度。常见错误：脚位太靠前、顶端锁死弹跳。', '固定器械'),
  ExerciseMeta('罗马尼亚硬拉', MuscleGroups(main: '腿', secondary: ['背', '核心']), true, 'gym', '站直微屈膝，屈髋俯身让杠贴大腿下放至腘绳肌绷紧，再伸髋站起，杠全程贴近身体。常见错误：蹲式下蹲、杠离腿太远、弓背。', '杠铃'),
  ExerciseMeta('哑铃罗马尼亚硬拉', MuscleGroups(main: '腿', secondary: ['背']), true, 'both', '双哑铃贴大腿前侧，屈髋俯身至腘绳肌有明显拉伸感，背全程平直。常见错误：哑铃飘离身体、起身时用腰折断。', '哑铃'),
  ExerciseMeta('腿屈伸（股四头）', MuscleGroups(main: '腿', secondary: []), false, 'gym', '坐姿脚踝勾住滚筒，股四头收缩把小腿踢至伸直，顶峰停一秒缓慢回放。常见错误：靠惯性甩起、臀部离座。', '固定器械'),
  ExerciseMeta('腿弯举（腘绳肌）', MuscleGroups(main: '腿', secondary: []), false, 'gym', '俯卧脚踝压住滚筒，腘绳肌收缩把小腿向臀部弯起，慢速回放。常见错误：抬臀借力、幅度减半。', '固定器械'),
  ExerciseMeta('站姿提踵', MuscleGroups(main: '腿', secondary: []), false, 'both', '前脚掌踩台阶、脚跟悬空，小腿收缩把脚跟顶到最高点停一秒，再下放到拉伸位。常见错误：弹跳式快做、行程不足。', '自重'),
  ExerciseMeta('杠铃臀桥', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '仰卧、杠铃垫毛巾压在髋部，臀发力把髋顶至肩髋膝一条线，顶峰夹臀 1-2 秒。常见错误：过度挺腰代替臀发力、腘绳代偿。', '杠铃'),
  // ============ 腿（居家） ============
  ExerciseMeta('徒手深蹲', MuscleGroups(main: '腿', secondary: []), true, 'home', '双脚与肩同宽，屈髋屈膝下蹲至大腿平行，双臂前平举配重；新手打底动作。常见错误：膝内扣、脚跟离地、弓腰。', '自重'),
  ExerciseMeta('哑铃高脚杯深蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'both', '双手捧哑铃于胸前、肘部内收，下蹲至肘能触大腿内侧；前置负重帮你保持躯干直立。常见错误：哑铃飘离身体、脚跟离地。', '哑铃'),
  ExerciseMeta('箭步蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'home', '一腿向前跨步下蹲至双膝约 90 度，前腿发力站回，可原地亦可行走。常见错误：前膝超脚尖过多、躯干歪斜、后膝砸地。', '自重'),
  ExerciseMeta('臀桥', MuscleGroups(main: '腿', secondary: ['核心']), false, 'home', '仰卧屈膝双脚踩实，臀发力把髋顶至肩髋膝一线，顶峰夹紧。常见错误：用腰腹顶得过高、脚位放得太远。', '自重'),
  ExerciseMeta('单腿臀桥', MuscleGroups(main: '腿', secondary: ['核心']), false, 'home', '一腿伸直悬空，另一腿单独完成臀桥，两侧对称着练。常见错误：骨盆倾斜、靠腰部扭动补幅度。', '自重'),
  ExerciseMeta('靠墙静蹲', MuscleGroups(main: '腿', secondary: []), false, 'home', '背贴墙滑至大腿平行地面、膝约 90 度静持，膝盖方向与脚尖一致。常见错误：双手撑大腿借力、大腿没蹲到位。', '自重'),

  // ============ 核心 ============
  ExerciseMeta('平板支撑', MuscleGroups(main: '核心', secondary: []), false, 'home', '肘撑与肩同宽，从头到脚一条直线，核心臀腿同时收紧、保持呼吸。常见错误：塌腰、撅臀、抬头。', '自重'),
  ExerciseMeta('侧平板支撑', MuscleGroups(main: '核心', secondary: []), false, 'home', '侧撑、肘在肩正下方，髋抬起至全身一条线，两侧都要练。常见错误：髋部下沉、身体前后倾倒。', '自重'),
  ExerciseMeta('卷腹', MuscleGroups(main: '核心', secondary: []), false, 'home', '仰卧屈膝、下背贴地，腹肌收缩把肩胛骨带离地面即可，不需要坐起。常见错误：抱头猛拽颈椎、靠惯性甩起。', '自重'),
  ExerciseMeta('悬垂举腿', MuscleGroups(main: '核心', secondary: ['手臂']), false, 'gym', '悬挂在单杠上身体稳定，下腹发力抬腿（屈膝起步、进阶直腿），慢放防摆荡。常见错误：靠摆荡甩腿、幅度只做一半。', '自重'),
  ExerciseMeta('俄罗斯转体', MuscleGroups(main: '核心', secondary: []), false, 'home', '坐姿后仰约 45 度、脚可离地，胸椎带动左右转体，目光随手走。常见错误：只有手臂在晃、塌腰。', '自重'),
  ExerciseMeta('健腹轮', MuscleGroups(main: '核心', secondary: ['手臂']), false, 'both', '跪姿核心收紧，向前滚轮至能控制的极限再拉回，腹部全程绷住不塌腰。常见错误：滚太远腰塌、靠肩膀硬拉回来。', '其他器械'),

  // ============ 功能性训练 ============
  ExerciseMeta('壶铃摆荡', MuscleGroups(main: '腿', secondary: ['背', '核心']), true, 'both', '髋部后坐铰链，爆发式伸髋把壶铃荡至胸口高度，手臂只是绳索不主动上抬。常见错误：用腰甩、蹲起代替伸髋、荡过头顶变肩推。', '壶铃'),
  ExerciseMeta('哑铃农夫行走', MuscleGroups(main: '核心', secondary: ['手臂', '肩']), true, 'both', '双手持哑铃垂于体侧，肩胛稳定、核心收紧，小步稳定行走；握力核心一起练。常见错误：耸肩、身体侧倾、拖脚走。', '哑铃'),
  ExerciseMeta('箱跳', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '双脚跳上稳固跳箱，落地轻、全脚掌站稳后走下来，不要跳下。常见错误：箱高贪多、落地膝内扣、跳下震膝。', '自重'),
  ExerciseMeta('深蹲跳', MuscleGroups(main: '腿', secondary: ['核心']), true, 'home', '下蹲至半蹲位，爆发式跳起，落地屈膝缓冲顺势接下一次。常见错误：落地僵硬、膝内扣。', '自重'),
  ExerciseMeta('波比跳', MuscleGroups(main: '核心', secondary: ['胸', '腿']), true, 'home', '下蹲撑地、双腿后蹬成俯卧撑、收腿起身垂直跳；全身心肺利器，稳住节奏别追速度。常见错误：俯卧撑段塌腰、落地重击关节。', '自重'),
  ExerciseMeta('登山跑', MuscleGroups(main: '核心', secondary: ['腿']), false, 'home', '俯撑姿势肩在手腕正上方，双腿交替快速提膝向胸口，髋部保持稳定不上下弹。常见错误：臀部抬过高、手腕后移肩压过大。', '自重'),
  ExerciseMeta('熊爬', MuscleGroups(main: '核心', secondary: ['肩', '腿']), true, 'home', '四肢撑地、膝盖离地约三厘米，对侧手脚同步前行，背部保持水平。常见错误：臀部抬太高、膝盖触地。', '自重'),
  ExerciseMeta('死虫式', MuscleGroups(main: '核心', secondary: []), false, 'home', '仰卧下背贴地，对侧手脚同时缓慢伸展至接近地面再收回，腰部全程不离地。常见错误：腰部拱起、动作太快失去控制。', '自重'),
  ExerciseMeta('鸟狗式', MuscleGroups(main: '核心', secondary: ['背']), false, 'home', '四点跪姿，对侧手脚同时伸展至与躯干一条线停 2 秒收回，练核心抗旋转。常见错误：腰塌、髋部翻转、手脚抬得过高。', '自重'),
  ExerciseMeta('哑铃单腿硬拉', MuscleGroups(main: '腿', secondary: ['核心']), true, 'both', '单腿站立微屈膝，另一腿向后伸，屈髋俯身至站立侧腘绳肌拉伸，臀部发力回正。常见错误：髋部转动、用腰折断起身。', '哑铃'),
  ExerciseMeta('药球砸地', MuscleGroups(main: '核心', secondary: ['背', '肩']), true, 'gym', '双手举药球过头顶，核心发力把球向正前方地面猛砸，顺势屈髋跟随。常见错误：只用手臂扔、砸向侧方危险。', '其他器械'),
  ExerciseMeta('战绳（双甩）', MuscleGroups(main: '核心', secondary: ['肩', '手臂']), true, 'gym', '半蹲位核心稳定，双臂同时把战绳上下猛甩出连续波浪，保持呼吸节奏。常见错误：直立伸膝只用手臂、节奏忽快忽慢。', '其他器械'),
  ExerciseMeta('弹力带伐木', MuscleGroups(main: '核心', secondary: ['肩']), true, 'home', '带子固定在体侧高位或低位，双手持带从肩上方斜向对侧髋发力拉，躯干旋转带动手臂。常见错误：只用手臂拉、膝盖跟着拧。', '弹力带'),
  ExerciseMeta('雪橇推', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '俯身前倾成斜线推雪橇，小步快走、全脚掌蹬地。常见错误：直立推不动、步子迈太大。', '其他器械'),
  ExerciseMeta('土耳其起立', MuscleGroups(main: '核心', secondary: ['肩', '手臂']), true, 'both', '仰卧单臂举壶铃锁定，同侧屈膝、翻身用肘撑起、跪起再站起，全程盯住壶铃、手臂保持锁直。动作复杂，先徒手练熟再加重量。常见错误：壶铃偏离垂直线、弓腰起身。', '壶铃'),

  // ============ 补库新增（2026-09，wger/free-exercise-db/训练体系常识） ============
  // —— 胸 ——
  ExerciseMeta('哑铃仰卧上拉', MuscleGroups(main: '胸', secondary: ['背']), false, 'both',
      '上背横躺平凳、双脚踩实，双手托一只哑铃一端举在胸口上方；肘部微屈并全程保持角度不变，靠胸和背阔把哑铃沿弧线向头后下放至感到拉伸，再沿原弧线收回。常见错误：肘角越拉越大变成三头臂屈伸，以及下放过深拉伤肩关节。',
      '哑铃'),
  // —— 背 ——
  ExerciseMeta('山羊挺身', MuscleGroups(main: '背', secondary: ['腿']), false, 'gym',
      '髋部贴住罗马椅垫、脚踝勾住挡板，双手抱胸；屈髋控制躯干下放至约与地面平行，靠下背和臀部把上身挺起到与腿成一条直线即止。不要刻意向后反弓腰椎，也不要靠甩动借力，全程慢而有控制。可抱杠铃片渐进加重。',
      '固定器械'),
  ExerciseMeta('反向划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'both',
      '找低单杠、架上的横杠或稳固桌子，身体从头到脚绷成一条直线、脚跟撑地，握距略宽于肩；肩胛先收紧下沉，再屈肘把胸口拉向横杆、顶点停一秒。常见错误：塌腰撅臀、用脖子够杠或只用手臂拽而不收肩胛。把杠调高即可降低难度。',
      '自重'),
  // —— 肩 ——
  ExerciseMeta('阿诺德推举', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'both',
      '坐姿背靠垫，双手各持一哑铃举在胸前、掌心朝向自己；向上推起的同时旋转手腕到掌心朝前，下落时反向旋回起点。全程肘部微收在身体前侧、小臂垂直地面，腰背贴垫不反弓。常见错误：重量贪大导致旋转做不完整、变成借力甩肩。',
      '哑铃'),
  ExerciseMeta('弹力带肩外旋', MuscleGroups(main: '肩', secondary: []), false, 'home',
      '大臂夹紧身体侧面、肘弯 90 度，握弹力带一端，前臂向外旋开像开门；带子向内拉时保持肘部始终不离身侧。肩袖小肌群保养动作，重量要轻、次数可到 15-20 次。常见错误：肘部外飘、躯干跟着旋转代偿。',
      '弹力带'),
  ExerciseMeta('蝴蝶机反向飞鸟（后束）', MuscleGroups(main: '肩', secondary: ['背']), false, 'gym',
      '坐姿胸口贴紧靠垫、肩膀下沉，双手握把手，用肘部带动手臂向侧后方展开；顶峰收缩一秒再缓慢还原，全程重量可控不甩动。常见错误：耸肩让斜方肌代偿、幅度过大靠惯性甩。',
      '固定器械'),
  // —— 手臂 ——
  ExerciseMeta('牧师凳弯举', MuscleGroups(main: '手臂', secondary: []), false, 'gym',
      '上臂与腋下贴紧斜垫、肘部固定在垫上，只有小臂做弯举；顶峰稍停，再缓慢放到底感受拉伸，肘部微屈不停留泄力。凳子角度让二头在底部拉伸最充分。常见错误：耸肩、肘部抬离垫面借力甩起。',
      '固定器械'),
  // —— 腿 ——
  ExerciseMeta('登阶', MuscleGroups(main: '腿', secondary: ['核心']), true, 'both',
      '找膝高左右的凳子或台阶，全脚掌踩实后靠前腿的臀和大腿把身体蹬上去，后腿轻点即收、不借力；下落时由前腿控制慢放。常见错误：上身前倾过多，或后腿猛蹬抢走前腿的刺激。可双手持哑铃加重。',
      '自重'),
  ExerciseMeta('坐姿提踵', MuscleGroups(main: '腿', secondary: []), false, 'gym',
      '屈膝约 90 度坐在提踵器上，前脚掌踩踏板、膝盖压住固定垫；脚跟下放到底让小腿充分拉伸，再踮起到最高点顶峰停 1-2 秒。屈膝姿势练的是深层比目鱼肌。常见错误：幅度太小只在中段蹭、靠惯性上下颠。',
      '固定器械'),
  ExerciseMeta('北欧腿弯举', MuscleGroups(main: '腿', secondary: []), false, 'home',
      '跪姿、脚踝被人或沙发压住固定，髋到肩保持一条直线慢慢前倒；只用腘绳肌把自己拉回来，初期可以双手轻推地面减负。下放得越慢价值越大。常见错误：塌腰撅臀着倒下去、上来就追全程——先做半程或加弹力带辅助。',
      '自重'),
  ExerciseMeta('颈前深蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym',
      '杠铃压在锁骨与三角肌前束上，手肘抬高朝前接近与地面平行，核心收紧、躯干保持垂直下蹲到大腿平行或更低。常见错误：手肘下垂导致杠铃前滚、躯干前倾；手腕或肩灵活度不足时先用高脚杯深蹲过渡。',
      '杠铃'),
  ExerciseMeta('杠铃臀推', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym',
      '肩胛下缘靠住训练凳，杠铃加垫压在髋部，双脚踩实地面；脚跟发力把髋顶到肩、髋、膝成一条直线，顶峰收紧臀肌 1-2 秒再控制下放。常见错误：顶端过度塌腰（腰椎超伸）、靠惯性弹起。',
      '杠铃'),
  // —— 核心 ——
  ExerciseMeta('绳索卷腹', MuscleGroups(main: '核心', secondary: []), false, 'gym',
      '面对高位滑轮跪地，绳索把手握在头两侧、髋部保持固定；用腹肌把肋骨向骨盆方向卷下来、肘部朝膝盖方向走，背部拱起才算卷到位。常见错误：整个上身像鞠躬一样平着俯下去——那是髋在动，不是腹肌在卷。',
      '龙门架绳索'),
  ExerciseMeta('帕洛夫推举', MuscleGroups(main: '核心', secondary: ['肩']), false, 'gym',
      '侧身站在龙门架滑轮（居家可用弹力带锚点替代）旁，双手把拉到胸前的把手稳住，先感受侧腹的抗旋转张力；呼气把双臂向前推直、停 2-3 秒再缓慢收回，两侧都做。常见错误：被重量带着转腰、推出时憋气塌腰。',
      '龙门架绳索'),
  ExerciseMeta('反向卷腹', MuscleGroups(main: '核心', secondary: []), false, 'home',
      '仰卧屈膝、下背贴地，靠下腹把骨盆向肋骨方向卷起、膝盖向胸口收，而不是用腿甩；下放要缓慢，腰部始终不离开地面。常见错误：靠大腿摆动借力，动作变成抬腿而非骨盆卷起。',
      '自重'),
  ExerciseMeta('哑铃侧屈', MuscleGroups(main: '核心', secondary: []), false, 'both',
      '单手握哑铃站直，另一手扶头，向握铃一侧屈体，再靠对侧腹斜肌把身体拉直，全程骨盆稳定；身体只做侧向折叠，不前倾不后仰。常见错误：低头含胸用惯性晃动、重量太大变成耸肩。',
      '哑铃'),

  // ============ 补库第二弹（2026-09-27，wger 动作库肌群映射事实精选） ============
  // 肌群归属/器械分类参考 wger exercise database（CC BY-SA 数据的事实性映射），
  // 名称与讲解为本项目中文名。重点补器械与绳索类常见动作的空缺。
  // —— 胸 ——
  ExerciseMeta('坐姿推胸（推胸机）', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'gym', '座高调到把手与胸中部同高，背贴稳靠垫，水平向前推至手臂伸展不锁死，缓慢回放。常见错误：座椅太高变成推肩、肩膀前探离垫。', '固定器械'),
  ExerciseMeta('史密斯机卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'gym', '肩胛收紧仰卧，杠沿轨道落胸口中线，推起不锁死；轨道稳定适合安全冲重量。常见错误：依赖轨道失去收紧、底部反弹。', '杠铃'),
  ExerciseMeta('哑铃地板卧推', MuscleGroups(main: '胸', secondary: ['手臂']), true, 'both', '坐地面后仰持哑铃，屈肘让大臂贴地停一秒再推起；行程受限对肩友好、顶峰挤压明显。常见错误：手肘砸地、腰部拱起。', '哑铃'),
  // —— 背 ——
  ExerciseMeta('器械划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '坐姿胸抵住垫子，肘贴身向后拉至把手到腹部，顶峰夹背。常见错误：躯干后仰借力、耸肩。', '固定器械'),
  ExerciseMeta('单臂绳索划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '单手握把手，肩胛先收缩再屈肘，把把手拉向髋侧，躯干稳定不旋转。常见错误：转腰甩重量、拉向胸口。', '龙门架绳索'),
  ExerciseMeta('引体向上（反手）', MuscleGroups(main: '背', secondary: ['手臂']), true, 'both', '反握与肩同宽，肱二头参与更多，下巴过杠即可，其余要领同正握引体。常见错误：半程、蹬腿借力。', '自重'),
  // —— 肩 ——
  ExerciseMeta('绳索侧平举', MuscleGroups(main: '肩', secondary: []), false, 'gym', '滑轮调低，单手越过身体抓对侧把手向外展开至肩平，全程张力不断。常见错误：站姿不稳、耸肩。', '龙门架绳索'),
  ExerciseMeta('哑铃耸肩', MuscleGroups(main: '肩', secondary: []), false, 'both', '双哑铃垂于体侧，垂直耸肩至最高点停一秒；比杠铃行程更长更自由。常见错误：绕环转肩、弯臂硬拽。', '哑铃'),
  // —— 手臂 ——
  ExerciseMeta('曲杠弯举（EZ杠）', MuscleGroups(main: '手臂', secondary: []), false, 'gym', 'EZ 杠握槽让手腕更自然，肘贴身弯举至肩前；手腕压力大者优先选它。常见错误：摆腰甩杠。', '杠铃'),
  ExerciseMeta('上斜哑铃弯举', MuscleGroups(main: '手臂', secondary: []), false, 'both', '靠在上斜凳上手臂垂向后方，二头从拉伸位开始弯举，顶端充分挤压。常见错误：肘往前送、肩部代偿。', '哑铃'),
  ExerciseMeta('绳索过顶臂屈伸', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '背对高位滑轮、绳索举过头顶，肘朝前固定，三头发力把绳向前下方压至伸直。常见错误：肘外张、身体前趴压重量。', '龙门架绳索'),
  ExerciseMeta('仰卧杠铃臂屈伸', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '仰卧持杠于额头上方，上臂垂直地面固定，屈肘让杠向头顶后方下放再伸直。重量务必保守，保护到位再做。常见错误：上臂跟着摆、杠往脸的方向飘。', '杠铃'),
  ExerciseMeta('弹力带过顶臂屈伸', MuscleGroups(main: '手臂', secondary: []), false, 'home', '带子一端踩住或固定在身后低处，双手过头抓带屈肘下放至脑后，三头伸直。常见错误：肘外张、弓腰。', '弹力带'),
  // —— 腿 ——
  ExerciseMeta('相扑硬拉', MuscleGroups(main: '腿', secondary: ['背', '核心']), true, 'gym', '宽站距、脚尖略外展，双臂垂在腿内侧，髋位更低背更竖直，腿内侧与臀主导起杠；对腰更友好。常见错误：膝盖过度内扣、杠离身体。', '杠铃'),
  ExerciseMeta('史密斯机深蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '杠压斜方肌、双脚可比自由深蹲稍靠前站，沿轨道垂直下蹲再站起；平衡要求低，适合冲重量。常见错误：脚位太靠后膝盖压力大、借轨道弓腰。', '杠铃'),
  ExerciseMeta('哑铃箭步蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'both', '双手持铃垂于体侧做箭步蹲，配重降低平衡要求、更容易加量。常见错误：跨步太小挤膝、躯干前扑。', '哑铃'),
  ExerciseMeta('腿外展（外展机）', MuscleGroups(main: '腿', secondary: []), false, 'gym', '坐姿双腿贴住挡板向外展开至臀外侧充分收缩，缓慢回放。常见错误：重量过大身体后仰、用惯性弹开。', '固定器械'),
  ExerciseMeta('腿内收（内收机）', MuscleGroups(main: '腿', secondary: []), false, 'gym', '坐姿双腿挡板向内夹至大腿内侧收缩，缓慢回放。常见错误：重量过大甩腿、腰部扭转。', '固定器械'),
  ExerciseMeta('弹力带侧向走', MuscleGroups(main: '腿', secondary: []), false, 'home', '带子套在脚踝上方，半蹲位保持带子张力横向侧行，全程膝盖与脚尖同向。常见错误：站得太直、膝内扣。', '弹力带'),
  // —— 核心 / 体能 ——
  ExerciseMeta('仰卧举腿', MuscleGroups(main: '核心', secondary: ['腿']), false, 'home', '仰卧双腿并拢伸直，下腹发力把腿抬至接近垂直再缓慢下放至将触地。常见错误：腰部拱起离地、自由落体式下放。', '自重'),
  ExerciseMeta('空中蹬车', MuscleGroups(main: '核心', secondary: []), false, 'home', '仰卧对侧肘碰膝交替进行，另一腿伸直悬空，重点在转体幅度而不是卷起高度。常见错误：抱头拉颈、伸直腿放太低压腰。', '自重'),
  ExerciseMeta('跳绳', MuscleGroups(main: '腿', secondary: ['核心']), false, 'both', '手腕摇绳、前脚掌轻点小跳，膝盖微屈缓冲，节奏比跳的高度重要。常见错误：大臂抡绳、跳得过高总绊脚。', '其他器械'),

  // ============ 补库第三弹（2026-09-27 深夜，Arono 拍板从 free-exercise-db 再扩一批） ============
  // 同第二弹口径：肌群/复合单关节取 free-exercise-db（Unlicense）事实映射，
  // 名称与要点原创；全部有对应示意图（见 exercise_media.dart）。
  // —— 胸 ——
  ExerciseMeta('下斜杠铃卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'gym', '下斜凳勾住双脚固定，杠铃落胸口中下沿再沿略向后上的轨迹推起，主打胸下沿。常见错误：身体向头部方向滑动、杠铃漂向颈部。', '杠铃'),
  ExerciseMeta('哑铃上斜飞鸟', MuscleGroups(main: '胸', secondary: []), false, 'both', '上斜凳仰卧，肘部微屈角度固定，哑铃沿弧线打开至胸上沿充分拉伸再合拢。常见错误：肘角变化变成推、下放过深压肩。', '哑铃'),
  ExerciseMeta('史密斯机上斜卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'gym', '上斜姿势下沿史密斯机轨道推起，肩胛全程收紧；轨道已固定平衡，更要主动放慢离心。常见错误：臀部滑动离凳、底部借反弹。', '杠铃'),
  ExerciseMeta('绳索上斜夹胸', MuscleGroups(main: '胸', secondary: []), false, 'gym', '龙门架滑轮调低位，仰卧上斜凳，绳索从身体两侧向上向内夹拢至胸前上方。常见错误：屈肘变成推、肩胛跟着上抬。', '龙门架绳索'),
  ExerciseMeta('哑铃窄距卧推', MuscleGroups(main: '胸', secondary: ['手臂']), true, 'both', '哑铃并拢悬于胸口中线上方窄距推起，胸内侧与三头参与更多。常见错误：肘过度外展、顶端哑铃相撞失稳。', '哑铃'),
  // —— 背 ——
  ExerciseMeta('早安式', MuscleGroups(main: '背', secondary: ['腿']), true, 'gym', '杠铃压上背，屈髋俯身至上背接近平行地面再伸髋站直，腘绳与下背全程绷住。重量保守，这是练后链不是练极限。常见错误：屈膝变深蹲、弓背、贪重。', '杠铃'),
  ExerciseMeta('V把下拉', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '窄距 V 把下拉至锁骨位置，肘部贴身垂直向下，背阔下部与外侧刺激多。常见错误：身体过度后仰变成划船。', '龙门架绳索'),
  ExerciseMeta('窄距高位下拉', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '窄距把杠拉向上胸，肘沿身体两侧走，行程比宽距更长。常见错误：幅度只做一半、二头代偿。', '龙门架绳索'),
  ExerciseMeta('反握杠铃划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '俯身约 45 度反握杠铃贴身拉向下腹，对背阔下部刺激好。常见错误：弓腰、靠爆发甩杠。', '杠铃'),
  ExerciseMeta('哑铃双臂俯身划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'both', '俯身双哑铃同时拉向髋部两侧，肘贴身向后顶，顶峰夹背。常见错误：耸肩、躯干起伏借力。', '哑铃'),
  ExerciseMeta('仰卧杠铃上拉', MuscleGroups(main: '背', secondary: ['胸', '手臂']), false, 'gym', '横凳仰卧，屈臂固定角度把杠铃从头顶后方沿弧线拉回胸口上方，练背阔与胸。常见错误：肘角失控变成臂屈伸、臀部下坠。', '杠铃'),
  ExerciseMeta('反手高位下拉', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '反握与肩同宽把杠拉到锁骨上方，肱二头参与多、对新手友好。常见错误：身体后仰过度、半程。', '龙门架绳索'),
  // —— 肩 ——
  ExerciseMeta('坐姿杠铃推举', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'gym', '坐姿从锁骨位把杠推过头顶至耳侧，核心绷紧腰不塌。常见错误：过度挺腰、肘部外飘。', '杠铃'),
  ExerciseMeta('直立划船', MuscleGroups(main: '肩', secondary: ['手臂']), false, 'gym', '窄握把杠贴身拉至下颌高度，肘始终高于手；练肩中束与斜方。肩部不适者改用绳索宽握或跳过。常见错误：杠离身体、耸肩代偿、拉得过高。', '杠铃'),
  ExerciseMeta('绳索反向飞鸟', MuscleGroups(main: '肩', secondary: ['背']), false, 'gym', '龙门架两滑轮对穿，双手交叉握对侧把手反向展开，肩后束持续张力。常见错误：用背阔代偿、重量过大。', '龙门架绳索'),
  ExerciseMeta('单臂哑铃推举', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'both', '单侧哑铃推举，核心抗侧屈保持骨盆端正，两侧对称着练。常见错误：躯干歪斜借力。', '哑铃'),
  // —— 手臂 ——
  ExerciseMeta('集中弯举', MuscleGroups(main: '手臂', secondary: []), false, 'both', '坐姿肘抵大腿内侧单独弯举，另一手可扶腿稳定，顶端充分挤压二头。常见错误：甩臂借力、身体后仰。', '哑铃'),
  ExerciseMeta('反握杠铃弯举', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '掌心朝下反握杠铃弯举，练前臂伸肌与肱肌，握力短板的补课动作，重量宜轻。常见错误：贪重导致腕痛、甩杠。', '杠铃'),
  ExerciseMeta('绳索锤式弯举', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '绳索把手对握做锤式弯举，肱肌与前臂全程张力，顶端不像哑铃会失压。常见错误：肘部前移。', '龙门架绳索'),
  ExerciseMeta('V把下压', MuscleGroups(main: '手臂', secondary: []), false, 'gym', 'V 把下压至手臂完全伸直，主打三头外侧头，顶端挤压一秒。常见错误：肘外张、身体下压借力。', '龙门架绳索'),
  ExerciseMeta('仰卧哑铃臂屈伸', MuscleGroups(main: '手臂', secondary: []), false, 'both', '仰卧持哑铃于额头上方，上臂垂直固定，屈肘向头顶后方下放再伸直。常见错误：上臂跟着摆动、下放过猛。', '哑铃'),
  ExerciseMeta('哑铃后踢', MuscleGroups(main: '手臂', secondary: []), false, 'both', '俯身肘部固定向上向后踢伸三头，顶端挤压一秒慢回。常见错误：甩动借力、幅度不足。', '哑铃'),
  ExerciseMeta('上斜哑铃锤式弯举', MuscleGroups(main: '手臂', secondary: []), false, 'both', '靠在上斜凳上手臂垂向后方，对握弯举从拉伸位开始，肱肌刺激深。常见错误：肘往前送、肩部代偿。', '哑铃'),
  // —— 腿 ——
  ExerciseMeta('直腿硬拉', MuscleGroups(main: '腿', secondary: ['背']), true, 'gym', '膝盖几乎锁直微屈，屈髋让杠贴腿下放至腘绳极限再伸髋站起；比罗马尼亚硬拉膝角更严格，重量更轻。常见错误：弓背、杠离腿。', '杠铃'),
  ExerciseMeta('相扑哑铃深蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'both', '宽站距脚尖外展，双手持一只哑铃垂于体前垂直下蹲，大腿内侧与臀参与多。常见错误：膝内扣、脚跟离地。', '哑铃'),
  ExerciseMeta('杠铃箭步蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '杠铃压上背做箭步蹲，配重稳定适合渐进加重。常见错误：跨步过小挤膝、躯干前扑。', '杠铃'),
  ExerciseMeta('坐姿腿弯举', MuscleGroups(main: '腿', secondary: []), false, 'gym', '坐姿器械腿弯举，与俯卧腿弯举的髋角互补，腘绳不同段刺激。常见错误：抬臀离垫、幅度减半。', '固定器械'),
  ExerciseMeta('驴式提踵', MuscleGroups(main: '腿', secondary: []), false, 'gym', '屈髋俯身让小腿在拉伸位发力提踵，需要器械挡板或伙伴压住腰背。常见错误：弹跳式快做、行程不足。', '其他器械'),
  ExerciseMeta('箱式深蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '蹲到稳固的箱子顶面停一拍再站起，强化伸髋力量与底部信心。常见错误：坐上箱子就放松弓腰。', '其他器械'),
  // —— 核心 ——
  ExerciseMeta('仰卧起坐', MuscleGroups(main: '核心', secondary: []), false, 'home', '屈膝仰卧，腹肌发力把上半身卷起至胸口贴近大腿再缓慢回放。下背不适者改练卷腹。常见错误：抱头拽颈、脚被压死全靠髋甩。', '自重'),
  ExerciseMeta('侧卷腹', MuscleGroups(main: '核心', secondary: []), false, 'home', '仰卧屈膝倒向一侧，腹斜肌收缩把同侧肋骨拉向髋部卷起，两侧对称。常见错误：拉脖子、靠转体惯性。', '自重'),
  ExerciseMeta('健身球卷腹', MuscleGroups(main: '核心', secondary: []), false, 'both', '仰卧于健身球上做卷腹，不稳定平面额外激活核心稳定肌。常见错误：球上打滑、颈部代偿发力。', '其他器械'),
  ExerciseMeta('V字两头起', MuscleGroups(main: '核心', secondary: []), false, 'home', '上下肢同时抬起手脚相触成 V 字再缓慢下放，整个腹直肌参与。常见错误：只甩腿、下放时腰砸地。', '自重'),
  ExerciseMeta('器械卷腹', MuscleGroups(main: '核心', secondary: []), false, 'gym', '坐姿卷腹器械，胸椎发力把上身卷向骨盆方向，回放要慢。常见错误：髋部前后晃代偿、重量过大靠惯性。', '固定器械'),
  // —— 功能 ——
  ExerciseMeta('借力推', MuscleGroups(main: '肩', secondary: ['手臂', '腿']), true, 'gym', '屈膝微蹲借腿部蹬伸把杠铃一次性推过头顶，练全身爆发力；蹬伸与上推同步完成。常见错误：分成先蹲后推两段、推起时脚跟离地。', '杠铃'),
  ExerciseMeta('壶铃单臂划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'both', '俯身单手持壶铃贴身拉向髋侧，肘贴肋走。常见错误：扭转躯干借力、拉向胸口。', '壶铃'),

  // ============ 补库第四弹（2026-09-29，Arono 点名：臀腿 + 商业健身房器械） ============
  // 同前口径：肌群/复合判定参考 free-exercise-db 事实映射，名称与要点原创；
  // 全部有对应示意图（见 exercise_media.dart）。臀部动作沿用惯例归主肌群「腿」。
  // —— 腿（臀为主） ——
  ExerciseMeta('绳索髋屈伸', MuscleGroups(main: '腿', secondary: ['核心']), false, 'gym', '龙门架滑轮调最低位，背对器械双手从胯下握住绳索，屈髋俯身再伸髋把重量顶起站直，顶峰夹臀一秒；主打臀大肌与腘绳。常见错误：用腰过度超伸代替伸髋、站得离器械太远张力松掉。', '龙门架绳索'),
  ExerciseMeta('绳索单腿后踢', MuscleGroups(main: '腿', secondary: []), false, 'gym', '绳索扣在一侧脚踝，双手扶架站稳微前倾，该腿伸直向后上方踢到臀肌收紧再慢回；一侧练完换边。常见错误：踢得过高改用腰借力、支撑腿晃动。', '龙门架绳索'),
  ExerciseMeta('跪姿后踢腿', MuscleGroups(main: '腿', secondary: ['核心']), false, 'both', '四点跪姿双手撑地，保持一侧膝弯 90 度、脚跟向天花板方向上顶，顶到臀肌绷紧即停，不必追求高度。常见错误：塌腰代偿、骨盆翻转、动作过快。', '自重'),
  ExerciseMeta('弹力带髋伸展', MuscleGroups(main: '腿', secondary: []), false, 'home', '弹力带一端固定在身后低位（或踩在另一脚下），另一端套在髋部/脚踝，对抗弹力向前伸髋站直，顶端夹臀。常见错误：站立不稳、用弓腰顶行程。', '弹力带'),
  ExerciseMeta('跪姿杠铃蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '小腿贴地跪姿，杠铃压肩（在架内做、设好保护销），臀向后向下坐再蹬地顶髋回到跪直；臀大肌孤立刺激强，重量保守。常见错误：身体后仰、脚背没压实。', '杠铃'),
  // —— 腿（器械） ——
  ExerciseMeta('站姿腿弯举', MuscleGroups(main: '腿', secondary: []), false, 'gym', '站姿弯举器，挡辊压在训练腿脚跟上方，扶稳把手屈膝把脚跟勾向臀部再慢放；单侧逐腿练。常见错误：身体前倾借力、用惯性甩配重。', '固定器械'),
  ExerciseMeta('单腿腿屈伸', MuscleGroups(main: '腿', secondary: []), false, 'gym', '腿屈伸器上只放一条腿，伸直到顶停一秒再慢放，专门补两侧力量差。常见错误：臀部离座借力、配重回落弹跳。', '固定器械'),
  ExerciseMeta('倒蹬机提踵', MuscleGroups(main: '腿', secondary: []), false, 'gym', '腿举器上只把前脚掌踩在踏板下缘，膝盖伸直固定，小腿发力把踏板顶全程；斜躺角度可以上大重量。常见错误：屈膝借力、底部弹震。', '固定器械'),
  ExerciseMeta('史密斯机提踵', MuscleGroups(main: '腿', secondary: []), false, 'gym', '史密斯机杠压肩、前脚掌踩稳，脚跟下放到充分拉伸再顶起至最高；轨道固定不用管平衡，纯练小腿。常见错误：行程过短、屈膝借力。', '固定器械'),
  ExerciseMeta('框架硬拉机', MuscleGroups(main: '腿', secondary: ['背']), true, 'gym', '框架硬拉器对握把手，屈髋起始、伸髋站直到顶端夹臀；固定轨迹去掉杠铃平衡负担，适合安全上大重量练后链。常见错误：顶端塌腰超伸、下放砸配重。', '固定器械'),
  ExerciseMeta('臀腘绳挺身（GHD）', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '臀腘绳凳（GHD）固定脚踝，从跪直位缓缓俯身至接近水平，再用臀与腘绳把身体拉回；初期力量不足先做半程。常见错误：用腰椎超伸代替伸髋、下落过快。', '固定器械'),
  ExerciseMeta('反向山羊挺身', MuscleGroups(main: '腿', secondary: ['核心']), true, 'gym', '俯卧在反向挺身器上，双腿自然下垂，臀与腘绳发力把两腿向后上方摆到与身体成一线再慢回；对下背压力小、练后链好。常见错误：顶端塌腰、靠惯性甩腿。', '固定器械'),
  // —— 背（器械） ——
  ExerciseMeta('俯卧T杠划船', MuscleGroups(main: '背', secondary: ['手臂']), true, 'gym', '胸腹俯卧在 T 杠划船凳上，双臂把把手拉向胸口，顶端肩胛充分收拢；躯干被固定无法借力。常见错误：幅度减半、头部抬离靠垫。', '固定器械'),
  ExerciseMeta('高位划船机', MuscleGroups(main: '背', secondary: ['肩']), true, 'gym', '坐姿高位把位，把手向锁骨方向拉，肘部张开沿身体两侧走，上背与肩后束刺激多。常见错误：身体后仰摇借力、只拉半程。', '固定器械'),
  // —— 肩（器械） ——
  ExerciseMeta('坐姿推肩机', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'gym', '背贴靠垫坐稳，把手从耳侧沿固定轨道上推至手臂接近伸直；不用平衡负担，专注肩部发力。常见错误：耸肩、顶端不伸直。', '固定器械'),
  ExerciseMeta('耸肩机', MuscleGroups(main: '肩', secondary: []), false, 'gym', '耸肩器把手在体侧，双肩垂直向耳侧方向耸起至顶、停一秒慢放；固定轨道可安全上大重量。常见错误：绕肩旋转、屈肘上提。', '固定器械'),
  // —— 手臂（器械） ——
  ExerciseMeta('器械弯举', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '弯举器手臂固定在垫板上屈肘弯举到顶挤压二头；垫板限制肘部前移，孤立度高。常见错误：臀部离座、配重片回落砸堆。', '固定器械'),
  ExerciseMeta('坐姿臂屈伸机', MuscleGroups(main: '手臂', secondary: []), false, 'gym', '坐姿臂屈伸器，上臂贴稳挡垫，前臂下压至完全伸直停一秒；对肘关节友好、三头孤立。常见错误：肘部离垫、身体下压借力。', '固定器械'),
  // —— 胸（器械） ——
  ExerciseMeta('上斜推胸机', MuscleGroups(main: '胸', secondary: ['肩']), true, 'gym', '上斜姿势的坐姿推胸器，背贴靠垫沿固定轨道向斜上方推起，主打胸上沿。常见错误：肩部耸起、顶端偷懒不伸直。', '固定器械'),
  // ============ 补库第五弹（2026-09-29 晚，Arono 点名：居家/出差可练） ============
  // 弹力带全家桶 + 自重/哑铃补位，全部 home 场景、有对应示意图。
  ExerciseMeta('弹力带深蹲', MuscleGroups(main: '腿', secondary: ['核心']), true, 'home', '双脚踩住弹力带两端，双手把带拉到肩侧，屈髋下蹲至大腿平行再站起；带的阻力越往下越大，全程躯干立直。常见错误：带从脚下打滑、膝盖内扣。', '弹力带'),
  ExerciseMeta('弹力带早安式', MuscleGroups(main: '腿', secondary: ['核心']), true, 'home', '弹力带踩脚下、绕过肩背，屈髋俯身至上背接近平行地面再伸髋站直，练腘绳与臀。常见错误：弓背、屈膝变深蹲。', '弹力带'),
  ExerciseMeta('弹力带卧推', MuscleGroups(main: '胸', secondary: ['肩', '手臂']), true, 'home', '弹力带固定在凳后（或绕背上），双手持带推起至手臂伸直再慢放；张力越推越大，与杠铃手感互补。常见错误：带松掉失去张力、肘部过度外展。', '弹力带'),
  ExerciseMeta('弹力带推肩', MuscleGroups(main: '肩', secondary: ['手臂']), true, 'home', '踩住弹力带、双手拉到肩侧，垂直向上推起至手臂伸直；核心绷紧不塌腰。常见错误：耸肩借力、推起轨迹前后晃。', '弹力带'),
  ExerciseMeta('弹力带臂屈伸', MuscleGroups(main: '手臂', secondary: []), false, 'home', '弹力带固定在高位（门框/单杠），双手抓带从头后向上伸直手臂，练三头；肘部位置固定只动小臂。常见错误：肘部外张、身体下沉借力。', '弹力带'),
  ExerciseMeta('弹力带提踵', MuscleGroups(main: '腿', secondary: []), false, 'home', '前脚掌踩住弹力带（或踩一端、拉另一端到肩），脚跟下放到拉伸位再顶起到最高，慢下慢上。常见错误：行程过短、弹震式快做。', '弹力带'),
  ExerciseMeta('弹力带臀桥', MuscleGroups(main: '腿', secondary: ['核心']), false, 'home', '弹力带套在膝上方、仰卧屈膝，臀发力把髋顶到肩髋膝一线，顶峰对抗带的外拉夹臀一秒。常见错误：塌腰顶过高、用脚蹬地借力。', '弹力带'),
  ExerciseMeta('弹力带直立划船', MuscleGroups(main: '肩', secondary: ['手臂']), false, 'home', '踩住弹力带双手窄握，贴身拉至下颌高度、肘高于手再慢放。肩部不适者减小幅度或跳过。常见错误：杠（带）离身、耸肩代偿。', '弹力带'),
  ExerciseMeta('俯卧背挺身', MuscleGroups(main: '腿', secondary: ['背', '核心']), true, 'home', '俯卧在地面（或床沿），双手轻扶耳侧，用臀与下背把上身抬起至自然高度再慢放；幅度小一点、控制优先。常见错误：抬头过度折颈、猛甩起身。', '自重'),
  ExerciseMeta('哑铃交替平举', MuscleGroups(main: '肩', secondary: []), false, 'both', '双手持哑铃，一侧前平举至肩高回落的同时另一侧侧平举，交替进行；躯干稳定不晃。常见错误：借甩动、耸肩。', '哑铃'),
];

/// 兼容旧引用：薄肌计划内置词表 = 大库子集。
const kBaojiExerciseMeta = kExerciseLibrary;

/// 按名字查内置动作库条目（词表外动作——AI 沉淀/手填的——返回 null）。
/// 杠铃片速配等按器械分支的功能用它判断动作类别。
ExerciseMeta? libraryMetaByName(String name) {
  for (final m in kExerciseLibrary) {
    if (m.name == name) return m;
  }
  return null;
}

/// 别名/标点归一后再查库（「平板卧推」→「杠铃卧推」、半角
/// 「上斜杠铃卧推(轻)」→ 全角库名），供起始重量/器械分支这类
/// 「同一个动作换个叫法也要认」的场景用；词表外返回 null。
ExerciseMeta? libraryMetaForLift(String name) {
  final exact = libraryMetaByName(name);
  if (exact != null) return exact;
  final key = exerciseKeyOf(name);
  if (key.isEmpty) return null;
  for (final m in kExerciseLibrary) {
    if (exerciseKeyOf(m.name) == key) return m;
  }
  return null;
}

/// 是否动作库标注的**纯自重**动作：gear='自重' 且不是「负重 X」变体。
/// 「负重引体向上」「负重双杠臂屈伸」虽然挂在自重器械上，但训练时要记
/// 外加重量，不算纯自重。
bool isLibraryBodyweightExercise(String name) {
  final meta = libraryMetaForLift(name);
  if (meta == null || meta.gear != '自重') return false;
  return !meta.name.startsWith('负重');
}

/// 新计划动作的默认负荷类型（P2-E）：动作库标注为纯自重的动作按
/// bodyweight 落库，其余（含「负重引体/负重双杠」）按常规负重。
/// 修复固定回归：内置薄肌计划与所有模板安装走 [PresetExercise.toPlanExercise]
/// 时原本一律落 PlanExercise 默认的 weighted，导致俯卧撑/引体向上/双杠臂屈伸
/// 等自重动作在训练页看不到「自重」口径与自重变式建议。
String defaultLoadTypeFor(String name) =>
    isLibraryBodyweightExercise(name) ? LoadMode.bodyweight : LoadMode.weighted;

/// 首次训练没有历史时的起始重量（P2-A）：
/// 按「细分器械 + 复合/单关节」推导，不给每个动作逐个手填。
/// 单位 kg；哑铃/壶铃为每只重量（与内置计划口径一致）。
/// 自重/弹力带/其他器械（药球、战绳、跳箱等按次或自身体重计）为 0。
double defaultStartWeightOf(ExerciseMeta meta) {
  switch (meta.gear) {
    case '杠铃':
      // 自由杠/史密斯/EZ 杠同一口径：复合含杆 40kg，单关节 20kg。
      return meta.isCompound ? 40 : 20;
    case '哑铃':
    case '壶铃':
      return meta.isCompound ? 10 : 6;
    case '龙门架绳索':
      return 10;
    case '固定器械':
      return 20;
    case '自重':
    case '弹力带':
    case '其他器械':
      return 0;
  }
  // 器械未标注（内置条目都有 gear；主要给外部传入的 meta/测试构造用）：
  // 按场景兜底——健身房默认有配重，居家默认自重或轻器械。
  switch (meta.equipment) {
    case 'gym':
      return 20;
    case 'home':
      return 0;
  }
  return 10;
}

/// 少量显式覆盖：按器械基线明显偏离常见起始档的动作。
/// 只收高频、基线会明显偏轻的项；内置薄肌计划的显式起始重量另有一份
/// （kBaojiExercisesByWeekday），优先级更高。
const kStartWeightOverrides = <String, double>{
  // 下拉/划船类绳索动作的配重片起点比孤立绳索动作高。
  '高位下拉': 30,
  'V把下拉': 30,
  '窄距高位下拉': 30,
  '反手高位下拉': 30,
  '单臂绳索划船': 20,
};

// ================= 计划模板 =================

class PresetExercise {
  final String name;
  final int sets;
  final int repsMin;
  final int repsMax;
  final int restSec;
  final String kind;
  const PresetExercise(this.name, this.sets, this.repsMin, this.repsMax,
      this.restSec, this.kind);

  PlanExercise toPlanExercise(int dayId, int orderIdx) => PlanExercise(
        dayId: dayId,
        name: name,
        orderIdx: orderIdx,
        sets: sets,
        repsMin: repsMin,
        repsMax: repsMax,
        restSec: restSec,
        kind: kind,
        // 自重动作（俯卧撑/引体/双杠/臀桥等）按自重口径落库，
        // 不再吃 PlanExercise 的默认 weighted（P2-E 复核修复）。
        loadType: defaultLoadTypeFor(name),
        rule: ProgressionRule(
          repsMin: repsMin,
          repsMax: repsMax,
          incrementKg: kind == 'compound' ? 2.5 : 1.25,
          workingSets: sets,
          desc: kind == 'compound'
              ? '全部正式组达 $repsMax 次且末组余力≥1 → 加 2.5kg；有组低于 $repsMin 次 → 减 5%'
              : '全部正式组达 $repsMax 次且末组余力≥1 → 加 1.25kg',
        ),
      );
}

class PlanTemplate {
  final String name;
  final String source; // preset
  final String intro; // 模板选择页的一句介绍
  final String note; // 适合谁
  final Map<int, List<PresetExercise>> byWeekday; // weekday -> 动作
  const PlanTemplate({
    required this.name,
    required this.source,
    required this.intro,
    required this.note,
    required this.byWeekday,
  });

  String get dayTitle => name;
}

/// 模板 1：三分化 PPL（推/拉/腿，每周 6 练或 3 练轮转）——健美经典。
const kPplTemplate = PlanTemplate(
  name: '三分化（推·拉·腿）',
  source: 'preset',
  intro: '推日（胸肩三头）/ 拉日（背二头）/ 腿日，经典健美分化，每肌群每周刺激 1-2 次',
  note: '适合每周 3-6 练、以增肌为主的训练者；时间紧就按 推→拉→腿 轮转',
  byWeekday: {
    // 周一 推
    1: [
      PresetExercise('杠铃卧推', 4, 5, 8, 180, 'compound'),
      PresetExercise('坐姿哑铃推举', 3, 8, 12, 120, 'compound'),
      PresetExercise('上斜哑铃卧推', 3, 8, 12, 120, 'compound'),
      PresetExercise('哑铃侧平举', 4, 12, 15, 75, 'assistance'),
      PresetExercise('绳索下压', 3, 10, 12, 75, 'assistance'),
    ],
    // 周二 拉
    2: [
      PresetExercise('杠铃硬拉', 3, 5, 8, 180, 'compound'),
      PresetExercise('引体向上', 4, 6, 10, 150, 'compound'),
      PresetExercise('坐姿划船', 3, 8, 12, 120, 'assistance'),
      PresetExercise('俯身飞鸟（后束）', 4, 12, 15, 75, 'assistance'),
      PresetExercise('杠铃弯举', 3, 10, 12, 75, 'assistance'),
    ],
    // 周三 腿
    3: [
      PresetExercise('杠铃深蹲', 4, 5, 8, 180, 'compound'),
      PresetExercise('罗马尼亚硬拉', 3, 8, 10, 150, 'compound'),
      PresetExercise('腿举（倒蹬机）', 3, 10, 12, 120, 'compound'),
      PresetExercise('腿弯举（腘绳肌）', 3, 10, 12, 75, 'assistance'),
      PresetExercise('站姿提踵', 4, 12, 15, 60, 'assistance'),
    ],
    // 周四 推（第二循环，轻重高次）
    4: [
      PresetExercise('上斜杠铃卧推', 3, 8, 12, 120, 'compound'),
      PresetExercise('哑铃卧推', 3, 8, 12, 120, 'compound'),
      PresetExercise('哑铃侧平举', 4, 12, 20, 60, 'assistance'),
      PresetExercise('哑铃颈后臂屈伸', 3, 10, 12, 75, 'assistance'),
    ],
    // 周五 拉
    5: [
      PresetExercise('高位下拉', 4, 8, 12, 120, 'compound'),
      PresetExercise('T杠划船', 3, 8, 12, 120, 'compound'),
      PresetExercise('面拉', 3, 12, 15, 60, 'assistance'),
      PresetExercise('哑铃锤式弯举', 3, 10, 12, 60, 'assistance'),
    ],
    // 周六 腿（第二循环）
    6: [
      PresetExercise('保加利亚分腿蹲', 3, 8, 12, 120, 'compound'),
      PresetExercise('哑铃罗马尼亚硬拉', 3, 8, 12, 120, 'compound'),
      PresetExercise('腿屈伸（股四头）', 3, 12, 15, 60, 'assistance'),
      PresetExercise('杠铃臀桥', 3, 10, 12, 90, 'compound'),
    ],
  },
);

/// 模板 2：五分化（胸/背/肩/手臂/腿）——经典健美式，每部位一天精雕。
const kBroSplitTemplate = PlanTemplate(
  name: '五分化（胸·背·肩·臂·腿）',
  source: 'preset',
  intro: '每天专攻一个部位，动作量大、单部位刺激深，经典健美式训练',
  note: '适合每周稳定 5 练、追求单部位容量的中高级训练者',
  byWeekday: {
    // 周一 胸
    1: [
      PresetExercise('杠铃卧推', 4, 6, 8, 180, 'compound'),
      PresetExercise('上斜哑铃卧推', 3, 8, 12, 120, 'compound'),
      PresetExercise('坐姿夹胸（蝴蝶机）', 3, 12, 15, 75, 'assistance'),
      PresetExercise('绳索夹胸', 3, 12, 15, 60, 'assistance'),
      PresetExercise('双杠臂屈伸（挺胸）', 3, 8, 12, 90, 'compound'),
    ],
    // 周二 背
    2: [
      PresetExercise('引体向上', 4, 6, 10, 150, 'compound'),
      PresetExercise('杠铃划船', 4, 8, 10, 150, 'compound'),
      PresetExercise('高位下拉', 3, 10, 12, 90, 'assistance'),
      PresetExercise('坐姿划船', 3, 10, 12, 90, 'assistance'),
      PresetExercise('直臂下压', 3, 12, 15, 60, 'assistance'),
    ],
    // 周三 肩
    3: [
      PresetExercise('站姿推举', 4, 6, 8, 180, 'compound'),
      PresetExercise('哑铃侧平举', 4, 12, 15, 60, 'assistance'),
      PresetExercise('哑铃前平举', 3, 12, 15, 60, 'assistance'),
      PresetExercise('俯身飞鸟（后束）', 4, 12, 15, 60, 'assistance'),
      PresetExercise('杠铃耸肩', 3, 10, 12, 75, 'assistance'),
    ],
    // 周四 手臂
    4: [
      PresetExercise('窄距卧推', 3, 8, 10, 120, 'compound'),
      PresetExercise('绳索下压', 4, 10, 12, 60, 'assistance'),
      PresetExercise('哑铃颈后臂屈伸', 3, 10, 12, 75, 'assistance'),
      PresetExercise('杠铃弯举', 4, 8, 12, 75, 'assistance'),
      PresetExercise('哑铃锤式弯举', 3, 10, 12, 60, 'assistance'),
    ],
    // 周五 腿
    5: [
      PresetExercise('杠铃深蹲', 4, 5, 8, 180, 'compound'),
      PresetExercise('腿举（倒蹬机）', 4, 10, 12, 120, 'compound'),
      PresetExercise('罗马尼亚硬拉', 3, 8, 10, 150, 'compound'),
      PresetExercise('腿屈伸（股四头）', 3, 12, 15, 60, 'assistance'),
      PresetExercise('腿弯举（腘绳肌）', 3, 12, 15, 60, 'assistance'),
      PresetExercise('站姿提踵', 4, 12, 15, 60, 'assistance'),
    ],
  },
);

/// 模板 3：功能性训练（全身 3 练，多关节 + 核心 + 体能）。
const kFunctionalTemplate = PlanTemplate(
  name: '功能性训练（全身）',
  source: 'preset',
  intro: '壶铃/爆发/核心/单侧动作，练"用得上的力量"，兼顾体态与心肺',
  note: '适合久坐办公、想改善体能与核心稳定的人；健身房居家动作各半可替换',
  byWeekday: {
    // 周一 全身 A（下肢主导）
    1: [
      PresetExercise('壶铃摆荡', 4, 12, 15, 60, 'compound'),
      PresetExercise('哑铃高脚杯深蹲', 3, 8, 12, 120, 'compound'),
      PresetExercise('哑铃单腿硬拉', 3, 8, 10, 90, 'compound'),
      PresetExercise('健腹轮', 3, 8, 12, 60, 'assistance'),
      PresetExercise('死虫式', 3, 10, 12, 45, 'assistance'),
    ],
    // 周三 全身 B（上肢主导）
    3: [
      PresetExercise('哑铃卧推', 4, 8, 12, 120, 'compound'),
      PresetExercise('哑铃单臂划船', 4, 8, 12, 90, 'compound'),
      PresetExercise('坐姿哑铃推举', 3, 8, 12, 90, 'compound'),
      PresetExercise('弹力带面拉', 3, 12, 15, 45, 'assistance'),
      PresetExercise('平板支撑', 3, 40, 60, 45, 'assistance'),
    ],
    // 周五 全身 C（爆发 + 体能）
    5: [
      PresetExercise('深蹲跳', 4, 8, 10, 90, 'compound'),
      PresetExercise('波比跳', 3, 10, 12, 60, 'compound'),
      PresetExercise('哑铃农夫行走', 3, 30, 40, 75, 'compound'),
      PresetExercise('弹力带伐木', 3, 10, 12, 45, 'compound'),
      PresetExercise('鸟狗式', 3, 10, 12, 45, 'assistance'),
    ],
  },
);

/// 模板 4：居家哑铃全身（健身房去不了时的备胎）。
const kHomeTemplate = PlanTemplate(
  name: '居家哑铃全身',
  source: 'preset',
  intro: '一副哑铃 + 自重，全身 3 练，出差/居家不断训',
  note: '适合只有哑铃（或弹力带）的环境；回健身房后切回主力计划',
  byWeekday: {
    1: [
      PresetExercise('哑铃卧推', 4, 8, 12, 90, 'compound'),
      PresetExercise('哑铃单臂划船', 4, 8, 12, 75, 'compound'),
      PresetExercise('哑铃高脚杯深蹲', 3, 10, 12, 90, 'compound'),
      PresetExercise('哑铃侧平举', 3, 12, 15, 45, 'assistance'),
      PresetExercise('卷腹', 3, 15, 20, 45, 'assistance'),
    ],
    3: [
      PresetExercise('俯卧撑', 4, 12, 20, 60, 'compound'),
      PresetExercise('弹力带坐姿划船', 4, 12, 15, 60, 'assistance'),
      PresetExercise('箭步蹲', 3, 10, 12, 75, 'compound'),
      PresetExercise('派克俯卧撑', 3, 8, 12, 75, 'compound'),
      PresetExercise('哑铃弯举', 3, 10, 12, 45, 'assistance'),
    ],
    5: [
      PresetExercise('上斜俯卧撑', 4, 12, 15, 60, 'compound'),
      PresetExercise('哑铃罗马尼亚硬拉', 3, 10, 12, 90, 'compound'),
      PresetExercise('臀桥', 3, 12, 15, 60, 'assistance'),
      PresetExercise('凳上臂屈伸', 3, 10, 12, 45, 'assistance'),
      PresetExercise('平板支撑', 3, 40, 60, 45, 'assistance'),
    ],
  },
);

/// 全部可选模板（模板选择页展示）。
const kPlanTemplates = [kPplTemplate, kBroSplitTemplate, kFunctionalTemplate, kHomeTemplate];
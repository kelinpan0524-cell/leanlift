package com.arono.baoji_timer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.Log

/**
 * 前台服务（2026-10-22 扩展为两种用途）：
 * - 训练态（specialUse）：训练进行中用前台服务提升进程优先级，
 *   锁屏/切后台/杀进程都不中断；常驻训练卡通知对齐"当前动作/本组目标/
 *   剩余时间"三要素，休息态附暂停/±10 秒按钮，点通知回训练页；
 * - 心率记录（connectedDevice）：心率设备连上、但不在训练中时，
 *   用 connectedDevice 类型保活 BLE 连接与采样，通知文案
 *   「LeanLift 正在记录心率」；训练开始后由训练卡接管（同一通知位）。
 *
 * 计时权威源仍在 Dart 侧（墙钟差值），本服务不计时——只承载进程优先级
 * 与通知展示；通知内容每次由 Dart 推送（ACTION_START 幂等更新）。
 */
class TrainingForegroundService : Service() {

    companion object {
        private const val TAG = "TrainingFgs"
        // v2（2026-10-11）：Android 8+ 通道属性只在首次创建时生效，老 ID
        // "training_ongoing"（IMPORTANCE_LOW、无锁屏可见性）在升级安装上
        // 冻结，2026-10-07 加的 VISIBILITY_PUBLIC 对老用户静默无效。换新 ID
        // 让所有用户拿到新属性（DEFAULT+PUBLIC）；旧通道留在系统设置里无害。
        const val CHANNEL_ID = "training_ongoing_v2"
        const val CHANNEL_ID_HR = "hr_recording_v1"
        const val NOTIF_ID = 10

        const val ACTION_START = "com.arono.baoji_timer.training.START"
        const val ACTION_STOP = "com.arono.baoji_timer.training.STOP"
        const val ACTION_START_HR = "com.arono.baoji_timer.hr.START"
        const val ACTION_STOP_HR = "com.arono.baoji_timer.hr.STOP"
        const val ACTION_PAUSE = "pause"
        const val ACTION_RESUME = "resume"
        const val ACTION_MINUS10 = "minus10"
        const val ACTION_PLUS10 = "plus10"

        private const val MODE_NONE = 0
        private const val MODE_TRAINING = 1
        private const val MODE_HR = 2

        /** 通知栏按钮动作回调（MainActivity 注入，转发给 Dart 侧 handler）。 */
        @JvmStatic
        var actionSink: ((String) -> Unit)? = null

        /** Dart → 原生：启动（或幂等更新）前台服务与训练卡通知。 */
        fun start(context: Context, args: Map<*, *>?) {
            val intent = Intent(context, TrainingForegroundService::class.java)
                .setAction(ACTION_START)
            if (args != null) {
                for ((k, v) in args) {
                    val key = k.toString()
                    when (v) {
                        is Int -> intent.putExtra(key, v)
                        is Long -> intent.putExtra(key, v)
                        is Boolean -> intent.putExtra(key, v)
                        is String -> intent.putExtra(key, v)
                        is Double -> intent.putExtra(key, v)
                    }
                }
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            // 沿用原行为：训练可能在前台/后台结束，用 startForegroundService
            // 保证命令一定送达（服务已在跑时不会触发新的 5 秒配额问题）。
            ContextCompat.startForegroundService(
                context,
                Intent(context, TrainingForegroundService::class.java)
                    .setAction(ACTION_STOP)
            )
        }

        /** Dart → 原生：心率已连接，拉起 connectedDevice 类型的前台服务。 */
        fun startHr(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, TrainingForegroundService::class.java)
                    .setAction(ACTION_START_HR)
            )
        }

        /** Dart → 原生：心率已断开且不在训练中，停掉心率前台服务。 */
        fun stopHr(context: Context) {
            startCommand(context, ACTION_STOP_HR)
        }

        /**
         * 停止类命令用 startService 而不是 startForegroundService：
         * 服务没在跑时无需占用一次「5 秒内必须 startForeground」的配额。
         */
        private fun startCommand(context: Context, action: String) {
            try {
                context.startService(
                    Intent(context, TrainingForegroundService::class.java)
                        .setAction(action)
                )
            } catch (e: Exception) {
                Log.w(TAG, "startService($action) failed: ${e.message}")
            }
        }
    }

    private var mode = MODE_NONE
    private var hrActive = false
    /** 当前 startForeground 用的类型位，0 = 尚未 startForeground。 */
    private var foregroundTypes = 0
    /** 最近一次训练卡通知：心率断开时用它把类型降回 specialUse。 */
    private var lastTrainingNotification: Notification? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // 训练结束：整个前台服务退场。会话收工时 Dart 侧会同时断开
                // 心率；若这里保留「记录心率」卡，用户在训练中手动断过心率
                // 的话 hrActive 会残留，通知就再也关不掉。
                stopAll()
                return START_NOT_STICKY
            }
            ACTION_STOP_HR -> {
                hrActive = false
                if (mode == MODE_TRAINING) {
                    // 训练中：训练卡继续兜着，只是去掉 connectedDevice 类型
                    // （有最近通知就重开一次；没有也不影响训练保活）。
                    val n = lastTrainingNotification
                    if (n != null && foregroundTypes !=
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                    ) {
                        startForegroundCompat(
                            n,
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                            allowSpecialUseFallback = true
                        )
                    }
                    return START_NOT_STICKY
                }
                stopAll()
                return START_NOT_STICKY
            }
            ACTION_PAUSE, ACTION_RESUME, ACTION_MINUS10, ACTION_PLUS10 -> {
                // 通知栏遥控：只在训练卡模式下转发给 Dart（会话状态机处理）
                if (mode == MODE_TRAINING) {
                    intent.action?.let { actionSink?.invoke(it) }
                }
                return START_NOT_STICKY
            }
            ACTION_START_HR -> {
                hrActive = true
                if (mode == MODE_TRAINING) {
                    // 训练卡已在跑：优先保证训练卡不换文案；类型保持
                    // specialUse 即可（训练前台服务已提供进程优先级）。
                    return START_NOT_STICKY
                }
                ensureChannels()
                mode = MODE_HR
                startForegroundCompat(
                    buildHrNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                    allowSpecialUseFallback = false
                )
                return START_NOT_STICKY
            }
            null -> {
                // 系统重建（无 intent）：Dart 侧状态机已不在，复活只会渲染
                // 一张与真实训练无关的假卡——直接退场，会话由 App 重启时恢复。
                stopAll()
                return START_NOT_STICKY
            }
        }
        // ACTION_START：训练卡（每次都带最新三要素）
        ensureChannels()
        mode = MODE_TRAINING
        val notification = buildNotification(intent)
        lastTrainingNotification = notification
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        if (hrActive) {
            // 心率连接期间同时声明 connectedDevice：Android 14+ 要求
            // manifest 与 FOREGROUND_SERVICE_CONNECTED_DEVICE 权限齐备。
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        }
        startForegroundCompat(notification, types, allowSpecialUseFallback = true)
        return START_NOT_STICKY
    }

    /**
     * 幂等 startForeground：类型不变时只 notify 更新内容（训练卡每秒推送
     * 时更轻）；类型变化才重新 startForeground。失败时按需回退 specialUse，
     * 仍失败则停服务，绝不让训练崩在服务上。
     */
    private fun startForegroundCompat(
        notification: Notification,
        types: Int,
        allowSpecialUseFallback: Boolean,
    ) {
        if (foregroundTypes == types) {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIF_ID, notification)
            return
        }
        try {
            ServiceCompat.startForeground(this, NOTIF_ID, notification, types)
            foregroundTypes = types
        } catch (e: Exception) {
            Log.w(TAG, "startForeground(type=$types) failed: ${e.message}")
            if (allowSpecialUseFallback && types != 0 &&
                types != ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            ) {
                try {
                    ServiceCompat.startForeground(
                        this, NOTIF_ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                    )
                    foregroundTypes = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                    return
                } catch (e2: Exception) {
                    Log.w(TAG, "specialUse fallback failed: ${e2.message}")
                }
            }
            stopAll()
        }
    }

    private fun stopAll() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foregroundTypes = 0
        lastTrainingNotification = null
        mode = MODE_NONE
        hrActive = false
        stopSelf()
    }

    override fun onDestroy() {
        mode = MODE_NONE
        foregroundTypes = 0
        lastTrainingNotification = null
        super.onDestroy()
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // DEFAULT（2026-10-11）：LOW 会被 ROM 归入"静默"桶，ColorOS 等锁屏
        // 对静默通知更保守（可整档不显示）。无声由下面 setSound(null)+
        // enableVibration(false)+setOnlyAlertOnce 保证，重要性升档不出声。
        val ch = NotificationChannel(
            CHANNEL_ID, "训练进行中", NotificationManager.IMPORTANCE_DEFAULT
        )
        ch.description = "训练中的常驻卡片（无声常驻，不响铃）"
        ch.setSound(null, null)
        ch.enableVibration(false)
        ch.setShowBadge(false)
        // 锁屏全内容可见（2026-10-04）：用户开了"锁屏隐藏敏感内容"时，
        // PRIVATE 通道在锁屏只显示"内容已隐藏"——计时卡不是敏感信息，
        // 显式 PUBLIC 保证锁屏上完整可见。
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(ch)

        val hr = NotificationChannel(
            CHANNEL_ID_HR, "心率记录中", NotificationManager.IMPORTANCE_DEFAULT
        )
        hr.description = "心率设备连接期间的常驻卡片（无声常驻，不响铃）"
        hr.setSound(null, null)
        hr.enableVibration(false)
        hr.setShowBadge(false)
        hr.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(hr)
    }

    private fun contentPi(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    /** 心率记录前台服务通知（不在训练中时显示）。 */
    private fun buildHrNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID_HR)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("LeanLift 正在记录心率")
            .setContentText("心率设备已连接 · 切到后台也会继续记录")
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText("心率设备已连接 · 切到后台也会继续记录")
            )
            .setContentIntent(contentPi())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
            .build()

    private fun buildNotification(i: Intent?): Notification {
        val resting = (i?.getIntExtra("phase", 0) ?: 0) == 1
        val title = i?.getStringExtra("title") ?: "训练进行中"
        val text = i?.getStringExtra("text") ?: ""
        val paused = i?.getBooleanExtra("paused", false) ?: false
        val chronoBase = i?.getLongExtra("chronoBase", 0L) ?: 0L
        val restEndAt = i?.getLongExtra("restEndAt", 0L) ?: 0L
        val remaining = i?.getIntExtra("remaining", -1) ?: -1
        val total = i?.getIntExtra("total", 0) ?: 0

        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(contentPi())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            // 不设 setSilent：静默标记会让 ROM 把卡归入"静默"组，锁屏
            // 展示更保守；无声已由通道 setSound(null) + 无振动保证。
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)
            .setShowWhen(true)
        when {
            // 休息态：系统 chronometer 倒数到 restEndAt——锁屏上由系统自己
            // 走秒（2026-10-04），不依赖 Dart 每秒推送；±10 秒/暂停/继续时
            // Dart 会推新卡换 when。暂停态冻结，走普通文本。
            resting && !paused && restEndAt > 0 -> {
                b.setUsesChronometer(true)
                    .setChronometerCountDown(true)
                    .setWhen(restEndAt)
            }
            // 动作态：chronometer 正数累计训练时长，系统自己走秒
            !resting && chronoBase > 0 -> {
                b.setUsesChronometer(true).setWhen(chronoBase)
            }
            else -> b.setUsesChronometer(false)
        }
        if (resting && remaining >= 0 && total > 0) {
            b.setProgress(total, remaining.coerceAtMost(total), false)
        }
        if (resting) {
            b.addAction(0, if (paused) "继续" else "暂停", actionPi(if (paused) ACTION_RESUME else ACTION_PAUSE))
            b.addAction(0, "-10 秒", actionPi(ACTION_MINUS10))
            b.addAction(0, "+10 秒", actionPi(ACTION_PLUS10))
        }
        return b.build()
    }

    private fun actionPi(action: String): PendingIntent =
        PendingIntent.getService(
            this, action.hashCode(),
            Intent(this, TrainingForegroundService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
}

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
 * 训练态前台服务（调研条目 1/3）：
 * 训练进行中用前台服务提升进程优先级，锁屏/切后台/杀进程都不中断；
 * 常驻训练卡通知对齐"当前动作/本组目标/剩余时间"三要素，
 * 休息态附暂停/±10 秒按钮，点通知回训练页。
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
        const val NOTIF_ID = 10

        const val ACTION_START = "com.arono.baoji_timer.training.START"
        const val ACTION_STOP = "com.arono.baoji_timer.training.STOP"
        const val ACTION_PAUSE = "pause"
        const val ACTION_RESUME = "resume"
        const val ACTION_MINUS10 = "minus10"
        const val ACTION_PLUS10 = "plus10"

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
            ContextCompat.startForegroundService(
                context,
                Intent(context, TrainingForegroundService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                foreground = false
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PAUSE, ACTION_RESUME, ACTION_MINUS10, ACTION_PLUS10 -> {
                // 通知栏遥控：转发给 Dart（会话状态机统一处理），服务自身不动
                intent.action?.let { actionSink?.invoke(it) }
                return START_NOT_STICKY
            }
            null -> {
                // 系统重建（无 intent）：Dart 侧状态机已不在，复活只会渲染
                // 一张与真实训练无关的假卡——直接退场，会话由 App 重启时恢复。
                stopSelf()
                return START_NOT_STICKY
            }
        }
        ensureChannel()
        val notification = buildNotification(intent)
        return try {
            if (!foreground) {
                // specialUse：训练计时无系统预设类型可用，targetSdk 34+ 必须声明类型；
                // manifest 已注册 FOREGROUND_SERVICE_SPECIAL_USE 权限与 subtype 说明。
                ServiceCompat.startForeground(
                    this, NOTIF_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
                foreground = true
            } else {
                // 已在前台：后续内容更新走 notify()（比重复 startForeground 轻）
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(NOTIF_ID, notification)
            }
            START_NOT_STICKY
        } catch (e: Exception) {
            // 低概率：通知权限被回收等。吞掉，不能让训练崩在服务上。
            Log.w(TAG, "startForeground failed: ${e.message}")
            stopSelf()
            foreground = false
            START_NOT_STICKY
        }
    }

    private fun ensureChannel() {
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
    }

    private fun buildNotification(i: Intent?): Notification {
        val resting = (i?.getIntExtra("phase", 0) ?: 0) == 1
        val title = i?.getStringExtra("title") ?: "训练进行中"
        val text = i?.getStringExtra("text") ?: ""
        val paused = i?.getBooleanExtra("paused", false) ?: false
        val chronoBase = i?.getLongExtra("chronoBase", 0L) ?: 0L
        val restEndAt = i?.getLongExtra("restEndAt", 0L) ?: 0L
        val remaining = i?.getIntExtra("remaining", -1) ?: -1
        val total = i?.getIntExtra("total", 0) ?: 0

        val contentPi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(contentPi)
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

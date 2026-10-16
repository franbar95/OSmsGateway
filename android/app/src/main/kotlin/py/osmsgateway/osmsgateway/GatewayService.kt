package py.osmsgateway.osmsgateway

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

/**
 * Servicio en primer plano con notificación persistente. Su único trabajo es
 * mantener vivo el proceso de la aplicación (y con él el motor Flutter que
 * ejecuta el servidor HTTP y la cola de SMS) mientras la pantalla está cerrada.
 */
class GatewayService : Service() {

    companion object {
        private const val CHANNEL_ID = "gateway_status"
        private const val NOTIFICATION_ID = 1001
        private const val EXTRA_TEXT = "text"

        /** Inicia el servicio, o actualiza el texto de la notificación si ya corre. */
        fun start(context: Context, text: String) {
            val intent = Intent(context, GatewayService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GatewayService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty().ifBlank { "Servidor activo" }
        createChannel()
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // Si el sistema mata el proceso no se reinicia solo: sin el motor Flutter
        // no habría servidor que mantener. El arranque tras reinicio va aparte.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID, "Estado del servidor", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Indica que OSmsGateway está atendiendo peticiones"
                setShowBadge(false)
            }
        )
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("OSmsGateway")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}

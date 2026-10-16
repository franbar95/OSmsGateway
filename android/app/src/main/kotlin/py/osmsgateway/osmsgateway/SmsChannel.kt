package py.osmsgateway.osmsgateway

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SmsMessage
import android.telephony.TelephonyManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

/**
 * Envío de SMS con SmsManager. Informa a Dart por separado de:
 *  - "SENT": el módem/pila de radio sacó todas las partes del SMS.
 *  - "DELIVERED": la operadora devolvió un informe de entrega con TP-Status 0x00
 *    para todas las partes.
 *  - "FAILED" / "DELIVERY_FAILED": fallo de envío o entrega rechazada.
 *  - "DELIVERY_UNKNOWN": informe de entrega que no se pudo interpretar.
 * Que Android acepte la solicitud se informa como respuesta del método "send".
 */
class SmsChannel(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "py.osmsgateway/sms"
        const val ACTION_SENT = "py.osmsgateway.SMS_SENT"
        const val ACTION_DELIVERED = "py.osmsgateway.SMS_DELIVERED"
        const val REQUEST_SEND_SMS = 4711
        private const val MAX_AGE_MS = 48L * 60 * 60 * 1000

        /**
         * Clasifica el TP-Status de un informe de entrega (3GPP TS 23.040):
         * 0x00 recibido por el destinatario (única entrega confirmada);
         * 0x20-0x3F error temporal (la red sigue intentando, no es definitivo);
         * 0x40-0x7F fallo definitivo; cualquier otro valor (por ejemplo 0x01
         * "reenviado sin confirmar" o 0x02 "reemplazado") NO confirma entrega.
         */
        fun classifyDeliveryStatus(status: Int): String = when (status) {
            0x00 -> "DELIVERED"
            in 0x20..0x3F -> "PENDING"
            in 0x40..0x7F -> "DELIVERY_FAILED"
            else -> "UNCONFIRMED"
        }
    }

    private class Progress(val parts: Int) {
        val createdAt = System.currentTimeMillis()
        var sent = 0
        var delivered = 0
        var sendFailedReported = false
        var deliveryFinalReported = false
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val context: Context = activity.applicationContext
    private val progress = HashMap<String, Progress>() // solo hilo principal
    private val requestCodes = AtomicInteger(1)
    private var pendingPermission: MethodChannel.Result? = null
    private var receiverRegistered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val id = intent.getStringExtra("id") ?: return
            val p = progress[id] ?: return
            when (intent.action) {
                ACTION_SENT -> onPartSent(id, p, resultCode)
                ACTION_DELIVERED -> onPartDelivered(id, p, intent)
            }
        }
    }

    init {
        channel.setMethodCallHandler(this)
        val filter = IntentFilter().apply {
            addAction(ACTION_SENT)
            addAction(ACTION_DELIVERED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (receiverRegistered) {
            context.unregisterReceiver(receiver)
            receiverRegistered = false
        }
    }

    private fun emit(id: String, event: String, code: Int? = null, detail: String? = null) {
        channel.invokeMethod(
            "onSmsEvent",
            mapOf("id" to id, "event" to event, "code" to code, "detail" to detail)
        )
    }

    private fun onPartSent(id: String, p: Progress, resultCode: Int) {
        if (resultCode == Activity.RESULT_OK) {
            p.sent++
            if (p.sent == p.parts) emit(id, "SENT")
        } else if (!p.sendFailedReported) {
            p.sendFailedReported = true
            emit(id, "FAILED", resultCode, "SmsManager result code $resultCode")
            progress.remove(id)
        }
    }

    private fun onPartDelivered(id: String, p: Progress, intent: Intent) {
        if (p.deliveryFinalReported) return
        val pdu = intent.getByteArrayExtra("pdu")
        val format = intent.getStringExtra("format")
        val status: Int? = try {
            if (pdu == null) null else {
                val msg = if (Build.VERSION.SDK_INT >= 23) SmsMessage.createFromPdu(pdu, format)
                else @Suppress("DEPRECATION") SmsMessage.createFromPdu(pdu)
                msg?.status
            }
        } catch (e: Exception) {
            null
        }
        if (status == null) {
            p.deliveryFinalReported = true
            emit(id, "DELIVERY_UNKNOWN", null, "No se pudo leer el informe de entrega")
            progress.remove(id)
            return
        }
        when (classifyDeliveryStatus(status)) {
            "DELIVERED" -> {
                p.delivered++
                if (p.delivered == p.parts) {
                    p.deliveryFinalReported = true
                    emit(id, "DELIVERED", status)
                    progress.remove(id)
                }
            }
            "DELIVERY_FAILED" -> {
                p.deliveryFinalReported = true
                emit(id, "DELIVERY_FAILED", status)
                progress.remove(id)
            }
            "UNCONFIRMED" -> {
                p.deliveryFinalReported = true
                emit(id, "DELIVERY_UNKNOWN", status, "TP-Status $status no confirma entrega")
                progress.remove(id)
            }
            else -> Unit // error temporal: llegará otro informe
        }
    }

    private fun hasSendPermission(): Boolean =
        Build.VERSION.SDK_INT < 23 ||
            context.checkSelfPermission(Manifest.permission.SEND_SMS) ==
            PackageManager.PERMISSION_GRANTED

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_SEND_SMS) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
        return true
    }

    @Suppress("DEPRECATION")
    private fun smsManager(): SmsManager =
        if (Build.VERSION.SDK_INT >= 31) context.getSystemService(SmsManager::class.java)
        else SmsManager.getDefault()

    private fun pendingIntent(action: String, id: String, part: Int, mutable: Boolean): PendingIntent {
        val intent = Intent(action).setPackage(context.packageName).putExtra("id", id)
        // El informe de entrega añade su PDU como extra al reenviar el intent,
        // lo que exige un PendingIntent mutable; el de envío no lo necesita.
        val flags = PendingIntent.FLAG_ONE_SHOT or when {
            Build.VERSION.SDK_INT >= 31 && mutable -> PendingIntent.FLAG_MUTABLE
            Build.VERSION.SDK_INT >= 23 && !mutable -> PendingIntent.FLAG_IMMUTABLE
            else -> 0
        }
        return PendingIntent.getBroadcast(context, requestCodes.getAndIncrement(), intent, flags)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSmsCapable" -> {
                val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                result.success(tm?.isSmsCapable ?: false)
            }
            "hasPermission" -> result.success(hasSendPermission())
            // Carpeta privada de la app (se conserva al reiniciar el teléfono).
            "filesDir" -> result.success(context.filesDir.absolutePath)
            "requestPermission" -> {
                if (hasSendPermission()) {
                    result.success(true)
                } else if (pendingPermission != null) {
                    result.error("BUSY", "Ya hay una solicitud de permiso en curso", null)
                } else {
                    pendingPermission = result
                    activity.requestPermissions(
                        arrayOf(Manifest.permission.SEND_SMS), REQUEST_SEND_SMS
                    )
                }
            }
            "send" -> send(call, result)
            else -> result.notImplemented()
        }
    }

    private fun send(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val to = call.argument<String>("to")
        val message = call.argument<String>("message")
        if (id.isNullOrBlank() || to.isNullOrBlank() || message.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "id, destinatario y mensaje son obligatorios", null)
            return
        }
        if (!hasSendPermission()) {
            result.error("NO_PERMISSION", "Falta el permiso SEND_SMS", null)
            return
        }
        // Limpia seguimientos viejos que nunca recibieron informe de entrega.
        val now = System.currentTimeMillis()
        progress.entries.removeAll { now - it.value.createdAt > MAX_AGE_MS }
        if (progress.containsKey(id)) {
            result.error("DUPLICATE_ID", "El id ya está en uso", null)
            return
        }
        try {
            val manager = smsManager()
            val parts = manager.divideMessage(message)
            val sentIntents = ArrayList<PendingIntent>()
            val deliveryIntents = ArrayList<PendingIntent>()
            for (i in parts.indices) {
                sentIntents.add(pendingIntent(ACTION_SENT, id, i, false))
                deliveryIntents.add(pendingIntent(ACTION_DELIVERED, id, i, true))
            }
            progress[id] = Progress(parts.size)
            try {
                manager.sendMultipartTextMessage(to, null, parts, sentIntents, deliveryIntents)
            } catch (e: Exception) {
                progress.remove(id)
                throw e
            }
            result.success(parts.size)
        } catch (e: Exception) {
            result.error("SEND_FAILED", e.message ?: e.javaClass.simpleName, null)
        }
    }
}

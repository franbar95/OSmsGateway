package py.osmsgateway.osmsgateway

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Motor Flutter compartido por todo el proceso. Vive en una caché propia, así
 * que cerrar la Activity (por ejemplo, al deslizar la app de recientes) no
 * destruye el servidor HTTP ni la cola de SMS que corren dentro de él.
 * El proceso se mantiene vivo mientras corra [GatewayService].
 */
object GatewayEngine {
    private const val ENGINE_ID = "osmsgateway_engine"

    /** Canal de SMS, creado una sola vez junto con el motor. */
    @Volatile
    var smsChannel: SmsChannel? = null
        private set

    @Synchronized
    fun get(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        // El constructor registra los plugins. El punto de entrada de Dart lo
        // ejecuta la primera Activity que se asocie al motor.
        val engine = FlutterEngine(app)
        smsChannel = SmsChannel(app, engine.dartExecutor.binaryMessenger)
        cache.put(ENGINE_ID, engine)
        return engine
    }
}

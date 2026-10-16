package py.osmsgateway.osmsgateway

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    // Motor compartido: sobrevive a esta Activity (ver GatewayEngine).
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        GatewayEngine.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        GatewayEngine.smsChannel?.attachActivity(this)
    }

    override fun onDestroy() {
        GatewayEngine.smsChannel?.detachActivity(this)
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (GatewayEngine.smsChannel?.onRequestPermissionsResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
}

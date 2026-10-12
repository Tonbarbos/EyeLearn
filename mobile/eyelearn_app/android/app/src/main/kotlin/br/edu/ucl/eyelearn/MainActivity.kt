package br.edu.ucl.eyelearn

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Registra o canal de captura do olhar.
 *
 * A FlutterActivity já é um LifecycleOwner, que é o que o CameraX precisa para
 * liberar a câmera quando a tela sai de foco -- sem isso a câmera continuaria
 * ligada com o aplicativo em segundo plano.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val plugin = GazePlugin(context = this, lifecycleOwner = this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GazePlugin.CHANNEL,
        ).setMethodCallHandler(plugin)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GazePlugin.FRAMES_CHANNEL,
        ).setStreamHandler(plugin)
    }
}

package br.edu.ucl.eyelearn

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.LifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarkerResult
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Captura de pontos do rosto com o MediaPipe Face Landmarker.
 *
 * Roda aqui, e não no Dart, por um motivo só: o centro da íris. O modelo com
 * refinamento de íris entrega 478 pontos, e é o único que permite estimar
 * olhar. Os pacotes Flutter disponíveis expõem o ML Kit Face Mesh, de 468
 * pontos sem íris, com que só se obtém pose de cabeça -- um percurso construído
 * a partir disso pareceria funcionar e não mediria leitura.
 *
 * **Os quadros não saem daqui.** Cada quadro é convertido, analisado e
 * descartado; o que atravessa para o Dart são as coordenadas dos pontos. Nenhum
 * quadro é gravado em disco nem enviado pela rede. É o que sustenta o parágrafo
 * de privacidade da seção 4.6 do relatório.
 *
 * O modelo `face_landmarker.task` precisa estar em `android/app/src/main/assets`.
 * Baixe-o da documentação do MediaPipe Tasks Vision; não é redistribuído neste
 * repositório.
 */
class GazePlugin(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val CHANNEL = "br.edu.ucl.eyelearn/gaze"
        const val FRAMES_CHANNEL = "$CHANNEL/frames"

        private const val MODEL_ASSET = "face_landmarker.task"

        /** Quantidade de pontos do modelo com refinamento de íris. */
        private const val EXPECTED_LANDMARKS = 478
    }

    private var landmarker: FaceLandmarker? = null
    private var sink: EventChannel.EventSink? = null
    private var analysisExecutor: ExecutorService? = null
    private var cameraProvider: ProcessCameraProvider? = null

    /** Instante do primeiro quadro, para que o percurso comece em zero. */
    private var firstFrameNanos: Long? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "start" -> start(result)
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (landmarker != null) {
            result.success(null)
            return
        }

        try {
            landmarker = buildLandmarker()
        } catch (error: Exception) {
            // Falhar alto: sem modelo não há captura, e seguir adiante
            // mostraria uma tela de leitura que não está medindo nada.
            result.error(
                "MODEL_UNAVAILABLE",
                "não foi possível carregar $MODEL_ASSET: ${error.message}",
                null,
            )
            return
        }

        try {
            bindCamera()
        } catch (error: Exception) {
            stop()
            result.error(
                "CAMERA_UNAVAILABLE",
                "não foi possível abrir a câmera frontal: ${error.message}",
                null,
            )
            return
        }

        result.success(null)
    }

    private fun buildLandmarker(): FaceLandmarker {
        val baseOptions = BaseOptions.builder()
            .setModelAssetPath(MODEL_ASSET)
            // GPU quando houver; o Face Landmarker cai para CPU sozinho onde
            // não houver delegado disponível.
            .setDelegate(Delegate.GPU)
            .build()

        val options = FaceLandmarker.FaceLandmarkerOptions.builder()
            .setBaseOptions(baseOptions)
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumFaces(1)
            // O que torna a estimativa de olhar possível. Sem isto o modelo
            // entrega 468 pontos e nenhuma íris.
            .setOutputFaceBlendshapes(false)
            .setMinFaceDetectionConfidence(0.5f)
            .setMinTrackingConfidence(0.5f)
            .setResultListener { result, _ -> publish(result) }
            .setErrorListener { error ->
                mainHandler.post {
                    sink?.error("INFERENCE_FAILED", error.message, null)
                }
            }
            .build()

        return FaceLandmarker.createFromOptions(context, options)
    }

    private fun bindCamera() {
        val executor = Executors.newSingleThreadExecutor()
        analysisExecutor = executor

        val providerFuture = ProcessCameraProvider.getInstance(context)
        val provider = providerFuture.get()
        cameraProvider = provider

        val analysis = ImageAnalysis.Builder()
            // Descartar quadro atrasado em vez de enfileirar: uma fila cresce
            // sob carga e os pontos chegariam defasados do que está na tela.
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()

        analysis.setAnalyzer(executor) { image -> analyse(image) }

        provider.unbindAll()
        provider.bindToLifecycle(
            lifecycleOwner,
            CameraSelector.DEFAULT_FRONT_CAMERA,
            analysis,
        )
    }

    private fun analyse(image: ImageProxy) {
        try {
            val detector = landmarker ?: return
            val bitmap = image.toBitmap()
            val mpImage = BitmapImageBuilder(bitmap).build()
            detector.detectAsync(mpImage, image.imageInfo.timestamp / 1_000_000)
        } catch (error: Exception) {
            mainHandler.post {
                sink?.error("FRAME_FAILED", error.message, null)
            }
        } finally {
            // Sempre fechar: o pool de quadros do CameraX é pequeno, e um
            // quadro não liberado trava a captura em poucos segundos.
            image.close()
        }
    }

    private fun publish(result: FaceLandmarkerResult) {
        val faces = result.faceLandmarks()
        if (faces.isEmpty()) return

        val landmarks = faces[0]
        if (landmarks.size < EXPECTED_LANDMARKS) {
            // O lado Dart também confere, mas avisar aqui aponta a causa: o
            // modelo carregado é o sem refinamento de íris.
            mainHandler.post {
                sink?.error(
                    "NO_IRIS_LANDMARKS",
                    "o modelo entregou ${landmarks.size} pontos; " +
                        "são necessários $EXPECTED_LANDMARKS",
                    null,
                )
            }
            return
        }

        val startNanos = firstFrameNanos ?: System.nanoTime().also {
            firstFrameNanos = it
        }
        val timestamp = (System.nanoTime() - startNanos) / 1_000_000_000.0

        val payload = mapOf(
            "timestamp" to timestamp,
            "landmarks" to landmarks.map { listOf(it.x(), it.y(), it.z()) },
        )

        // O EventSink só aceita chamadas da thread principal.
        mainHandler.post { sink?.success(payload) }
    }

    private fun stop() {
        cameraProvider?.unbindAll()
        cameraProvider = null

        analysisExecutor?.shutdown()
        analysisExecutor = null

        landmarker?.close()
        landmarker = null

        firstFrameNanos = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stop()
    }
}

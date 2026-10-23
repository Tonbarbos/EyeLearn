/// A origem do olhar da plataforma em que o aplicativo está rodando.
///
/// No Android, o canal nativo (CameraX + MediaPipe em Kotlin). No navegador,
/// a câmera do navegador + MediaPipe para web (`web/gaze.js`). As duas
/// entregam os mesmos 478 pontos do rosto, e o resto do aplicativo -- da
/// calibração à exportação -- não sabe qual está em uso.
library;

export 'platform_gaze_native.dart'
    if (dart.library.js_interop) 'platform_gaze_web.dart';

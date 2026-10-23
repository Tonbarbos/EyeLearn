import 'gaze_channel.dart';
import 'gaze_source.dart';

/// Android: o canal nativo.
GazeSource createPlatformGazeSource() => GazeChannel();

/// No Android a permissão de câmera é pedida pelo aplicativo antes de ligar
/// a captura; no navegador, é o próprio navegador quem pergunta.
const bool platformAsksCameraPermission = false;

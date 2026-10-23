/// A origem dos pontos do rosto, como as telas a enxergam.
///
/// Existe como interface, e não como classe concreta, por duas razões. A
/// primeira é que as telas passam a poder ser exercitadas sem câmera, sem
/// Android e sem o modelo do MediaPipe -- é o que torna possível a
/// pré-visualização em navegador de `main_demo.dart`. A segunda é que o canal
/// nativo só existe no Android: no navegador e no iOS ele lança
/// `MissingPluginException`, e uma tela que recebe a origem por parâmetro pode
/// receber outra em vez de quebrar.
library;

import 'package:eyelearn_core/eyelearn_core.dart';

/// Erro na captura, vindo do lado nativo ou da leitura dos quadros.
class GazeCaptureError implements Exception {
  final String message;
  final Object? cause;

  const GazeCaptureError(this.message, [this.cause]);

  @override
  String toString() => 'GazeCaptureError: $message';
}

/// De onde vêm os quadros de pontos do rosto.
abstract interface class GazeSource {
  /// Liga a captura.
  ///
  /// Throws [GazeCaptureError] quando não há como capturar -- sem câmera
  /// frontal, sem permissão, sem modelo. Nos três casos o aplicativo não tem
  /// como seguir, e insistir mostraria uma tela de leitura que não está
  /// medindo nada.
  Future<void> start();

  /// Desliga a captura e libera os recursos.
  ///
  /// É melhor esforço: se a origem já caiu, não há o que fazer, e propagar o
  /// erro impediria a tela de fechar.
  Future<void> stop();

  /// Fluxo de quadros.
  Stream<FaceFrame> frames();
}

/// Canal com o lado nativo, que roda o MediaPipe Face Landmarker.
///
/// **Por que canal nativo e não um pacote do pub.** O que a estimativa de olhar
/// precisa é do centro da íris, e isso só existe no modelo do MediaPipe com
/// refinamento de íris -- 478 pontos. Os pacotes Flutter disponíveis expõem o
/// ML Kit Face Mesh, que entrega 468 pontos sem íris: dá para detectar rosto e
/// pose de cabeça, não olhar. Um percurso construído a partir de pose de cabeça
/// pareceria funcionar e não mediria leitura.
///
/// O lado nativo recebe os quadros da câmera, roda o modelo em modo de
/// transmissão e envia os pontos por este canal. Nenhum quadro atravessa para o
/// Dart, e nenhum é gravado: é o que sustenta o parágrafo de privacidade da
/// seção 4.6 do relatório.
library;

import 'dart:async';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/services.dart';

/// Nome do canal. Tem de coincidir com o do lado nativo.
const String gazeChannelName = 'br.edu.ucl.eyelearn/gaze';

/// Erro na captura, vindo do lado nativo ou da leitura dos quadros.
class GazeCaptureError implements Exception {
  final String message;
  final Object? cause;

  const GazeCaptureError(this.message, [this.cause]);

  @override
  String toString() => 'GazeCaptureError: $message';
}

/// Acesso à captura de pontos do rosto.
class GazeChannel {
  final MethodChannel _methods;
  final EventChannel _events;

  GazeChannel({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(gazeChannelName),
      _events = events ?? const EventChannel('$gazeChannelName/frames');

  /// Liga a câmera e o modelo.
  ///
  /// Throws [GazeCaptureError] quando o aparelho não tem câmera frontal, quando
  /// a permissão foi negada ou quando o modelo não carrega. Nos três casos o
  /// aplicativo não tem como seguir, e insistir mostraria uma tela de leitura
  /// que não está medindo nada.
  Future<void> start() async {
    try {
      await _methods.invokeMethod<void>('start');
    } on PlatformException catch (error) {
      throw GazeCaptureError(
        error.message ?? 'não foi possível iniciar a captura',
        error,
      );
    } on MissingPluginException catch (error) {
      throw GazeCaptureError(
        'a captura não está disponível nesta plataforma; só Android está '
        'implementado',
        error,
      );
    }
  }

  /// Desliga a câmera e libera o modelo.
  ///
  /// Chamada mesmo quando a atividade é abandonada no meio: deixar a câmera
  /// ligada depois de sair da tela de leitura é, além de desperdício de
  /// bateria, uma captura que ninguém pediu.
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } on PlatformException {
      // Parar é melhor esforço: se o lado nativo já caiu, não há o que fazer,
      // e propagar o erro impediria a tela de fechar.
    } on MissingPluginException {
      // Idem.
    }
  }

  /// Fluxo de quadros de pontos do rosto.
  ///
  /// Quadros malformados são descartados com aviso em vez de derrubarem o
  /// fluxo: num aparelho real um quadro ocasional vem incompleto, e perder a
  /// gravação inteira por causa dele seria pior.
  Stream<FaceFrame> frames() => _events
      .receiveBroadcastStream()
      .map((payload) {
        if (payload is! Map) {
          throw GazeCaptureError('quadro em formato inesperado: $payload');
        }
        return FaceFrame.fromChannel(payload);
      })
      .handleError((Object error) {
        // Deixa passar: o assinante decide se conta as perdas.
      }, test: (error) => error is FormatException);
}

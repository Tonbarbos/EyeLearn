/// Monta e envia o arquivo de sessão.
///
/// Substitui um servidor pela folha de compartilhamento: em casa, o
/// responsável manda o arquivo ao professor pelo canal que preferir
/// (WhatsApp, e-mail), e o professor o importa no painel. No navegador sem
/// compartilhamento de arquivo, o arquivo é baixado.
///
/// O arquivo é montado na memória, sem `dart:io`, para servir ao Android e ao
/// navegador com o mesmo código.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:share_plus/share_plus.dart';

/// Resultado de uma exportação.
class ExportedSession {
  final Session session;
  final Uint8List bytes;

  const ExportedSession({required this.session, required this.bytes});

  String get fileName => sessionFileName(session);

  /// A sessão em JSON compacto, para a entrega cifrada: menos da metade do
  /// arquivo formatado (o percurso do time-lapse tem centenas de números,
  /// cada um numa linha no formato bonito).
  Uint8List get compactBytes =>
      Uint8List.fromList(utf8.encode(jsonEncode(session.toJson())));
}

/// Monta a sessão a partir da gravação.
ExportedSession exportSession({
  required String participantCode,
  String? activityCode,
  required String task,
  required DateTime startedAt,
  required GazeTrace trace,
  required RecordingQuality quality,
  required Map<String, double> features,
  required ModelArtifact artifact,
  GazeHeatmap? heatmap,
  double? outOfPositionRatio,
  GazePath? gazePath,
  double? calibrationErrorDegrees,
}) {
  final session = Session.fromAnalysis(
    participantCode: participantCode,
    activityCode: activityCode,
    task: task,
    startedAt: startedAt,
    durationSeconds: trace.duration,
    samplingRateHz: trace.samplingRate,
    validSampleRatio: quality.validRatio,
    features: features,
    artifact: artifact,
    heatmap: heatmap,
    outOfPositionRatio: outOfPositionRatio,
    gazePath: gazePath ?? GazePath.fromTrace(trace),
    calibrationErrorDegrees: calibrationErrorDegrees,
  );
  return ExportedSession(
    session: session,
    bytes: Uint8List.fromList(utf8.encode(session.toJsonString())),
  );
}

/// Nome do arquivo de sessão.
///
/// Começa pelo código do participante e pela tarefa para que o professor
/// reconheça o arquivo antes de abrir, e termina pelo instante em ISO sem
/// pontuação, que ordena alfabeticamente na mesma ordem cronológica.
String sessionFileName(Session session) {
  final stamp = session.startedAt
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .split('-')
      .take(6)
      .join('');
  return 'eyelearn_${session.participantCode}_${session.task}_$stamp.json';
}

/// Abre a folha de compartilhamento com o arquivo.
///
/// É ação do adulto, nunca automática: a criança termina a atividade e o
/// aparelho não envia nada por conta própria.
Future<void> shareSession(ExportedSession exported) async {
  await Share.shareXFiles(
    [
      XFile.fromData(
        exported.bytes,
        name: exported.fileName,
        mimeType: 'application/json',
      ),
    ],
    fileNameOverrides: [exported.fileName],
    subject: 'Sessão EyeLearn — ${exported.session.participantCode}',
  );
}

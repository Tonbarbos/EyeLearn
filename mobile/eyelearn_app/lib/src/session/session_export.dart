/// Grava e compartilha o arquivo de sessão.
///
/// Substitui um servidor pela folha de compartilhamento do sistema: o professor
/// recebe o arquivo pelo canal que preferir e o importa no painel. Nada trafega
/// pela rede a partir do aplicativo, o que mantém verdadeiro o parágrafo de
/// privacidade da seção 4.6 em vez de exigir reescrevê-lo.
library;

import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Resultado de uma exportação.
class ExportedSession {
  final File file;
  final Session session;

  const ExportedSession({required this.file, required this.session});
}

/// Monta a sessão, grava no diretório de documentos e devolve o arquivo.
///
/// O arquivo fica no diretório de documentos do aplicativo, não em área
/// compartilhada: só o próprio aplicativo o lê, até que o adulto escolha
/// compartilhá-lo. Em área compartilhada qualquer aplicativo do aparelho teria
/// acesso a dado comportamental de criança.
Future<ExportedSession> exportSession({
  required String participantCode,
  required String task,
  required DateTime startedAt,
  required GazeTrace trace,
  required RecordingQuality quality,
  required Map<String, double> features,
  required ModelArtifact artifact,
}) async {
  final session = Session.fromAnalysis(
    participantCode: participantCode,
    task: task,
    startedAt: startedAt,
    durationSeconds: trace.duration,
    samplingRateHz: trace.samplingRate,
    validSampleRatio: quality.validRatio,
    features: features,
    artifact: artifact,
  );

  final directory = await getApplicationDocumentsDirectory();
  final file = File('${directory.path}/${sessionFileName(session)}');
  await file.writeAsString(session.toJsonString(), flush: true);

  return ExportedSession(file: file, session: session);
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

/// Abre a folha de compartilhamento do sistema com o arquivo.
///
/// É ação do adulto, nunca automática: a criança termina a atividade e o
/// aparelho não envia nada por conta própria.
Future<void> shareSession(ExportedSession exported) async {
  await Share.shareXFiles([
    XFile(exported.file.path, mimeType: 'application/json'),
  ], subject: 'Sessão EyeLearn — ${exported.session.participantCode}');
}

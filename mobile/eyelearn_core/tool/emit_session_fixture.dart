/// Gera um arquivo de sessão de exemplo, no formato que o aplicativo grava.
///
/// Existe para fechar a fronteira de linguagem na direção contrária à dos
/// vetores de ouro: ali o Dart consome o que o Python produz; aqui o Python
/// consome o que o Dart produz. Sem este arquivo, o formato de sessão seria
/// afirmado por cada lado isoladamente, e um campo renomeado em um deles só
/// apareceria quando um professor tentasse importar uma sessão de verdade.
///
/// Rode com:
///
///     dart run tool/emit_session_fixture.dart
library;

import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';

void main() {
  final artifact = ModelArtifact.fromJsonString(
    File('assets/model_text.json').readAsStringSync(),
  );

  // Características plausíveis de uma leitura de texto a 30 Hz: cerca de
  // quatro fixações por segundo, duração média de 250 ms, poucas regressões.
  final features = <String, double>{
    'fixation_rate': 3.8,
    'fixation_duration_mean': 0.248,
    'fixation_duration_std': 0.071,
    'fixation_duration_median': 0.236,
    'saccade_rate': 3.6,
    'saccade_amplitude_mean': 2.31,
    'saccade_amplitude_std': 1.84,
    'progressive_amplitude_mean': 2.04,
    'regression_ratio': 0.17,
    'regression_rate': 0.61,
    'peak_velocity_mean': 88.4,
    'line_sweep_rate': 0.22,
    'reading_time': 31.6,
    'scanpath_length': 263.2,
  };

  final session = Session.fromAnalysis(
    participantCode: 'EXEMPLO01',
    task: 'text',
    startedAt: DateTime.utc(2026, 10, 12, 14, 30),
    durationSeconds: 31.6,
    samplingRateHz: 29.4,
    validSampleRatio: 0.91,
    features: features,
    artifact: artifact,
  );

  const path = 'assets/session_example.json';
  File(path).writeAsStringSync('${session.toJsonString()}\n');
  stdout.writeln('sessão de exemplo escrita em $path');
}

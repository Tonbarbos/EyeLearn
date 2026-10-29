import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_app/src/teacher/etdd70_comparison.dart';
import 'package:eyelearn_app/src/teacher/session_report.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter_test/flutter_test.dart';

final _example = jsonDecode(
  File('../eyelearn_core/assets/comparison_example.json').readAsStringSync(),
) as Map<String, dynamic>;

const _names = {
  'AAA222': 'Alice Prado',
  'BBB333': 'Bruno Lima',
  'CCC444': 'Carla Dias',
  'DDD555': 'Davi Rocha',
  'EEE666': 'Elisa Moura',
  'FFF777': 'Fábio Reis',
};

List<Session> _sessions() {
  final trace = GazeTrace(
    t: [for (var i = 0; i < 300; i++) i / 15],
    x: [for (var i = 0; i < 300; i++) -10.0 + (i % 30) * 0.7],
    y: [for (var i = 0; i < 300; i++) -7.0 + 2.6 * ((i ~/ 30) % 6)],
  );
  return [
    for (final raw
        in (_example['sessions'] as List).cast<Map<String, dynamic>>())
      Session.fromJson({
        ...raw,
        'heatmap':
            GazeHeatmap.fromTrace(trace, textArea: [-11.0, -9.0, 11.0, 8.0])
                .toJson(),
        'gaze_path': GazePath.fromTrace(trace).toJson(),
      }),
  ];
}

void main() {
  testWidgets('relatório de uma sessão e da turma, em PDF', (tester) async {
    final sessions = _sessions();
    final reference = (await tester.runAsync(loadEtdd70Reference))!;
    final now = DateTime(2026, 10, 29, 15);
    final one = sessions.firstWhere((s) => s.task == 'text');

    final single = (await tester.runAsync(() => buildSessionReport(
          className: '5º A',
          session: one,
          studentName: _names[one.participantCode]!,
          classSessions: sessions,
          etdd70: reference,
          now: now,
        )))!;
    expect(String.fromCharCodes(single.sublist(0, 5)), '%PDF-');

    final all = (await tester.runAsync(() => buildClassReport(
          className: '5º A',
          students: [
            for (final e in _names.entries) (code: e.key, name: e.value)
          ],
          sessions: sessions,
          etdd70: reference,
          now: now,
        )))!;
    expect(String.fromCharCodes(all.sublist(0, 5)), '%PDF-');
    expect(all.length, greaterThan(single.length));

    final out = Platform.environment['EYELEARN_PDF_OUT'];
    if (out != null) {
      File('$out-sessao.pdf').writeAsBytesSync(single);
      File('$out-turma.pdf').writeAsBytesSync(all);
    }
  });
}

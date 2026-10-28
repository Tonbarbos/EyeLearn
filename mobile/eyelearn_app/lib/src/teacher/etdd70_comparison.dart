/// Uma sessão comparada com as crianças do ETDD70.
///
/// Para quando não há turma com quem comparar: um teste com uma sessão só,
/// ou uma turma com menos de três gravações. Porta do
/// `scripts/compare_session.py`, com a mesma referência
/// (`assets/etdd70_reference.json`, de `scripts/make_etdd70_reference.py`).
///
/// **Não é diagnóstico.** A base é de crianças tchecas lendo em tcheco num
/// rastreador de bancada; a sessão é de outra pessoa, outro texto e outro
/// equipamento. O tela diz isso antes do gráfico, e o que a comparação mostra
/// bem é a distância entre o sinal da câmera e o do laboratório.
library;

import 'dart:convert';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import 'comparison_chart.dart';
import 'panel_widgets.dart';

const etdd70ReferenceAsset = 'assets/etdd70_reference.json';

/// Nome de cada característica para o professor.
const etdd70FeatureLabels = {
  'fixation_rate': 'Fixações por segundo',
  'fixation_duration_mean': 'Duração média da fixação (s)',
  'fixation_duration_std': 'Desvio da duração da fixação (s)',
  'fixation_duration_median': 'Mediana da duração da fixação (s)',
  'saccade_rate': 'Sacadas por segundo',
  'saccade_amplitude_mean': 'Amplitude média da sacada (°)',
  'saccade_amplitude_std': 'Desvio da amplitude da sacada (°)',
  'progressive_amplitude_mean': 'Amplitude da sacada para a frente (°)',
  'regression_ratio': 'Proporção de regressões',
  'regression_rate': 'Regressões por segundo',
  'peak_velocity_mean': 'Velocidade de pico média (°/s)',
  'line_sweep_rate': 'Trocas de linha por segundo',
  'reading_time': 'Tempo de leitura (s)',
  'scanpath_length': 'Comprimento do percurso (°)',
};

class GroupStats {
  final double mean;
  final double std;
  const GroupStats(this.mean, this.std);
}

class Etdd70Row {
  final String feature;
  final double value;
  final GroupStats typical;
  final GroupStats dyslexic;

  const Etdd70Row(this.feature, this.value, this.typical, this.dyslexic);

  /// Desvios em relação às crianças sem dislexia.
  double get zTypical =>
      typical.std > 0 ? (value - typical.mean) / typical.std : 0;
}

class Etdd70Comparison {
  final String conditionLabel;
  final int nTypical;
  final int nDyslexic;
  final List<Etdd70Row> rows;

  const Etdd70Comparison({
    required this.conditionLabel,
    required this.nTypical,
    required this.nDyslexic,
    required this.rows,
  });
}

/// A condição da referência mais próxima da taxa da sessão.
String etdd70Condition(double rateHz) => rateHz >= 100
    ? 'original'
    : rateHz < 22.5
        ? '15hz_2deg'
        : '30hz_2deg';

/// Compara; `null` se a referência não tem a tarefa.
Etdd70Comparison? compareWithEtdd70(
    Session session, Map<String, dynamic> reference) {
  final task = (reference['tasks'] as Map<String, dynamic>)[session.task];
  if (task == null) return null;
  final condition =
      (task as Map<String, dynamic>)[etdd70Condition(session.samplingRateHz)]
          as Map<String, dynamic>;
  final groups = condition['groups'] as Map<String, dynamic>;
  GroupStats stats(String group, String feature) {
    final f = ((groups[group] as Map<String, dynamic>)['features']
        as Map<String, dynamic>)[feature] as Map<String, dynamic>;
    return GroupStats(
        (f['mean'] as num).toDouble(), (f['std'] as num).toDouble());
  }

  return Etdd70Comparison(
    conditionLabel: condition['label'] as String,
    nTypical: (groups['typical'] as Map<String, dynamic>)['n'] as int,
    nDyslexic: (groups['dyslexic'] as Map<String, dynamic>)['n'] as int,
    rows: [
      for (final name in (reference['feature_names'] as List).cast<String>())
        Etdd70Row(name, session.features[name] ?? 0, stats('typical', name),
            stats('dyslexic', name)),
    ],
  );
}

Future<Map<String, dynamic>> loadEtdd70Reference() async =>
    jsonDecode(await rootBundle.loadString(etdd70ReferenceAsset))
        as Map<String, dynamic>;

/// Abre a comparação de uma sessão.
Future<void> showEtdd70Comparison(
  BuildContext context,
  Session session,
  String studentName, {
  Future<Map<String, dynamic>> Function() loadReference = loadEtdd70Reference,
}) async {
  final reference = await loadReference();
  if (!context.mounted) return;
  final comparison = compareWithEtdd70(session, reference);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      // No celular, a margem padrão do diálogo come um terço da largura.
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      title: Text('$studentName × ETDD70'),
      content: SizedBox(
        width: 720,
        child: comparison == null
            ? const Text('A base não tem esta tarefa.')
            : _ComparisonBody(session: session, comparison: comparison),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fechar'),
        ),
      ],
    ),
  );
}

class _ComparisonBody extends StatelessWidget {
  final Session session;
  final Etdd70Comparison comparison;

  const _ComparisonBody({required this.session, required this.comparison});

  @override
  Widget build(BuildContext context) {
    String n(double v) => v.abs() >= 100
        ? v.toStringAsFixed(0)
        : v.abs() >= 10
            ? v.toStringAsFixed(1)
            : v.toStringAsFixed(2);
    final far = comparison.rows.where((r) => r.zTypical.abs() > 3).length;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Referência: ETDD70 a ${comparison.conditionLabel}, a condição '
            'mais próxima desta sessão (${session.samplingRateHz.round()} Hz). '
            '${comparison.nTypical} crianças sem dislexia e '
            '${comparison.nDyslexic} com.',
            style: AppType.body.copyWith(fontSize: 14, color: Palette.inkMuted),
          ),
          const SizedBox(height: 10),
          const ErrorNotice(
            'Não é diagnóstico. A base é de crianças tchecas lendo em tcheco '
            'num rastreador de laboratório; esta sessão é de outra pessoa, '
            'outro texto e outro equipamento. Tempo de leitura e comprimento '
            'do percurso dependem do tamanho do texto e não se comparam.',
          ),
          const SizedBox(height: 14),
          Text(
              'Desvios em relação às crianças sem dislexia '
              '($far de ${comparison.rows.length} características a mais de '
              '3 desvios):',
              style: AppType.subtitle),
          const SizedBox(height: 8),
          ComparisonChart(
            scores: {for (final r in comparison.rows) r.feature: r.zTypical},
            reference: 'às crianças sem dislexia da base',
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth < 520
                ? _FeatureList(comparison: comparison, format: n)
                : Table(
                    key: const Key('etdd70-table'),
                    columnWidths: const {0: FlexColumnWidth(3)},
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    children: [
                      TableRow(
                        children: [
                          for (final h in [
                            'Característica',
                            'Sessão',
                            'Sem dislexia',
                            'Com dislexia',
                            'Desvios',
                          ])
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(h, style: AppType.label),
                            ),
                        ],
                      ),
                      for (final r in comparison.rows)
                        TableRow(
                          children: [
                            Text(etdd70FeatureLabels[r.feature] ?? r.feature,
                                style: AppType.body.copyWith(fontSize: 13.5)),
                            Text(n(r.value)),
                            Text('${n(r.typical.mean)} ± ${n(r.typical.std)}'),
                            Text(
                                '${n(r.dyslexic.mean)} ± ${n(r.dyslexic.std)}'),
                            Text(
                              '${r.zTypical >= 0 ? '+' : '−'}'
                              '${r.zTypical.abs().toStringAsFixed(1)}',
                              style: TextStyle(
                                fontWeight: r.zTypical.abs() > 3
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// A tabela das características, para tela estreita: uma linha por
/// característica, com os números embaixo do nome em vez de em colunas.
class _FeatureList extends StatelessWidget {
  final Etdd70Comparison comparison;
  final String Function(double) format;

  const _FeatureList({required this.comparison, required this.format});

  @override
  Widget build(BuildContext context) => Column(
        key: const Key('etdd70-table'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in comparison.rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(etdd70FeatureLabels[r.feature] ?? r.feature,
                            style: AppType.body.copyWith(fontSize: 14.5)),
                      ),
                      Text(
                        '${r.zTypical >= 0 ? '+' : '−'}'
                        '${r.zTypical.abs().toStringAsFixed(1)}',
                        style: AppType.body.copyWith(
                          fontSize: 14.5,
                          fontWeight: r.zTypical.abs() > 3
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'sessão ${format(r.value)} · sem dislexia '
                    '${format(r.typical.mean)} ± ${format(r.typical.std)} · '
                    'com ${format(r.dyslexic.mean)} ± ${format(r.dyslexic.std)}',
                    style: AppType.body
                        .copyWith(fontSize: 12.5, color: Palette.inkMuted),
                  ),
                ],
              ),
            ),
        ],
      );
}

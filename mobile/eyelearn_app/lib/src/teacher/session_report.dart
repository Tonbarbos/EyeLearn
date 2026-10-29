/// Relatório em PDF das sessões: de uma sessão de um aluno, ou da turma
/// inteira (a gravação mais recente de cada aluno em cada tarefa).
///
/// Leva o que o painel mostra e cabe em papel: a qualidade da captura, o mapa
/// de calor com o texto, as características comparadas com a turma e com as
/// crianças sem dislexia do ETDD70, e as sugestões pedagógicas. O time-lapse
/// fica de fora, por ser animação.
///
/// O PDF é montado no navegador (pacote `pdf`, Dart puro) e entregue como
/// download: nada sai do aparelho do professor. O relatório leva nomes de
/// crianças, por isso o aviso no rodapé de cada página.
library;

import 'dart:ui' as ui;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'etdd70_comparison.dart';
import 'heatmap_view.dart';
import 'panel_widgets.dart';

/// O aviso que vai em todo relatório.
const reportDisclaimer =
    'Não é diagnóstico. O EyeLearn descreve o padrão de leitura e sugere '
    'adaptações ao professor; avaliação clínica é de profissional '
    'habilitado. A comparação com o ETDD70 usa crianças tchecas lendo em '
    'tcheco num rastreador de laboratório: serve de referência, não de '
    'régua. Documento com dados de crianças: guarde e compartilhe com '
    'cuidado.';

/// Um aluno no relatório.
typedef ReportStudent = ({String code, String name});

/// Relatório de uma sessão.
Future<Uint8List> buildSessionReport({
  required String className,
  required Session session,
  required String studentName,
  required List<Session> classSessions,
  Map<String, dynamic>? etdd70,
  required DateTime now,
}) async {
  final fonts = await _ReportFonts.load();
  final doc = _document(fonts);
  final section = await _SessionSection.prepare(
      session, studentName, classSessions, etdd70);
  doc.addPage(_page(
    fonts,
    now,
    [
      _title(fonts, 'Relatório de leitura', '$studentName · $className'),
      _disclaimer(fonts),
      ...section.build(fonts),
    ],
  ));
  return doc.save();
}

/// Relatório da turma: um resumo e, por aluno, a sessão mais recente de cada
/// tarefa.
Future<Uint8List> buildClassReport({
  required String className,
  required List<ReportStudent> students,
  required List<Session> sessions,
  Map<String, dynamic>? etdd70,
  required DateTime now,
}) async {
  final fonts = await _ReportFonts.load();
  final doc = _document(fonts);
  final names = {for (final s in students) s.code: s.name};
  String nameOf(String code) => names[code] ?? code;

  // A mais recente de cada aluno em cada tarefa.
  final latest = <(String, String), Session>{};
  for (final s in sessions) {
    final key = (s.participantCode, s.task);
    final current = latest[key];
    if (current == null || s.startedAt.isAfter(current.startedAt)) {
      latest[key] = s;
    }
  }
  final chosen = latest.values.toList()
    ..sort((a, b) {
      final byName =
          nameOf(a.participantCode).compareTo(nameOf(b.participantCode));
      return byName != 0 ? byName : a.task.compareTo(b.task);
    });

  final sections = [
    for (final s in chosen)
      await _SessionSection.prepare(
          s, nameOf(s.participantCode), sessions, etdd70),
  ];

  doc.addPage(_page(fonts, now, [
    _title(fonts, 'Relatório de leitura da turma', className),
    _disclaimer(fonts),
    pw.Text(
      '${chosen.length} gravações (a mais recente de cada aluno em cada '
      'tarefa), de ${sessions.length} no total.',
      style: fonts.body,
    ),
    pw.SizedBox(height: 10),
    _summaryTable(fonts, sections),
  ]));
  // Uma página (ou mais, se não couber) por aluno, com as tarefas dele.
  final byStudent = <String, List<_SessionSection>>{};
  for (final section in sections) {
    byStudent
        .putIfAbsent(section.session.participantCode, () => [])
        .add(section);
  }
  for (final group in byStudent.values) {
    doc.addPage(_page(fonts, now, [
      _title(fonts, group.first.studentName, className),
      for (final section in group) ...section.build(fonts),
    ]));
  }
  return doc.save();
}

// -- peças -------------------------------------------------------------------

class _ReportFonts {
  final pw.Font regular;
  final pw.Font bold;
  _ReportFonts(this.regular, this.bold);

  /// A Roboto que o aplicativo já leva: tem os acentos e os símbolos que a
  /// fonte padrão do PDF não tem.
  static Future<_ReportFonts> load() async => _ReportFonts(
        pw.Font.ttf(await rootBundle.load('fonts/Roboto-Regular.ttf')),
        pw.Font.ttf(await rootBundle.load('fonts/Roboto-Medium.ttf')),
      );

  pw.TextStyle get body =>
      pw.TextStyle(font: regular, fontSize: 9.5, color: _ink);
  pw.TextStyle get muted =>
      pw.TextStyle(font: regular, fontSize: 8.5, color: _muted);
  pw.TextStyle get strong =>
      pw.TextStyle(font: bold, fontSize: 9.5, color: _ink);
  pw.TextStyle get heading =>
      pw.TextStyle(font: bold, fontSize: 13, color: _ink);
  pw.TextStyle get title => pw.TextStyle(font: bold, fontSize: 18, color: _ink);
}

const _ink = PdfColor.fromInt(0xFF1C2033);
const _muted = PdfColor.fromInt(0xFF6B7194);
const _line = PdfColor.fromInt(0xFFE6E5F2);
const _brand = PdfColor.fromInt(0xFF5B4BE8);
const _amber = PdfColor.fromInt(0xFF9A5B00);
const _coralSoft = PdfColor.fromInt(0xFFFFE9E6);
const _coral = PdfColor.fromInt(0xFFA32317);

pw.Document _document(_ReportFonts fonts) => pw.Document(
      title: 'Relatório de leitura · EyeLearn',
      creator: 'EyeLearn',
      theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
    );

pw.MultiPage _page(
        _ReportFonts fonts, DateTime now, List<pw.Widget> children) =>
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 30),
      footer: (context) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(
                'EyeLearn · não é diagnóstico · contém dados de crianças · '
                'gerado em ${formatDateTime(now)}',
                style: fonts.muted.copyWith(fontSize: 7.5),
              ),
            ),
            pw.Text('${context.pageNumber} de ${context.pagesCount}',
                style: fonts.muted.copyWith(fontSize: 7.5)),
          ],
        ),
      ),
      build: (_) => children,
    );

pw.Widget _title(_ReportFonts fonts, String title, String subtitle) =>
    pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _brand, width: 2)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(title, style: fonts.title),
          pw.Text(subtitle, style: fonts.muted.copyWith(fontSize: 10)),
        ],
      ),
    );

pw.Widget _disclaimer(_ReportFonts fonts) => pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 10),
      padding: const pw.EdgeInsets.all(8),
      decoration: const pw.BoxDecoration(
        color: _coralSoft,
        borderRadius: pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Text(reportDisclaimer,
          style: fonts.body.copyWith(color: _coral, fontSize: 8.5)),
    );

pw.Widget _summaryTable(_ReportFonts fonts, List<_SessionSection> sections) =>
    pw.TableHelper.fromTextArray(
      headers: ['Aluno', 'Tarefa', 'Data', 'Captura', 'Fora da faixa da turma'],
      data: [
        for (final s in sections)
          [
            s.studentName,
            taskLabel(s.session.task),
            formatDateTime(s.session.startedAt),
            s.session.hasUsableQuality() ? 'boa' : 'baixa',
            s.classZ == null
                ? '—'
                : s.outsideClass.isEmpty
                    ? 'nenhuma'
                    : s.outsideClass.join(', '),
          ],
      ],
      headerStyle: fonts.strong.copyWith(fontSize: 8.5),
      cellStyle: fonts.body.copyWith(fontSize: 8.5),
      headerDecoration: const pw.BoxDecoration(color: _line),
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _line, width: 0.5),
        bottom: pw.BorderSide(color: _line, width: 0.5),
      ),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      columnWidths: {
        0: const pw.FlexColumnWidth(2.2),
        1: const pw.FlexColumnWidth(1.6),
        2: const pw.FlexColumnWidth(1.4),
        3: const pw.FlexColumnWidth(0.9),
        4: const pw.FlexColumnWidth(3),
      },
    );

/// Uma sessão no relatório, com tudo calculado antes de montar a página.
class _SessionSection {
  final Session session;
  final String studentName;

  /// Desvios em relação à turma; `null` se a turma tem menos de três
  /// crianças nessa tarefa, ou se esta não é a gravação que entra na
  /// comparação (vale a mais recente de boa qualidade).
  final Map<String, double>? classZ;
  final String? classNote;
  final List<String> suggestions;
  final Etdd70Comparison? etdd70;
  final Uint8List? heatmapPng;

  _SessionSection({
    required this.session,
    required this.studentName,
    required this.classZ,
    required this.classNote,
    required this.suggestions,
    required this.etdd70,
    required this.heatmapPng,
  });

  List<String> get outsideClass => [
        for (final (name, label) in presentedFeatures)
          if ((classZ?[name]?.abs() ?? 0) >= highlightThreshold) label,
      ];

  static Future<_SessionSection> prepare(
    Session session,
    String studentName,
    List<Session> classSessions,
    Map<String, dynamic>? etdd70,
  ) async {
    Map<String, double>? classZ;
    String? note;
    var suggestions = const <String>[];
    try {
      final comparison = compareWithinClass(classSessions, session.task);
      final latest = classSessions
          .where((s) =>
              s.participantCode == session.participantCode &&
              s.task == session.task &&
              s.hasUsableQuality())
          .fold<Session?>(
              null,
              (best, s) => best == null || s.startedAt.isAfter(best.startedAt)
                  ? s
                  : best);
      if (latest != null &&
          latest.startedAt == session.startedAt &&
          comparison.participantCodes.contains(session.participantCode)) {
        classZ = comparison.forParticipant(session.participantCode);
        suggestions = comparison.suggestionsFor(session.participantCode);
      } else {
        note = session.hasUsableQuality()
            ? 'Não é a gravação mais recente desta tarefa; a comparação com '
                'a turma usa a mais recente.'
            : 'Gravação com qualidade baixa: fica fora da comparação com a '
                'turma.';
      }
    } on NotEnoughParticipants catch (error) {
      note = 'A turma tem ${error.count} '
          '${error.count == 1 ? 'criança' : 'crianças'} nesta tarefa; a '
          'comparação com a turma começa com três.';
    }
    return _SessionSection(
      session: session,
      studentName: studentName,
      classZ: classZ,
      classNote: note,
      suggestions: suggestions,
      etdd70: etdd70 == null ? null : compareWithEtdd70(session, etdd70),
      heatmapPng: session.heatmap == null
          ? null
          : await renderHeatmapPng(session.heatmap!, session.task),
    );
  }

  List<pw.Widget> build(_ReportFonts fonts) {
    final s = session;
    final map = s.heatmap;
    final path = s.gazePath;
    final facts = <(String, String)>[
      ('Duração', '${s.durationSeconds.round()} s'),
      ('Quadros por segundo', '${s.samplingRateHz.round()}'),
      ('Amostras aproveitáveis', '${(100 * s.validSampleRatio).round()}%'),
      ('Captura', s.hasUsableQuality() ? 'boa' : 'baixa'),
      if (map?.onTextFraction case final f?)
        ('Olhar sobre o texto', '${(100 * f).round()}% do tempo'),
      if (path != null && map != null && !path.isEmpty)
        (
          'Olhar fora da tela',
          '${(100 * path.offScreenFraction(map.halfWidth, map.halfHeight)).round()}% do tempo'
        ),
      if (s.outOfPositionRatio case final r?)
        ('Fora da posição da calibração', '${(100 * r).round()}% do tempo'),
    ];

    return [
      pw.Container(
        margin: const pw.EdgeInsets.only(top: 6, bottom: 6),
        child: pw.Text(
          '${taskLabel(s.task)} · ${formatDateTime(s.startedAt)}',
          style: fonts.heading,
        ),
      ),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (heatmapPng case final png?)
            pw.Container(
              width: 150,
              margin: const pw.EdgeInsets.only(right: 14),
              child: pw.Column(
                children: [
                  pw.Image(pw.MemoryImage(png), width: 150),
                  pw.SizedBox(height: 3),
                  pw.Text('Onde o olhar ficou (a tela do celular)',
                      style: fonts.muted, textAlign: pw.TextAlign.center),
                ],
              ),
            ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final (label, value) in facts)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 2),
                    child: pw.Row(children: [
                      pw.Expanded(child: pw.Text(label, style: fonts.muted)),
                      pw.Text(value, style: fonts.strong),
                    ]),
                  ),
                if (!s.hasUsableQuality())
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 4),
                    child: pw.Text(
                      'Captura com qualidade baixa (pouca imagem do rosto ou '
                      'câmera lenta): leia os números com cautela.',
                      style: fonts.body.copyWith(color: _amber),
                    ),
                  ),
                pw.SizedBox(height: 8),
                _featureTable(fonts),
                if (classNote case final note?)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 4),
                    child: pw.Text(note, style: fonts.muted),
                  ),
                if (etdd70 case final e?)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 2),
                    child: pw.Text('ETDD70: ${e.conditionLabel}.',
                        style: fonts.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
      if (suggestions.isNotEmpty) ...[
        pw.SizedBox(height: 8),
        pw.Text('O que pode ajudar', style: fonts.strong),
        for (final text in suggestions)
          pw.Bullet(text: text, style: fonts.body),
      ],
      pw.SizedBox(height: 14),
    ];
  }

  pw.Widget _featureTable(_ReportFonts fonts) {
    final etddZ = {for (final r in etdd70?.rows ?? <Etdd70Row>[]) r.feature: r};
    String z(double? v) => v == null
        ? '—'
        : '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(v.abs() >= 10 ? 0 : 1)}'
            .replaceAll('.', ',');
    return pw.TableHelper.fromTextArray(
      headers: ['Característica', 'Valor', 'Turma', 'ETDD70 sem dislexia'],
      data: [
        for (final (name, label) in presentedFeatures)
          [
            label,
            _formatValue(name, s: session),
            classZ == null
                ? '—'
                : '${z(classZ![name])} (${describeDirection(classZ![name] ?? 0)})',
            z(etddZ[name]?.zTypical),
          ],
      ],
      headerStyle: fonts.strong.copyWith(fontSize: 8.5),
      cellStyle: fonts.body.copyWith(fontSize: 8.5),
      headerDecoration: const pw.BoxDecoration(color: _line),
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _line, width: 0.5),
        bottom: pw.BorderSide(color: _line, width: 0.5),
      ),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      columnWidths: {
        0: const pw.FlexColumnWidth(2.2),
        1: const pw.FlexColumnWidth(1.2),
        2: const pw.FlexColumnWidth(2.2),
        3: const pw.FlexColumnWidth(1.3),
      },
      cellAlignments: {
        1: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
      },
    );
  }
}

/// Valor de uma característica com a unidade.
String _formatValue(String name, {required Session s}) {
  final v = s.features[name];
  if (v == null) return '—';
  String n(double x, int digits) =>
      x.toStringAsFixed(digits).replaceAll('.', ',');
  return switch (name) {
    'fixation_duration_mean' => '${n(v * 1000, 0)} ms',
    'fixation_rate' => '${n(v, 1)}/s',
    'regression_ratio' => '${n(100 * v, 0)}%',
    'saccade_amplitude_mean' => '${n(v, 1)}°',
    'line_sweep_rate' => '${n(v, 2)}/s',
    'reading_time' => '${n(v, 0)} s',
    _ => n(v, 2),
  };
}

/// O mapa de calor da sessão como PNG, desenhado como no painel.
Future<Uint8List> renderHeatmapPng(GazeHeatmap map, String task,
    {double width = 300}) async {
  final height = width * map.halfHeight / map.halfWidth;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paintHeatmap(canvas, Size(width, height), map, sessionPassage(task));
  final image =
      await recorder.endRecording().toImage(width.round(), height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

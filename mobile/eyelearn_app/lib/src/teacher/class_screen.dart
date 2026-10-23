/// Uma turma: a leitura comparada com a turma, os alunos, as atividades com o
/// link para as famílias e as sessões importadas.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'comparison_chart.dart';
import 'panel_widgets.dart';
import 'teacher_controller.dart';

/// Texto para o grupo das famílias. O código vai separado, de propósito.
/// Igual a `parents_message` do painel Python.
String parentsMessage(String className, String link) =>
    'Atividade de leitura do EyeLearn ($className).\n\n'
    'Abra o link no celular, digite o código da turma que a professora '
    'mandou à parte, e deixe a criança escolher o nome e digitar o PIN. '
    'São poucos minutos, num lugar com boa luz, com o celular apoiado na '
    'mesa. A câmera é usada só no aparelho: nenhuma imagem sai dele.\n\n'
    '$link';

class ClassScreen extends StatelessWidget {
  final TeacherController controller;
  final VaultClass target;

  const ClassScreen({
    super.key,
    required this.controller,
    required this.target,
  });

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmAction(
      context,
      title: 'Apagar a turma ${target.name}?',
      body: 'Os alunos, as atividades e as sessões desta turma serão apagados '
          'deste navegador. Links já enviados param de servir.',
      action: 'Apagar a turma',
    );
    if (!ok || !context.mounted) return;
    await controller.change((v) => v.deleteClass(target));
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Scaffold(
            appBar: AppBar(
              title: Text(target.name),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (_) => _delete(context),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'apagar', child: Text('Apagar a turma')),
                  ],
                ),
              ],
              bottom: const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                tabs: [
                  Tab(text: 'Leitura da turma'),
                  Tab(text: 'Alunos'),
                  Tab(text: 'Atividades e link'),
                  Tab(text: 'Sessões'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                ComparisonTab(controller: controller, target: target),
                StudentsTab(controller: controller, target: target),
                ActivitiesTab(controller: controller, target: target),
                SessionsTab(controller: controller, target: target),
              ],
            ),
          ),
        ),
      );
}

String _nameOf(VaultClass target, String code) =>
    target.studentByCode(code)?.fullName ?? code;

// -- leitura da turma ----------------------------------------------------------

class ComparisonTab extends StatefulWidget {
  final TeacherController controller;
  final VaultClass target;

  const ComparisonTab({
    super.key,
    required this.controller,
    required this.target,
  });

  @override
  State<ComparisonTab> createState() => _ComparisonTabState();
}

class _ComparisonTabState extends State<ComparisonTab> {
  String _task = 'text';
  String? _selected;

  VaultClass get target => widget.target;

  @override
  Widget build(BuildContext context) {
    final sessions = target.sessions;
    final lowQuality =
        sessions.where((s) => s.task == _task && !s.hasUsableQuality()).length;
    ClassComparison? comparison;
    String? notEnough;
    try {
      comparison = compareWithinClass(sessions, _task);
    } on NotEnoughParticipants catch (error) {
      notEnough = error.message;
    }

    return PanelBody(
      children: [
        SegmentedButton<String>(
          segments: [
            for (final task in homeworkTasks)
              ButtonSegment(value: task, label: Text(taskLabel(task))),
          ],
          selected: {_task},
          onSelectionChanged: (s) => setState(() {
            _task = s.first;
            _selected = null;
          }),
        ),
        const SizedBox(height: 16),
        if (comparison == null)
          AppCard(child: Text(notEnough!, style: AppType.subtitle))
        else
          ..._comparison(comparison),
        if (lowQuality > 0) ...[
          const SizedBox(height: 12),
          Text(
            '${plural(lowQuality, 'gravação', 'gravações')} desta tarefa '
            'com qualidade baixa (pouca imagem do rosto ou câmera lenta) '
            '${lowQuality == 1 ? 'ficou' : 'ficaram'} fora da comparação.',
            style: AppType.body.copyWith(fontSize: 14, color: Palette.inkMuted),
          ),
        ],
        const SizedBox(height: 16),
        const NoticeCard(
          icon: Icons.info_outline_rounded,
          tint: Color(0xFF3A2FB0),
          background: Palette.brandSoft,
          text: 'Isto não é diagnóstico. O painel mostra a que distância da '
              'média da turma está a leitura de cada criança, para orientar '
              'uma observação mais atenta. Dislexia só se avalia com '
              'profissional habilitado.',
        ),
      ],
    );
  }

  List<Widget> _comparison(ClassComparison comparison) {
    final presented = {for (final (name, _) in presentedFeatures) name};
    final labels = {for (final (name, label) in presentedFeatures) name: label};
    // Quem mais se afasta primeiro: é quem o gráfico mostra ao abrir.
    final flagged = [
      for (final MapEntry(key: code, value: features)
          in comparison.outliers().entries)
        if (features.any(presented.contains))
          (code, features.where(presented.contains).toList()),
    ]..sort((a, b) {
        final byCount = b.$2.length.compareTo(a.$2.length);
        return byCount != 0
            ? byCount
            : _nameOf(target, a.$1).compareTo(_nameOf(target, b.$1));
      });
    final outliers = {for (final (code, features) in flagged) code: features};
    final codes = [...comparison.participantCodes]
      ..sort((a, b) => _nameOf(target, a).compareTo(_nameOf(target, b)));
    final selected = codes.contains(_selected)
        ? _selected!
        : (outliers.keys.isNotEmpty ? outliers.keys.first : codes.first);
    final scores = comparison.forParticipant(selected);
    final suggestions = comparison.suggestionsFor(selected);

    return [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Fora da faixa da turma', style: AppType.title),
            const SizedBox(height: 4),
            Text(
              '${plural(codes.length, 'criança comparada', 'crianças comparadas')}'
              ' (vale a gravação mais recente de cada uma).',
              style: AppType.body.copyWith(color: Palette.inkMuted),
            ),
            const SizedBox(height: 12),
            if (outliers.isEmpty)
              const Text('Ninguém fora da faixa de ±1,5 desvio nesta tarefa.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(key: code, value: features)
                      in outliers.entries)
                    ActionChip(
                      avatar: Icon(
                        Icons.visibility_outlined,
                        size: 18,
                        color: code == selected ? Colors.white : Palette.brand,
                      ),
                      backgroundColor:
                          code == selected ? Palette.brand : Palette.brandSoft,
                      labelStyle: TextStyle(
                          color: code == selected ? Colors.white : Palette.ink),
                      label: Text('${_nameOf(target, code)} · '
                          '${features.map((f) => labels[f]!.toLowerCase()).join(', ')}'),
                      onPressed: () => setState(() => _selected = code),
                    ),
                ],
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButton<String>(
              value: selected,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              style: AppType.title.copyWith(color: Palette.ink),
              items: [
                for (final code in codes)
                  DropdownMenuItem(
                      value: code, child: Text(_nameOf(target, code))),
              ],
              onChanged: (code) => setState(() => _selected = code),
            ),
            const SizedBox(height: 8),
            ComparisonChart(scores: scores),
            const SizedBox(height: 16),
            if (suggestions.isEmpty)
              Text(
                'Nenhuma característica acima da faixa da turma: nada a '
                'sugerir nesta tarefa.',
                style: AppType.body.copyWith(color: Palette.inkMuted),
              )
            else ...[
              const Text('Sugestões', style: AppType.subtitle),
              const SizedBox(height: 8),
              for (final text in suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Icon(Icons.lightbulb_outline_rounded,
                            size: 18, color: aboveClass),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(text, style: AppType.body)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    ];
  }
}

// -- alunos --------------------------------------------------------------------

class StudentsTab extends StatelessWidget {
  final TeacherController controller;
  final VaultClass target;

  const StudentsTab({
    super.key,
    required this.controller,
    required this.target,
  });

  Future<void> _add(BuildContext context) async {
    final names = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Adicionar alunos'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Um nome completo por linha. O sistema sorteia um '
                  'PIN de 4 dígitos para cada criança.'),
              const SizedBox(height: 12),
              panelField(names, 'Nomes', Icons.people_outline_rounded,
                  maxLines: 10, autofocus: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Adicionar'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final lines = [
      for (final line in names.text.split('\n'))
        if (line.trim().isNotEmpty) line,
    ];
    final added = <NewStudent>[];
    final problems = <String>[];
    await controller.change((v) {
      for (final line in lines) {
        try {
          added.add(v.addStudent(target, line));
        } on VaultError catch (error) {
          problems.add(sentence(error.message));
        }
      }
    });
    if (context.mounted && (added.isNotEmpty || problems.isNotEmpty)) {
      await _showPins(context, added, problems);
    }
  }

  Future<void> _showPins(
    BuildContext context,
    List<NewStudent> added,
    List<String> problems,
  ) {
    final list = [
      for (final s in added) '${s.student.fullName}: PIN ${s.pin}',
    ].join('\n');
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(added.length == 1 ? 'Anote o PIN' : 'Anote os PINs'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (added.isNotEmpty) ...[
                  const Text('Eles aparecem só agora. Entregue a cada criança '
                      'o seu, num bilhete ou na agenda; depois, o painel só '
                      'pode sortear um novo.'),
                  const SizedBox(height: 12),
                  for (final s in added)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text(s.student.fullName,
                                  style: AppType.body)),
                          Text(s.pin,
                              style: AppType.title.copyWith(letterSpacing: 4)),
                        ],
                      ),
                    ),
                ],
                for (final p in problems) ...[
                  const SizedBox(height: 8),
                  ErrorNotice(p),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (added.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: list));
                showMessage(context, 'Lista copiada.');
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copiar a lista'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Anotei'),
          ),
        ],
      ),
    );
  }

  Future<void> _resetPin(BuildContext context, VaultStudent student) async {
    final ok = await confirmAction(
      context,
      title: 'Sortear outro PIN para ${student.fullName}?',
      body: 'O PIN atual para de funcionar no próximo link que você mandar.',
      action: 'Sortear',
    );
    if (!ok || !context.mounted) return;
    final pin = await controller.change((v) => v.resetPin(student));
    if (context.mounted) {
      await _showPins(context, [NewStudent(student, pin)], const []);
    }
  }

  Future<void> _delete(BuildContext context, VaultStudent student) async {
    final ok = await confirmAction(
      context,
      title: 'Apagar ${student.fullName}?',
      body: 'O aluno e todas as sessões dele serão apagados deste navegador. '
          'É o que atende a um pedido de eliminação dos dados (LGPD).',
      action: 'Apagar',
    );
    if (!ok || !context.mounted) return;
    await controller.change((v) => v.deleteStudent(target, student));
  }

  @override
  Widget build(BuildContext context) {
    final students = target.sortedStudents;
    final counts = <String, int>{};
    for (final p in target.sessionPayloads) {
      final code = p['participant_code'] as String;
      counts[code] = (counts[code] ?? 0) + 1;
    }
    return PanelBody(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(plural(students.length, 'aluno', 'alunos'),
                  style: AppType.title),
            ),
            FilledButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.person_add_alt_rounded),
              label: const Text('Adicionar alunos'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (students.isEmpty)
          const AppCard(child: Text('Nenhum aluno ainda.'))
        else
          PanelList(
            child: Column(
              children: [
                for (final s in students)
                  ListTile(
                    title: Text(s.fullName),
                    subtitle: Text('código ${s.code} · '
                        '${plural(counts[s.code] ?? 0, 'sessão', 'sessões')}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (choice) => choice == 'pin'
                          ? _resetPin(context, s)
                          : _delete(context, s),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: 'pin', child: Text('Sortear outro PIN')),
                        PopupMenuItem(value: 'apagar', child: Text('Apagar')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text(
          'As famílias veem só o primeiro nome e a inicial do sobrenome '
          '("Ana S."). Nome completo e data de nascimento ficam só aqui.',
          style: AppType.body.copyWith(fontSize: 14, color: Palette.inkMuted),
        ),
      ],
    );
  }
}

// -- atividades e link -------------------------------------------------------

class ActivitiesTab extends StatefulWidget {
  final TeacherController controller;
  final VaultClass target;

  const ActivitiesTab({
    super.key,
    required this.controller,
    required this.target,
  });

  @override
  State<ActivitiesTab> createState() => _ActivitiesTabState();
}

class _ActivitiesTabState extends State<ActivitiesTab> {
  ShareLink? _link;
  bool _sealing = false;

  TeacherController get controller => widget.controller;
  VaultClass get target => widget.target;

  Future<void> _create() async {
    final today = controller.now;
    var task = 'text';
    var opens = DateTime(today.year, today.month, today.day);
    var due = opens.add(const Duration(days: 7));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          Future<DateTime?> pick(DateTime initial) => showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: opens.isBefore(today) ? opens : today,
                lastDate: today.add(const Duration(days: 365)),
              );
          return AlertDialog(
            title: const Text('Nova atividade'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: task,
                    decoration: const InputDecoration(labelText: 'Leitura'),
                    items: [
                      for (final t in homeworkTasks)
                        DropdownMenuItem(value: t, child: Text(taskLabel(t))),
                    ],
                    onChanged: (v) => setDialog(() => task = v ?? task),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_available_rounded),
                    title: const Text('Começa em'),
                    subtitle: Text(formatDate(opens)),
                    onTap: () async {
                      final d = await pick(opens);
                      if (d != null) {
                        setDialog(() {
                          opens = d;
                          if (due.isBefore(opens)) due = opens;
                        });
                      }
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_busy_rounded),
                    title: const Text('Prazo (até o fim do dia)'),
                    subtitle: Text(formatDate(due)),
                    onTap: () async {
                      final d = await pick(due);
                      if (d != null) setDialog(() => due = d);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Criar'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;
    await guard(context, () async {
      await controller.change((v) => v.createActivity(target, task,
          due: due, opens: opens, today: controller.now));
      setState(() => _link = null);
      if (mounted) {
        showMessage(context, 'Atividade criada. Gere e mande o link de novo.');
      }
    });
  }

  Future<void> _delete(VaultActivity activity) async {
    final ok = await confirmAction(
      context,
      title: 'Apagar a atividade?',
      body: 'Ela some do próximo link. Sessões já importadas ficam.',
      action: 'Apagar',
    );
    if (!ok || !mounted) return;
    await controller.change((v) => v.deleteActivity(target, activity));
    setState(() => _link = null);
  }

  Future<void> _generate() async {
    setState(() => _sealing = true);
    // Um quadro para o indicador aparecer: a chave do link leva um instante.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      final link = await controller.change((v) => v.shareLink(target,
          baseUrl: controller.environment.appUrl, now: controller.now));
      if (mounted) setState(() => _link = link);
    } finally {
      if (mounted) setState(() => _sealing = false);
    }
  }

  Future<void> _newCode() async {
    final ok = await confirmAction(
      context,
      title: 'Trocar o código da turma?',
      body: 'Os links já enviados deixam de abrir. Será preciso mandar às '
          'famílias o link novo e o código novo.',
      action: 'Trocar o código',
    );
    if (!ok || !mounted) return;
    await controller.change((v) => v.newAccessCode(target));
    await _generate();
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    showMessage(context, '$what copiado.');
  }

  @override
  Widget build(BuildContext context) {
    final now = controller.now;
    final done = target.completedActivityCodes();
    final activities = target.sortedActivities;
    final link = _link;
    return PanelBody(
      children: [
        Row(
          children: [
            const Expanded(
                child: Text('Atividades de casa', style: AppType.title)),
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nova atividade'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (activities.isEmpty)
          const AppCard(child: Text('Nenhuma atividade ainda.'))
        else
          PanelList(
            child: Column(
              children: [
                for (final a in activities)
                  ListTile(
                    leading: _StatusDot(activity: a, now: now),
                    title: Text(taskLabel(a.task)),
                    subtitle: Text(
                      'de ${formatShortDate(DateTime.parse(a.opensOn))} até '
                      '${formatShortDate(a.due.toLocal())} · entregue por '
                      '${done[a.code]?.length ?? 0} de ${target.students.length}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Apagar',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => _delete(a),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 24),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Link para as famílias', style: AppType.title),
              const SizedBox(height: 6),
              Text(
                'Mande o link no grupo das famílias e o código separado (em '
                'outra mensagem ou na agenda): sem o código, o link não abre. '
                'Quando mudar alunos ou atividades, gere e mande o link de '
                'novo; o código continua o mesmo.',
                style: AppType.body.copyWith(color: Palette.inkMuted),
              ),
              const SizedBox(height: 16),
              if (target.students.isEmpty)
                const Text('Cadastre os alunos antes de gerar o link.')
              else if (link == null)
                PrimaryButton(
                  label: _sealing ? 'Gerando…' : 'Gerar o link',
                  icon: Icons.link_rounded,
                  onPressed: _sealing ? null : _generate,
                )
              else ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Palette.background,
                    borderRadius: BorderRadius.circular(Shapes.chipRadius),
                  ),
                  child: SelectableText(
                    parentsMessage(target.name, link.url),
                    maxLines: 8,
                    style: AppType.body.copyWith(fontSize: 14),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _copy(
                          parentsMessage(target.name, link.url), 'Mensagem'),
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copiar a mensagem'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _copy(link.url, 'Link'),
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('Copiar só o link'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('CÓDIGO DA TURMA', style: AppType.label),
                          SelectableText(
                            link.accessCode,
                            style: AppType.display
                                .copyWith(fontSize: 30, letterSpacing: 4),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Copiar o código',
                      onPressed: () => _copy(link.accessCode, 'Código'),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _sealing ? null : _newCode,
                    child: const Text('Trocar o código (se vazou)'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  final VaultActivity activity;
  final DateTime now;

  const _StatusDot({required this.activity, required this.now});

  @override
  Widget build(BuildContext context) {
    final opens = DateTime.parse(activity.opensOn);
    final (label, colour) = activity.due.isBefore(now)
        ? ('Encerrada', Palette.inkMuted)
        : now.isBefore(opens)
            ? ('Ainda não começou', Palette.amber)
            : ('Aberta', Palette.green);
    return Tooltip(
      message: label,
      child: Icon(Icons.circle, size: 14, color: colour),
    );
  }
}

// -- sessões -------------------------------------------------------------------

class SessionsTab extends StatelessWidget {
  final TeacherController controller;
  final VaultClass target;

  const SessionsTab({
    super.key,
    required this.controller,
    required this.target,
  });

  Future<void> _import(BuildContext context) async {
    final pick = controller.environment.platform.pickFiles!;
    final files = await pick();
    if (files.isEmpty) return;
    final report = await controller
        .change((v) => v.importFiles({for (final f in files) f.name: f.text}));
    if (context.mounted) await showImportReport(context, report);
  }

  @override
  Widget build(BuildContext context) {
    final canImport = controller.environment.platform.pickFiles != null;
    final activities = {for (final a in target.activities) a.code: a};
    final sessions = target.sessions.reversed.toList();
    return PanelBody(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(plural(sessions.length, 'sessão', 'sessões'),
                  style: AppType.title),
            ),
            FilledButton.icon(
              onPressed: canImport ? () => _import(context) : null,
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('Importar arquivos'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'As famílias mandam um arquivo .json por atividade (pelo WhatsApp ou '
          'e-mail). Salve-os no computador e importe todos de uma vez; '
          'arquivos repetidos são ignorados.',
          style: AppType.body.copyWith(fontSize: 14, color: Palette.inkMuted),
        ),
        const SizedBox(height: 12),
        if (sessions.isEmpty)
          const AppCard(child: Text('Nenhuma sessão importada ainda.'))
        else
          PanelList(
            child: Column(
              children: [
                for (final s in sessions)
                  ListTile(
                    leading: Icon(
                      s.hasUsableQuality()
                          ? Icons.check_circle_outline_rounded
                          : Icons.report_gmailerrorred_rounded,
                      color: s.hasUsableQuality()
                          ? Palette.green
                          : const Color(0xFFA32317),
                    ),
                    title: Text(_nameOf(target, s.participantCode)),
                    subtitle: Text([
                      taskLabel(s.task),
                      formatDateTime(s.startedAt),
                      if (s.activityCode != null &&
                          !activities.containsKey(s.activityCode))
                        'atividade apagada',
                      if (!s.hasUsableQuality()) 'qualidade baixa',
                    ].join(' · ')),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

Future<void> showImportReport(BuildContext context, ImportReport report) {
  final lines = <(IconData, Color, String)>[
    if (report.imported.isNotEmpty)
      (
        Icons.check_circle_outline_rounded,
        Palette.green,
        '${plural(report.imported.length, 'sessão importada', 'sessões importadas')}.'
      ),
    if (report.duplicates.isNotEmpty)
      (
        Icons.copy_all_rounded,
        Palette.inkMuted,
        '${plural(report.duplicates.length, 'arquivo já estava', 'arquivos já estavam')} '
            'no painel.'
      ),
    if (report.unknownCodes.isNotEmpty)
      (
        Icons.help_outline_rounded,
        const Color(0xFFA32317),
        'Código de aluno que não é de nenhuma turma sua: '
            '${report.unknownCodes.join(', ')}. O aluno foi apagado, ou o '
            'arquivo é de outro professor.'
      ),
    if (report.wrongActivity.isNotEmpty)
      (
        Icons.event_busy_rounded,
        const Color(0xFFA32317),
        'Atividade que não é da turma do aluno: '
            '${report.wrongActivity.join(', ')}.'
      ),
    if (report.unreadable.isNotEmpty)
      (
        Icons.broken_image_outlined,
        const Color(0xFFA32317),
        'Não é arquivo de sessão do EyeLearn: ${report.unreadable.join(', ')}.'
      ),
  ];
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Importação'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (icon, colour, text) in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: colour, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(text)),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

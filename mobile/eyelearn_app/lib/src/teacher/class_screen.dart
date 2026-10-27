/// Uma turma: a leitura comparada com a turma, os alunos, as atividades com o
/// link para as famílias e as sessões importadas.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../delivery/inbox.dart';
import 'comparison_chart.dart';
import 'etdd70_comparison.dart';
import 'heatmap_view.dart';
import 'panel_widgets.dart';
import 'teacher_controller.dart';

/// Texto para o grupo das famílias. O link já leva a turma inteira.
String parentsMessage(String className, String link) =>
    'Atividade de leitura do EyeLearn ($className).\n\n'
    'Abra o link no celular e deixe a criança escolher o nome e digitar o '
    'PIN. '
    'São poucos minutos, num lugar com boa luz, com o celular apoiado na '
    'mesa. A câmera é usada só no aparelho: nenhuma imagem sai dele.\n\n'
    '$link';

class ClassScreen extends StatefulWidget {
  final TeacherController controller;
  final VaultClass target;

  const ClassScreen({
    super.key,
    required this.controller,
    required this.target,
  });

  @override
  State<ClassScreen> createState() => _ClassScreenState();
}

class _ClassScreenState extends State<ClassScreen> {
  TeacherController get controller => widget.controller;
  VaultClass get target => widget.target;

  @override
  void initState() {
    super.initState();
    // As sessões chegam sozinhas: ao abrir a turma, o painel busca as
    // entregas novas.
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => fetchDeliveries(context, controller, target, quiet: true));
  }

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
        length: 3,
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
                  Tab(text: 'Turma'),
                  Tab(text: 'Leitura da turma'),
                  Tab(text: 'Sessões'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                SetupTab(controller: controller, target: target),
                ComparisonTab(controller: controller, target: target),
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

  /// Com quem comparar: `turma` ou `base` (ETDD70). Sem escolha, a turma
  /// quando dá (três gravações ou mais) e a base enquanto não dá.
  String? _mode;

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
    final mode = _mode ?? (comparison == null ? 'base' : 'turma');

    return PanelBody(
      children: [
        // Fichas que quebram linha, e não botões segmentados: no celular os
        // segmentos espremiam o texto em três linhas.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final task in homeworkTasks)
              ChoiceChip(
                label: Text(taskLabel(task)),
                selected: _task == task,
                onSelected: (_) => setState(() {
                  _task = task;
                  _selected = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          key: const Key('comparison-mode'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, icon, label) in const [
              ('turma', Icons.groups_outlined, 'Com a turma'),
              ('base', Icons.dataset_outlined, 'Com a base ETDD70'),
            ])
              ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: mode == value,
                onSelected: (_) => setState(() => _mode = value),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (mode == 'base')
          BaseComparisonView(
            key: ValueKey(_task),
            target: target,
            task: _task,
          )
        else if (comparison == null)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(notEnough!, style: AppType.subtitle),
                const SizedBox(height: 6),
                Text(
                  'Enquanto isso, a leitura de cada criança pode ser '
                  'comparada com a base ETDD70, em "Com a base ETDD70".',
                  style: AppType.body.copyWith(color: Palette.inkMuted),
                ),
              ],
            ),
          )
        else
          ..._comparison(comparison),
        if (lowQuality > 0 && mode == 'turma') ...[
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
              Column(
                children: [
                  for (final MapEntry(key: code, value: features)
                      in outliers.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: code == selected
                            ? Palette.brand
                            : Palette.brandSoft,
                        borderRadius: BorderRadius.circular(Shapes.chipRadius),
                        child: InkWell(
                          borderRadius:
                              BorderRadius.circular(Shapes.chipRadius),
                          onTap: () => setState(() => _selected = code),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                Icon(Icons.visibility_outlined,
                                    size: 18,
                                    color: code == selected
                                        ? Colors.white
                                        : Palette.brand),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text.rich(
                                    TextSpan(children: [
                                      TextSpan(
                                          text: _nameOf(target, code),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      TextSpan(
                                          text:
                                              ' · ${features.map((f) => labels[f]!.toLowerCase()).join(', ')}'),
                                    ]),
                                    style: AppType.body.copyWith(
                                      fontSize: 14,
                                      color: code == selected
                                          ? Colors.white
                                          : Palette.ink,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
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

/// A leitura de cada criança comparada com as crianças do ETDD70, desde a
/// primeira gravação: não depende de a turma ter três sessões.
class BaseComparisonView extends StatefulWidget {
  final VaultClass target;
  final String task;

  const BaseComparisonView({
    super.key,
    required this.target,
    required this.task,
  });

  @override
  State<BaseComparisonView> createState() => _BaseComparisonViewState();
}

class _BaseComparisonViewState extends State<BaseComparisonView> {
  static Future<Map<String, dynamic>>? _reference;
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final latest = <String, Session>{};
    for (final s in widget.target.sessions) {
      if (s.task == widget.task) latest[s.participantCode] = s;
    }
    if (latest.isEmpty) {
      return const AppCard(
        child: Text('Ainda não há gravação desta tarefa.',
            style: AppType.subtitle),
      );
    }
    final codes = latest.keys.toList()
      ..sort((a, b) =>
          _nameOf(widget.target, a).compareTo(_nameOf(widget.target, b)));
    final code = codes.contains(_selected) ? _selected! : codes.first;
    final session = latest[code]!;

    return FutureBuilder<Map<String, dynamic>>(
      future: _reference ??= loadEtdd70Reference(),
      builder: (context, snapshot) {
        final reference = snapshot.data;
        if (reference == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final comparison = compareWithEtdd70(session, reference);
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButton<String>(
                value: code,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                style: AppType.title.copyWith(color: Palette.ink),
                items: [
                  for (final c in codes)
                    DropdownMenuItem(
                        value: c, child: Text(_nameOf(widget.target, c))),
                ],
                onChanged: (c) => setState(() => _selected = c),
              ),
              Text(
                'Gravação de ${formatDateTime(session.startedAt)}, '
                '${session.samplingRateHz.round()} quadros/s'
                '${session.hasUsableQuality() ? '' : ' (qualidade baixa)'}'
                '${comparison == null ? '' : '. Referência: ETDD70 a '
                    '${comparison.conditionLabel}, a condição mais próxima.'}',
                style: AppType.body
                    .copyWith(fontSize: 14, color: Palette.inkMuted),
              ),
              const SizedBox(height: 10),
              if (session.heatmap != null) ...[
                Center(
                  child: GazeHeatmapView(
                      heatmap: session.heatmap!, task: session.task),
                ),
                const SizedBox(height: 14),
              ],
              if (comparison == null)
                const Text('A base não tem esta tarefa.')
              else ...[
                const Text(
                    'Desvios em relação às crianças sem dislexia da base:',
                    style: AppType.subtitle),
                const SizedBox(height: 8),
                ComparisonChart(
                  scores: {
                    for (final r in comparison.rows) r.feature: r.zTypical,
                  },
                  reference: 'às crianças sem dislexia da base',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => showEtdd70Comparison(
                        context, session, _nameOf(widget.target, code),
                        loadReference: () async => reference),
                    child: const Text('Ver todas as características'),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              const ErrorNotice(
                'Não é diagnóstico. A base é de crianças tchecas lendo em '
                'tcheco num rastreador de laboratório; a gravação é de outro '
                'texto e de uma câmera de celular. Serve para ver se a '
                'captura está no caminho, não para concluir nada sobre a '
                'criança.',
              ),
            ],
          ),
        );
      },
    );
  }
}

// -- turma: passo a passo --------------------------------------------------

/// Prazos oferecidos ao criar a atividade, em dias a partir de hoje.
const _dueOptions = [3, 7, 14];

/// A turma em três passos: atividade, alunos, link.
///
/// O link vem por último porque leva dentro a lista de alunos e de
/// atividades: um link copiado antes de cadastrar os alunos abriria uma turma
/// vazia. Quando algo muda depois de copiado, o cartão do link avisa.
class SetupTab extends StatefulWidget {
  final TeacherController controller;
  final VaultClass target;

  const SetupTab({super.key, required this.controller, required this.target});

  @override
  State<SetupTab> createState() => _SetupTabState();
}

class _SetupTabState extends State<SetupTab> {
  final _studentName = TextEditingController();
  final _studentFocus = FocusNode();
  int _dueDays = 7;

  /// A versão do cofre quando o link foi copiado pela última vez; `null` se
  /// ainda não foi.
  int? _copiedRevision;

  TeacherController get controller => widget.controller;
  VaultClass get target => widget.target;

  @override
  void dispose() {
    _studentName.dispose();
    _studentFocus.dispose();
    super.dispose();
  }

  Future<void> _createActivity(String task) async {
    final today = controller.now;
    final day = DateTime(today.year, today.month, today.day);
    await guard(context, () async {
      await controller.change((v) => v.createActivity(target, task,
          due: day.add(Duration(days: _dueDays)), opens: day, today: day));
    });
  }

  Future<void> _deleteActivity(VaultActivity activity) async {
    final ok = await confirmAction(
      context,
      title: 'Apagar a atividade?',
      body: 'Ela some do próximo link. Sessões já importadas ficam.',
      action: 'Apagar',
    );
    if (!ok || !mounted) return;
    await controller.change((v) => v.deleteActivity(target, activity));
  }

  Future<void> _addStudent() async {
    final name = _studentName.text;
    if (name.trim().isEmpty) return;
    // Limpa antes de gravar: quem digita a lista em sequência já está no
    // próximo nome enquanto este é salvo.
    _studentName.clear();
    _studentFocus.requestFocus();
    await guard(context, () async {
      await controller.change((v) => v.addStudent(target, name,
          pin: debugStudentPin, enforcePinRules: false));
    });
  }

  Future<void> _deleteStudent(VaultStudent student) async {
    final ok = await confirmAction(
      context,
      title: 'Apagar ${student.fullName}?',
      body: 'O aluno e todas as sessões dele serão apagados deste navegador. '
          'É o que atende a um pedido de eliminação dos dados (LGPD).',
      action: 'Apagar',
    );
    if (!ok || !mounted) return;
    await controller.change((v) => v.deleteStudent(target, student));
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _copiedRevision = controller.revision);
    showMessage(context, '$what copiado.');
  }

  @override
  Widget build(BuildContext context) {
    final now = controller.now;
    final done = target.completedActivityCodes();
    final activities = target.sortedActivities;
    final students = target.sortedStudents;
    final ready = students.isNotEmpty && activities.isNotEmpty;
    // O link se monta na hora, sempre com a turma como está: não há botão de
    // gerar. Se algo mudou depois de copiado, o cartão avisa.
    final link = ready
        ? controller.vault.compactLink(target,
            baseUrl: controller.environment.appUrl, now: now)
        : null;
    final stale =
        _copiedRevision != null && _copiedRevision != controller.revision;

    return PanelBody(
      children: [
        _Step(
          number: 1,
          title: 'Atividade',
          done: activities.isNotEmpty,
          children: [
            Text('Escolha a leitura. Ela fica aberta a partir de hoje.',
                style: AppType.body.copyWith(color: Palette.inkMuted)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Prazo:'),
                for (final days in _dueOptions)
                  ChoiceChip(
                    label: Text('$days dias'),
                    selected: _dueDays == days,
                    onSelected: (_) => setState(() => _dueDays = days),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final task in homeworkTasks)
                  FilledButton.tonalIcon(
                    onPressed: () => _createActivity(task),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(taskLabel(task)),
                  ),
              ],
            ),
            if (activities.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final a in activities)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _StatusDot(activity: a, now: now),
                  title: Text(taskLabel(a.task)),
                  subtitle: Text(
                    'até ${formatShortDate(a.due.toLocal())} · entregue por '
                    '${done[a.code]?.length ?? 0} de ${students.length}',
                  ),
                  trailing: IconButton(
                    tooltip: 'Apagar a atividade',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _deleteActivity(a),
                  ),
                ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        _Step(
          number: 2,
          title: 'Alunos',
          done: students.isNotEmpty,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _studentName,
                    focusNode: _studentFocus,
                    textCapitalization: TextCapitalization.words,
                    // Sem tirar o foco: Enter e já o próximo nome.
                    onEditingComplete: _addStudent,
                    decoration: InputDecoration(
                      labelText: 'Nome do aluno',
                      prefixIcon: const Icon(Icons.person_add_alt_rounded),
                      filled: true,
                      fillColor: Palette.background,
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(Shapes.chipRadius + 2),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _addStudent,
                  child: const Text('Adicionar'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Modo de teste: o PIN de todos os alunos é $debugStudentPin.',
              style: AppType.body
                  .copyWith(fontSize: 14, color: const Color(0xFF8A5300)),
            ),
            for (final s in students)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.fullName),
                subtitle: Text('aparece como '
                    '"${displayNames([
                      s.fullName
                    ]).single}" · código ${s.code}'),
                trailing: IconButton(
                  tooltip: 'Apagar o aluno',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _deleteStudent(s),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _Step(
          number: 3,
          title: 'Link',
          done: _copiedRevision != null && !stale,
          children: [
            Text(
              'Copie e mande no grupo das famílias. Quem abre entra direto na '
              'turma, sem código.',
              style: AppType.body.copyWith(color: Palette.inkMuted),
            ),
            const SizedBox(height: 12),
            if (link == null)
              const Text('Crie a atividade e cadastre os alunos antes.')
            else ...[
              if (stale)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: NoticeCard(
                    icon: Icons.sync_problem_rounded,
                    tint: Color(0xFF8A5300),
                    background: Palette.amberSoft,
                    text: 'Você mudou alunos ou atividades depois de copiar: '
                        'copie o link de novo e mande o novo às famílias.',
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Palette.background,
                  borderRadius: BorderRadius.circular(Shapes.chipRadius),
                ),
                child: SelectableText(
                  link,
                  key: const Key('class-link'),
                  maxLines: 3,
                  style: AppType.body.copyWith(fontSize: 13),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: () => _copy(link, 'Link'),
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copiar o link'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _copy(parentsMessage(target.name, link), 'Mensagem'),
                    icon: const Icon(Icons.chat_outlined),
                    label: const Text('Copiar com mensagem'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Um passo numerado, que fica verde quando feito.
class _Step extends StatelessWidget {
  final int number;
  final String title;
  final bool done;
  final List<Widget> children;

  const _Step({
    required this.number,
    required this.title,
    required this.done,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => AppCard(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: done ? Palette.green : Palette.brandSoft,
                    child: done
                        ? const Icon(Icons.check_rounded,
                            size: 18, color: Colors.white)
                        : Text('$number',
                            style: AppType.body.copyWith(
                                color: Palette.brand,
                                fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 12),
                  Text(title, style: AppType.title),
                ],
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );
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

/// Busca as entregas novas e conta o que chegou. Com [quiet], não diz nada
/// quando não chegou nada nem quando falta internet.
Future<void> fetchDeliveries(
  BuildContext context,
  TeacherController controller,
  VaultClass target, {
  bool quiet = false,
}) async {
  try {
    final report = await controller.fetchDeliveries(target);
    if (report == null || !context.mounted) return;
    final arrived = report.imported.length;
    if (arrived > 0) {
      showMessage(context,
          '${plural(arrived, 'sessão nova chegou', 'sessões novas chegaram')}.');
    } else if (!quiet) {
      showMessage(context, 'Nenhuma sessão nova.');
    }
    final problems = report.unknownCodes.length +
        report.unreadable.length +
        report.wrongActivity.length;
    if (problems > 0 && context.mounted) {
      await showImportReport(context, report);
    }
  } on InboxError {
    if (!quiet && context.mounted) {
      showMessage(context, 'Sem conexão com a caixa de entrega agora.');
    }
  }
}

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
    final hasInbox = controller.environment.inbox != null;
    final activities = {for (final a in target.activities) a.code: a};
    final sessions = target.sessions.reversed.toList();
    return PanelBody(
      children: [
        Text(plural(sessions.length, 'sessão', 'sessões'),
            style: AppType.title),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (hasInbox)
              FilledButton.icon(
                onPressed: () => fetchDeliveries(context, controller, target),
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Buscar entregas'),
              ),
            OutlinedButton.icon(
              onPressed: canImport ? () => _import(context) : null,
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('Importar arquivos'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          hasInbox
              ? 'As sessões chegam sozinhas quando a criança termina a '
                  'atividade, cifradas para este painel; o painel busca ao '
                  'abrir a turma. Arquivos .json mandados à mão também podem '
                  'ser importados.'
              : 'As famílias mandam um arquivo .json por atividade (pelo '
                  'WhatsApp ou e-mail). Salve-os no computador e importe '
                  'todos de uma vez; arquivos repetidos são ignorados.',
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
                  _SessionRow(
                    session: s,
                    name: _nameOf(target, s.participantCode),
                    activityDeleted: s.activityCode != null &&
                        !activities.containsKey(s.activityCode),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Uma sessão na lista: nome e detalhes em cima, ações embaixo. Ações ao
/// lado, como antes, espremiam o nome numa coluna de uma palavra no celular.
class _SessionRow extends StatelessWidget {
  final Session session;
  final String name;
  final bool activityDeleted;

  const _SessionRow({
    required this.session,
    required this.name,
    required this.activityDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    final ok = s.hasUsableQuality();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              ok
                  ? Icons.check_circle_outline_rounded
                  : Icons.report_gmailerrorred_rounded,
              color: ok ? Palette.green : const Color(0xFFA32317),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppType.body.copyWith(fontSize: 16)),
                Text(
                  [
                    taskLabel(s.task),
                    formatDateTime(s.startedAt),
                    '${s.samplingRateHz.round()} quadros/s',
                    if (activityDeleted) 'atividade apagada',
                    if (!ok) 'qualidade baixa',
                    // Fora da posição da calibração, o olhar perde precisão.
                    if ((s.outOfPositionRatio ?? 0) >= 0.1)
                      'fora da posição em '
                          '${(100 * s.outOfPositionRatio!).round()}% do tempo',
                  ].join(' · '),
                  style: AppType.body
                      .copyWith(fontSize: 13.5, color: Palette.inkMuted),
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    if (s.heatmap != null)
                      TextButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            insetPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 24),
                            title: Text('Onde o olhar ficou · $name'),
                            content: GazeHeatmapView(
                                heatmap: s.heatmap!, task: s.task, width: 240),
                            actions: [
                              FilledButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Fechar'),
                              ),
                            ],
                          ),
                        ),
                        icon: const Icon(Icons.blur_on_rounded, size: 18),
                        label: const Text('Mapa do olhar'),
                      ),
                    TextButton.icon(
                      onPressed: () => showEtdd70Comparison(context, s, name),
                      icon: const Icon(Icons.dataset_outlined, size: 18),
                      label: const Text('Comparar com o ETDD70'),
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

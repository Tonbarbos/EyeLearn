/// O aplicativo do aluno, como dever de casa.
///
/// Celular não entra na escola: a criança faz a atividade em casa. O fluxo é
///
/// 1. o responsável abre o link que o professor mandou no grupo e digita o
///    código da turma, uma vez (ver `Roster.openLink`);
/// 2. a criança toca no próprio nome e digita o PIN;
/// 3. aparecem as atividades dela: a fazer, feitas, a começar, encerradas;
/// 4. ela calibra seguindo uma bolinha e lê o texto;
/// 5. o responsável envia o arquivo de sessão ao professor.
///
/// A criança nunca vê resultado: a tela final diz que ela terminou, e é tudo.
///
/// O mesmo fluxo serve ao Android, ao navegador e à pré-visualização: o que
/// muda entre eles (de onde vem o olhar, onde a turma é guardada, como o
/// arquivo é enviado, que horas são) chega em [HomeworkEnvironment].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import 'activity/models.dart';
import 'activity/passages.dart';
import 'gaze/gaze_source.dart';
import 'delivery/inbox.dart';
import 'session/class_storage.dart';
import 'session/session_export.dart';
import 'teacher/teacher_controller.dart';
import 'teacher/teacher_screens.dart';
import 'ui/calibration_screen.dart';
import 'ui/finished_screen.dart';
import 'ui/gaze_test_screen.dart';
import 'ui/reading_screen.dart';
import 'ui/student_login.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

class HomeworkEnvironment {
  /// Um modelo por tarefa; ver `loadModels`.
  final Map<String, ModelArtifact> models;

  /// Cria a origem do olhar para uma atividade.
  final GazeSource Function() gaze;

  final ClassStorage storage;

  final DateTime Function() clock;

  /// O link com que o aplicativo foi aberto, no navegador. `null` no Android.
  final String? initialLink;

  /// Pede a permissão de câmera antes de ligar a captura; `null` quando quem
  /// pergunta é o navegador. Devolve se foi concedida.
  final Future<bool> Function()? requestCamera;

  /// Envia o arquivo; `null` esconde o botão (pré-visualização).
  final Future<void> Function(ExportedSession)? share;

  /// Ganchos da pré-visualização, que conduz um olhar sintético.
  final void Function(GazeSource, CalibrationTarget)? onTargetShown;
  final void Function(GazeSource)? onReadingStarted;
  final VoidCallback Function(GazeSource)? onGazeTestViewing;

  /// Aviso extra nas telas de entrada (a pré-visualização mostra código e
  /// PINs da turma fictícia).
  final Widget? joinHint;
  final Widget? pickerHint;

  /// O painel do professor, no mesmo site; `null` esconde a entrada.
  final TeacherEnvironment? teacher;

  /// A caixa de entrega do professor; `null` sem projeto configurado, e
  /// aí a sessão só sai por arquivo.
  final Inbox? inbox;

  /// Onde ficam as entregas que não saíram por falta de internet.
  final Outbox? outbox;

  const HomeworkEnvironment({
    required this.models,
    required this.gaze,
    required this.storage,
    required this.clock,
    this.initialLink,
    this.requestCamera,
    this.share,
    this.onTargetShown,
    this.onReadingStarted,
    this.onGazeTestViewing,
    this.joinHint,
    this.pickerHint,
    this.teacher,
    this.inbox,
    this.outbox,
  });
}

/// Fragmento do endereço que abre direto o painel: `.../#professor`.
const teacherFragment = 'professor';

/// Fragmento que abre direto o teste do olhar: `.../#olhar`.
const gazeTestFragment = 'olhar';

class HomeworkApp extends StatelessWidget {
  final HomeworkEnvironment environment;
  final String title;

  const HomeworkApp({
    super.key,
    required this.environment,
    this.title = 'EyeLearn',
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: title,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: HomeworkHome(environment: environment),
      );
}

/// Decide a primeira tela: entrar na turma ou escolher o aluno.
class HomeworkHome extends StatefulWidget {
  final HomeworkEnvironment environment;

  const HomeworkHome({super.key, required this.environment});

  @override
  State<HomeworkHome> createState() => _HomeworkHomeState();
}

class _HomeworkHomeState extends State<HomeworkHome> {
  /// Vive enquanto o aplicativo estiver aberto: voltar da tela do PIN e tocar
  /// no nome de novo não zera a contagem de tentativas.
  final _limiter = PinAttemptLimiter();

  Roster? _roster;
  bool _loading = true;
  bool _teacherFirst = false;
  String? _pendingLink;

  /// Erro de um link compacto que não abriu (cortado ou de outra versão).
  String? _linkError;

  HomeworkEnvironment get env => widget.environment;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    // Entregas guardadas por falta de internet saem agora, em segundo plano.
    final inbox = env.inbox;
    final outbox = env.outbox;
    if (inbox != null && outbox != null) unawaited(flushOutbox(inbox, outbox));
    final link = env.initialLink;
    if (link != null && Uri.tryParse(link)?.fragment == gazeTestFragment) {
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => _openGazeTest());
      return;
    }
    if (env.teacher != null &&
        link != null &&
        Uri.tryParse(link)?.fragment == teacherFragment) {
      setState(() {
        _teacherFirst = true;
        _loading = false;
      });
      return;
    }
    final saved = await env.storage.load();
    Roster? roster;

    // Link compacto (`#p=`), o do painel web: a turma vem aberta no link, e
    // entra direto, sem perguntar nada. A turma é a do link, mesmo que outra
    // estivesse guardada.
    if (link != null) {
      try {
        final compact = Roster.compactOf(link);
        if (compact != null) {
          roster = Roster.fromJsonString(compact);
          await env.storage.save(packageJson: compact, code: '');
          if (mounted) {
            setState(() {
              _roster = roster;
              _loading = false;
            });
          }
          return;
        }
      } on FormatException catch (error) {
        _linkError = error.message;
      } on RangeError {
        _linkError = 'o link está incompleto';
      }
    }

    // Um link compacto que não abriu não é link cifrado: não pede código.
    final hasLink = link != null &&
        _linkError == null &&
        Roster.fragmentOf(link).isNotEmpty;
    if (saved != null) {
      roster = Roster.fromJsonString(saved.packageJson);
      if (hasLink) {
        // Link novo da mesma turma (o professor criou atividade): abre com o
        // código guardado, sem perguntar de novo.
        try {
          final json = Roster.openSealed(Roster.fragmentOf(link), saved.code);
          roster = Roster.fromJsonString(json);
          await env.storage.save(packageJson: json, code: saved.code);
        } on FormatException {
          // Outra turma ou código trocado: pede o código.
          roster = null;
          _pendingLink = link;
        }
      }
    } else if (hasLink) {
      _pendingLink = link;
    }

    if (mounted) {
      setState(() {
        _roster = roster;
        _loading = false;
      });
    }
  }

  Future<void> _joined(String packageJson, String code) async {
    await env.storage.save(packageJson: packageJson, code: code);
    setState(() {
      _roster = Roster.fromJsonString(packageJson);
      _pendingLink = null;
    });
  }

  Future<void> _leaveClass() async {
    await env.storage.clear();
    setState(() => _roster = null);
  }

  Future<void> _studentSelected(RosterStudent student) async {
    final roster = _roster!;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PinScreen(
          student: student,
          limiter: _limiter,
          onAccepted: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (context) => StudentActivitiesScreen(
                environment: env,
                roster: roster,
                student: student,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openTeacher() => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TeacherGate(environment: env.teacher!),
        ),
      );

  /// Testar o olhar: calibra e mostra a bolinha. Não grava nada.
  Future<void> _openGazeTest() async {
    final ask = env.requestCamera;
    if (ask != null && !await ask()) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GazeTestScreen(
          gaze: env.gaze,
          onTargetShown: env.onTargetShown,
          onViewing: env.onGazeTestViewing,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_teacherFirst) return TeacherGate(environment: env.teacher!);
    final teacher = env.teacher == null ? null : _openTeacher;
    final roster = _roster;
    if (roster == null) {
      return JoinClassScreen(
        initialLink: _pendingLink,
        onJoined: _joined,
        hint: env.joinHint,
        onTeacher: teacher,
        onTestGaze: _openGazeTest,
        initialError: _linkError,
      );
    }
    return ChooseStudentScreen(
      roster: roster,
      onSelected: _studentSelected,
      onLeaveClass: _leaveClass,
      trainedOnSyntheticData: anyTrainedOnSyntheticData(env.models),
      hint: env.pickerHint,
      onTeacher: teacher,
      onTestGaze: _openGazeTest,
    );
  }
}

/// O cabeçalho de marca.
class BrandHero extends StatelessWidget {
  final String subtitle;

  const BrandHero({super.key, this.subtitle = 'Vamos ler juntos?'});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Shapes.cardRadius + 4),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Palette.brand, Palette.brandDeep],
          ),
          boxShadow: Shapes.buttonShadow,
        ),
        child: Column(
          children: [
            const EyeMascot(size: 84, iris: Palette.amber),
            const SizedBox(height: 14),
            Text(
              'EyeLearn',
              style:
                  AppType.display.copyWith(color: Colors.white, fontSize: 30),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppType.subtitle.copyWith(color: Colors.white70),
            ),
          ],
        ),
      );
}

/// Entrar na turma: link (quando não veio pela barra de endereço) e código.
class JoinClassScreen extends StatefulWidget {
  final String? initialLink;
  final Future<void> Function(String packageJson, String code) onJoined;

  /// Erro do link com que o aplicativo foi aberto, para mostrar de cara.
  final String? initialError;
  final Widget? hint;
  final VoidCallback? onTeacher;
  final VoidCallback? onTestGaze;

  const JoinClassScreen({
    super.key,
    required this.initialLink,
    required this.onJoined,
    this.initialError,
    this.hint,
    this.onTeacher,
    this.onTestGaze,
  });

  @override
  State<JoinClassScreen> createState() => _JoinClassScreenState();
}

class _JoinClassScreenState extends State<JoinClassScreen> {
  late final _link = TextEditingController(text: widget.initialLink ?? '');
  final _code = TextEditingController();
  late String? _error =
      widget.initialError == null ? null : _sentence(widget.initialError!);
  bool _opening = false;

  bool get _hasLink => (widget.initialLink ?? '').isNotEmpty;

  @override
  void dispose() {
    _link.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _opening = true;
    });
    // Um quadro para o indicador aparecer: a derivação da chave leva um
    // instante no celular.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      // Link compacto colado: abre sem código.
      final compact = Roster.compactOf(_link.text);
      if (compact != null) {
        Roster.fromJsonString(compact); // confere o formato antes de guardar
        await widget.onJoined(compact, '');
        return;
      }
      final json = Roster.openSealed(Roster.fragmentOf(_link.text), _code.text);
      Roster.fromJsonString(json); // confere o formato antes de guardar
      await widget.onJoined(json, _code.text);
    } on FormatException catch (error) {
      setState(() => _error = _sentence(error.message));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  static String _sentence(String text) =>
      '${text[0].toUpperCase()}${text.substring(1)}.';

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const BrandHero(subtitle: 'Atividade de leitura em casa'),
                const SizedBox(height: 22),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Entrar na turma', style: AppType.title),
                      const SizedBox(height: 6),
                      Text(
                        _hasLink
                            ? 'Digite o código da turma que a professora mandou.'
                            : 'Cole o link que a professora mandou no grupo e '
                                'digite o código da turma.',
                        style: AppType.body.copyWith(color: Palette.inkMuted),
                      ),
                      const SizedBox(height: 16),
                      if (!_hasLink) ...[
                        TextField(
                          controller: _link,
                          decoration: _decoration('Link da turma', Icons.link),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: _code,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        onSubmitted: (_) => _submit(),
                        style: AppType.title.copyWith(letterSpacing: 3),
                        decoration: _decoration(
                          'Código da turma',
                          Icons.key_rounded,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  NoticeCard(
                    icon: Icons.error_outline_rounded,
                    tint: const Color(0xFFA32317),
                    background: Palette.coralSoft,
                    text: _error!,
                  ),
                ],
                if (widget.hint != null) ...[
                  const SizedBox(height: 12),
                  widget.hint!,
                ],
                const SizedBox(height: 20),
                PrimaryButton(
                  label: _opening ? 'Abrindo…' : 'Entrar',
                  icon: Icons.login_rounded,
                  onPressed: _opening ? null : _submit,
                ),
                const SizedBox(height: 16),
                const NoticeCard(
                  icon: Icons.lock_outline_rounded,
                  tint: Color(0xFF3A2FB0),
                  background: Palette.brandSoft,
                  text: 'A câmera é usada só neste aparelho: nenhuma imagem é '
                      'gravada nem enviada. Ao final, você escolhe enviar ao '
                      'professor um arquivo com as medidas da leitura.',
                ),
                const SizedBox(height: 8),
                if (widget.onTestGaze != null)
                  TextButton.icon(
                    onPressed: widget.onTestGaze,
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('Testar o olhar'),
                  ),
                if (widget.onTeacher != null)
                  TextButton.icon(
                    onPressed: widget.onTeacher,
                    icon: const Icon(Icons.school_outlined),
                    label: const Text('Sou professor'),
                  ),
              ],
            ),
          ),
        ),
      );

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: Palette.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Shapes.chipRadius + 2),
          borderSide: BorderSide.none,
        ),
      );
}

/// Quem vai ler: os nomes da turma.
class ChooseStudentScreen extends StatelessWidget {
  final Roster roster;
  final ValueChanged<RosterStudent> onSelected;
  final VoidCallback onLeaveClass;
  final bool trainedOnSyntheticData;
  final Widget? hint;
  final VoidCallback? onTeacher;
  final VoidCallback? onTestGaze;

  const ChooseStudentScreen({
    super.key,
    required this.roster,
    required this.onSelected,
    required this.onLeaveClass,
    this.trainedOnSyntheticData = false,
    this.hint,
    this.onTeacher,
    this.onTestGaze,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const BrandHero(),
                const SizedBox(height: 22),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(roster.className.toUpperCase(),
                          style: AppType.label),
                      const SizedBox(height: 6),
                      const Text('Quem vai ler hoje?', style: AppType.title),
                      Text(
                        'Toque no seu nome',
                        style: AppType.body.copyWith(color: Palette.inkMuted),
                      ),
                      const SizedBox(height: 14),
                      StudentPicker(roster: roster, onSelected: onSelected),
                    ],
                  ),
                ),
                if (hint != null) ...[const SizedBox(height: 12), hint!],
                const SizedBox(height: 14),
                const NoticeCard(
                  icon: Icons.info_outline_rounded,
                  tint: Color(0xFF3A2FB0),
                  background: Palette.brandSoft,
                  text: 'Este aplicativo não faz diagnóstico. Ele descreve o '
                      'padrão de leitura e sugere adaptações ao professor. '
                      'Avaliação clínica é de profissional habilitado.',
                ),
                if (trainedOnSyntheticData) ...[
                  const SizedBox(height: 10),
                  const NoticeCard(
                    icon: Icons.science_outlined,
                    tint: Color(0xFFA32317),
                    background: Palette.coralSoft,
                    text: 'O modelo embarcado foi treinado em dados sintéticos '
                        'e não aprendeu nada sobre leitura.',
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onLeaveClass,
                  child: const Text('Sair desta turma'),
                ),
                if (onTestGaze != null)
                  TextButton(
                    onPressed: onTestGaze,
                    child: const Text('Testar o olhar'),
                  ),
                if (onTeacher != null)
                  TextButton(
                    onPressed: onTeacher,
                    child: const Text('Sou professor'),
                  ),
              ],
            ),
          ),
        ),
      );
}

/// As atividades de um aluno, e o que fazer com cada uma.
class StudentActivitiesScreen extends StatefulWidget {
  final HomeworkEnvironment environment;
  final Roster roster;
  final RosterStudent student;

  const StudentActivitiesScreen({
    super.key,
    required this.environment,
    required this.roster,
    required this.student,
  });

  @override
  State<StudentActivitiesScreen> createState() =>
      _StudentActivitiesScreenState();
}

class _StudentActivitiesScreenState extends State<StudentActivitiesScreen> {
  Set<String> _done = {};
  String? _error;

  HomeworkEnvironment get env => widget.environment;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final done = await env.storage.doneFor(widget.student.code);
    if (mounted) setState(() => _done = done);
  }

  /// Ordem: a fazer (prazo mais perto primeiro), a começar, feitas,
  /// encerradas.
  List<(HomeworkActivity, HomeworkStatus)> get _items {
    final now = env.clock();
    final items = [
      for (final activity in widget.roster.activities)
        (activity, activity.statusAt(now, done: _done.contains(activity.code))),
    ];
    const order = [
      HomeworkStatus.pending,
      HomeworkStatus.upcoming,
      HomeworkStatus.done,
      HomeworkStatus.closed,
    ];
    items.sort((a, b) {
      final byStatus = order.indexOf(a.$2).compareTo(order.indexOf(b.$2));
      return byStatus != 0 ? byStatus : a.$1.dueAt.compareTo(b.$1.dueAt);
    });
    return items;
  }

  Future<void> _start(HomeworkActivity activity) async {
    setState(() => _error = null);
    final model = env.models[activity.task];
    if (model == null) {
      setState(() => _error = 'Atividade de um tipo que este aplicativo não '
          'conhece. Atualize a página.');
      return;
    }
    final ask = env.requestCamera;
    if (ask != null && !await ask()) {
      setState(() =>
          _error = 'Sem acesso à câmera não é possível acompanhar o olhar.');
      return;
    }
    if (!mounted) return;

    // Uma rota só para calibração, leitura e fim: o `await` volta quando a
    // atividade termina de fato (ou é abandonada), e não na troca de tela.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ActivityRunScreen(
          environment: env,
          model: model,
          roster: widget.roster,
          student: widget.student,
          activity: activity,
        ),
      ),
    );
    await _reload();
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}';
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final pending =
        items.where((item) => item.$2 == HomeworkStatus.pending).length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Trocar de aluno',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  InitialAvatar(name: widget.student.displayName, size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Oi, ${widget.student.displayName.split(' ').first}!',
                          style: AppType.display.copyWith(fontSize: 26),
                        ),
                        Text(
                          pending == 0
                              ? 'Nenhuma atividade para fazer agora.'
                              : pending == 1
                                  ? 'Você tem 1 atividade para fazer.'
                                  : 'Você tem $pending atividades para fazer.',
                          style: AppType.subtitle,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (items.isEmpty)
                const AppCard(
                  child: Text(
                    'A professora ainda não passou nenhuma atividade.',
                    style: AppType.body,
                  ),
                ),
              for (final (activity, status) in items) ...[
                HomeworkCard(
                  activity: activity,
                  status: status,
                  date: _date,
                  onStart: () => _start(activity),
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null)
                NoticeCard(
                  icon: Icons.error_outline_rounded,
                  tint: const Color(0xFFA32317),
                  background: Palette.coralSoft,
                  text: _error!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uma atividade na lista do aluno.
class HomeworkCard extends StatelessWidget {
  final HomeworkActivity activity;
  final HomeworkStatus status;
  final String Function(DateTime) date;
  final VoidCallback onStart;

  const HomeworkCard({
    super.key,
    required this.activity,
    required this.status,
    required this.date,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final passage = passageById(activity.task);
    final (label, colour, background, icon) = switch (status) {
      HomeworkStatus.pending => (
          'Até ${date(activity.dueAt)}',
          Palette.brandDeep,
          Palette.brandSoft,
          Icons.menu_book_rounded,
        ),
      HomeworkStatus.done => (
          'Feita',
          const Color(0xFF0E7A54),
          Palette.greenSoft,
          Icons.check_circle_rounded,
        ),
      HomeworkStatus.upcoming => (
          'Começa em ${date(activity.opensOn)}',
          Palette.inkMuted,
          Palette.background,
          Icons.schedule_rounded,
        ),
      HomeworkStatus.closed => (
          'Prazo encerrado',
          Palette.inkMuted,
          Palette.background,
          Icons.lock_clock_rounded,
        ),
    };
    final active = status == HomeworkStatus.pending;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration:
                    BoxDecoration(color: background, shape: BoxShape.circle),
                child: Icon(icon, color: colour),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      passage.title,
                      style: AppType.title.copyWith(
                        color: active ? Palette.ink : Palette.inkMuted,
                      ),
                    ),
                    Text(
                      label,
                      style: AppType.body.copyWith(
                        color: colour,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (active) ...[
            const SizedBox(height: 14),
            PrimaryButton(
              label: 'Fazer agora',
              icon: Icons.play_arrow_rounded,
              onPressed: onStart,
            ),
          ],
        ],
      ),
    );
  }
}

enum _RunStage { calibrating, reading, finished }

/// Uma atividade, da calibração ao fim, numa rota só.
///
/// Quem fecha a rota -- terminando ou voltando no meio -- desliga a câmera, em
/// [dispose]: deixar a câmera ligada depois de sair da atividade seria uma
/// captura que ninguém pediu.
class ActivityRunScreen extends StatefulWidget {
  final HomeworkEnvironment environment;
  final ModelArtifact model;
  final RosterStudent student;
  final HomeworkActivity activity;

  /// A turma: dá a caixa de entrega (o uid) e a chave do professor.
  final Roster? roster;

  const ActivityRunScreen({
    super.key,
    required this.environment,
    required this.model,
    required this.student,
    required this.activity,
    this.roster,
  });

  @override
  State<ActivityRunScreen> createState() => _ActivityRunScreenState();
}

class _ActivityRunScreenState extends State<ActivityRunScreen> {
  late final GazeSource _gaze = widget.environment.gaze();
  late final Passage _passage = passageById(widget.activity.task);

  _RunStage _stage = _RunStage.calibrating;
  GazeCalibration? _calibration;
  ExportedSession? _exported;
  DeliveryState? _delivery;
  late DateTime _startedAt;

  HomeworkEnvironment get env => widget.environment;

  @override
  void dispose() {
    _gaze.stop();
    super.dispose();
  }

  void _calibrated(GazeCalibration calibration) {
    setState(() {
      _calibration = calibration;
      _startedAt = env.clock();
      _stage = _RunStage.reading;
    });
  }

  Future<void> _finished(
      GazeTrace trace, RecordingQuality quality, List<double>? textArea) async {
    final analysis = analyse(trace, widget.model.preprocessing);
    final exported = exportSession(
      participantCode: widget.student.code,
      activityCode: widget.activity.code,
      task: _passage.id,
      startedAt: _startedAt,
      trace: trace,
      quality: quality,
      features: analysis.features,
      artifact: widget.model,
      heatmap: GazeHeatmap.fromTrace(trace, textArea: textArea),
    );
    // Conta como feita só se a captura serviu: uma gravação ruim fica
    // pendente, e a tela final sugere repetir.
    if (exported.session.hasUsableQuality()) {
      await env.storage.markDone(widget.student.code, widget.activity.code);
    }
    if (!mounted) return;
    setState(() {
      _exported = exported;
      _stage = _RunStage.finished;
    });
    await _deliver(exported);
  }

  /// Envia sozinho à caixa do professor, cifrado para ele. Sem caixa ou sem
  /// chave no link, a sessão sai pelo arquivo, como antes.
  Future<void> _deliver(ExportedSession exported) async {
    final inbox = env.inbox;
    final roster = widget.roster;
    final key = roster?.deliveryKey;
    if (inbox == null || roster == null || key == null) return;
    final Uint8List public;
    try {
      public = parseDeliveryPublicKey(key);
    } on FormatException {
      return;
    }
    setState(() => _delivery = DeliveryState.sending);
    final blob = sealForTeacher(exported.bytes, public);
    final sent = await deliverOrKeep(
        inbox, env.outbox ?? MemoryOutbox(), roster.classUid, blob);
    if (mounted) {
      setState(
          () => _delivery = sent ? DeliveryState.sent : DeliveryState.queued);
    }
  }

  @override
  Widget build(BuildContext context) => switch (_stage) {
        _RunStage.calibrating => CalibrationScreen(
            channel: _gaze,
            onTargetShown: env.onTargetShown == null
                ? null
                : (target) => env.onTargetShown!(_gaze, target),
            onCalibrated: _calibrated,
          ),
        _RunStage.reading => ReadingScreen(
            channel: _gaze,
            calibration: _calibration!,
            passage: _passage,
            onStarted: env.onReadingStarted == null
                ? null
                : () => env.onReadingStarted!(_gaze),
            onFinished: _finished,
          ),
        _RunStage.finished => FinishedScreen(
            session: _exported!.session,
            delivery: _delivery,
            onShare: env.share == null ? null : () => env.share!(_exported!),
            doneLabel: 'Voltar às atividades',
            onDone: () => Navigator.of(context).pop(),
          ),
      };
}

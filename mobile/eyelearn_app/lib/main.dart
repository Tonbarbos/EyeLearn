/// Aplicativo do aluno.
///
/// O fluxo é: o adulto importa uma vez a lista da turma que o painel exportou;
/// a cada atividade, o celular lê o QR que o professor projeta -- o que prova
/// que a criança está na sala e diz qual é a tarefa --; a criança toca no
/// próprio nome e digita o PIN, calibra seguindo uma bolinha e lê o texto; o
/// adulto compartilha o arquivo de sessão com o professor.
///
/// A criança nunca vê resultado. A tela final diz que ela terminou, e é tudo --
/// ver mais que isso seria receber um rótulo de um modelo cujo valor preditivo
/// positivo na prevalência escolar é de cerca de 22%.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'src/activity/models.dart';
import 'src/activity/passages.dart';
import 'src/gaze/gaze_channel.dart';
import 'src/session/roster_store.dart';
import 'src/session/session_export.dart';
import 'src/ui/calibration_screen.dart';
import 'src/ui/finished_screen.dart';
import 'src/ui/reading_screen.dart';
import 'src/ui/scan_screen.dart';
import 'src/ui/student_login.dart';
import 'src/ui/theme.dart';
import 'src/ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(EyeLearnApp(models: await loadModels()));
}

class EyeLearnApp extends StatelessWidget {
  final Map<String, ModelArtifact> models;

  const EyeLearnApp({super.key, required this.models});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'EyeLearn',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: SetupScreen(models: models),
      );
}

/// Tela inicial.
///
/// A atividade vem do QR do professor; a criança escolhe o próprio nome. Não
/// há cadastro de alunos no aplicativo: a lista vem pronta do painel, e o que
/// sai daqui na sessão é o código do aluno e o da atividade, não o nome.
class SetupScreen extends StatefulWidget {
  /// Um modelo por tarefa; ver `loadModels`.
  final Map<String, ModelArtifact> models;

  const SetupScreen({super.key, required this.models});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  /// Vive enquanto o aplicativo estiver aberto: voltar da tela do PIN e tocar
  /// no nome de novo não zera a contagem de tentativas.
  final _limiter = PinAttemptLimiter();

  ActivityTicket? _ticket;
  Roster? _roster;
  bool _loadingRoster = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    loadSavedRoster().then((roster) {
      if (mounted) {
        setState(() {
          _roster = roster;
          _loadingRoster = false;
        });
      }
    });
  }

  Future<void> _importRoster() async {
    try {
      final roster = await pickAndSaveRoster();
      if (roster == null || !mounted) return;
      setState(() {
        _roster = roster;
        _ticket = null; // o QR lido era da turma anterior
        _error = null;
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _error = 'Não foi possível usar o arquivo: '
            '${error.message}.');
      }
    }
  }

  Future<void> _scan() async {
    final roster = _roster;
    if (roster == null) return;
    final ticket = await scanActivity(context, roster);
    if (ticket != null && mounted) {
      setState(() {
        _ticket = ticket;
        _error = null;
      });
    }
  }

  /// A atividade lida, se a entrada ainda estiver aberta.
  ActivityTicket? get _openTicket {
    final ticket = _ticket;
    return ticket != null && ticket.isOpenAt(DateTime.now().toUtc())
        ? ticket
        : null;
  }

  Future<void> _studentSelected(RosterStudent student) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PinScreen(
          student: student,
          limiter: _limiter,
          onAccepted: () {
            Navigator.of(context).pop();
            final ticket = _openTicket;
            if (ticket == null) {
              // A entrada fechou enquanto a criança digitava o PIN.
              setState(() {
                _ticket = null;
                _error = 'A entrada na atividade fechou. Leia o QR de novo.';
              });
              return;
            }
            _begin(student.code, ticket);
          },
        ),
      ),
    );
  }

  bool get _trainedOnSyntheticData => anyTrainedOnSyntheticData(widget.models);

  Future<void> _begin(String code, ActivityTicket ticket) async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(
        () => _error = 'Sem acesso à câmera não é possível acompanhar o olhar.',
      );
      return;
    }
    if (!mounted) return;

    setState(() => _error = null);
    final channel = GazeChannel();

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CalibrationScreen(
          channel: channel,
          onCalibrated: (calibration) => Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (context) => _ReadingFlow(
                channel: channel,
                calibration: calibration,
                passage: passageById(ticket.task),
                artifact: widget.models[ticket.task]!,
                participantCode: code,
                activityCode: ticket.activityCode,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Hero(),
                const SizedBox(height: 26),
                _whoIsReading(),
                const SizedBox(height: 16),
                const NoticeCard(
                  icon: Icons.info_outline_rounded,
                  tint: Color(0xFF3A2FB0),
                  background: Palette.brandSoft,
                  text:
                      'Este aplicativo não faz diagnóstico. Ele descreve o padrão '
                      'de leitura observado e sugere adaptações ao professor. '
                      'Avaliação clínica é de profissional habilitado.',
                ),
                if (_trainedOnSyntheticData) ...[
                  const SizedBox(height: 10),
                  const NoticeCard(
                    icon: Icons.science_outlined,
                    tint: Color(0xFFA32317),
                    background: Palette.coralSoft,
                    text:
                        'O modelo embarcado foi treinado em dados sintéticos e não '
                        'aprendeu nada sobre leitura. Serve só para experimentar.',
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  NoticeCard(
                    icon: Icons.error_outline_rounded,
                    tint: const Color(0xFFA32317),
                    background: Palette.coralSoft,
                    text: _error!,
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _whoIsReading() {
    if (_loadingRoster) {
      return const AppCard(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final roster = _roster;
    if (roster == null) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Nenhuma turma neste aparelho', style: AppType.title),
            const SizedBox(height: 8),
            Text(
              'No painel do professor, em “Alunos e turmas”, exporte a lista '
              'da turma e envie o arquivo para este celular.',
              style: AppType.body.copyWith(color: Palette.inkMuted),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Importar lista da turma',
              icon: Icons.group_add_rounded,
              onPressed: _importRoster,
            ),
          ],
        ),
      );
    }

    final ticket = _openTicket;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ActivityCard(
          className: roster.className,
          ticket: ticket,
          onScan: _scan,
          onChangeClass: _importRoster,
        ),
        if (ticket != null) ...[
          const SizedBox(height: 16),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Quem vai ler hoje?', style: AppType.title),
                Text(
                  'Toque no seu nome',
                  style: AppType.body.copyWith(color: Palette.inkMuted),
                ),
                const SizedBox(height: 14),
                StudentPicker(roster: roster, onSelected: _studentSelected),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// O cabeçalho de marca da tela inicial.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Container(
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
                const EyeMascot(size: 92, iris: Palette.amber),
                const SizedBox(height: 16),
                Text(
                  'EyeLearn',
                  style: AppType.display
                      .copyWith(color: Colors.white, fontSize: 30),
                ),
                const SizedBox(height: 4),
                Text(
                  'Vamos ler juntos?',
                  style: AppType.subtitle.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      );
}

/// Liga a leitura à exportação.
class _ReadingFlow extends StatelessWidget {
  final GazeChannel channel;
  final GazeCalibration calibration;
  final Passage passage;
  final ModelArtifact artifact;
  final String participantCode;
  final String activityCode;

  const _ReadingFlow({
    required this.channel,
    required this.calibration,
    required this.passage,
    required this.artifact,
    required this.participantCode,
    required this.activityCode,
  });

  @override
  Widget build(BuildContext context) {
    final startedAt = DateTime.now();

    return ReadingScreen(
      channel: channel,
      calibration: calibration,
      passage: passage,
      onFinished: (trace, quality) async {
        final analysis = analyse(trace, artifact.preprocessing);
        final exported = await exportSession(
          participantCode: participantCode,
          activityCode: activityCode,
          task: passage.id,
          startedAt: startedAt,
          trace: trace,
          quality: quality,
          features: analysis.features,
          artifact: artifact,
        );

        if (!context.mounted) return;
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (context) => FinishedScreen(
              session: exported.session,
              onShare: () => shareSession(exported),
            ),
          ),
        );
      },
    );
  }
}

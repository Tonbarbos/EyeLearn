/// Pré-visualização em navegador.
///
/// Mostra as telas reais do aplicativo percorrendo o caminho real -- descarte
/// de piscada, detecção de fixações e sacadas, extração das características,
/// inferência do modelo embarcado. A única coisa trocada é a origem dos
/// quadros: em vez da câmera e do MediaPipe, uma [SyntheticGazeSource] emite
/// pontos de rosto a 30 Hz com a íris onde o roteiro pedir.
///
/// Serve para ver a interface sem Android, sem câmera e sem o modelo do
/// MediaPipe, e para gravar o fluxo. **Não é o aplicativo instalado**: não há
/// permissão de câmera, não há arquivo de sessão e não há compartilhamento.
///
/// Rode com:
///
///     flutter run -d chrome -t lib/main_demo.dart
library;

import 'dart:async';
import 'dart:convert';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/activity/passages.dart';
import 'src/gaze/synthetic_gaze_source.dart';
import 'src/ui/calibration_screen.dart';
import 'src/ui/finished_screen.dart';
import 'src/ui/reading_screen.dart';
import 'src/ui/student_login.dart';
import 'src/ui/theme.dart';
import 'src/ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final artifact = ModelArtifact.fromJsonString(
    await rootBundle.loadString('assets/model.json'),
  );

  // A lista fictícia vem com os PINs ao lado, para quem experimenta saber o
  // que digitar. No aplicativo real a lista não tem PIN em claro nenhum.
  final demo =
      jsonDecode(await rootBundle.loadString('assets/demo_roster.json'))
          as Map<String, dynamic>;
  final roster = Roster.fromJson(demo['roster'] as Map<String, dynamic>);
  final pins = (demo['pins_for_tests'] as Map).cast<String, String>();

  runApp(DemoApp(artifact: artifact, roster: roster, pins: pins));
}

class DemoApp extends StatelessWidget {
  final ModelArtifact artifact;
  final Roster roster;
  final Map<String, String> pins;

  const DemoApp({
    super.key,
    required this.artifact,
    required this.roster,
    required this.pins,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'EyeLearn — pré-visualização',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          useMaterial3: true,
        ),
        home: DemoFlow(artifact: artifact, roster: roster, pins: pins),
      );
}

/// Etapas da pré-visualização.
enum DemoStage { intro, login, calibrating, reading, finished }

class DemoFlow extends StatefulWidget {
  final ModelArtifact artifact;
  final Roster roster;
  final Map<String, String> pins;

  const DemoFlow({
    super.key,
    required this.artifact,
    required this.roster,
    required this.pins,
  });

  @override
  State<DemoFlow> createState() => _DemoFlowState();
}

class _DemoFlowState extends State<DemoFlow> {
  final _source = SyntheticGazeSource();
  final _passage = passages[1]; // "Uma história": texto com sentido.
  final _limiter = PinAttemptLimiter();

  DemoStage _stage = DemoStage.intro;
  GazeCalibration? _calibration;
  Session? _session;
  Timer? _script;
  String _participantCode = 'DEMO01';

  @override
  void dispose() {
    _script?.cancel();
    _source.stop();
    super.dispose();
  }

  void _begin() => setState(() => _stage = DemoStage.login);

  Future<void> _studentSelected(RosterStudent student) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => PinScreen(
            student: student,
            limiter: _limiter,
            onAccepted: () {
              Navigator.of(context).pop();
              setState(() {
                _participantCode = student.code;
                _stage = DemoStage.calibrating;
              });
            },
          ),
        ),
      );

  /// Conduz o olhar sintético pelas linhas do texto.
  ///
  /// Reproduz a estrutura de uma leitura: fixações de cerca de 250 ms avançando
  /// pela linha, retorno de linha ao chegar ao fim, uma regressão de vez em
  /// quando e uma piscada no meio. É o percurso que o pipeline vai analisar.
  void _driveReading() {
    const fixationsPerLine = 6;
    const lineCount = 6;
    const degreesPerFixation = 2.4;
    const lineSpacing = 3.2;

    var line = 0;
    var step = 0;
    var regressionsLeft = 4;
    var pendingRegression = false;

    _script = Timer.periodic(const Duration(milliseconds: 260), (timer) {
      if (line >= lineCount) {
        timer.cancel();
        return;
      }

      // Uma regressão a cada poucas fixações: volta uma palavra e relê.
      if (pendingRegression) {
        pendingRegression = false;
        _source.lookAtDegrees(
          -14.0 + (step - 1) * degreesPerFixation,
          -8.0 + line * lineSpacing,
        );
        return;
      }

      _source.lookAtDegrees(
        -14.0 + step * degreesPerFixation,
        -8.0 + line * lineSpacing,
      );

      if (regressionsLeft > 0 && step == 3) {
        pendingRegression = true;
        regressionsLeft--;
      }

      step++;
      if (step >= fixationsPerLine) {
        step = 0;
        line++;
        // Uma piscada no retorno de linha, que é onde ela mais acontece.
        if (line == 3) _source.blink();
      }
    });
  }

  void _onCalibrated(GazeCalibration calibration) {
    setState(() {
      _calibration = calibration;
      _stage = DemoStage.reading;
    });
  }

  void _onReadingFinished(GazeTrace trace, RecordingQuality quality) {
    _script?.cancel();

    final analysis = analyse(trace, widget.artifact.preprocessing);
    setState(() {
      _session = Session.fromAnalysis(
        participantCode: _participantCode,
        task: _passage.id,
        startedAt: DateTime.now(),
        durationSeconds: trace.duration,
        samplingRateHz: trace.samplingRate,
        validSampleRatio: quality.validRatio,
        features: analysis.features,
        artifact: widget.artifact,
      );
      _stage = DemoStage.finished;
    });
  }

  @override
  Widget build(BuildContext context) => switch (_stage) {
        DemoStage.intro =>
          _IntroScreen(artifact: widget.artifact, onStart: _begin),
        DemoStage.login => _DemoLoginScreen(
            roster: widget.roster,
            pins: widget.pins,
            onSelected: _studentSelected,
          ),
        DemoStage.calibrating => CalibrationScreen(
            channel: _source,
            onCalibrated: _onCalibrated,
            // Fecha o laço: a fonte sintética olha para o alvo que a tela mostra.
            onTargetShown: (target) => _source.lookAtFraction(
              fractionX: target.fractionX,
              fractionY: target.fractionY,
              degreesPerHalfWidth: CalibrationScreen.degreesPerHalfWidth,
              degreesPerHalfHeight: CalibrationScreen.degreesPerHalfHeight,
            ),
          ),
        DemoStage.reading => ReadingScreen(
            channel: _source,
            calibration: _calibration!,
            passage: _passage,
            onFinished: _onReadingFinished,
            onStarted: _driveReading,
          ),
        // Sem onShare: no navegador não há arquivo nem folha de compartilhamento.
        DemoStage.finished => FinishedScreen(session: _session!),
      };
}

/// Tela de abertura da pré-visualização.
///
/// Substitui a tela de configuração do aplicativo, que pede permissão de câmera
/// -- coisa que não existe aqui. Diz o que está sendo mostrado e o que não
/// está, para que ninguém confunda a pré-visualização com o aplicativo.
class _IntroScreen extends StatelessWidget {
  final ModelArtifact artifact;
  final VoidCallback onStart;

  const _IntroScreen({required this.artifact, required this.onStart});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
                      const EyeMascot(size: 88, iris: Palette.amber),
                      const SizedBox(height: 16),
                      Text(
                        'EyeLearn',
                        style: AppType.display.copyWith(
                          color: Colors.white,
                          fontSize: 29,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius:
                              BorderRadius.circular(Shapes.chipRadius),
                        ),
                        child: Text(
                          'PRÉ-VISUALIZAÇÃO',
                          style: AppType.label.copyWith(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('O que você vai ver', style: AppType.title),
                      SizedBox(height: 10),
                      NumberedStep(
                        number: 1,
                        title: 'Entrada',
                        detail:
                            'A criança toca no próprio nome e digita o PIN de '
                            'quatro dígitos. A lista vem do painel do professor.',
                      ),
                      NumberedStep(
                        number: 2,
                        title: 'Calibração',
                        detail:
                            'Cinco alvos. O olhar sintético segue cada um, e o '
                            'ajuste por mínimos quadrados reconstrói o mapa da '
                            'íris para a tela.',
                      ),
                      NumberedStep(
                        number: 3,
                        title: 'Leitura',
                        detail:
                            'Seis linhas. O percurso avança com fixações de cerca '
                            'de 250 ms, quatro regressões e uma piscada no retorno '
                            'de linha.',
                      ),
                      NumberedStep(
                        number: 4,
                        title: 'Fim',
                        detail:
                            'A criança vê que terminou, e nada mais. A qualidade '
                            'da captura aparece só para o adulto.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const NoticeCard(
                  icon: Icons.videocam_off_outlined,
                  tint: Color(0xFF9A5B00),
                  background: Palette.amberSoft,
                  text:
                      'A câmera está trocada por uma fonte sintética a 30 Hz. Sem '
                      'permissão de câmera, arquivo de sessão nem '
                      'compartilhamento: para isso, o aplicativo no Android.',
                ),
                if (artifact.metadata['training_data'] == 'synthetic') ...[
                  const SizedBox(height: 10),
                  const NoticeCard(
                    icon: Icons.science_outlined,
                    tint: Color(0xFFA32317),
                    background: Palette.coralSoft,
                    text:
                        'O modelo foi treinado em dados sintéticos e não aprendeu '
                        'nada sobre leitura. A pontuação do fim não significa nada.',
                  ),
                ],
                const SizedBox(height: 22),
                PrimaryButton(
                  label: 'Começar a pré-visualização',
                  icon: Icons.play_arrow_rounded,
                  onPressed: onStart,
                ),
              ],
            ),
          ),
        ),
      );
}

/// A escolha do nome, como na tela inicial do aplicativo, com os PINs da turma
/// fictícia à vista.
class _DemoLoginScreen extends StatelessWidget {
  final Roster roster;
  final Map<String, String> pins;
  final ValueChanged<RosterStudent> onSelected;

  const _DemoLoginScreen({
    required this.roster,
    required this.pins,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Quem vai ler hoje?', style: AppType.title),
                      Text(
                        '${roster.className} · toque no seu nome',
                        style: AppType.body.copyWith(color: Palette.inkMuted),
                      ),
                      const SizedBox(height: 14),
                      StudentPicker(roster: roster, onSelected: onSelected),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                NoticeCard(
                  icon: Icons.key_rounded,
                  tint: const Color(0xFF9A5B00),
                  background: Palette.amberSoft,
                  text: 'Turma fictícia. PINs: '
                      '${[
                    for (final s in roster.students)
                      '${s.displayName} ${pins[s.code]}',
                  ].join(' · ')}',
                ),
              ],
            ),
          ),
        ),
      );
}

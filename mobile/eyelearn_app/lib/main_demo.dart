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

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/activity/passages.dart';
import 'src/gaze/synthetic_gaze_source.dart';
import 'src/ui/calibration_screen.dart';
import 'src/ui/finished_screen.dart';
import 'src/ui/reading_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final artifact = ModelArtifact.fromJsonString(
    await rootBundle.loadString('assets/model.json'),
  );

  runApp(DemoApp(artifact: artifact));
}

class DemoApp extends StatelessWidget {
  final ModelArtifact artifact;

  const DemoApp({super.key, required this.artifact});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'EyeLearn — pré-visualização',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          useMaterial3: true,
        ),
        home: DemoFlow(artifact: artifact),
      );
}

/// Etapas da pré-visualização.
enum DemoStage { intro, calibrating, reading, finished }

class DemoFlow extends StatefulWidget {
  final ModelArtifact artifact;

  const DemoFlow({super.key, required this.artifact});

  @override
  State<DemoFlow> createState() => _DemoFlowState();
}

class _DemoFlowState extends State<DemoFlow> {
  final _source = SyntheticGazeSource();
  final _passage = passages[1]; // "Uma história": texto com sentido.

  DemoStage _stage = DemoStage.intro;
  GazeCalibration? _calibration;
  Session? _session;
  Timer? _script;

  @override
  void dispose() {
    _script?.cancel();
    _source.stop();
    super.dispose();
  }

  void _begin() => setState(() => _stage = DemoStage.calibrating);

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
        participantCode: 'DEMO01',
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
        appBar: AppBar(title: const Text('EyeLearn — pré-visualização')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Telas reais do aplicativo do aluno, com o pipeline real: descarte '
                'de piscada, detecção de fixações e sacadas, extração das '
                'características e inferência do modelo embarcado.',
                style: TextStyle(fontSize: 16, height: 1.45),
              ),
              const SizedBox(height: 18),
              const _Note(
                colour: Color(0xFFFFF3C4),
                textColour: Color(0xFF8D2B0B),
                text:
                    'A câmera está trocada por uma fonte sintética que emite pontos '
                    'de rosto a 30 Hz. Não há permissão de câmera, arquivo de sessão '
                    'nem compartilhamento: para isso, o aplicativo no Android.',
              ),
              if (artifact.metadata['training_data'] == 'synthetic') ...[
                const SizedBox(height: 12),
                const _Note(
                  colour: Color(0xFFFFE3E3),
                  textColour: Color(0xFF610404),
                  text:
                      'O modelo embarcado foi treinado em dados sintéticos e não '
                      'aprendeu nada sobre leitura. A pontuação que aparecer no fim '
                      'não significa nada.',
                ),
              ],
              const SizedBox(height: 28),
              const Text(
                'O que você vai ver',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const _Step(
                number: '1',
                title: 'Calibração',
                detail:
                    'Cinco alvos. O olhar sintético segue cada um, e o ajuste por '
                    'mínimos quadrados reconstrói o mapa do deslocamento da íris '
                    'para a tela.',
              ),
              const _Step(
                number: '2',
                title: 'Leitura',
                detail:
                    'Seis linhas de texto. O percurso avança pelas linhas com '
                    'fixações de cerca de 250 ms, quatro regressões e uma piscada '
                    'no retorno de linha.',
              ),
              const _Step(
                number: '3',
                title: 'Fim',
                detail:
                    'A criança vê que terminou, e nada mais. A qualidade da captura '
                    'aparece só para o adulto.',
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: onStart,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  textStyle: const TextStyle(fontSize: 18),
                ),
                child: const Text('Começar a pré-visualização'),
              ),
            ],
          ),
        ),
      );
}

class _Note extends StatelessWidget {
  final Color colour;
  final Color textColour;
  final String text;

  const _Note({
    required this.colour,
    required this.textColour,
    required this.text,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 14.5, height: 1.4, color: textColour),
        ),
      );
}

class _Step extends StatelessWidget {
  final String number;
  final String title;
  final String detail;

  const _Step({
    required this.number,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFF1565C0),
                shape: BoxShape.circle,
              ),
              child: Text(
                number,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(detail,
                      style: const TextStyle(fontSize: 14, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );
}

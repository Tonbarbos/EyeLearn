/// Pré-visualização em navegador, sem câmera.
///
/// Mostra as telas reais do aplicativo percorrendo o caminho real -- entrada
/// na turma por link e código, nome e PIN, lista de atividades, calibração,
/// leitura, descarte de piscada, detecção de fixações e sacadas, extração das
/// características, inferência do modelo da tarefa. A única coisa trocada é a
/// origem dos quadros: em vez da câmera e do MediaPipe, uma
/// [SyntheticGazeSource] emite pontos de rosto a 30 Hz com a íris onde o
/// roteiro pedir.
///
/// A turma é a fictícia de `assets/demo_class.json`, aberta pelo mesmo
/// caminho de um link de verdade, e o código e os PINs aparecem na tela. O
/// "hoje" da pré-visualização é o dia de referência do exemplo, para as
/// atividades aparecerem sempre nos mesmos estados.
///
/// Serve para ver a interface sem celular e para gravar o fluxo. **Não é o
/// aplicativo de verdade**: não há câmera, a turma não fica guardada e não há
/// envio de arquivo.
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
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/activity/models.dart';
import 'src/gaze/synthetic_gaze_source.dart';
import 'src/homework_app.dart';
import 'src/session/class_storage.dart';
import 'src/ui/calibration_screen.dart';
import 'src/ui/gaze_test_screen.dart';
import 'src/ui/theme.dart';
import 'src/ui/widgets.dart';

Future<void> main() async {
  setUrlStrategy(null);
  WidgetsFlutterBinding.ensureInitialized();

  final demo = jsonDecode(await rootBundle.loadString('assets/demo_class.json'))
      as Map<String, dynamic>;
  final roster = Roster.fromJson(demo['expected'] as Map<String, dynamic>);
  final pins = (demo['pins_for_tests'] as Map).cast<String, String>();
  final today = DateTime.parse(demo['today'] as String);

  runApp(
    HomeworkApp(
      title: 'EyeLearn — pré-visualização',
      environment: HomeworkEnvironment(
        models: await loadModels(),
        gaze: SyntheticGazeSource.new,
        storage: MemoryClassStorage(),
        // Dia de referência do exemplo, à hora de agora.
        clock: () {
          final now = DateTime.now();
          return DateTime(today.year, today.month, today.day, now.hour,
              now.minute, now.second);
        },
        // O link fictício chega como se viesse da barra de endereço.
        initialLink: '#t=${demo['fragment']}',
        onTargetShown: (gaze, target) =>
            (gaze as SyntheticGazeSource).lookAtFraction(
          fractionX: target.fractionX,
          fractionY: target.fractionY,
          degreesPerHalfWidth: CalibrationScreen.degreesPerHalfWidth,
          degreesPerHalfHeight: CalibrationScreen.degreesPerHalfHeight,
        ),
        onReadingStarted: (gaze) => driveReading(gaze as SyntheticGazeSource),
        onGazeTestViewing: (gaze) =>
            wanderOverReferences(gaze as SyntheticGazeSource),
        joinHint: _DemoHint(
          'Pré-visualização, turma fictícia. Código da turma: '
          '${demo['code']}',
        ),
        pickerHint: _DemoHint(
          'PINs da turma fictícia: ${[
            for (final s in roster.students) '${s.displayName} ${pins[s.code]}',
          ].join(' · ')}',
        ),
      ),
    ),
  );
}

/// Conduz o olhar sintético pelas linhas do texto.
///
/// Reproduz a estrutura de uma leitura: fixações de cerca de 250 ms avançando
/// pela linha, retorno de linha ao chegar ao fim, uma regressão de vez em
/// quando e uma piscada no meio. É o percurso que o pipeline vai analisar.
void driveReading(SyntheticGazeSource source) {
  const fixationsPerLine = 6;
  const lineCount = 6;
  const degreesPerFixation = 2.4;
  const lineSpacing = 3.2;

  var line = 0;
  var step = 0;
  var regressionsLeft = 4;
  var pendingRegression = false;

  Timer.periodic(const Duration(milliseconds: 260), (timer) {
    if (line >= lineCount) {
      timer.cancel();
      return;
    }

    // Uma regressão a cada poucas fixações: volta uma palavra e relê.
    if (pendingRegression) {
      pendingRegression = false;
      source.lookAtDegrees(
        -14.0 + (step - 1) * degreesPerFixation,
        -8.0 + line * lineSpacing,
      );
      return;
    }

    source.lookAtDegrees(
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
      if (line == 3) source.blink();
    }
  });
}

/// Passeia o olhar sintético pelos números do teste do olhar, um por vez,
/// com uma piscada de vez em quando. Devolve como parar.
VoidCallback wanderOverReferences(SyntheticGazeSource source) {
  var index = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
    final target = gazeReferences[index % gazeReferences.length];
    source.lookAtFraction(
      fractionX: target.dx,
      fractionY: target.dy,
      degreesPerHalfWidth: CalibrationScreen.degreesPerHalfWidth,
      degreesPerHalfHeight: CalibrationScreen.degreesPerHalfHeight,
    );
    if (index % 5 == 4) source.blink();
    index++;
  });
  return timer.cancel;
}

class _DemoHint extends StatelessWidget {
  final String text;

  const _DemoHint(this.text);

  @override
  Widget build(BuildContext context) => NoticeCard(
        icon: Icons.key_rounded,
        tint: const Color(0xFF9A5B00),
        background: Palette.amberSoft,
        text: text,
      );
}

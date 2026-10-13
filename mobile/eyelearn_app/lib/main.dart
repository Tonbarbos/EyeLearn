/// Aplicativo do aluno.
///
/// O fluxo é: um adulto informa o código do participante e escolhe a tarefa, a
/// criança calibra seguindo uma bolinha, lê o texto, e o adulto compartilha o
/// arquivo de sessão com o professor.
///
/// A criança nunca vê resultado. A tela final diz que ela terminou, e é tudo --
/// ver mais que isso seria receber um rótulo de um modelo cujo valor preditivo
/// positivo na prevalência escolar é de cerca de 22%.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'src/activity/passages.dart';
import 'src/gaze/gaze_channel.dart';
import 'src/session/session_export.dart';
import 'src/ui/calibration_screen.dart';
import 'src/ui/finished_screen.dart';
import 'src/ui/reading_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final artifact = ModelArtifact.fromJsonString(
    await rootBundle.loadString('assets/model.json'),
  );

  runApp(EyeLearnApp(artifact: artifact));
}

class EyeLearnApp extends StatelessWidget {
  final ModelArtifact artifact;

  const EyeLearnApp({super.key, required this.artifact});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'EyeLearn',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          useMaterial3: true,
        ),
        home: SetupScreen(artifact: artifact),
      );
}

/// Tela inicial, para o adulto.
///
/// Pede o código do participante e a tarefa. Não há cadastro de alunos no
/// aplicativo de propósito: a associação entre código e criança fica com o
/// professor, fora do aparelho.
class SetupScreen extends StatefulWidget {
  final ModelArtifact artifact;

  const SetupScreen({super.key, required this.artifact});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _codeController = TextEditingController();
  Passage _passage = passages.first;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  bool get _trainedOnSyntheticData =>
      widget.artifact.metadata['training_data'] == 'synthetic';

  Future<void> _begin() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Informe um código para o participante.');
      return;
    }

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
                passage: _passage,
                artifact: widget.artifact,
                participantCode: code,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('EyeLearn')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Este aplicativo não faz diagnóstico. Ele descreve o padrão '
                'de leitura observado e envia ao professor uma sugestão de '
                'adaptação pedagógica. Qualquer avaliação clínica é '
                'responsabilidade de profissional habilitado.',
                style: TextStyle(fontSize: 15, height: 1.4),
              ),
              if (_trainedOnSyntheticData) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFE3E3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Atenção: o modelo embarcado foi treinado em dados '
                    'sintéticos e não aprendeu nada sobre leitura. Serve '
                    'apenas para experimentar o aplicativo.',
                    style: TextStyle(fontSize: 15, color: Color(0xFF610404)),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Código do participante',
                  helperText: 'Nunca o nome da criança',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<Passage>(
                initialValue: _passage,
                decoration: const InputDecoration(
                  labelText: 'Tarefa',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final passage in passages)
                    DropdownMenuItem(
                        value: passage, child: Text(passage.title)),
                ],
                onChanged: (passage) {
                  if (passage != null) setState(() => _passage = passage);
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style:
                      const TextStyle(color: Color(0xFF610404), fontSize: 15),
                ),
              ],
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _begin,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  textStyle: const TextStyle(fontSize: 18),
                ),
                child: const Text('Calibrar e começar'),
              ),
            ],
          ),
        ),
      );
}

/// Liga a leitura à exportação.
class _ReadingFlow extends StatelessWidget {
  final GazeChannel channel;
  final GazeCalibration calibration;
  final Passage passage;
  final ModelArtifact artifact;
  final String participantCode;

  const _ReadingFlow({
    required this.channel,
    required this.calibration,
    required this.passage,
    required this.artifact,
    required this.participantCode,
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

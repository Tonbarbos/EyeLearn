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
import 'src/ui/theme.dart';
import 'src/ui/widgets.dart';

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
        theme: buildAppTheme(),
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
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Hero(),
                const SizedBox(height: 26),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Quem vai ler hoje?', style: AppType.title),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _codeController,
                        textCapitalization: TextCapitalization.characters,
                        style: AppType.body.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Código do participante',
                          helperText: 'Nunca o nome da criança',
                          helperStyle: AppType.body.copyWith(
                            fontSize: 12.5,
                            color: Palette.inkMuted,
                          ),
                          prefixIcon: const Icon(Icons.badge_outlined),
                          filled: true,
                          fillColor: Palette.background,
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(Shapes.chipRadius + 2),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text('Atividade', style: AppType.label),
                      const SizedBox(height: 10),
                      _TaskPicker(
                        selected: _passage,
                        onChanged: (passage) =>
                            setState(() => _passage = passage),
                      ),
                    ],
                  ),
                ),
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
                const SizedBox(height: 22),
                PrimaryButton(
                  label: 'Calibrar e começar',
                  icon: Icons.play_arrow_rounded,
                  onPressed: _begin,
                ),
              ],
            ),
          ),
        ),
      );
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

/// Escolha da atividade, em cartões tocáveis.
///
/// Em vez de uma lista suspensa: o adulto escolhe de pé, ao lado da criança,
/// e três alvos grandes são mais rápidos que abrir um menu.
class _TaskPicker extends StatelessWidget {
  final Passage selected;
  final ValueChanged<Passage> onChanged;

  const _TaskPicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final passage in passages)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TaskOption(
                passage: passage,
                selected: passage.id == selected.id,
                onTap: () => onChanged(passage),
              ),
            ),
        ],
      );
}

class _TaskOption extends StatelessWidget {
  final Passage passage;
  final bool selected;
  final VoidCallback onTap;

  const _TaskOption({
    required this.passage,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Shapes.chipRadius + 2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: selected ? Palette.brandSoft : Palette.background,
              borderRadius: BorderRadius.circular(Shapes.chipRadius + 2),
              border: Border.all(
                color: selected ? Palette.brand : Colors.transparent,
                width: 1.8,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 21,
                  color: selected ? Palette.brand : Palette.inkMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    passage.title,
                    style: AppType.body.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected ? Palette.brandDeep : Palette.ink,
                    ),
                  ),
                ),
                Text(
                  '${passage.lines.length} linhas',
                  style: AppType.body.copyWith(
                    fontSize: 12.5,
                    color: Palette.inkMuted,
                  ),
                ),
              ],
            ),
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

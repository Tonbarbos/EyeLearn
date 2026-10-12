/// Tela de leitura: a criança lê enquanto a câmera acompanha o olhar.
///
/// **Esta tela não mostra resultado nenhum, nem aqui nem depois.** A saída
/// pedagógica vai para o painel do professor. Mostrar a uma criança de nove
/// anos uma tela que diz algo sobre o padrão de leitura dela seria exatamente o
/// que o projeto se compromete a não fazer -- e, pior, seria um rótulo vindo de
/// um modelo cujo valor preditivo positivo na prevalência escolar é de cerca de
/// 22%.
///
/// O que a criança vê ao terminar é que terminou.
library;

import 'dart:async';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import '../activity/passages.dart';
import '../gaze/gaze_channel.dart';

class ReadingScreen extends StatefulWidget {
  final GazeChannel channel;
  final GazeCalibration calibration;
  final Passage passage;

  /// Chamada ao final, com o percurso e a qualidade da captura.
  final void Function(GazeTrace trace, RecordingQuality quality) onFinished;

  const ReadingScreen({
    super.key,
    required this.channel,
    required this.calibration,
    required this.passage,
    required this.onFinished,
  });

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  late final GazeRecorder _recorder;
  StreamSubscription<FaceFrame>? _subscription;

  bool _capturing = false;
  String? _warning;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recorder = GazeRecorder(
      calibration: widget.calibration,
      // Limites um pouco maiores que a tela: o olhar sai dela de vez em quando
      // e cortar justo na borda descartaria amostras legítimas das linhas de
      // cima e de baixo.
      boundsDeg: (w: 20.0, h: 30.0),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    // Deixar a câmera ligada depois de sair da tela é, além de desperdício de
    // bateria, uma captura que ninguém pediu.
    widget.channel.stop();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _warning = null;
    });

    try {
      await widget.channel.start();
    } on GazeCaptureError catch (error) {
      if (mounted) setState(() => _error = error.message);
      return;
    }

    _recorder.reset();
    _subscription = widget.channel.frames().listen(_onFrame);
    setState(() => _capturing = true);
  }

  void _onFrame(FaceFrame frame) {
    final rejection = _recorder.add(frame);
    if (rejection == null) {
      if (_warning != null) setState(() => _warning = null);
      return;
    }

    // Só o problema persistente vira aviso. Uma piscada é normal; avisar a
    // cada uma deixaria a tela piscando mensagens.
    final quality = _recorder.quality();
    if (quality.total < 30 || quality.validRatio > 0.7) return;

    final message = switch (quality.dominantProblem) {
      RejectionReason.noFace => 'Deixe o rosto na frente da tela 🙂',
      RejectionReason.eyesClosed => 'Olhos bem abertos!',
      RejectionReason.outsideStimulus => 'Olhe para as palavras',
      null => null,
    };
    if (message != null && message != _warning) {
      setState(() => _warning = message);
    }
  }

  Future<void> _finish() async {
    await _subscription?.cancel();
    _subscription = null;
    await widget.channel.stop();

    setState(() => _capturing = false);
    widget.onFinished(_recorder.build(), _recorder.quality());
  }

  @override
  Widget build(BuildContext context) {
    final passage = widget.passage;

    return Scaffold(
      backgroundColor: const Color(0xFFFDF8F0),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                passage.title,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF243B53),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                passage.instruction,
                style: const TextStyle(fontSize: 17, color: Color(0xFF486581)),
              ),
              const SizedBox(height: 24),
              Expanded(child: _PassageBody(passage: passage)),
              if (_warning != null) _Banner(text: _warning!, warning: true),
              if (_error != null) _Banner(text: _error!, warning: false),
              const SizedBox(height: 16),
              _ActionButton(
                capturing: _capturing,
                onPressed: _capturing ? _finish : _start,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// O texto a ler.
///
/// Linhas com espaçamento generoso e fonte grande: o percurso do olhar só é
/// separável em linhas se as linhas estiverem mais distantes que o erro da
/// estimativa, que é da ordem de 2 a 4 graus. Texto apertado produziria um
/// percurso em que as linhas se misturam, e o retorno de linha -- uma das
/// características medidas -- deixaria de ser detectável.
class _PassageBody extends StatelessWidget {
  final Passage passage;

  const _PassageBody({required this.passage});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final line in passage.lines)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text(
            line,
            style: const TextStyle(
              fontSize: 26,
              height: 1.4,
              color: Color(0xFF102A43),
            ),
          ),
        ),
    ],
  );
}

class _Banner extends StatelessWidget {
  final String text;
  final bool warning;

  const _Banner({required this.text, required this.warning});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: warning ? const Color(0xFFFFF3C4) : const Color(0xFFFFE3E3),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 17,
        color: warning ? const Color(0xFF8D2B0B) : const Color(0xFF610404),
      ),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  final bool capturing;
  final VoidCallback onPressed;

  const _ActionButton({required this.capturing, required this.onPressed});

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: capturing
          ? const Color(0xFF2E7D32)
          : const Color(0xFF1565C0),
      padding: const EdgeInsets.symmetric(vertical: 18),
      textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    ),
    child: Text(capturing ? 'Terminei de ler' : 'Começar'),
  );
}

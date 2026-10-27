/// Antes de calibrar: arrumar a posição do rosto e do celular.
///
/// **Não mostra a câmera.** Ver o próprio rosto causa estranheza e puxa o
/// olhar para ele. No lugar, um visor abstrato: um círculo tracejado é onde o
/// rosto deveria estar, e uma bolinha mostra onde ele está (andando para o
/// mesmo lado que a criança, e crescendo quando ela se aproxima). Embaixo, uma
/// lista do que já está bom.
///
/// Segue sozinha quando está tudo bem por um segundo e meio. Se a captura não
/// conseguir ficar boa (pouca luz em casa, por exemplo), depois de um tempo
/// aparece "Continuar assim mesmo": a sessão sai pior, mas não trava a
/// criança. As regras estão em `posture.dart`, no núcleo.
library;

import 'dart:async';
import 'dart:collection';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import '../gaze/gaze_source.dart';
import 'theme.dart';

/// A frase para cada problema, também usada na calibração e na leitura.
String positionMessage(PositionIssue issue) => switch (issue) {
      PositionIssue.noFace => 'Não estou vendo seu rosto',
      PositionIssue.offCentre => 'Fique bem na frente do celular',
      PositionIssue.tooFar => 'Chegue um pouco mais perto',
      PositionIssue.tooClose => 'Afaste um pouco o celular',
      PositionIssue.phoneFlat => 'Levante o celular, deixe ele em pé',
      PositionIssue.tiltedUpDown => 'Segure o celular na altura do rosto',
      PositionIssue.turned => 'Olhe de frente para o celular',
      PositionIssue.leaning => 'Deixe a cabeça reta',
      PositionIssue.dark => 'Está escuro. Procure um lugar com mais luz',
      PositionIssue.glare =>
        'Tem brilho nos óculos. Incline um pouco o celular',
      PositionIssue.eyesClosed => 'Olhos bem abertos!',
    };

/// Os itens da lista, cada um com os problemas que o deixam pendente.
const _checks = <(String, Set<PositionIssue>)>[
  ('Rosto no meio', {PositionIssue.noFace, PositionIssue.offCentre}),
  ('Distância boa', {PositionIssue.tooFar, PositionIssue.tooClose}),
  (
    'Celular de frente para o rosto',
    {
      PositionIssue.phoneFlat,
      PositionIssue.tiltedUpDown,
      PositionIssue.turned,
      PositionIssue.leaning,
    }
  ),
  ('Luz boa, sem brilho', {PositionIssue.dark, PositionIssue.glare}),
];

class PositioningScreen extends StatefulWidget {
  final GazeSource channel;

  /// Chamada quando a posição está boa (ou a criança decidiu seguir).
  final VoidCallback onReady;

  /// Quanto tempo tudo tem de ficar bom para seguir.
  final Duration hold;

  /// Depois de quanto tempo aparece "Continuar assim mesmo".
  final Duration giveUpAfter;

  const PositioningScreen({
    super.key,
    required this.channel,
    required this.onReady,
    this.hold = const Duration(milliseconds: 1500),
    this.giveUpAfter = const Duration(seconds: 20),
  });

  @override
  State<PositioningScreen> createState() => _PositioningScreenState();
}

class _PositioningScreenState extends State<PositioningScreen> {
  StreamSubscription<FaceFrame>? _subscription;
  Timer? _ticker;

  /// Tempo desde a abertura, contado pelo relógio da tela (e não por um
  /// cronômetro, para os testes poderem avançá-lo).
  Duration _elapsed = Duration.zero;
  static const _tick = Duration(milliseconds: 250);

  /// Problemas dos últimos quadros: um problema só vale se aparece em boa
  /// parte deles, para a lista não piscar a cada quadro.
  final _recent = ListQueue<List<PositionIssue>>();
  Posture? _posture;
  Duration? _lastFrameAt;
  Duration? _goodSince;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _begin();
    // A captura do navegador não manda quadro quando não acha rosto; o
    // relógio é que percebe a falta.
    _ticker = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() {
        _elapsed += _tick;
        _evaluate();
      });
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      await widget.channel.start();
    } on GazeCaptureError catch (error) {
      if (mounted) setState(() => _error = error.message);
      return;
    }
    if (!mounted) return;
    _subscription = widget.channel.frames().listen(_onFrame);
  }

  void _onFrame(FaceFrame frame) {
    _lastFrameAt = _elapsed;
    _posture = Posture.of(frame);
    _recent.addLast(assessPosition(frame));
    while (_recent.length > 8) {
      _recent.removeFirst();
    }
    setState(_evaluate);
  }

  bool get _faceMissing {
    final last = _lastFrameAt;
    return last == null || _elapsed - last > const Duration(milliseconds: 700);
  }

  List<PositionIssue> get _issues {
    if (_faceMissing || _recent.isEmpty) return const [PositionIssue.noFace];
    final counts = <PositionIssue, int>{};
    for (final frame in _recent) {
      for (final issue in frame) {
        counts[issue] = (counts[issue] ?? 0) + 1;
      }
    }
    return [
      for (final issue in PositionIssue.values)
        if ((counts[issue] ?? 0) * 2 >= _recent.length) issue,
    ];
  }

  void _evaluate() {
    if (_done) return;
    // Uma piscada não desfaz a posição.
    final blocking =
        _issues.where((i) => i != PositionIssue.eyesClosed).isNotEmpty;
    final now = _elapsed;
    if (blocking) {
      _goodSince = null;
    } else {
      _goodSince ??= now;
      if (now - _goodSince! >= widget.hold) _finish();
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _ticker?.cancel();
    _subscription?.cancel();
    _subscription = null;
    // Depois do quadro atual: chamar o pai dentro de um setState daria
    // erro de reconstrução.
    scheduleMicrotask(widget.onReady);
  }

  @override
  Widget build(BuildContext context) {
    final issues = _issues;
    final ok = issues.where((i) => i != PositionIssue.eyesClosed).isEmpty;
    final message = _error ??
        (ok
            ? 'Isso! Fique assim…'
            : positionMessage(issues.firstWhere(
                (i) => i != PositionIssue.eyesClosed,
              )));
    final posture = _faceMissing ? null : _posture;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Palette.nightTop, Palette.nightBottom],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  children: [
                    Text(
                      'Antes de começar',
                      style: AppType.body
                          .copyWith(color: Colors.white54, fontSize: 15),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      message,
                      key: const Key('positioning-message'),
                      textAlign: TextAlign.center,
                      style: AppType.title.copyWith(
                        color: ok ? Palette.green : Colors.white,
                        fontSize: 22,
                      ),
                    ),
                    const SizedBox(height: 22),
                    _Viewfinder(posture: posture, ok: ok),
                    const SizedBox(height: 22),
                    for (final (label, related) in _checks)
                      _CheckRow(
                        label: label,
                        done: !issues.any(related.contains),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      'Segure o celular em pé, na altura do rosto, a um palmo '
                      'e meio de distância. Usa óculos? Fique com eles até o '
                      'fim.',
                      textAlign: TextAlign.center,
                      style: AppType.body
                          .copyWith(color: Colors.white60, fontSize: 14),
                    ),
                    if (_elapsed >= widget.giveUpAfter && _error == null) ...[
                      const SizedBox(height: 14),
                      TextButton(
                        key: const Key('positioning-skip'),
                        onPressed: _finish,
                        child: const Text(
                          'Continuar assim mesmo',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// O visor: onde o rosto está em relação a onde deveria estar.
class _Viewfinder extends StatelessWidget {
  final Posture? posture;
  final bool ok;

  const _Viewfinder({required this.posture, required this.ok});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 200,
        height: 200,
        child: CustomPaint(
          painter: _ViewfinderPainter(posture: posture, ok: ok),
        ),
      );
}

class _ViewfinderPainter extends CustomPainter {
  final Posture? posture;
  final bool ok;

  _ViewfinderPainter({required this.posture, required this.ok});

  /// Largura do olho, em pixels da câmera, que dá o tamanho do alvo: uns
  /// 35 cm de distância.
  static const double _idealEye = 32;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final frame = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(28),
    );
    canvas.drawRRect(
        frame, Paint()..color = Colors.white.withValues(alpha: 0.06));

    // O alvo, tracejado.
    const targetRadius = 46.0;
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: 0.4);
    const segments = 24;
    for (var i = 0; i < segments; i += 2) {
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: targetRadius),
        i * 6.2832 / segments,
        6.2832 / segments,
        false,
        dash,
      );
    }

    final p = posture;
    if (p == null) return;
    // Espelhado: a câmera frontal vê a criança ao contrário, e a bolinha tem
    // de andar para o mesmo lado que ela.
    final position = Offset(
      size.width * (1 - p.centreX),
      size.height * p.centreY,
    );
    final scale = (p.eyeWidthPx ?? _idealEye) / _idealEye;
    final radius = (targetRadius * scale).clamp(12.0, size.width * 0.48);
    final colour = ok ? Palette.green : Palette.amber;
    canvas.save();
    canvas.clipRRect(frame);
    canvas.drawCircle(
        position, radius, Paint()..color = colour.withValues(alpha: 0.35));
    canvas.drawCircle(
      position,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = colour,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => true;
}

class _CheckRow extends StatelessWidget {
  final String label;
  final bool done;

  const _CheckRow({required this.label, required this.done});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
              color: done ? Palette.green : Colors.white38,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppType.body.copyWith(
                  color: done ? Colors.white : Colors.white60,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      );
}

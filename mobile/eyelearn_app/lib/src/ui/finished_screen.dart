/// Tela final do aplicativo do aluno.
///
/// Para a criança: terminou. Nada mais. A saída pedagógica vai para o
/// professor, e um rótulo vindo de um modelo cujo valor preditivo positivo na
/// prevalência escolar é de cerca de 22% não é coisa que se mostre a uma
/// criança de nove anos.
///
/// O que a criança vê é uma comemoração. O que o adulto vê fica abaixo, atrás
/// de um separador discreto, e trata só da qualidade da captura -- nunca do
/// resultado.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

class FinishedScreen extends StatelessWidget {
  final Session session;

  /// Ação de enviar ao professor.
  ///
  /// Chega por parâmetro, e não por importação, porque gravar e compartilhar
  /// arquivo depende de `dart:io` e das folhas de compartilhamento do sistema,
  /// que não existem no navegador. Nula esconde o botão -- é o que a
  /// pré-visualização de `main_demo.dart` faz.
  final Future<void> Function()? onShare;

  /// Botão de saída. Sem [onDone], volta ao início.
  final String doneLabel;
  final VoidCallback? onDone;

  const FinishedScreen({
    super.key,
    required this.session,
    this.onShare,
    this.doneLabel = 'Nova atividade',
    this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final usable = session.hasUsableQuality();

    return Scaffold(
      body: SafeArea(
        // Centra verticalmente quando sobra espaço e rola quando falta: a tela
        // precisa funcionar num aparelho alto e num de tela curta, sem deixar
        // a comemoração encostada no topo.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 28,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 18),
                  const _Celebration(),
                  const SizedBox(height: 26),
                  const Text('Terminei!', style: AppType.display),
                  const SizedBox(height: 8),
                  const Text(
                    'Obrigado por ler com a gente.',
                    textAlign: TextAlign.center,
                    style: AppType.subtitle,
                  ),
                  const SizedBox(height: 34),
                  _AdultSection(
                    session: session,
                    usable: usable,
                    onShare: onShare,
                    doneLabel: doneLabel,
                    onDone: onDone,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A comemoração: o mascote sobre um disco colorido, com raios.
///
/// Desenhada em código pelo mesmo motivo do mascote -- acompanha o tema sem
/// variantes exportadas.
class _Celebration extends StatelessWidget {
  const _Celebration();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 168,
        height: 168,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 168,
              height: 168,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Palette.brandSoft,
              ),
            ),
            Container(
              width: 122,
              height: 122,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Palette.brand, Palette.brandDeep],
                ),
              ),
            ),
            const EyeMascot(size: 86, iris: Palette.amber),
            // Confete: três formas simples em volta, que dão movimento à
            // composição sem precisar de animação.
            const Positioned(
                top: 8, right: 22, child: _Confetti(Palette.amber, 14)),
            const Positioned(
                bottom: 16, left: 14, child: _Confetti(Palette.green, 11)),
            const Positioned(
                top: 34, left: 4, child: _Confetti(Palette.coral, 9)),
          ],
        ),
      );
}

class _Confetti extends StatelessWidget {
  final Color colour;
  final double size;

  const _Confetti(this.colour, this.size);

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: 0.5,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(size * 0.3),
          ),
        ),
      );
}

/// A parte que é do adulto, não da criança.
class _AdultSection extends StatelessWidget {
  final Session session;
  final bool usable;
  final Future<void> Function()? onShare;

  final String doneLabel;
  final VoidCallback? onDone;

  const _AdultSection({
    required this.session,
    required this.usable,
    required this.onShare,
    required this.doneLabel,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.lock_outline_rounded,
                    size: 15, color: Palette.inkMuted),
                SizedBox(width: 7),
                Text('PARA O ADULTO', style: AppType.label),
              ],
            ),
            const SizedBox(height: 14),
            // IntrinsicHeight iguala a altura dos três: sem ele, o bloco
            // cujo rótulo cabe em uma linha fica mais baixo que os
            // vizinhos, e a fileira parece desalinhada.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: StatTile(
                      icon: Icons.check_circle_outline_rounded,
                      label: 'Amostras\naproveitáveis',
                      value: '${(session.validSampleRatio * 100).round()}%',
                      tint: usable ? Palette.green : Palette.coral,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      icon: Icons.speed_rounded,
                      label: 'Taxa de\namostragem',
                      value: '${session.samplingRateHz.toStringAsFixed(0)} Hz',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      icon: Icons.timer_outlined,
                      label: 'Duração',
                      value: '${session.durationSeconds.toStringAsFixed(0)} s',
                    ),
                  ),
                ],
              ),
            ),
            if (!usable) ...[
              const SizedBox(height: 14),
              const NoticeCard(
                icon: Icons.replay_rounded,
                tint: Color(0xFFA32317),
                background: Palette.coralSoft,
                text:
                    'A captura ficou abaixo do mínimo utilizável. Vale repetir a '
                    'atividade antes de enviar.',
              ),
            ],
            const SizedBox(height: 18),
            if (onShare != null) ...[
              PrimaryButton(
                label: 'Enviar ao professor',
                icon: Icons.ios_share_rounded,
                onPressed: onShare,
              ),
              const SizedBox(height: 10),
            ],
            SecondaryButton(
              label: doneLabel,
              onPressed: onDone ??
                  () =>
                      Navigator.of(context).popUntil((route) => route.isFirst),
            ),
          ],
        ),
      );
}

/// Peças visuais reaproveitadas pelas telas.
///
/// Nenhuma delas entra na área de leitura: ver a nota em `theme.dart` sobre
/// por que o estímulo fica sem decoração.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// O olho da marca, desenhado em código.
///
/// Em código, e não como imagem, por dois motivos: acompanha a cor e o tamanho
/// sem precisar de variantes exportadas, e pisca — o que dá ao aplicativo a
/// única animação de personagem que ele tem, sem custo de asset.
class EyeMascot extends StatefulWidget {
  final double size;

  /// Se o olho pisca sozinho.
  ///
  /// Desligado nas telas em que a criança precisa estar olhando para outra
  /// coisa: movimento na periferia puxa o olhar, e na calibração isso seria
  /// medido como erro.
  final bool blinking;

  final Color iris;

  const EyeMascot({
    super.key,
    this.size = 96,
    this.blinking = true,
    this.iris = Palette.brand,
  });

  @override
  State<EyeMascot> createState() => _EyeMascotState();
}

class _EyeMascotState extends State<EyeMascot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.blinking) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // A piscada ocupa os últimos 8% do ciclo: rápida e espaçada, como uma
          // piscada de verdade.
          final phase = _controller.value;
          final openness = phase > 0.92
              ? (1 - math.sin((phase - 0.92) / 0.08 * math.pi)).clamp(0.0, 1.0)
              : 1.0;

          return CustomPaint(
            size: Size(widget.size, widget.size * 0.66),
            painter: _EyePainter(openness: openness, iris: widget.iris),
          );
        },
      );
}

class _EyePainter extends CustomPainter {
  final double openness;
  final Color iris;

  _EyePainter({required this.openness, required this.iris});

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final halfHeight = size.height / 2 * openness.clamp(0.04, 1.0);

    // A amêndoa do olho: dois arcos espelhados.
    final almond = Path()
      ..moveTo(0, centre.dy)
      ..quadraticBezierTo(
          centre.dx, centre.dy - halfHeight * 2, size.width, centre.dy)
      ..quadraticBezierTo(centre.dx, centre.dy + halfHeight * 2, 0, centre.dy)
      ..close();

    canvas.drawPath(almond, Paint()..color = Palette.surface);
    canvas.save();
    canvas.clipPath(almond);

    final irisRadius = size.height * 0.36;
    canvas.drawCircle(centre, irisRadius, Paint()..color = iris);
    canvas.drawCircle(centre, irisRadius * 0.45, Paint()..color = Palette.ink);
    // O brilho, que é o que faz o olho parecer vivo e não um alvo.
    canvas.drawCircle(
      centre.translate(-irisRadius * 0.3, -irisRadius * 0.34),
      irisRadius * 0.22,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );

    canvas.restore();
    canvas.drawPath(
      almond,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.height * 0.085
        ..strokeJoin = StrokeJoin.round
        ..color = Palette.ink,
    );
  }

  @override
  bool shouldRepaint(_EyePainter old) =>
      old.openness != openness || old.iris != iris;
}

/// Cartão branco com canto arredondado e sombra difusa.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color colour;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.colour = Palette.surface,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(Shapes.cardRadius),
          boxShadow: Shapes.cardShadow,
        ),
        child: child,
      );
}

/// Aviso em tom suave, com ícone.
///
/// Substitui as caixas de alerta berrantes: o conteúdo é sério, mas a tela é
/// de uma criança, e um bloco vermelho de quatro linhas assusta sem informar
/// melhor.
class NoticeCard extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final Color background;
  final String text;

  const NoticeCard({
    super.key,
    required this.icon,
    required this.tint,
    required this.background,
    required this.text,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(Shapes.chipRadius + 4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: AppType.body.copyWith(fontSize: 14.5, color: tint),
              ),
            ),
          ],
        ),
      );
}

/// Botão principal, de largura total.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color colour;
  final IconData? icon;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.colour = Palette.brand,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Shapes.buttonRadius),
          boxShadow: onPressed == null ? const [] : Shapes.buttonShadow,
        ),
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: colour,
            foregroundColor: Colors.white,
            // Alvo de toque generoso: a mão é de uma criança, e a tela some
            // debaixo do dedo num botão fino.
            minimumSize: const Size.fromHeight(60),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Shapes.buttonRadius),
            ),
            textStyle: AppType.button,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 22),
                const SizedBox(width: 10),
              ],
              Text(label),
            ],
          ),
        ),
      );
}

/// Botão secundário, de contorno.
class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const SecondaryButton({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: Palette.brand,
          minimumSize: const Size.fromHeight(56),
          side: const BorderSide(color: Palette.line, width: 1.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Shapes.buttonRadius),
          ),
          textStyle: AppType.button.copyWith(fontSize: 16),
        ),
        child: Text(label),
      );
}

/// Passo numerado, usado nas listas de "o que vai acontecer".
class NumberedStep extends StatelessWidget {
  final int number;
  final String title;
  final String detail;

  const NumberedStep({
    super.key,
    required this.number,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Palette.brandSoft,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                '$number',
                style: AppType.body.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Palette.brand,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppType.body.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: AppType.body.copyWith(
                      fontSize: 14,
                      color: Palette.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// Indicador de progresso em pontos.
///
/// Mostra quanto falta sem pedir que a criança leia um número.
class StepDots extends StatelessWidget {
  final int count;
  final int current;
  final Color active;
  final Color inactive;

  const StepDots({
    super.key,
    required this.count,
    required this.current,
    this.active = Palette.amber,
    this.inactive = Colors.white24,
  });

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var index = 0; index < count; index++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              margin: const EdgeInsets.symmetric(horizontal: 5),
              width: index == current ? 26 : 9,
              height: 9,
              decoration: BoxDecoration(
                color: index <= current ? active : inactive,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
        ],
      );
}

/// Número com rótulo, para os indicadores de qualidade.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color tint;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tint = Palette.brand,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: Palette.background,
          borderRadius: BorderRadius.circular(Shapes.chipRadius + 2),
        ),
        child: Column(
          // Centra o conteúdo na altura que o IntrinsicHeight da fileira
          // impõe: sem isto, um bloco de rótulo curto fica com o texto colado
          // no topo enquanto os vizinhos ocupam duas linhas.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: tint),
            const SizedBox(height: 7),
            Text(value, style: AppType.stat.copyWith(fontSize: 18)),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: AppType.body
                  .copyWith(fontSize: 11.5, color: Palette.inkMuted),
            ),
          ],
        ),
      );
}

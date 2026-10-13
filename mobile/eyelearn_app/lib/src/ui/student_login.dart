/// Login do aluno: escolher o próprio nome e digitar o PIN.
///
/// A lista vem do painel do professor (ver `Roster` no núcleo). O PIN é
/// conferido aqui mesmo, offline.
///
/// Duas decisões de tela para uma criança de nove anos: os nomes são cartões
/// grandes, com a inicial num círculo colorido -- quem ainda lê devagar acha o
/// próprio nome pela inicial e pela cor --, e o teclado é numérico, próprio,
/// com teclas de 72 pontos, em vez do teclado do sistema, que cobre metade da
/// tela e muda de aparelho para aparelho.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../activity/passages.dart';
import 'theme.dart';
import 'widgets.dart';

/// Cores dos círculos de inicial, em rodízio. Só as da marca: nenhum verde ou
/// vermelho que soe como "certo" ou "errado" ao lado de um nome.
const _avatarColours = [
  (Palette.brand, Colors.white),
  (Palette.amber, Palette.ink),
  (Palette.brandDeep, Colors.white),
  (Color(0xFFB9B1FF), Palette.ink),
];

/// Grade com os nomes da turma.
class StudentPicker extends StatelessWidget {
  final Roster roster;
  final ValueChanged<RosterStudent> onSelected;

  const StudentPicker({
    super.key,
    required this.roster,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth > 520 ? 3 : 2;
          const spacing = 10.0;
          final width =
              (constraints.maxWidth - spacing * (columns - 1)) / columns;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final (index, student) in roster.students.indexed)
                SizedBox(
                  width: width,
                  child: _NameTile(
                    student: student,
                    colours: _avatarColours[index % _avatarColours.length],
                    onTap: () => onSelected(student),
                  ),
                ),
            ],
          );
        },
      );
}

class _NameTile extends StatelessWidget {
  final RosterStudent student;
  final (Color, Color) colours;
  final VoidCallback onTap;

  const _NameTile({
    required this.student,
    required this.colours,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: Palette.background,
        borderRadius: BorderRadius.circular(Shapes.chipRadius + 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Shapes.chipRadius + 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                InitialAvatar(name: student.displayName, colours: colours),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    student.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class InitialAvatar extends StatelessWidget {
  final String name;
  final (Color, Color) colours;
  final double size;

  const InitialAvatar({
    super.key,
    required this.name,
    this.colours = (Palette.brand, Colors.white),
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: colours.$1, shape: BoxShape.circle),
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: AppType.title.copyWith(
            color: colours.$2,
            fontSize: size * 0.45,
          ),
        ),
      );
}

/// Confere o PIN fora da linha da interface.
///
/// São vinte mil rodadas de HMAC: rodando na linha da interface, o teclado
/// congelaria por um instante a cada tentativa, e a criança tocaria de novo
/// achando que não pegou.
Future<bool> _checkInBackground(RosterStudent student, String pin) =>
    compute(_verify, (pin, student.pinHash));

bool _verify((String, String) input) => verifyPin(input.$1, input.$2);

/// Tela do PIN.
///
/// Chama [onAccepted] quando o PIN confere. Os erros são ditos com calma e sem
/// vermelho: errar o PIN não é falha da criança, e a tela que vem a seguir é a
/// de leitura, onde ela precisa estar tranquila.
class PinScreen extends StatefulWidget {
  final RosterStudent student;
  final PinAttemptLimiter limiter;
  final VoidCallback onAccepted;

  /// Troca a conferência em segundo plano, para teste.
  final Future<bool> Function(RosterStudent, String) check;

  const PinScreen({
    super.key,
    required this.student,
    required this.limiter,
    required this.onAccepted,
    this.check = _checkInBackground,
  });

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _typed = '';
  String? _message;
  bool _checking = false;

  bool get _locked => widget.limiter.isLocked(widget.student.code);

  @override
  void initState() {
    super.initState();
    final locked = widget.limiter.lockedResult(widget.student.code);
    if (locked != null) _message = _lockedMessage(locked.lockout);
  }

  void _press(String digit) {
    if (_checking || _locked || _typed.length >= pinLength) return;
    setState(() {
      _typed += digit;
      _message = null;
    });
    if (_typed.length == pinLength) _submit();
  }

  void _erase() {
    if (_checking || _typed.isEmpty) return;
    setState(() => _typed = _typed.substring(0, _typed.length - 1));
  }

  Future<void> _submit() async {
    final code = widget.student.code;
    final locked = widget.limiter.lockedResult(code);
    if (locked != null) {
      setState(() {
        _typed = '';
        _message = _lockedMessage(locked.lockout);
      });
      return;
    }

    setState(() => _checking = true);
    final accepted = await widget.check(widget.student, _typed);
    if (!mounted) return;
    final result = widget.limiter.register(code, accepted: accepted);

    setState(() {
      _checking = false;
      _typed = '';
      _message = switch (result.outcome) {
        PinOutcome.accepted => null,
        PinOutcome.rejected => 'Esse não é o seu PIN. Tente de novo.',
        PinOutcome.locked => _lockedMessage(result.lockout),
      };
    });
    if (result.outcome == PinOutcome.accepted) widget.onAccepted();
  }

  String _lockedMessage(Duration lockout) {
    final minutes = (lockout.inSeconds / 60).ceil();
    return 'Vamos esperar $minutes ${minutes == 1 ? 'minuto' : 'minutos'}. '
        'Se esqueceu o PIN, chame o professor.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            tooltip: 'Não sou eu',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  children: [
                    InitialAvatar(name: widget.student.displayName, size: 72),
                    const SizedBox(height: 12),
                    Text(
                      'Oi, ${widget.student.displayName.split(' ').first}!',
                      style: AppType.display.copyWith(fontSize: 26),
                    ),
                    const SizedBox(height: 4),
                    const Text('Digite o seu PIN', style: AppType.subtitle),
                    const SizedBox(height: 22),
                    _PinDots(filled: _typed.length, busy: _checking),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 44,
                      child: _message == null
                          ? null
                          : Text(
                              _message!,
                              textAlign: TextAlign.center,
                              style: AppType.body.copyWith(
                                color: Palette.brandDeep,
                                fontSize: 15,
                              ),
                            ),
                    ),
                    const Spacer(),
                    _Keypad(
                      enabled: !_checking && !_locked,
                      onDigit: _press,
                      onErase: _erase,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _PinDots extends StatelessWidget {
  final int filled;
  final bool busy;

  const _PinDots({required this.filled, required this.busy});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < pinLength; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              margin: const EdgeInsets.symmetric(horizontal: 9),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: busy
                    ? Palette.amber
                    : i < filled
                        ? Palette.brand
                        : Colors.transparent,
                border: Border.all(
                  color: busy ? Palette.amber : Palette.brand,
                  width: 2.2,
                ),
              ),
            ),
        ],
      );
}

class _Keypad extends StatelessWidget {
  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback onErase;

  const _Keypad({
    required this.enabled,
    required this.onDigit,
    required this.onErase,
  });

  @override
  Widget build(BuildContext context) {
    Widget key(String digit) => _Key(
          label: digit,
          onTap: enabled ? () => onDigit(digit) : null,
        );
    Widget row(List<Widget> keys) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: keys,
          ),
        );
    return Column(
      children: [
        row([key('1'), key('2'), key('3')]),
        row([key('4'), key('5'), key('6')]),
        row([key('7'), key('8'), key('9')]),
        row([
          const SizedBox(width: _Key.size, height: _Key.size),
          key('0'),
          _Key(
            icon: Icons.backspace_outlined,
            semanticLabel: 'Apagar',
            onTap: enabled ? onErase : null,
            plain: true,
          ),
        ]),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  static const size = 72.0;

  final String? label;
  final IconData? icon;
  final String? semanticLabel;
  final VoidCallback? onTap;
  final bool plain;

  const _Key({
    this.label,
    this.icon,
    this.semanticLabel,
    this.onTap,
    this.plain = false,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: semanticLabel ?? label,
        child: Material(
          color: plain ? Colors.transparent : Palette.surface,
          shape: const CircleBorder(),
          elevation: plain ? 0 : 1.5,
          shadowColor: Palette.brand.withValues(alpha: 0.25),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: label != null
                    ? Text(
                        label!,
                        style: AppType.display.copyWith(
                          fontSize: 28,
                          color: onTap == null ? Palette.inkMuted : Palette.ink,
                        ),
                      )
                    : Icon(icon, color: Palette.inkMuted, size: 26),
              ),
            ),
          ),
        ),
      );
}

/// O cartão da atividade na tela inicial.
///
/// Sem atividade lida, pede o QR. Com ela, mostra a tarefa e até quando a
/// entrada fica aberta -- a tarefa vem do professor, não é escolhida aqui.
class ActivityCard extends StatelessWidget {
  final String className;
  final ActivityTicket? ticket;
  final VoidCallback onScan;
  final VoidCallback? onChangeClass;

  const ActivityCard({
    super.key,
    required this.className,
    required this.ticket,
    required this.onScan,
    this.onChangeClass,
  });

  static String _clock(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final ticket = this.ticket;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(className.toUpperCase(), style: AppType.label),
              ),
              if (onChangeClass != null)
                TextButton(
                  onPressed: onChangeClass,
                  child: const Text('Trocar turma'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (ticket == null) ...[
            const Text('Leia o QR da atividade', style: AppType.title),
            const SizedBox(height: 6),
            Text(
              'O professor abre a atividade no painel e mostra o QR na tela. '
              'Só dá para entrar de dentro da sala.',
              style: AppType.body.copyWith(color: Palette.inkMuted),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Ler QR da atividade',
              icon: Icons.qr_code_scanner_rounded,
              onPressed: onScan,
            ),
          ] else ...[
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Palette.brandSoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.menu_book_rounded,
                    color: Palette.brand,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        passageById(ticket.task).title,
                        style: AppType.title,
                      ),
                      Text(
                        'Entrada aberta até ${_clock(ticket.expiresAt)}',
                        style: AppType.body.copyWith(
                          color: Palette.inkMuted,
                          fontSize: 14.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

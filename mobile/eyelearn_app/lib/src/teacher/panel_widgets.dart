/// Peças comuns às telas do painel do professor.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'teacher_controller.dart';

/// Nome das tarefas para o professor.
const taskLabels = {
  'syllables': 'Sílabas',
  'text': 'Texto (uma história)',
  'pseudotext': 'Palavras inventadas',
};

String taskLabel(String task) => taskLabels[task] ?? task;

String sentence(String text) => text.isEmpty
    ? text
    : '${text[0].toUpperCase()}${text.substring(1)}'
        '${text.endsWith('.') ? '' : '.'}';

String plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

String _two(int n) => n.toString().padLeft(2, '0');

/// `24/10/2026`.
String formatDate(DateTime day) =>
    '${_two(day.day)}/${_two(day.month)}/${day.year}';

/// `24/10`, sem o ano.
String formatShortDate(DateTime day) => '${_two(day.day)}/${_two(day.month)}';

String formatDateTime(DateTime t) {
  final local = t.toLocal();
  return '${formatDate(local)} ${_two(local.hour)}:${_two(local.minute)}';
}

/// Conteúdo centralizado e com largura máxima: o painel abre num computador,
/// e uma linha de 1900 pixels não se lê.
class PanelBody extends StatelessWidget {
  final List<Widget> children;
  final bool narrow;

  const PanelBody({super.key, required this.children, this.narrow = false});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: narrow ? 520 : 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      );
}

Widget panelField(
  TextEditingController controller,
  String label,
  IconData icon, {
  bool obscure = false,
  bool autofocus = false,
  int maxLines = 1,
  String? hint,
  ValueChanged<String>? onSubmitted,
}) =>
    TextField(
      controller: controller,
      obscureText: obscure,
      autofocus: autofocus,
      maxLines: obscure ? 1 : maxLines,
      minLines: 1,
      autocorrect: !obscure,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: Palette.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Shapes.chipRadius + 2),
          borderSide: BorderSide.none,
        ),
      ),
    );

/// Cartão com linhas de lista. O [Material] transparente é onde as linhas
/// pintam o realce do toque; sem ele, o fundo do cartão o esconderia.
class PanelList extends StatelessWidget {
  final Widget child;
  const PanelList({super.key, required this.child});

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Material(type: MaterialType.transparency, child: child),
      );
}

class ErrorNotice extends StatelessWidget {
  final String text;
  const ErrorNotice(this.text, {super.key});

  @override
  Widget build(BuildContext context) => NoticeCard(
        icon: Icons.error_outline_rounded,
        tint: const Color(0xFFA32317),
        background: Palette.coralSoft,
        text: text,
      );
}

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));

/// Roda a ação e mostra o erro de regra (PIN, nome, prazo) em vez de quebrar.
Future<void> guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } on VaultError catch (error) {
    if (context.mounted) showMessage(context, sentence(error.message));
  } on WrongPassword {
    if (context.mounted) showMessage(context, 'A senha não confere.');
  }
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 420, child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.coral),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// Lembrete da cópia de segurança.
class BackupReminder extends StatelessWidget {
  final TeacherController controller;
  const BackupReminder({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final last = controller.lastBackup;
    return AppCard(
      colour: Palette.amberSoft,
      child: Row(
        children: [
          const Icon(Icons.save_alt_rounded, color: Color(0xFF8A5300)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              last == null
                  ? 'Os dados estão só neste navegador. Baixe uma cópia de '
                      'segurança e guarde-a fora do computador (pen drive, '
                      'e-mail para você mesmo): ela vai cifrada com a sua senha.'
                  : 'A última cópia de segurança é de ${formatDate(last)}, e '
                      'houve mudanças depois. Vale baixar uma nova.',
              style: AppType.body.copyWith(color: const Color(0xFF8A5300)),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: () => guard(context, controller.downloadBackup),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Baixar'),
          ),
        ],
      ),
    );
  }
}

/// Entrada do painel do professor e a lista de turmas.
///
/// O painel roda inteiro no navegador do professor. Os dados ficam num cofre
/// cifrado com a senha dele, no próprio navegador; a cópia de segurança é o
/// mesmo cofre, num arquivo. Não há conta em servidor, e não há como
/// recuperar a senha: as telas dizem isso antes de criar o cofre.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'class_screen.dart';
import 'panel_widgets.dart';
import 'teacher_controller.dart';

/// Decide entre criar o painel, restaurar uma cópia e entrar.
class TeacherGate extends StatefulWidget {
  final TeacherEnvironment environment;

  const TeacherGate({super.key, required this.environment});

  @override
  State<TeacherGate> createState() => _TeacherGateState();
}

enum _Mode { loading, unlock, welcome, create, restore }

class _TeacherGateState extends State<TeacherGate> {
  _Mode _mode = _Mode.loading;
  VaultEnvelope? _stored;
  String? _storedText;

  /// A cópia de segurança escolhida, à espera da senha.
  String? _backupText;
  VaultEnvelope? _backup;

  final _name = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  TeacherEnvironment get env => widget.environment;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final text = await env.storage.load();
    VaultEnvelope? envelope;
    if (text != null) {
      try {
        envelope = VaultEnvelope.parse(text);
      } on FormatException {
        envelope = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _storedText = envelope == null ? null : text;
      _stored = envelope;
      _mode = envelope == null ? _Mode.welcome : _Mode.unlock;
    });
  }

  void _go(_Mode mode) => setState(() {
        _mode = mode;
        _error = null;
        _password.clear();
      });

  Future<void> _run(Future<TeacherController> Function() open) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = await open();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => TeacherHomeScreen(controller: controller),
      ));
    } on WrongPassword {
      setState(() => _error = 'A senha não confere.');
    } on VaultError catch (error) {
      setState(() => _error = sentence(error.message));
    } on FormatException catch (error) {
      setState(() => _error = sentence(error.message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Só nome e senha: o usuário sai do nome, e é só o rótulo do cofre neste
  /// navegador e no nome do arquivo da cópia de segurança.
  void _create() => _run(() => TeacherController.create(
        env,
        username: usernameFrom(_name.text),
        name: _name.text,
        password: _password.text,
      ));

  void _unlock() => _run(() => TeacherController.unlock(
        env,
        _storedText!,
        _password.text,
      ));

  void _restore() => _run(() => TeacherController.unlock(
        env,
        _backupText!,
        _password.text,
        restoring: true,
      ));

  Future<void> _pickBackup() async {
    final pick = env.platform.pickFiles;
    if (pick == null) return;
    final files = await pick();
    if (files.isEmpty) return;
    try {
      final envelope = VaultEnvelope.parse(files.first.text);
      setState(() {
        _backupText = files.first.text;
        _backup = envelope;
        _error = null;
        _mode = _Mode.restore;
      });
    } on FormatException catch (error) {
      setState(() => _error = sentence(error.message));
    }
  }

  Future<void> _forget() async {
    final ok = await confirmAction(
      context,
      title: 'Apagar o painel deste navegador?',
      body: 'As turmas, os alunos e as sessões guardados aqui serão apagados. '
          'Só é possível recuperá-los com uma cópia de segurança e a senha.',
      action: 'Apagar',
    );
    if (!ok) return;
    await env.storage.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Painel do professor')),
        body: PanelBody(
          narrow: true,
          children: [
            if (_mode == _Mode.loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              _header(),
              const SizedBox(height: 18),
              AppCard(
                child: Material(
                  type: MaterialType.transparency,
                  child: _form(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                ErrorNotice(_error!),
              ],
              const SizedBox(height: 16),
              ..._footer(),
            ],
          ],
        ),
      );

  Widget _header() {
    final (title, text) = switch (_mode) {
      _Mode.unlock => (
          'Olá de novo',
          'Digite a senha do painel de ${_stored!.username}.'
        ),
      _Mode.create => (
          'Criar o painel',
          'Os dados ficam só neste navegador, cifrados com a sua senha.'
        ),
      _Mode.restore => (
          'Restaurar a cópia de segurança',
          'Cópia de ${_backup!.username}. Digite a senha do painel.'
        ),
      _ => (
          'Leitura da turma, em casa',
          'Cadastre a turma, crie as atividades de leitura e mande o link às '
              'famílias. Depois, importe as sessões que elas devolverem.'
        ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppType.display.copyWith(fontSize: 26)),
        const SizedBox(height: 6),
        Text(text, style: AppType.body.copyWith(color: Palette.inkMuted)),
      ],
    );
  }

  Widget _form() => switch (_mode) {
        _Mode.welcome => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PrimaryButton(
                label: 'Criar o painel',
                icon: Icons.add_rounded,
                onPressed: () => _go(_Mode.create),
              ),
              const SizedBox(height: 12),
              SecondaryButton(
                label: 'Restaurar uma cópia de segurança',
                onPressed: env.platform.pickFiles == null ? null : _pickBackup,
              ),
            ],
          ),
        _Mode.create => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              panelField(_name, 'Seu nome', Icons.person_outline_rounded,
                  autofocus: true),
              const SizedBox(height: 12),
              panelField(_password, 'Senha (8 caracteres ou mais)',
                  Icons.lock_outline_rounded,
                  obscure: true, onSubmitted: (_) => _create()),
              const SizedBox(height: 10),
              Text(
                'Anote a senha: não há como recuperá-la, e sem ela os dados '
                'dos alunos ficam ilegíveis.',
                style: AppType.body
                    .copyWith(fontSize: 14, color: const Color(0xFF8A5300)),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: _busy ? 'Criando…' : 'Criar',
                onPressed: _busy ? null : _create,
              ),
            ],
          ),
        _Mode.unlock || _Mode.restore => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              panelField(_password, 'Senha', Icons.lock_outline_rounded,
                  obscure: true,
                  autofocus: true,
                  onSubmitted: (_) =>
                      _mode == _Mode.unlock ? _unlock() : _restore()),
              const SizedBox(height: 16),
              PrimaryButton(
                label: _busy ? 'Abrindo…' : 'Entrar',
                icon: Icons.login_rounded,
                onPressed:
                    _busy ? null : (_mode == _Mode.unlock ? _unlock : _restore),
              ),
            ],
          ),
        _Mode.loading => const SizedBox.shrink(),
      };

  List<Widget> _footer() => switch (_mode) {
        _Mode.unlock => [
            if (env.platform.pickFiles != null)
              TextButton(
                onPressed: _pickBackup,
                child: const Text('Abrir uma cópia de segurança'),
              ),
            TextButton(
              onPressed: _forget,
              child: const Text('Apagar o painel deste navegador'),
            ),
          ],
        _Mode.create || _Mode.restore => [
            TextButton(
              onPressed: () =>
                  _go(_stored == null ? _Mode.welcome : _Mode.unlock),
              child: const Text('Voltar'),
            ),
          ],
        _ => [
            const NoticeCard(
              icon: Icons.lock_outline_rounded,
              tint: Color(0xFF3A2FB0),
              background: Palette.brandSoft,
              text: 'Nenhum dado de aluno vai para servidor. O nome completo '
                  'fica só neste navegador; as famílias recebem o primeiro '
                  'nome e a inicial, dentro de um link cifrado.',
            ),
          ],
      };
}

/// Usuário a partir do nome: minúsculas, sem acento nem espaço.
String usernameFrom(String name) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final buffer = StringBuffer();
  for (final ch in name.trim().toLowerCase().split('')) {
    final i = from.indexOf(ch);
    final c = i >= 0 ? to[i] : ch;
    if (RegExp('[a-z0-9]').hasMatch(c)) {
      buffer.write(c);
    } else if (buffer.isNotEmpty && !buffer.toString().endsWith('-')) {
      buffer.write('-');
    }
  }
  final slug = buffer.toString().replaceAll(RegExp(r'-+$'), '');
  return slug.isEmpty ? 'professor' : slug;
}

/// As turmas do professor.
class TeacherHomeScreen extends StatelessWidget {
  final TeacherController controller;

  const TeacherHomeScreen({super.key, required this.controller});

  Future<void> _newClass(BuildContext context) async {
    final name = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nova turma'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              panelField(
                  name, 'Nome da turma (ex.: 5º A)', Icons.groups_outlined,
                  autofocus: true,
                  onSubmitted: (_) => Navigator.pop(context, true)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    if (created != true || !context.mounted) return;
    await guard(context, () async {
      final target = await controller.change((v) => v.createClass(name.text));
      if (context.mounted) _open(context, target);
    });
  }

  void _open(BuildContext context, VaultClass target) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ClassScreen(controller: controller, target: target),
      ));

  Future<void> _changePassword(BuildContext context) async {
    final current = TextEditingController();
    final fresh = TextEditingController();
    final again = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trocar a senha'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              panelField(current, 'Senha atual', Icons.lock_outline_rounded,
                  obscure: true),
              const SizedBox(height: 12),
              panelField(fresh, 'Nova senha', Icons.lock_reset_rounded,
                  obscure: true),
              const SizedBox(height: 12),
              panelField(again, 'Repita a nova senha', Icons.lock_reset_rounded,
                  obscure: true),
              const SizedBox(height: 12),
              const Text('Cópias de segurança antigas continuam abrindo só com '
                  'a senha antiga. Baixe uma cópia nova depois de trocar.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Trocar'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (fresh.text != again.text) {
      showMessage(context, 'As duas senhas novas não são iguais.');
      return;
    }
    await guard(context, () async {
      await controller.changePassword(current.text, fresh.text);
      if (context.mounted) showMessage(context, 'Senha trocada.');
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final vault = controller.vault;
          return Scaffold(
            appBar: AppBar(
              title: Text('Turmas de ${vault.teacherName}'),
              actions: [
                IconButton(
                  tooltip: 'Baixar cópia de segurança',
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () => guard(context, controller.downloadBackup),
                ),
                PopupMenuButton<String>(
                  onSelected: (choice) {
                    if (choice == 'senha') _changePassword(context);
                    if (choice == 'sair') {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              TeacherGate(environment: controller.environment),
                        ),
                      );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'senha', child: Text('Trocar a senha')),
                    PopupMenuItem(value: 'sair', child: Text('Sair')),
                  ],
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _newClass(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nova turma'),
            ),
            body: PanelBody(
              children: [
                if (controller.backupIsStale) ...[
                  BackupReminder(controller: controller),
                  const SizedBox(height: 16),
                ],
                if (vault.classes.isEmpty)
                  const AppCard(
                    child: Text(
                      'Nenhuma turma ainda. Comece por "Nova turma".',
                      style: AppType.subtitle,
                    ),
                  ),
                for (final target in vault.sortedClasses) ...[
                  _ClassCard(
                    target: target,
                    now: controller.now,
                    onTap: () => _open(context, target),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 72),
              ],
            ),
          );
        },
      );
}

class _ClassCard extends StatelessWidget {
  final VaultClass target;
  final DateTime now;
  final VoidCallback onTap;

  const _ClassCard({
    required this.target,
    required this.now,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final open = target.activities.where((a) => !a.due.isBefore(now)).length;
    final details = [
      if (target.school != null) target.school!,
      if (target.grade != null) target.grade!,
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Shapes.cardRadius),
        onTap: onTap,
        child: AppCard(
          child: Row(
            children: [
              const CircleAvatar(
                radius: 24,
                backgroundColor: Palette.brandSoft,
                child: Icon(Icons.groups_rounded, color: Palette.brand),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(target.name, style: AppType.title),
                    if (details.isNotEmpty)
                      Text(details,
                          style:
                              AppType.body.copyWith(color: Palette.inkMuted)),
                    const SizedBox(height: 4),
                    Text(
                      '${plural(target.students.length, 'aluno', 'alunos')} · '
                      '${plural(open, 'atividade aberta', 'atividades abertas')}'
                      ' · ${plural(target.sessionPayloads.length, 'sessão', 'sessões')}',
                      style: AppType.body
                          .copyWith(fontSize: 14, color: Palette.inkMuted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Palette.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

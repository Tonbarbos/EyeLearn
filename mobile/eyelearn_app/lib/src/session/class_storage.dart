/// A turma guardada no aparelho, e o que cada aluno já fez.
///
/// Guarda o pacote já aberto (alunos, atividades), o código da turma e, por
/// aluno, as atividades feitas neste aparelho. Com o código guardado, um link
/// novo da mesma turma -- mandado quando o professor cria atividade -- abre
/// sem pedir o código de novo.
///
/// No navegador vai para o armazenamento do site, no Android para as
/// preferências do aplicativo; nos dois casos, só este aplicativo lê. O
/// Safari pode apagar o armazenamento de um site que fica semanas sem uso: aí
/// basta abrir o link e digitar o código outra vez.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ClassStorage {
  /// O pacote aberto (o JSON da turma) e o código, ou `null` se não houver.
  Future<({String packageJson, String code})?> load();

  Future<void> save({required String packageJson, required String code});

  Future<void> clear();

  /// Códigos das atividades que o aluno já fez neste aparelho.
  Future<Set<String>> doneFor(String studentCode);

  Future<void> markDone(String studentCode, String activityCode);
}

class PrefsClassStorage implements ClassStorage {
  static const _packageKey = 'eyelearn.turma';
  static const _codeKey = 'eyelearn.codigo';
  static const _doneKey = 'eyelearn.feitas';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<({String packageJson, String code})?> load() async {
    final prefs = await _prefs;
    final package = prefs.getString(_packageKey);
    final code = prefs.getString(_codeKey);
    if (package == null || code == null) return null;
    return (packageJson: package, code: code);
  }

  @override
  Future<void> save({required String packageJson, required String code}) async {
    final prefs = await _prefs;
    await prefs.setString(_packageKey, packageJson);
    await prefs.setString(_codeKey, code);
  }

  @override
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(_packageKey);
    await prefs.remove(_codeKey);
    await prefs.remove(_doneKey);
  }

  Future<Map<String, List<String>>> _done() async {
    final raw = (await _prefs).getString(_doneKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>)
        .map((key, value) => MapEntry(key, (value as List).cast<String>()));
  }

  @override
  Future<Set<String>> doneFor(String studentCode) async =>
      {...?(await _done())[studentCode]};

  @override
  Future<void> markDone(String studentCode, String activityCode) async {
    final done = await _done();
    done.putIfAbsent(studentCode, () => []);
    if (!done[studentCode]!.contains(activityCode)) {
      done[studentCode]!.add(activityCode);
    }
    await (await _prefs).setString(_doneKey, jsonEncode(done));
  }
}

/// Em memória: pré-visualização e testes.
class MemoryClassStorage implements ClassStorage {
  ({String packageJson, String code})? _saved;
  final _done = <String, Set<String>>{};

  @override
  Future<({String packageJson, String code})?> load() async => _saved;

  @override
  Future<void> save(
          {required String packageJson, required String code}) async =>
      _saved = (packageJson: packageJson, code: code);

  @override
  Future<void> clear() async {
    _saved = null;
    _done.clear();
  }

  @override
  Future<Set<String>> doneFor(String studentCode) async =>
      {...?_done[studentCode]};

  @override
  Future<void> markDone(String studentCode, String activityCode) async =>
      _done.putIfAbsent(studentCode, () => {}).add(activityCode);
}

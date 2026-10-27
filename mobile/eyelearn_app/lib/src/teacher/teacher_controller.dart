/// O cofre aberto, e onde ele é gravado.
///
/// Toda mudança passa por [TeacherController.change]: aplica, cifra de novo
/// com a chave já derivada (nonce novo) e grava. Não há "salvar" para o
/// professor esquecer; o que ele precisa lembrar é a cópia de segurança, e o
/// painel lembra por ele ([TeacherController.backupIsStale]).
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../delivery/inbox.dart';
import 'teacher_platform.dart';

/// Onde o cofre cifrado fica no aparelho.
abstract interface class VaultStorage {
  Future<String?> load();
  Future<void> save(String envelope);
  Future<void> clear();

  /// Quando foi baixada a última cópia de segurança.
  Future<DateTime?> lastBackup();
  Future<void> markBackup(DateTime when);
}

/// No navegador, o armazenamento do site; no Android, as preferências.
class PrefsVaultStorage implements VaultStorage {
  static const _vaultKey = 'eyelearn.painel.cofre';
  static const _backupKey = 'eyelearn.painel.copia';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<String?> load() async => (await _prefs).getString(_vaultKey);

  @override
  Future<void> save(String envelope) async =>
      (await _prefs).setString(_vaultKey, envelope);

  @override
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(_vaultKey);
    await prefs.remove(_backupKey);
  }

  @override
  Future<DateTime?> lastBackup() async {
    final raw = (await _prefs).getString(_backupKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  @override
  Future<void> markBackup(DateTime when) async =>
      (await _prefs).setString(_backupKey, when.toIso8601String());
}

/// Para os testes e a pré-visualização.
class MemoryVaultStorage implements VaultStorage {
  String? envelope;
  DateTime? backup;

  MemoryVaultStorage({this.envelope});

  @override
  Future<String?> load() async => envelope;

  @override
  Future<void> save(String value) async => envelope = value;

  @override
  Future<void> clear() async {
    envelope = null;
    backup = null;
  }

  @override
  Future<DateTime?> lastBackup() async => backup;

  @override
  Future<void> markBackup(DateTime when) async => backup = when;
}

/// O que o painel recebe de fora.
class TeacherEnvironment {
  final TeacherPlatform platform;
  final VaultStorage storage;
  final DateTime Function() clock;

  /// Iterações da chave para cofres novos. Os testes baixam; o valor de
  /// verdade é [vaultKdfIterations].
  final int kdfIterations;

  /// Onde o link da turma abre.
  final String appUrl;

  /// A caixa de entrega de onde as sessões chegam sozinhas; `null` sem
  /// projeto configurado, e aí só a importação de arquivos.
  final Inbox? inbox;

  const TeacherEnvironment({
    required this.platform,
    required this.storage,
    required this.clock,
    this.kdfIterations = vaultKdfIterations,
    this.appUrl = defaultAppUrl,
    this.inbox,
  });
}

class TeacherController extends ChangeNotifier {
  final TeacherEnvironment environment;
  final TeacherVault vault;
  SealKey _key;
  int _iterations;
  DateTime? _lastBackup;
  bool _changedSinceBackup;

  TeacherController._(
    this.environment,
    this.vault,
    this._key,
    this._iterations,
    this._lastBackup, {
    bool changedSinceBackup = false,
  }) : _changedSinceBackup = changedSinceBackup;

  VaultStorage get _storage => environment.storage;
  DateTime get now => environment.clock();

  DateTime? get lastBackup => _lastBackup;

  /// Sobe a cada mudança no cofre. A tela do link usa para saber se o link
  /// que mostra ainda é o da turma como está.
  int revision = 0;

  /// Se vale lembrar o professor da cópia de segurança: nunca baixou, ou
  /// mudou alguma coisa depois da última e ela tem mais de uma semana.
  bool get backupIsStale =>
      _lastBackup == null ||
      (_changedSinceBackup &&
          now.difference(_lastBackup!) > const Duration(days: 7));

  /// Cria o cofre e grava.
  static Future<TeacherController> create(
    TeacherEnvironment environment, {
    required String username,
    required String name,
    required String password,
  }) async {
    checkPassword(password);
    final vault = TeacherVault.create(username, name);
    final iterations = environment.kdfIterations;
    final key = await environment.platform
        .deriveKey(password, iterations, randomBytes(sealSaltBytes));
    final controller =
        TeacherController._(environment, vault, key, iterations, null);
    await controller._save();
    await environment.platform.persistStorage();
    return controller;
  }

  /// Abre o cofre. Lança [WrongPassword] ou [FormatException].
  ///
  /// [restoring] é o texto de uma cópia de segurança: aberta com sucesso, ela
  /// passa a ser o cofre deste aparelho.
  static Future<TeacherController> unlock(
    TeacherEnvironment environment,
    String envelopeText,
    String password, {
    bool restoring = false,
  }) async {
    final envelope = VaultEnvelope.parse(envelopeText);
    final key = await environment.platform
        .deriveKey(password, envelope.iterations, envelope.salt);
    final vault = unlockVault(envelope, key);
    if (restoring) {
      await environment.storage.save(envelopeText);
      await environment.storage.markBackup(environment.clock());
      await environment.platform.persistStorage();
    }
    return TeacherController._(environment, vault, key, envelope.iterations,
        await environment.storage.lastBackup());
  }

  /// Aplica a mudança e grava o cofre. Se [action] lançar, nada é gravado e
  /// o erro sobe para a tela.
  Future<T> change<T>(T Function(TeacherVault vault) action) async {
    final result = action(vault);
    revision++;
    _changedSinceBackup = true;
    await _save();
    notifyListeners();
    return result;
  }

  Future<void> _save() async => _storage
      .save(lockVault(vault, _key, iterations: _iterations).toJsonString());

  /// Busca na caixa as entregas novas da turma e importa. `null` sem caixa.
  ///
  /// Lança [InboxError] sem conexão.
  Future<ImportReport?> fetchDeliveries(VaultClass target) async {
    final inbox = environment.inbox;
    if (inbox == null) return null;
    final deliveries =
        await inbox.fetch(target.uid, after: target.deliveryCursor);
    if (deliveries.isEmpty) return ImportReport();
    return change((v) => v.importDeliveries(target, deliveries));
  }

  /// Baixa a cópia de segurança: o mesmo cofre cifrado, num arquivo.
  Future<void> downloadBackup() async {
    final text = lockVault(vault, _key, iterations: _iterations).toJsonString();
    final day = now;
    final stamp = '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    await environment.platform
        .saveFile('eyelearn-painel-${vault.username}-$stamp.json', text);
    _lastBackup = now;
    _changedSinceBackup = false;
    await _storage.markBackup(_lastBackup!);
    notifyListeners();
  }

  /// Troca a senha. As cópias de segurança antigas continuam abrindo com a
  /// senha antiga.
  Future<void> changePassword(String current, String fresh) async {
    final check =
        await environment.platform.deriveKey(current, _iterations, _key.salt);
    if (!listEquals(check.key, _key.key)) throw const WrongPassword();
    checkPassword(fresh);
    _iterations = environment.kdfIterations;
    _key = await environment.platform
        .deriveKey(fresh, _iterations, randomBytes(sealSaltBytes));
    await _save();
    notifyListeners();
  }
}

/// A caixa de entrega: onde o aparelho deixa a sessão e o painel a busca.
///
/// É uma tabela do Supabase (`supabase/entregas.sql`), usada pela API REST
/// com a chave pública (anon) do projeto. A caixa só guarda blocos cifrados
/// para o professor (`delivery.dart`, no núcleo), com a turma e a hora de
/// chegada: nem o Supabase nem quem tiver a chave pública lê o conteúdo.
///
/// Sem projeto configurado ([InboxConfig.fromEnvironment] vazio), não há
/// caixa: a sessão sai como antes, por arquivo.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Uma entrega na caixa.
typedef Delivery = ({int id, String blob});

abstract interface class Inbox {
  /// Deixa um bloco na caixa da turma. Lança [InboxError] se não deu.
  Future<void> send(String classUid, String blob);

  /// As entregas da turma depois de [after], em ordem de chegada.
  Future<List<Delivery>> fetch(String classUid, {int after = 0});
}

class InboxError implements Exception {
  final String message;
  const InboxError(this.message);

  @override
  String toString() => 'InboxError: $message';
}

/// Endereço e chave pública do projeto Supabase.
///
/// Vêm da compilação (`--dart-define=SUPABASE_URL=... --dart-define=
/// SUPABASE_ANON_KEY=...`, que `.github/workflows/pages.yml` preenche com as
/// variáveis do repositório). A chave anon é pública por natureza: vai no
/// site de qualquer jeito, e o que ela pode fazer está limitado pelas regras
/// da tabela.
class InboxConfig {
  final String url;
  final String anonKey;

  const InboxConfig(this.url, this.anonKey);

  static const fromEnvironment = InboxConfig(
    String.fromEnvironment('SUPABASE_URL'),
    String.fromEnvironment('SUPABASE_ANON_KEY'),
  );

  bool get configured => url.isNotEmpty && anonKey.isNotEmpty;

  /// A caixa, ou `null` sem projeto configurado.
  Inbox? create({http.Client? client}) =>
      configured ? SupabaseInbox(this, client: client) : null;
}

class SupabaseInbox implements Inbox {
  final InboxConfig config;
  final http.Client _client;

  SupabaseInbox(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  Uri _table([Map<String, String>? query]) =>
      Uri.parse('${config.url.replaceAll(RegExp(r'/+$'), '')}/rest/v1/entregas')
          .replace(queryParameters: query);

  Map<String, String> get _headers => {
        'apikey': config.anonKey,
        'Authorization': 'Bearer ${config.anonKey}',
        'Content-Type': 'application/json',
      };

  @override
  Future<void> send(String classUid, String blob) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            _table(),
            headers: {..._headers, 'Prefer': 'return=minimal'},
            body: jsonEncode({'turma': classUid, 'blob': blob}),
          )
          .timeout(const Duration(seconds: 20));
    } on Exception catch (error) {
      throw InboxError('sem conexão ($error)');
    }
    if (response.statusCode >= 300) {
      throw InboxError('a caixa recusou (${response.statusCode})');
    }
  }

  @override
  Future<List<Delivery>> fetch(String classUid, {int after = 0}) async {
    final http.Response response;
    try {
      response = await _client
          .get(
            _table({
              'select': 'id,blob',
              'turma': 'eq.$classUid',
              'id': 'gt.$after',
              'order': 'id.asc',
              'limit': '500',
            }),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 20));
    } on Exception catch (error) {
      throw InboxError('sem conexão ($error)');
    }
    if (response.statusCode >= 300) {
      throw InboxError('a caixa recusou (${response.statusCode})');
    }
    return [
      for (final row
          in (jsonDecode(response.body) as List).cast<Map<String, dynamic>>())
        (id: (row['id'] as num).toInt(), blob: row['blob'] as String),
    ];
  }
}

/// Caixa na memória, para os testes e a pré-visualização.
class MemoryInbox implements Inbox {
  final rows = <({int id, String classUid, String blob})>[];
  bool offline = false;

  @override
  Future<void> send(String classUid, String blob) async {
    if (offline) throw const InboxError('sem conexão');
    rows.add((id: rows.length + 1, classUid: classUid, blob: blob));
  }

  @override
  Future<List<Delivery>> fetch(String classUid, {int after = 0}) async {
    if (offline) throw const InboxError('sem conexão');
    return [
      for (final r in rows)
        if (r.classUid == classUid && r.id > after) (id: r.id, blob: r.blob),
    ];
  }
}

/// Entregas que não saíram (sem internet na hora), para tentar de novo.
abstract interface class Outbox {
  Future<List<({String classUid, String blob})>> pending();
  Future<void> add(String classUid, String blob);
  Future<void> remove(String blob);
}

class PrefsOutbox implements Outbox {
  static const _key = 'eyelearn.entregas_pendentes';

  @override
  Future<List<({String classUid, String blob})>> pending() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    return [
      for (final e in (jsonDecode(raw) as List).cast<Map<String, dynamic>>())
        (classUid: e['turma'] as String, blob: e['blob'] as String),
    ];
  }

  Future<void> _save(List<({String classUid, String blob})> items) async =>
      (await SharedPreferences.getInstance()).setString(
          _key,
          jsonEncode([
            for (final i in items) {'turma': i.classUid, 'blob': i.blob},
          ]));

  @override
  Future<void> add(String classUid, String blob) async =>
      _save([...await pending(), (classUid: classUid, blob: blob)]);

  @override
  Future<void> remove(String blob) async => _save([
        for (final i in await pending())
          if (i.blob != blob) i
      ]);
}

class MemoryOutbox implements Outbox {
  final items = <({String classUid, String blob})>[];

  @override
  Future<List<({String classUid, String blob})>> pending() async =>
      List.of(items);

  @override
  Future<void> add(String classUid, String blob) async =>
      items.add((classUid: classUid, blob: blob));

  @override
  Future<void> remove(String blob) async =>
      items.removeWhere((i) => i.blob == blob);
}

/// Entrega ou guarda para depois. Devolve se saiu agora.
Future<bool> deliverOrKeep(
    Inbox inbox, Outbox outbox, String classUid, String blob) async {
  try {
    await inbox.send(classUid, blob);
    return true;
  } on InboxError {
    await outbox.add(classUid, blob);
    return false;
  }
}

/// Tenta de novo as entregas guardadas. Devolve quantas saíram.
Future<int> flushOutbox(Inbox inbox, Outbox outbox) async {
  var sent = 0;
  for (final item in await outbox.pending()) {
    try {
      await inbox.send(item.classUid, item.blob);
      await outbox.remove(item.blob);
      sent++;
    } on InboxError {
      break; // sem conexão: o resto também não vai agora
    }
  }
  return sent;
}

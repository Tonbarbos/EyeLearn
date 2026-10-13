/// O QR de entrada na atividade, conferido no aparelho.
///
/// O professor abre a atividade no painel e projeta o QR; o aplicativo só deixa
/// a criança entrar depois de lê-lo. Quem consegue ler a tela do professor
/// está na sala -- sem rede, sem localização, sem Bluetooth.
///
/// Formato e regras em `eyelearn/storage/ticket.py`, do lado Python, que gera
/// o QR. Os dois lados são conferidos contra o mesmo arquivo de exemplo em
/// `test/activity_test.dart`.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'roster.dart';

const ticketPrefix = 'EYELEARN1';
const ticketTasks = {'syllables', 'text', 'pseudotext'};
const _macBytes = 16;

/// Tolerância para relógio de celular um pouco adiantado em relação ao do
/// computador do professor. Igual à do Python.
const ticketGrace = Duration(seconds: 120);

/// QR que não é de atividade, de outra turma, adulterado ou vencido.
///
/// [message] é a frase para a tela, para o adulto que segura o celular.
class TicketException implements Exception {
  final String message;

  const TicketException(this.message);

  @override
  String toString() => 'TicketException: $message';
}

class ActivityTicket {
  final String classUid;
  final String activityCode;
  final String task;
  final DateTime expiresAt;

  const ActivityTicket({
    required this.classUid,
    required this.activityCode,
    required this.task,
    required this.expiresAt,
  });

  /// Se a entrada ainda está aberta em [now], com a mesma tolerância.
  bool isOpenAt(DateTime now) => !now.isAfter(expiresAt.add(ticketGrace));

  /// Confere o texto lido do QR contra a turma carregada no aparelho.
  ///
  /// Lança [TicketException] com a razão.
  factory ActivityTicket.verify(String text, Roster roster, DateTime now) {
    final parts = text.trim().split('.');
    // Só ASCII visível: um QR qualquer com acento não pode virar exceção
    // não tratada na assinatura.
    final printable = RegExp(r'^[\x21-\x7e]*$').hasMatch(text.trim());
    if (!printable || parts.length != 6 || parts[0] != ticketPrefix) {
      throw const TicketException('Este não é um QR de atividade do EyeLearn.');
    }
    final [_, uid, code, task, expires, mac] = parts;
    if (uid != roster.classUid) {
      throw const TicketException(
        'Este QR é de outra turma. Confira a lista de turma do aparelho.',
      );
    }
    final expected = _mac(roster.activityKey, parts.take(5).join('.'));
    if (!_equalConstantTime(mac, expected)) {
      throw const TicketException('QR inválido.');
    }
    final seconds = int.tryParse(expires);
    if (!ticketTasks.contains(task) || seconds == null) {
      throw const TicketException('QR inválido.');
    }
    final ticket = ActivityTicket(
      classUid: uid,
      activityCode: code,
      task: task,
      expiresAt:
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    );
    if (!ticket.isOpenAt(now)) {
      throw const TicketException(
        'A entrada nesta atividade já fechou. Peça ao professor para abrir de '
        'novo.',
      );
    }
    return ticket;
  }

  /// Monta o texto do QR. Do lado do aplicativo só a pré-visualização no
  /// navegador usa, para simular o QR do professor.
  static String issue({
    required Roster roster,
    required String activityCode,
    required String task,
    required DateTime expiresAt,
  }) {
    final body = [
      ticketPrefix,
      roster.classUid,
      activityCode,
      task,
      expiresAt.millisecondsSinceEpoch ~/ 1000,
    ].join('.');
    return '$body.${_mac(roster.activityKey, body)}';
  }
}

String _mac(String keyHex, String body) {
  final key = [
    for (var i = 0; i + 1 < keyHex.length; i += 2)
      int.parse(keyHex.substring(i, i + 2), radix: 16),
  ];
  final digest = Hmac(sha256, key).convert(ascii.encode(body)).bytes;
  return base64Url.encode(digest.sublist(0, _macBytes)).replaceAll('=', '');
}

bool _equalConstantTime(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

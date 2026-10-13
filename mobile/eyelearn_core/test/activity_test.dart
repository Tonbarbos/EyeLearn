import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Lista e QRs gerados pelo Python (`scripts/make_roster_fixture.py`).
final fixture = jsonDecode(
  File('assets/roster_example.json').readAsStringSync(),
) as Map<String, dynamic>;
final roster = Roster.fromJson(fixture['roster'] as Map<String, dynamic>);
final tickets = (fixture['tickets_for_tests'] as Map).cast<String, String>();
final opened = DateTime.parse(tickets['opened_at']!);
final expires = DateTime.parse(tickets['expires_at']!);

Matcher throwsTicket(String fragment) => throwsA(
      isA<TicketException>()
          .having((e) => e.message, 'message', contains(fragment)),
    );

void main() {
  group('fronteira com o Python', () {
    test('o QR do painel confere', () {
      // Se este teste falha, nenhuma criança entra na atividade.
      final ticket = ActivityTicket.verify(tickets['valid']!, roster, opened);
      expect(ticket.activityCode, tickets['activity_code']);
      expect(ticket.task, tickets['task']);
      expect(ticket.expiresAt, expires);
    });

    test('o Dart assina igual ao Python', () {
      final issued = ActivityTicket.issue(
        roster: roster,
        activityCode: tickets['activity_code']!,
        task: tickets['task']!,
        expiresAt: expires,
      );
      expect(issued, tickets['valid']);
    });

    test('QR de outra turma é recusado', () {
      expect(
        () => ActivityTicket.verify(tickets['other_class']!, roster, opened),
        throwsTicket('outra turma'),
      );
    });
  });

  group('prazo', () {
    test('aceita até o fim, com a tolerância de relógio', () {
      final late = expires.add(const Duration(seconds: 119));
      expect(ActivityTicket.verify(tickets['valid']!, roster, late), isNotNull);
    });

    test('recusa depois', () {
      final late = expires.add(const Duration(seconds: 121));
      expect(
        () => ActivityTicket.verify(tickets['valid']!, roster, late),
        throwsTicket('fechou'),
      );
    });

    test('isOpenAt acompanha o prazo', () {
      final ticket = ActivityTicket.verify(tickets['valid']!, roster, opened);
      expect(ticket.isOpenAt(expires), isTrue);
      expect(ticket.isOpenAt(expires.add(const Duration(minutes: 3))), isFalse);
    });
  });

  group('adulteração', () {
    // Estender o prazo, trocar a tarefa ou a atividade de um QR antigo: tudo
    // isso muda o texto assinado.
    for (final (index, value) in [
      (2, 'OUTRO123'),
      (3, 'syllables'),
      (4, '9999999999'),
    ]) {
      test('campo $index trocado', () {
        final parts = tickets['valid']!.split('.');
        parts[index] = value;
        expect(
          () => ActivityTicket.verify(parts.join('.'), roster, opened),
          throwsTicket('inválido'),
        );
      });
    }

    test('assinatura trocada', () {
      final parts = tickets['valid']!.split('.');
      parts[5] = 'A' * parts[5].length;
      expect(
        () => ActivityTicket.verify(parts.join('.'), roster, opened),
        throwsTicket('inválido'),
      );
    });
  });

  group('não é QR de atividade', () {
    for (final text in [
      '',
      'https://exemplo.com',
      'EYELEARN1.a.b',
      'EYELEARN2.x.y.text.1.z',
      'EYELEARN1.${roster.classUid}.ÇÃO.text.1.x',
    ]) {
      test('"$text"', () {
        expect(
          () => ActivityTicket.verify(text, roster, opened),
          throwsA(isA<TicketException>()),
        );
      });
    }
  });

  group('sessão', () {
    test('leva o código da atividade quando há', () {
      final json = Session(
        participantCode: 'ABC234',
        activityCode: 'KMYX8X42',
        task: 'text',
        startedAt: opened,
        durationSeconds: 1,
        samplingRateHz: 30,
        validSampleRatio: 1,
        features: const {},
        score: 0,
        modelMetadata: const {},
      ).toJson();
      expect(json['activity_code'], 'KMYX8X42');
      expect(Session.fromJson(json).activityCode, 'KMYX8X42');
    });

    test('omite o campo quando não há', () {
      final json = Session(
        participantCode: 'ABC234',
        task: 'text',
        startedAt: opened,
        durationSeconds: 1,
        samplingRateHz: 30,
        validSampleRatio: 1,
        features: const {},
        score: 0,
        modelMetadata: const {},
      ).toJson();
      expect(json.containsKey('activity_code'), isFalse);
    });
  });
}

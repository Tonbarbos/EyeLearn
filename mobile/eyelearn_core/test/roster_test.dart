import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Lista e PINs gerados pelo Python (`scripts/make_roster_fixture.py`).
final fixture = jsonDecode(
  File('assets/roster_example.json').readAsStringSync(),
) as Map<String, dynamic>;

final roster = Roster.fromJson(fixture['roster'] as Map<String, dynamic>);
final pins = (fixture['pins_for_tests'] as Map).cast<String, String>();

Map<String, dynamic> validRoster() =>
    jsonDecode(jsonEncode(fixture['roster'])) as Map<String, dynamic>;

void main() {
  group('PBKDF2-HMAC-SHA256', () {
    // Vetores publicados (RFC 7914, seção 11, e os de referência do
    // PBKDF2-SHA256): independentes do nosso Python e do nosso Dart.
    final password = utf8.encode('password');
    final salt = utf8.encode('salt');

    test('1 iteração', () {
      expect(
        hex(pbkdf2Sha256(password, salt, 1, 32)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('2 iterações', () {
      expect(
        hex(pbkdf2Sha256(password, salt, 2, 32)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('4096 iterações', () {
      expect(
        hex(pbkdf2Sha256(password, salt, 4096, 32)),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });

    test('chave maior que um bloco', () {
      // Exercita a concatenação de blocos, que a chave de 32 bytes do PIN
      // nunca usa: o primeiro bloco tem de ser o da chave de 32.
      final long = pbkdf2Sha256(password, salt, 2, 40);
      expect(long.length, 40);
      expect(
          hex(long.sublist(0, 32)), hex(pbkdf2Sha256(password, salt, 2, 32)));
    });
  });

  group('fronteira com o Python', () {
    test('todo PIN do arquivo confere', () {
      // Se este teste falha, nenhuma criança consegue entrar no aplicativo.
      for (final student in roster.students) {
        expect(student.checkPin(pins[student.code]!), isTrue,
            reason: student.displayName);
      }
    });

    test('PIN de um colega não confere', () {
      final [first, second, ...] = roster.students;
      expect(first.checkPin(pins[second.code]!), isFalse);
    });

    test('lista não carrega nome completo', () {
      for (final student in roster.students) {
        expect(student.displayName.split(' ').length, lessThanOrEqualTo(2));
      }
    });
  });

  group('verifyPin com hash malformado', () {
    for (final stored in [
      '',
      '2580',
      r'scrypt-v1$00$00',
      r'pbkdf2-sha256$0$00$00',
      r'pbkdf2-sha256$abc$00$00',
      r'pbkdf2-sha256$10$zz$00',
      r'pbkdf2-sha256$10$000$00',
      r'pbkdf2-sha256$10$00$',
      r'pbkdf2-sha256$99999999999$00$00',
    ]) {
      test('"$stored" é falso, não erro', () {
        expect(verifyPin('2580', stored), isFalse);
      });
    }
  });

  group('Roster.fromJson', () {
    test('lê o arquivo do painel', () {
      expect(roster.className, '5º A (exemplo)');
      expect(roster.students, hasLength(4));
    });

    test('recusa outro formato', () {
      final json = validRoster()..['format'] = 'eyelearn-sessao';
      expect(() => Roster.fromJson(json), throwsFormatException);
    });

    test('recusa versão desconhecida', () {
      final json = validRoster()..['format_version'] = 2;
      expect(() => Roster.fromJson(json), throwsFormatException);
    });

    test('recusa código repetido', () {
      final json = validRoster();
      final students = json['students'] as List;
      students.add(Map<String, dynamic>.from(students.first as Map));
      expect(() => Roster.fromJson(json), throwsFormatException);
    });
  });

  group('PinAttemptLimiter', () {
    late DateTime now;
    late PinAttemptLimiter limiter;
    late RosterStudent ana;
    late String anaPin;

    setUp(() {
      now = DateTime.utc(2026, 10, 13, 9);
      limiter = PinAttemptLimiter(maxFailures: 3, clock: () => now);
      ana = roster.students.first;
      anaPin = pins[ana.code]!;
    });

    test('aceita o PIN certo', () {
      expect(limiter.attempt(ana, anaPin).outcome, PinOutcome.accepted);
    });

    test('recusa o errado sem bloquear de cara', () {
      expect(limiter.attempt(ana, '0000').outcome, PinOutcome.rejected);
    });

    test('bloqueia no limite, mesmo com o PIN certo', () {
      limiter.attempt(ana, '0000');
      limiter.attempt(ana, '0000');
      final third = limiter.attempt(ana, '0000');
      expect(third.outcome, PinOutcome.locked);
      expect(third.lockout, const Duration(minutes: 1));
      expect(limiter.attempt(ana, anaPin).outcome, PinOutcome.locked);
    });

    test('o bloqueio expira e dobra na próxima vez', () {
      for (var i = 0; i < 3; i++) {
        limiter.attempt(ana, '0000');
      }
      now = now.add(const Duration(minutes: 1, seconds: 1));
      for (var i = 0; i < 3; i++) {
        limiter.attempt(ana, '0000');
      }
      expect(limiter.remainingLockout(ana.code), const Duration(minutes: 2));
    });

    test('acertar zera a contagem', () {
      limiter.attempt(ana, '0000');
      limiter.attempt(ana, '0000');
      limiter.attempt(ana, anaPin);
      limiter.attempt(ana, '0000');
      limiter.attempt(ana, '0000');
      expect(limiter.isLocked(ana.code), isFalse);
    });

    test('o erro de um não bloqueia o colega', () {
      final colega = roster.students[1];
      for (var i = 0; i < 3; i++) {
        limiter.attempt(ana, '0000');
      }
      expect(limiter.isLocked(colega.code), isFalse);
    });
  });
}

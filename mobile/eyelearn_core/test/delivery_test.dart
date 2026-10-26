import 'dart:convert';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

void main() {
  test('o professor abre o que foi cifrado para ele', () {
    final teacher = DeliveryKeyPair.generate();
    final public = parseDeliveryPublicKey(teacher.publicKeyText);
    final sealed = sealForTeacher(utf8.encode('{"oi": 1}'), public);
    expect(sealed, isNot(contains('oi')));
    expect(utf8.decode(openDelivery(sealed, teacher)), '{"oi": 1}');
  });

  test('cada entrega sai diferente, mesmo com o mesmo conteúdo', () {
    final teacher = DeliveryKeyPair.generate();
    final a = sealForTeacher([1, 2, 3], teacher.publicKey);
    final b = sealForTeacher([1, 2, 3], teacher.publicKey);
    expect(a, isNot(b));
  });

  test('outro professor não abre', () {
    final teacher = DeliveryKeyPair.generate();
    final other = DeliveryKeyPair.generate();
    final sealed = sealForTeacher([1, 2, 3], teacher.publicKey);
    expect(() => openDelivery(sealed, other), throwsFormatException);
  });

  test('bloco alterado ou cortado não abre', () {
    final teacher = DeliveryKeyPair.generate();
    final sealed = sealForTeacher(List.filled(40, 7), teacher.publicKey);
    final flipped = sealed.substring(0, sealed.length - 3) +
        (sealed[sealed.length - 3] == 'A' ? 'B' : 'A') +
        sealed.substring(sealed.length - 2);
    expect(() => openDelivery(flipped, teacher), throwsFormatException);
    expect(() => openDelivery(sealed.substring(0, 30), teacher),
        throwsFormatException);
  });

  test('a privada volta do hexadecimal do cofre', () {
    final teacher = DeliveryKeyPair.generate();
    final again = DeliveryKeyPair.fromPrivateHex(teacher.privateKeyHex);
    expect(again.publicKeyText, teacher.publicKeyText);
    final sealed = sealForTeacher([9], teacher.publicKey);
    expect(openDelivery(sealed, again), [9]);
  });

  test('chave de entrega inválida no link é recusada', () {
    expect(() => parseDeliveryPublicKey('abc'), throwsFormatException);
  });

  test('do cofre ao link ao aparelho e de volta ao cofre', () {
    final vault = TeacherVault.create('prof', 'Prof. Ana');
    final turma = vault.createClass('5º A');
    final ana = vault
        .addStudent(turma, 'Ana Souza',
            pin: debugStudentPin, enforcePinRules: false)
        .student;
    final atividade = vault.createActivity(turma, 'text', due: DateTime.now());

    // O aparelho: só tem o link.
    final roster =
        Roster.fromJsonString(Roster.compactOf(vault.compactLink(turma))!);
    expect(roster.deliveryKey, vault.deliveryKeys.publicKeyText);
    final session = {
      'format_version': sessionFormatVersion,
      'participant_code': ana.code,
      'activity_code': atividade.code,
      'task': 'text',
      'started_at': '2026-10-26T18:14:15.860Z',
      'duration_seconds': 30.0,
      'sampling_rate_hz': 20.0,
      'valid_sample_ratio': 0.9,
      'features': {for (final n in featureNames) n: 1.0},
      'score': 0.5,
      'model': {'training_data': 'etdd70'},
    };
    final blob = sealForTeacher(utf8.encode(jsonEncode(session)),
        parseDeliveryPublicKey(roster.deliveryKey!));

    // O painel: busca e importa.
    final restored = TeacherVault.fromJson(
        jsonDecode(jsonEncode(vault.toJson())) as Map<String, dynamic>);
    final target = restored.classes.single;
    final report = restored.importDeliveries(target, [
      (id: 7, blob: blob),
      (id: 8, blob: blob),
      (id: 9, blob: sealForTeacher([1], DeliveryKeyPair.generate().publicKey)),
    ]);
    expect(report.imported, ['entrega 7']);
    expect(report.duplicates, ['entrega 8']);
    expect(report.unreadable, ['entrega 9']);
    expect(target.deliveryCursor, 9);
    expect(target.completedActivityCodes()[atividade.code], {ana.code});
  });
}

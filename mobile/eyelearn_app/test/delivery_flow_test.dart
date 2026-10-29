import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_app/src/delivery/inbox.dart';
import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/homework_app.dart';
import 'package:eyelearn_app/src/session/class_storage.dart';
import 'package:eyelearn_app/src/ui/calibration_screen.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('caixa do Supabase', () {
    const config = InboxConfig('https://abc.supabase.co/', 'eyJchave-anon');

    test('sem projeto configurado, não há caixa', () {
      expect(const InboxConfig('', '').create(), isNull);
      expect(InboxConfig.fromEnvironment.configured, isFalse);
    });

    test('envia para a tabela com a chave anon', () async {
      late http.Request sent;
      final inbox = config.create(client: MockClient((request) async {
        sent = request;
        return http.Response('', 201);
      }))!;
      await inbox.send('0123456789abcdef', 'BLOCO');
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'https://abc.supabase.co/rest/v1/entregas');
      expect(sent.headers['apikey'], 'eyJchave-anon');
      expect(sent.headers['Authorization'], 'Bearer eyJchave-anon');
      expect(jsonDecode(sent.body),
          {'turma': '0123456789abcdef', 'blob': 'BLOCO'});
    });

    test('busca só as novas da turma, em ordem', () async {
      late Uri asked;
      final inbox = config.create(client: MockClient((request) async {
        asked = request.url;
        return http.Response(
            jsonEncode([
              {'id': 8, 'blob': 'A'},
              {'id': 9, 'blob': 'B'},
            ]),
            200);
      }))!;
      final rows = await inbox.fetch('0123456789abcdef', after: 7);
      expect(asked.queryParameters['turma'], 'eq.0123456789abcdef');
      expect(asked.queryParameters['id'], 'gt.7');
      expect(asked.queryParameters['order'], 'id.asc');
      expect(rows.map((r) => r.id), [8, 9]);
    });

    test('chave publicável nova vai só em apikey', () async {
      late http.Request sent;
      final inbox =
          const InboxConfig('https://abc.supabase.co', 'sb_publishable_abc123')
              .create(client: MockClient((request) async {
        sent = request;
        return http.Response('[]', 200);
      }))!;
      await inbox.fetch('0123456789abcdef');
      expect(sent.headers['apikey'], 'sb_publishable_abc123');
      expect(sent.headers.containsKey('Authorization'), isFalse);
    });

    test('recusa da caixa vira InboxError com o código', () async {
      final inbox = config.create(
          client: MockClient((_) async => http.Response(
              '{"code":"23514","message":"violates check constraint"}', 400)))!;
      await expectLater(
        inbox.send('x', 'y'),
        throwsA(isA<InboxError>()
            .having((e) => e.status, 'status', 400)
            .having((e) => e.refused, 'refused', isTrue)
            .having((e) => e.message, 'message', contains('check'))),
      );
    });

    test('sem resposta não é recusa', () async {
      final inbox = config.create(
          client: MockClient((_) async => throw http.ClientException('x')))!;
      await expectLater(
        inbox.send('x', 'y'),
        throwsA(isA<InboxError>().having((e) => e.refused, 'refused', false)),
      );
    });

    test('recusada fica guardada e não segura as outras', () async {
      final inbox = MemoryInbox()..maxBlobLength = 5;
      final outbox = MemoryOutbox();
      expect(await deliverOrKeep(inbox, outbox, 'turma', 'grande-demais'),
          DeliveryOutcome.refused);
      await outbox.add('turma', 'b2');
      expect(await flushOutbox(inbox, outbox), 1);
      expect(outbox.items.single.blob, 'grande-demais');
      // A regra da caixa mudou: sai na próxima.
      inbox.maxBlobLength = 500000;
      expect(await flushOutbox(inbox, outbox), 1);
      expect(outbox.items, isEmpty);
    });

    test('sem internet, guarda e manda depois', () async {
      final inbox = MemoryInbox()..offline = true;
      final outbox = MemoryOutbox();
      expect(await deliverOrKeep(inbox, outbox, 'turma', 'b1'),
          DeliveryOutcome.offline);
      expect(outbox.items, hasLength(1));
      expect(await flushOutbox(inbox, outbox), 0);
      inbox.offline = false;
      expect(await flushOutbox(inbox, outbox), 1);
      expect(outbox.items, isEmpty);
      expect(inbox.rows.single.blob, 'b1');
    });
  });

  testWidgets('a criança termina e a sessão chega cifrada ao professor',
      (tester) async {
    final vault = TeacherVault.create('prof', 'Prof. Ana');
    final turma = vault.createClass('5º A');
    final ana = vault
        .addStudent(turma, 'Ana Souza',
            pin: debugStudentPin, enforcePinRules: false)
        .student;
    final atividade = vault.createActivity(turma, 'text',
        due: DateTime.now().add(const Duration(days: 3)));
    final roster =
        Roster.fromJsonString(Roster.compactOf(vault.compactLink(turma))!);
    final inbox = MemoryInbox();
    final model = ModelArtifact.fromJsonString(
        File('../eyelearn_core/assets/model_text.json').readAsStringSync());

    await tester.pumpWidget(MaterialApp(
      home: ActivityRunScreen(
        environment: HomeworkEnvironment(
          models: {'text': model},
          gaze: SyntheticGazeSource.new,
          storage: MemoryClassStorage(),
          clock: DateTime.now,
          inbox: inbox,
          outbox: MemoryOutbox(),
          onTargetShown: (gaze, target) =>
              (gaze as SyntheticGazeSource).lookAtFraction(
            fractionX: target.fractionX,
            fractionY: target.fractionY,
            degreesPerHalfWidth: CalibrationScreen.degreesPerHalfWidth,
            degreesPerHalfHeight: CalibrationScreen.degreesPerHalfHeight,
          ),
        ),
        model: model,
        roster: roster,
        student: roster.students.single,
        activity: roster.activities.single,
      ),
    ));
    // Calibração (nove alvos) e a contagem da leitura.
    for (var i = 0; i < 260; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Terminei de ler'), findsOneWidget);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Terminei de ler'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('delivery-sent')), findsOneWidget);
    expect(find.text('Enviar ao professor'), findsNothing);
    expect(find.text('Enviar como arquivo'), findsNothing);

    // Na caixa, só um bloco ilegível.
    final row = inbox.rows.single;
    expect(row.classUid, turma.uid);
    expect(row.blob, isNot(contains(ana.code)));

    // O painel abre e importa.
    final report = vault.importDeliveries(
        turma, await inbox.fetch(turma.uid, after: turma.deliveryCursor));
    expect(report.imported, hasLength(1));
    // A sessão chega com o mapa de calor e a área do texto.
    final delivered = turma.sessions.single;
    expect(delivered.heatmap, isNotNull);
    expect(delivered.heatmap!.textArea, hasLength(4));
    expect(delivered.heatmap!.total, greaterThan(1));
    expect(turma.completedActivityCodes()[atividade.code], {ana.code});
  });
}

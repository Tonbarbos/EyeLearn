/// Testes das tarefas de leitura.
///
/// A afirmação central é de desenho, não de estética: **nenhuma linha pode
/// quebrar na tela**. `passages.dart` fixa a quebra de linha de propósito,
/// porque o retorno de linha é uma das características medidas — se a quebra
/// mudar de aparelho para aparelho, a contagem de retornos de linha deixa de
/// ser comparável entre participantes.
///
/// O defeito que este teste existe para impedir apareceu na primeira
/// pré-visualização gravada: na largura de um celular em retrato, cada uma das
/// seis linhas do texto virava duas, e o percurso teria doze retornos de linha
/// onde o modelo espera cinco.
library;

import 'dart:io';

import 'package:eyelearn_app/src/activity/passages.dart';
import 'package:eyelearn_app/src/ui/reading_screen.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

/// Larguras de tela em que o aplicativo tem de caber, em pixels lógicos.
///
/// 360 é o piso prático dos aparelhos Android em uso; 412 é um Pixel atual.
const List<double> phoneWidths = [360.0, 412.0];

void main() {
  // A medida tem de ser feita na fonte que o aparelho usa. A fonte embutida
  // nos testes do Flutter é monoespaçada de um em por glifo, cerca de 1,5 vez
  // mais larga que a real: medir com ela reprovaria textos que cabem bem no
  // celular.
  //
  // Carrega o mesmo arquivo que o aplicativo embute, e não uma cópia no
  // diretório de testes: duas cópias poderiam divergir, e o teste passaria a
  // medir uma fonte que a tela não usa.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Roboto')
      ..addFont(
        File('fonts/Roboto-Regular.ttf')
            .readAsBytes()
            .then((bytes) => ByteData.view(Uint8List.fromList(bytes).buffer)),
      );
    await loader.load();
  });

  group('o texto cabe na largura do celular', () {
    // Mede a largura real do texto com o mesmo estilo da tela. Perguntar ao
    // Flutter se ele quebrou não serve: com `softWrap: false` ele nunca
    // quebra, só corta, e `didExceedMaxLines` fica sempre falso.
    //
    // A fonte dos testes do Flutter é monoespaçada de um em por glifo, bem
    // mais larga que a real. Isso torna a medida conservadora: o que passa
    // aqui passa no aparelho com folga.
    for (final width in phoneWidths) {
      final available = width - ReadingScreenBody.horizontalPadding * 2;

      for (final passage in passages) {
        test('${passage.id} em ${width.toInt()}px', () {
          final fontSize = ReadingScreenBody.fittedFontSize(passage, available);

          expect(
            fontSize,
            greaterThan(ReadingScreenBody.minimumFontSize),
            reason:
                'a tarefa ${passage.id} precisa encolher até $fontSize px para '
                'caber em ${available.toStringAsFixed(0)}px, abaixo do piso de '
                'legibilidade. Encurte as linhas em vez de diminuir a fonte.',
          );

          // A escala escolhida tem de de fato fazer a linha mais larga caber.
          final widest = ReadingScreenBody.widestLine(passage);
          final scaled =
              widest * fontSize / ReadingScreenBody.lineStyle.fontSize!;
          expect(
            scaled,
            lessThanOrEqualTo(available + 0.5),
            reason: 'a linha mais larga de ${passage.id} ainda estoura',
          );
        });
      }
    }

    test('a escala nunca aumenta a fonte', () {
      // Numa tela larga o tamanho de base é o desejado; esticar o texto para
      // preencher mudaria a amplitude das sacadas sem motivo.
      final fontSize = ReadingScreenBody.fittedFontSize(passages[1], 5000);
      expect(fontSize, equals(ReadingScreenBody.lineStyle.fontSize));
    });

    test('largura degenerada não quebra o cálculo', () {
      expect(
        ReadingScreenBody.fittedFontSize(passages[1], 0),
        equals(ReadingScreenBody.lineStyle.fontSize),
      );
    });

    test('a escala é a mesma para todas as linhas da tarefa', () {
      // Escalar linha a linha daria tamanhos diferentes na mesma página e
      // mudaria a amplitude das sacadas entre uma linha e outra -- justamente
      // uma das características medidas.
      final fontSize = ReadingScreenBody.fittedFontSize(passages[1], 320);
      expect(fontSize, isNot(equals(0)));
      expect(fontSize.isFinite, isTrue);
    });
  });

  group('o corpo do texto não permite quebra', () {
    testWidgets('toda linha é renderizada em uma linha só', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ReadingScreenBody(passage: passages[1])),
      );

      for (final line in passages[1].lines) {
        final widget = tester.widget<Text>(find.text(line));
        expect(widget.maxLines, equals(1), reason: line);
        expect(widget.softWrap, isFalse, reason: line);
      }
    });

    testWidgets('todas as linhas usam o mesmo tamanho', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ReadingScreenBody(passage: passages[1])),
      );

      final sizes = passages[1]
          .lines
          .map((line) => tester.widget<Text>(find.text(line)).style!.fontSize)
          .toSet();
      expect(sizes.length, equals(1));
    });
  });

  group('estrutura das tarefas', () {
    test('as três tarefas do ETDD70 estão presentes', () {
      // Treinar numa estrutura de tarefa e medir em outra mudaria o que as
      // características significam.
      expect(
        passages.map((p) => p.id).toList(),
        equals(['syllables', 'text', 'pseudotext']),
      );
    });

    test('os identificadores são únicos', () {
      final ids = passages.map((p) => p.id).toList();
      expect(ids.toSet().length, equals(ids.length));
    });

    test('toda tarefa tem texto e instrução', () {
      for (final passage in passages) {
        expect(passage.lines, isNotEmpty, reason: passage.id);
        expect(passage.instruction.trim(), isNotEmpty, reason: passage.id);
        expect(passage.title.trim(), isNotEmpty, reason: passage.id);
      }
    });

    test('a busca por identificador encontra cada tarefa', () {
      for (final passage in passages) {
        expect(passageById(passage.id).title, equals(passage.title));
      }
    });

    test('identificador desconhecido é recusado', () {
      // Uma tarefa que não existe indica sessão corrompida, e seguir com a
      // primeira da lista gravaria a tarefa errada no arquivo.
      expect(() => passageById('nao_existe'), throwsArgumentError);
    });
  });
}

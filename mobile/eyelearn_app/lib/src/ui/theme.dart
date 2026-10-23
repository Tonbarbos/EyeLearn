/// Identidade visual do aplicativo do aluno.
///
/// Duas tipografias, e a separação é deliberada:
///
/// * **Outfit** na interface — títulos, botões, rótulos. Geométrica de formas
///   arredondadas, que é o que uma criança de nove anos reconhece como
///   aplicativo.
/// * **Roboto** no texto de leitura, e só ali. O texto é o estímulo medido:
///   trocá-lo por uma fonte decorativa mudaria a largura das palavras, a
///   amplitude das sacadas entre elas e, portanto, as características
///   extraídas. Ver `ReadingScreenBody.lineStyle`.
///
/// Pela mesma razão, **a área de leitura não recebe decoração**: nem cor de
/// fundo, nem moldura, nem ilustração ao lado. Qualquer elemento visual perto
/// do texto atrai o olhar e contamina o percurso que o pipeline vai analisar.
/// Todo o capricho visual fica nas telas à volta.
library;

import 'package:flutter/material.dart';

/// Paleta.
///
/// Violeta como cor de marca, âmbar como acento e um verde de conclusão. Os
/// tons são saturados o bastante para parecerem de aplicativo infantil, e
/// dessaturados o bastante para não cansarem numa sessão de leitura.
abstract final class Palette {
  static const Color brand = Color(0xFF5B4BE8);
  static const Color brandDeep = Color(0xFF3A2FB0);
  static const Color brandSoft = Color(0xFFEDEAFF);

  static const Color amber = Color(0xFFFFB23F);
  static const Color amberSoft = Color(0xFFFFF3DE);

  static const Color green = Color(0xFF17A673);
  static const Color greenSoft = Color(0xFFE2F6EF);

  static const Color coral = Color(0xFFF2594B);
  static const Color coralSoft = Color(0xFFFFE9E6);

  static const Color ink = Color(0xFF1C2033);
  static const Color inkMuted = Color(0xFF6B7194);
  static const Color line = Color(0xFFE6E5F2);

  static const Color surface = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFF5F4FD);

  /// Fundo da tela de leitura.
  ///
  /// Branco levemente quente, sem tingimento: contraste alto para o texto e
  /// nenhuma cor que puxe o olhar para um canto.
  static const Color readingSurface = Color(0xFFFFFDF8);

  /// Fundo da calibração, onde o alvo precisa de contraste máximo.
  static const Color nightTop = Color(0xFF2A2362);
  static const Color nightBottom = Color(0xFF14102E);
}

/// Cantos e sombras.
abstract final class Shapes {
  static const double cardRadius = 26.0;
  static const double buttonRadius = 22.0;
  static const double chipRadius = 14.0;

  /// Sombra de cartão: difusa e de baixa opacidade.
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color(0x14262B4D),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];

  static const List<BoxShadow> buttonShadow = [
    BoxShadow(
      color: Color(0x335B4BE8),
      blurRadius: 18,
      offset: Offset(0, 8),
    ),
  ];
}

/// Tipografia da interface. Nunca do texto de leitura.
abstract final class AppType {
  static const String family = 'Outfit';

  static const TextStyle display = TextStyle(
    fontFamily: family,
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.15,
    color: Palette.ink,
  );

  static const TextStyle title = TextStyle(
    fontFamily: family,
    fontSize: 23,
    fontWeight: FontWeight.w700,
    height: 1.25,
    color: Palette.ink,
  );

  static const TextStyle subtitle = TextStyle(
    fontFamily: family,
    fontSize: 17,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: Palette.inkMuted,
  );

  static const TextStyle body = TextStyle(
    fontFamily: family,
    fontSize: 15.5,
    height: 1.45,
    color: Palette.ink,
  );

  static const TextStyle label = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
    color: Palette.inkMuted,
  );

  static const TextStyle button = TextStyle(
    fontFamily: family,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
  );

  static const TextStyle stat = TextStyle(
    fontFamily: family,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: Palette.ink,
  );
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Palette.brand,
    primary: Palette.brand,
    surface: Palette.surface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.background,
    fontFamily: AppType.family,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: AppType.title,
    ),
  );
}

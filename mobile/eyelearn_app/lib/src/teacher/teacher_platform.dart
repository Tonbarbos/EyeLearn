/// O que o painel do professor precisa da plataforma.
///
/// No navegador: WebCrypto para a chave do cofre, seletor de arquivos e
/// download (`web/panel.js`). Fora dele -- nos testes e no Android --, o
/// cálculo em Dart e a folha de compartilhamento; importar sessões fica para o
/// navegador.
library;

import 'dart:typed_data';

import 'package:eyelearn_core/eyelearn_core.dart';

export 'teacher_platform_native.dart'
    if (dart.library.js_interop) 'teacher_platform_web.dart';

/// Um arquivo escolhido pelo professor.
typedef PickedFile = ({String name, String text});

abstract interface class TeacherPlatform {
  /// Deriva a chave do cofre. Pode levar um instante; não trava a tela.
  Future<SealKey> deriveKey(String password, int iterations, Uint8List salt);

  /// Escolhe arquivos de texto; `null` se a plataforma não escolhe arquivos.
  Future<List<PickedFile>> Function()? get pickFiles;

  /// Entrega um arquivo ao professor: download no navegador.
  Future<void> saveFile(String name, String text);

  /// Idem, para um arquivo binário (o GIF do time-lapse).
  Future<void> saveBytes(String name, Uint8List bytes, String type);

  /// Pede ao navegador que não apague os dados do site sozinho.
  Future<bool> persistStorage();
}

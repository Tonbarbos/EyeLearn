/// Fora do navegador: chave em Dart, numa isolate, e arquivo pela folha de
/// compartilhamento.
library;

import 'dart:convert';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'teacher_platform.dart';

TeacherPlatform createTeacherPlatform() => NativeTeacherPlatform();

class NativeTeacherPlatform implements TeacherPlatform {
  @override
  Future<SealKey> deriveKey(String password, int iterations, Uint8List salt) =>
      compute(
        (args) => deriveVaultKey(args.$1, iterations: args.$2, salt: args.$3),
        (password, iterations, salt),
      );

  @override
  Future<List<PickedFile>> Function()? get pickFiles => null;

  @override
  Future<void> saveFile(String name, String text) => Share.shareXFiles(
        [
          XFile.fromData(
            Uint8List.fromList(utf8.encode(text)),
            name: name,
            mimeType: 'application/json',
          ),
        ],
        fileNameOverrides: [name],
      );

  @override
  Future<void> saveBytes(String name, Uint8List bytes, String type) =>
      Share.shareXFiles(
        [XFile.fromData(bytes, name: name, mimeType: type)],
        fileNameOverrides: [name],
      );

  @override
  Future<bool> persistStorage() async => true;
}

/// Navegador: `web/panel.js`.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:eyelearn_core/eyelearn_core.dart';

import 'teacher_platform.dart';

TeacherPlatform createTeacherPlatform() => WebTeacherPlatform();

@JS('eyelearnPanel')
external _Panel? get _panel;

extension type _Panel._(JSObject _) implements JSObject {
  external JSPromise<JSUint8Array> pbkdf2(
      JSUint8Array password, JSUint8Array salt, int iterations);
  external JSPromise<JSArray<_File>> pickFiles(String accept);
  external void download(String name, String text, String type);
  @JS('download')
  external void downloadBytes(String name, JSUint8Array bytes, String type);
  external JSPromise<JSBoolean> persist();
}

extension type _File._(JSObject _) implements JSObject {
  external String get name;
  external String get text;
}

class WebTeacherPlatform implements TeacherPlatform {
  @override
  Future<SealKey> deriveKey(
      String password, int iterations, Uint8List salt) async {
    final panel = _panel;
    if (panel == null) {
      // panel.js não carregou: o cálculo em Dart dá o mesmo resultado, só
      // que mais devagar.
      return deriveVaultKey(password, iterations: iterations, salt: salt);
    }
    final key = await panel
        .pbkdf2(Uint8List.fromList(utf8.encode(password)).toJS, salt.toJS,
            iterations)
        .toDart;
    return SealKey(key.toDart, salt);
  }

  @override
  Future<List<PickedFile>> Function()? get pickFiles {
    final panel = _panel;
    if (panel == null) return null;
    return () async {
      final files = await panel.pickFiles('.json,application/json').toDart;
      return [for (final f in files.toDart) (name: f.name, text: f.text)];
    };
  }

  @override
  Future<void> saveFile(String name, String text) async =>
      _panel?.download(name, text, 'application/json');

  @override
  Future<void> saveBytes(String name, Uint8List bytes, String type) async =>
      _panel?.downloadBytes(name, bytes.toJS, type);

  @override
  Future<bool> persistStorage() async {
    final panel = _panel;
    if (panel == null) return false;
    return (await panel.persist().toDart).toDart;
  }
}

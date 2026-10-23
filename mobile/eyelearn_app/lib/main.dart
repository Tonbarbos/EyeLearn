/// Aplicativo do aluno: Android e navegador.
///
/// O fluxo inteiro está em `src/homework_app.dart`. Aqui só se monta o que
/// depende da plataforma: de onde vem o olhar, onde a turma fica guardada,
/// como o arquivo é enviado e com que link a página foi aberta.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:permission_handler/permission_handler.dart';

import 'src/activity/models.dart';
import 'src/gaze/platform_gaze.dart';
import 'src/homework_app.dart';
import 'src/session/class_storage.dart';
import 'src/session/session_export.dart';
import 'src/teacher/teacher_controller.dart';
import 'src/teacher/teacher_platform.dart';

Future<void> main() async {
  // O link da turma chega no fragmento (#t=...). Lido antes de o Flutter
  // tocar no endereço, e com a estratégia de endereço desligada: a padrão
  // trataria o fragmento como nome de rota.
  final initialLink = kIsWeb ? Uri.base.toString() : null;
  setUrlStrategy(null);
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    HomeworkApp(
      environment: HomeworkEnvironment(
        models: await loadModels(),
        gaze: createPlatformGazeSource,
        storage: PrefsClassStorage(),
        clock: DateTime.now,
        initialLink: initialLink,
        requestCamera: platformAsksCameraPermission
            ? null
            : () async => (await Permission.camera.request()).isGranted,
        share: shareSession,
        teacher: TeacherEnvironment(
          platform: createTeacherPlatform(),
          storage: PrefsVaultStorage(),
          clock: DateTime.now,
        ),
      ),
    ),
  );
}

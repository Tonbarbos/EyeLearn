/// Os modelos embarcados, um por tarefa.
///
/// O padrão de leitura muda muito de uma tarefa para outra: no ETDD70, um
/// modelo único para as três acerta 77%, e um por tarefa, de 80% a 86%. A
/// tarefa vem do QR do professor, e o aplicativo usa o modelo dela.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/services.dart';

import 'passages.dart';

Future<Map<String, ModelArtifact>> loadModels() async => {
      for (final passage in passages)
        passage.id: ModelArtifact.fromJsonString(
          await rootBundle.loadString('assets/model_${passage.id}.json'),
        ),
    };

/// Se algum modelo veio de dados sintéticos, caso em que a tela avisa.
bool anyTrainedOnSyntheticData(Map<String, ModelArtifact> models) =>
    models.values
        .any((model) => model.metadata['training_data'] == 'synthetic');

/// A lista da turma guardada no aparelho.
///
/// O adulto importa uma vez o arquivo que o painel exportou; o aplicativo
/// guarda uma cópia no diretório de documentos dele, onde nenhum outro
/// aplicativo lê. Importar outra lista substitui a anterior: o aparelho serve a
/// uma turma de cada vez, e misturar duas listas deixaria a criança escolher
/// um nome de outra sala.
library;

import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

const _fileName = 'turma.json';

Future<File> _file() async =>
    File('${(await getApplicationDocumentsDirectory()).path}/$_fileName');

/// A lista guardada, ou `null` se ainda não houver -- ou se a guardada estiver
/// ilegível, caso em que o adulto importa de novo.
Future<Roster?> loadSavedRoster() async {
  final file = await _file();
  if (!await file.exists()) return null;
  try {
    return Roster.fromJsonString(await file.readAsString());
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// Abre o seletor de arquivos do sistema e importa a lista escolhida.
///
/// Devolve `null` se o adulto cancelar. Lança [FormatException], com a
/// mensagem para a tela, se o arquivo não for uma lista de turma: só então ele
/// substitui a lista guardada.
Future<Roster?> pickAndSaveRoster() async {
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Lista da turma',
    type: FileType.custom,
    allowedExtensions: const ['json'],
    withData: true,
  );
  final bytes = picked?.files.single.bytes;
  if (bytes == null) return null;

  final text = utf8.decode(bytes, allowMalformed: false);
  final Roster roster;
  try {
    roster = Roster.fromJsonString(text);
  } on TypeError {
    throw const FormatException('o arquivo não é uma lista de turma');
  }
  if (roster.students.isEmpty) {
    throw const FormatException('a lista não tem nenhum aluno');
  }
  await (await _file()).writeAsString(text, flush: true);
  return roster;
}

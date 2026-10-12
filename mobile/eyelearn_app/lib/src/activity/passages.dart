/// Textos das atividades de leitura.
///
/// As três tarefas reproduzem a estrutura do ETDD70 (Dostálová et al., 2024),
/// que é a base em que o modelo foi treinado: sílabas, texto com sentido e
/// pseudotexto. Treinar numa estrutura de tarefa e medir em outra mudaria o que
/// as características significam -- a proporção de regressões em leitura de
/// sílabas não é comparável à de texto corrido.
///
/// O conteúdo é em português e adequado a 9 e 10 anos, que é a faixa da base. O
/// pseudotexto respeita a fonotática do português: as palavras não existem, mas
/// são pronunciáveis, o que é o ponto da tarefa -- forçar decodificação sem
/// apoio de reconhecimento lexical.
library;

/// Uma tarefa de leitura.
class Passage {
  /// Identificador que viaja na sessão. Igual ao nome da tarefa no ETDD70.
  final String id;

  /// Título mostrado à criança.
  final String title;

  /// Instrução, em linguagem de criança.
  final String instruction;

  /// Linhas de texto, já quebradas.
  ///
  /// A quebra é fixa, e não automática pela largura da tela, porque o retorno
  /// de linha é uma das características medidas: se a quebra mudar de aparelho
  /// para aparelho, a contagem de retornos de linha deixa de ser comparável.
  final List<String> lines;

  const Passage({
    required this.id,
    required this.title,
    required this.instruction,
    required this.lines,
  });
}

/// As três tarefas, na ordem em que são apresentadas.
///
/// Sílabas primeiro, como aquecimento, e pseudotexto por último: é a tarefa
/// mais cansativa, e cansaço no início contaminaria as outras duas.
const List<Passage> passages = [
  Passage(
    id: 'syllables',
    title: 'Sílabas',
    instruction: 'Leia em voz alta, uma de cada vez, sem pressa.',
    lines: [
      'ma  pe  li  to  nu  ca  fe  ri',
      'bo  da  gu  sa  ve  mi  lo  te',
      'pa  ne  zi  fu  ro  cha  le  mu',
      'ta  bi  so  vu  je  na  pi  do',
    ],
  ),
  Passage(
    id: 'text',
    title: 'Uma história',
    instruction: 'Leia a história em voz alta, do seu jeito.',
    lines: [
      'O gato dormia na janela da cozinha.',
      'O sol da tarde esquentava o seu pelo.',
      'Na rua, dois meninos jogavam bola.',
      'A bola bateu no muro e fez barulho.',
      'O gato abriu um olho, olhou e voltou',
      'a dormir, porque ainda era muito cedo.',
    ],
  ),
  Passage(
    id: 'pseudotext',
    title: 'Palavras inventadas',
    instruction:
        'Estas palavras não existem. Leia em voz alta do jeito que você acha '
        'que elas falam.',
    lines: [
      'O tramo delia na vanjela da coxinha.',
      'O sul da tarpe esquendava o seu pelho.',
      'Na rula, dois menidos jofavam bula.',
      'A bula batreu no muvo e fez barulfo.',
      'O tramo abliu um olno, olhou e voltrou',
      'a delir, porcue ainda era muito cefo.',
    ],
  ),
];

/// A tarefa de um identificador.
///
/// Throws [ArgumentError] para identificador desconhecido: uma tarefa que não
/// existe indica sessão corrompida, e seguir com a primeira da lista gravaria
/// a tarefa errada no arquivo.
Passage passageById(String id) => passages.firstWhere(
  (passage) => passage.id == id,
  orElse: () => throw ArgumentError('tarefa desconhecida: $id'),
);

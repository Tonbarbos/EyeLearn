/// Tela de leitura: a criança lê enquanto a câmera acompanha o olhar.
///
/// **Esta tela não mostra resultado nenhum, nem aqui nem depois.** A saída
/// pedagógica vai para o painel do professor. Mostrar a uma criança de nove
/// anos uma tela que diz algo sobre o padrão de leitura dela seria exatamente o
/// que o projeto se compromete a não fazer -- e, pior, seria um rótulo vindo de
/// um modelo cujo valor preditivo positivo na prevalência escolar é de cerca de
/// 22%.
///
/// O que a criança vê ao terminar é que terminou.
library;

import 'dart:async';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import 'calibration_screen.dart';
import 'theme.dart';
import 'widgets.dart';

import '../activity/passages.dart';
import '../gaze/gaze_source.dart';

/// O que a leitura entrega ao terminar.
class ReadingResult {
  /// O percurso da análise (o olhar fora da área do texto vira `NaN`).
  final GazeTrace trace;
  final RecordingQuality quality;

  /// Onde o texto ficou na tela, em graus (esquerda, topo, direita, base),
  /// para o painel desenhar as linhas sob o olhar.
  final List<double>? textArea;

  /// Fração do tempo fora da posição da calibração; `null` sem referência.
  final double? outOfPosition;

  /// O percurso reduzido para o time-lapse, com o olhar fora da tela.
  final GazePath path;

  const ReadingResult({
    required this.trace,
    required this.quality,
    required this.textArea,
    required this.outOfPosition,
    required this.path,
  });
}

class ReadingScreen extends StatefulWidget {
  final GazeSource channel;
  final GazeCalibration calibration;
  final Passage passage;

  /// A posição em que a calibração foi feita; com ela, a tela avisa quando
  /// a criança sai dessa posição e conta quanto tempo ficou fora.
  final PostureReference? postureReference;

  /// Chamada ao final, com o que foi gravado.
  final void Function(ReadingResult result) onFinished;

  /// Chamada quando a captura começa.
  ///
  /// Existe para que uma origem de olhar que não seja a câmera possa iniciar o
  /// seu roteiro no mesmo instante em que a gravação começa -- é o que a
  /// pré-visualização de `main_demo.dart` usa. No aplicativo instalado fica
  /// nula: a câmera já está emitindo, e quem move os olhos é a criança.
  final VoidCallback? onStarted;

  const ReadingScreen({
    super.key,
    required this.channel,
    required this.calibration,
    required this.passage,
    required this.onFinished,
    this.onStarted,
    this.postureReference,
  });

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  late final GazeRecorder _recorder;
  PostureMonitor? _monitor;
  bool _outOfPosition = false;
  StreamSubscription<FaceFrame>? _subscription;

  bool _capturing = false;
  String? _warning;
  String? _error;

  final _textKey = GlobalKey();

  /// O retângulo do texto em graus, na mesma conversão da calibração: a
  /// tela inteira, dentro da área segura, vale ±meia-largura e ±meia-altura.
  List<double>? _textArea() {
    final box = _textKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final media = MediaQuery.of(context);
    final safe = media.padding;
    final width = media.size.width - safe.horizontal;
    final height = media.size.height - safe.vertical;
    if (width <= 0 || height <= 0) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    double dx(double px) =>
        ((px - safe.left) / width - 0.5) *
        2 *
        CalibrationScreen.degreesPerHalfWidth;
    double dy(double px) =>
        ((px - safe.top) / height - 0.5) *
        2 *
        CalibrationScreen.degreesPerHalfHeight;
    return [
      dx(topLeft.dx),
      dy(topLeft.dy),
      dx(topLeft.dx + box.size.width),
      dy(topLeft.dy + box.size.height),
    ];
  }

  /// Segundos que faltam para a leitura começar sozinha; `0` depois.
  ///
  /// Não há botão de começar: a criança chega da calibração e o texto já
  /// está na tela. A contagem dá tempo de achar a primeira palavra, e a
  /// gravação começa sozinha no fim dela.
  int _countdown = 3;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _recorder = GazeRecorder(
      calibration: widget.calibration,
      // Limites um pouco maiores que a tela: o olhar sai dela de vez em quando
      // e cortar justo na borda descartaria amostras legítimas das linhas de
      // cima e de baixo.
      boundsDeg: (w: 20.0, h: 30.0),
    );
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _countdown--);
      if (_countdown <= 0) {
        timer.cancel();
        _start();
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _subscription?.cancel();
    // Deixar a câmera ligada depois de sair da tela é, além de desperdício de
    // bateria, uma captura que ninguém pediu.
    widget.channel.stop();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _warning = null;
    });

    try {
      await widget.channel.start();
    } on GazeCaptureError catch (error) {
      if (mounted) setState(() => _error = error.message);
      return;
    }

    _recorder.reset();
    final reference = widget.postureReference;
    _monitor = reference == null ? null : PostureMonitor(reference);
    _subscription = widget.channel.frames().listen(_onFrame);
    setState(() => _capturing = true);
    widget.onStarted?.call();
  }

  void _onFrame(FaceFrame frame) {
    final monitor = _monitor;
    if (monitor != null) {
      monitor.add(frame);
      if (monitor.isOut != _outOfPosition) {
        setState(() => _outOfPosition = monitor.isOut);
      }
    }
    final rejection = _recorder.add(frame);
    if (rejection == null) {
      if (_warning != null) setState(() => _warning = null);
      return;
    }

    // Só o problema persistente vira aviso. Uma piscada é normal; avisar a
    // cada uma deixaria a tela piscando mensagens.
    final quality = _recorder.quality();
    if (quality.total < 30 || quality.validRatio > 0.7) return;

    final message = switch (quality.dominantProblem) {
      RejectionReason.noFace => 'Deixe o rosto na frente da tela 🙂',
      RejectionReason.eyesClosed => 'Olhos bem abertos!',
      RejectionReason.outsideStimulus => 'Olhe para as palavras',
      null => null,
    };
    if (message != null && message != _warning) {
      setState(() => _warning = message);
    }
  }

  Future<void> _finish() async {
    await _subscription?.cancel();
    _subscription = null;
    await widget.channel.stop();

    setState(() => _capturing = false);
    widget.onFinished(ReadingResult(
      trace: _recorder.build(),
      quality: _recorder.quality(),
      textArea: _textArea(),
      outOfPosition: _monitor?.outRatio,
      path: _recorder.path(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final passage = widget.passage;

    return Scaffold(
      backgroundColor: Palette.readingSurface,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReadingHeader(passage: passage, capturing: _capturing),

            // A área do estímulo. Sem cartão, sem moldura, sem cor de fundo
            // própria e sem nada ao lado: qualquer elemento visual aqui
            // atrairia o olhar e contaminaria o percurso que o pipeline vai
            // analisar. Todo o capricho visual do aplicativo para na borda
            // deste retângulo, e é de propósito.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ReadingScreenBody.horizontalPadding,
                ),
                child: ReadingScreenBody(linesKey: _textKey, passage: passage),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_outOfPosition || _warning != null)
                    NoticeCard(
                      key: _outOfPosition ? const Key('out-of-position') : null,
                      icon: _outOfPosition
                          ? Icons.screen_rotation_alt_rounded
                          : Icons.visibility_outlined,
                      tint: const Color(0xFF9A5B00),
                      background: Palette.amberSoft,
                      text: _outOfPosition
                          ? 'Volte o celular e o rosto para a posição do '
                              'começo'
                          : _warning!,
                    ),
                  if (_error != null)
                    NoticeCard(
                      icon: Icons.error_outline,
                      tint: const Color(0xFFA32317),
                      background: Palette.coralSoft,
                      text: _error!,
                    ),
                  if (_outOfPosition || _warning != null || _error != null)
                    const SizedBox(height: 14),
                  PrimaryButton(
                    key: const Key('reading-button'),
                    label: _capturing
                        ? 'Terminei de ler'
                        : _error != null
                            ? 'Tentar de novo'
                            : 'Começa em $_countdown…',
                    icon: _capturing
                        ? Icons.check_rounded
                        : _error != null
                            ? Icons.refresh_rounded
                            : Icons.hourglass_top_rounded,
                    colour: _capturing ? Palette.green : Palette.brand,
                    onPressed: _capturing
                        ? _finish
                        : _error != null
                            ? _start
                            : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cabeçalho da leitura: a tarefa, a instrução e o estado da captura.
///
/// Fica acima do texto e nunca ao lado dele, para não entrar no campo em que o
/// olhar trabalha.
class _ReadingHeader extends StatelessWidget {
  final Passage passage;
  final bool capturing;

  const _ReadingHeader({required this.passage, required this.capturing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(passage.title, style: AppType.title)),
                _CaptureBadge(capturing: capturing),
              ],
            ),
            const SizedBox(height: 4),
            Text(passage.instruction,
                style: AppType.subtitle.copyWith(fontSize: 15)),
          ],
        ),
      );
}

/// Selo de estado da captura.
///
/// O adulto precisa saber, à distância, se a atividade está gravando. A
/// criança não precisa, e por isso o selo é discreto e fica no canto, longe
/// do texto.
class _CaptureBadge extends StatelessWidget {
  final bool capturing;

  const _CaptureBadge({required this.capturing});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: capturing ? Palette.greenSoft : Palette.background,
          borderRadius: BorderRadius.circular(Shapes.chipRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: capturing ? Palette.green : Palette.inkMuted,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              capturing ? 'Gravando' : 'Pronto',
              style: AppType.label.copyWith(
                fontSize: 11.5,
                color: capturing ? const Color(0xFF0E6B49) : Palette.inkMuted,
              ),
            ),
          ],
        ),
      );
}

/// O texto a ler.
///
/// Linhas com espaçamento generoso: o percurso do olhar só é separável em
/// linhas se elas estiverem mais distantes que o erro da estimativa. Texto
/// apertado produziria um percurso em que as linhas se misturam, e o retorno
/// de linha -- uma das características medidas -- deixaria de ser detectável.
///
/// **Cada linha ocupa exatamente uma linha na tela**, e a fonte é escalada uma
/// única vez para que a linha mais larga caiba. Deixar o Flutter quebrar
/// sozinho era o defeito que a primeira pré-visualização gravada expôs: na
/// largura de um celular em retrato, cada uma das seis linhas do texto virava
/// duas, e o modelo receberia o dobro de retornos de linha.
///
/// A escala é uma só para todas as linhas. Escalar linha a linha, com um
/// `FittedBox` por linha, daria tamanhos diferentes na mesma página e mudaria
/// a amplitude das sacadas entre uma linha e outra -- justamente uma das
/// características medidas.
///
/// Público, e não privado, para que o teste possa renderizá-lo sem câmera,
/// sem calibração e sem origem de olhar.
class ReadingScreenBody extends StatelessWidget {
  /// Estilo das linhas, antes da escala.
  ///
  /// Exposto para que o teste meça com exatamente o mesmo estilo que a tela
  /// usa: medir com outro estilo validaria uma tela que não existe.
  ///
  /// A família é fixada em Roboto, e não deixada ao padrão da plataforma, por
  /// uma razão de medida: o mesmo texto tem de ocupar a mesma largura em todo
  /// aparelho. Com a fonte variando, a amplitude das sacadas entre palavras
  /// variaria junto, e as características deixariam de ser comparáveis entre
  /// participantes que usaram celulares diferentes.
  static const TextStyle lineStyle = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 26,
    height: 1.4,
    color: Color(0xFF102A43),
  );

  /// Margem lateral da tela de leitura, de cada lado.
  static const double horizontalPadding = 20.0;

  /// Folga deixada na largura, como fração.
  ///
  /// Sem folga, a escala faz a linha mais larga medir exatamente a largura
  /// disponível -- e o arredondamento de subpixel do rasterizador come o
  /// último glifo. Foi o que a pré-visualização mostrou: "muito cedo." virava
  /// "muito cedc". Dois por cento bastam, e o texto também não deve encostar
  /// na borda.
  static const double widthMargin = 0.98;

  /// Piso de legibilidade, em pixels lógicos.
  ///
  /// Abaixo disto o texto deixa de ser confortável para uma criança de nove ou
  /// dez anos, e encolher mais para fazer caber seria resolver um problema de
  /// conteúdo com tipografia. Uma tarefa cujas linhas não caibam neste piso
  /// precisa de linhas mais curtas, e é o que `test/passages_test.dart` cobra.
  static const double minimumFontSize = 17.0;

  final Passage passage;

  /// Chave do bloco das linhas, justo em volta delas: é o retângulo que vai
  /// na sessão (`text_area_deg`) e onde o painel desenha o texto de novo.
  final Key? linesKey;

  const ReadingScreenBody({super.key, required this.passage, this.linesKey});

  /// Largura da linha mais larga da tarefa, no tamanho de base.
  static double widestLine(Passage passage) {
    var widest = 0.0;
    for (final line in passage.lines) {
      final painter = TextPainter(
        text: TextSpan(text: line, style: lineStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
    }
    return widest;
  }

  /// Tamanho de fonte que faz a tarefa inteira caber na largura informada.
  ///
  /// Nunca aumenta: o tamanho de base é o desejado, e a escala só serve para
  /// caber. Nunca desce abaixo de [minimumFontSize] -- se nem assim couber, a
  /// linha é cortada, de forma visível, em vez de virar duas em silêncio.
  static double fittedFontSize(Passage passage, double availableWidth) {
    final widest = widestLine(passage);
    if (widest <= 0 || availableWidth <= 0) return lineStyle.fontSize!;

    final scaled =
        lineStyle.fontSize! * (availableWidth * widthMargin / widest);
    return scaled.clamp(minimumFontSize, lineStyle.fontSize!);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = fittedFontSize(passage, constraints.maxWidth);
          final style = lineStyle.copyWith(fontSize: fontSize);

          // Centrado na altura e encostado à esquerda, como sempre; o Align
          // deixa o bloco do tamanho exato das linhas, para a medida.
          return Align(
            alignment: Alignment.centerLeft,
            child: Column(
              key: linesKey,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in passage.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      line,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: style,
                    ),
                  ),
              ],
            ),
          );
        },
      );
}

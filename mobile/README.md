# EyeLearn no celular

Aplicativo do aluno: a criança lê na tela enquanto a câmera frontal acompanha o
olhar. É **dever de casa** -- celular não entra na escola -- e roda **no
navegador** do celular (iPhone e Android), publicado em
https://tonbarbos.github.io/EyeLearn/. O mesmo código compila também como
aplicativo Android. O **painel do professor** está no mesmo site, em
https://tonbarbos.github.io/EyeLearn/#professor, pensado para a tela do
computador (`lib/src/teacher/`; ver o README principal). A versão anterior do
painel, em PyQt6, continua em `eyelearn/panel`.

> **A criança nunca vê resultado.** A tela final diz que ela terminou, e é tudo.
> A saída pedagógica vai para o professor. Mostrar a uma criança de nove anos
> um rótulo vindo de um modelo cujo valor preditivo positivo na prevalência
> escolar é de cerca de 22% seria o oposto do que o projeto se compromete a
> fazer.

## Como a criança entra

1. O professor manda no grupo das famílias o **link da turma**, copiado do
   painel. O link leva a turma dentro dele.
2. O responsável abre o link e a turma aparece, sem digitar nada. O pacote
   compacto vai depois do `#` (`#p=`, `Roster.compactOf` e
   `Roster.fromCompact`), e o site que serve o aplicativo nunca recebe esse
   pedaço do endereço. Links antigos, cifrados (`#t=`), pedem o código.
3. A criança toca no próprio nome e digita o PIN de quatro dígitos num teclado
   próprio, de teclas grandes.
4. Aparecem as atividades dela: a fazer (com o prazo), feitas, a começar e
   encerradas. Ela escolhe uma e calibra; a leitura começa sozinha depois
   de uma contagem de 3 s.
5. Ao final, a sessão vai sozinha para a caixa de entrega da turma,
   cifrada para o professor (ver "Envio automático" no README principal);
   sem internet, fica guardada e sai na próxima abertura. Sem caixa
   configurada, o responsável envia o arquivo pelo compartilhar do sistema.
   A sessão leva o código do aluno e o da atividade.

A turma, o código e o que cada aluno já fez ficam guardados no aparelho
(`lib/src/session/class_storage.dart`). Quando o professor cria atividade, o
link novo abre sem pedir o código de novo.

- O link leva só "Ana S.", o código e o hash do PIN de cada aluno, e as
  atividades. Nome completo e data de nascimento ficam no computador do
  professor.
- O PIN é conferido no aparelho, offline, por PBKDF2-SHA256
  (`eyelearn_core/lib/src/roster.dart`). O pacote é fechado pelo Python e
  aberto pelo Dart; `test/roster_test.dart` abre um pacote gerado por
  `scripts/make_roster_fixture.py`, e confere os vetores publicados do PBKDF2.
- Cinco PINs errados bloqueiam aquele aluno por um minuto, dobrando a cada
  novo bloqueio. A mensagem pede para esperar e chamar o professor, sem
  vermelho: errar o PIN não é falha da criança.
- O Safari pode apagar o armazenamento de um site que fica semanas sem uso;
  aí basta abrir o link e digitar o código outra vez.

## O olhar no navegador

`web/gaze.js` abre a câmera frontal (`getUserMedia`) e roda o **MediaPipe Face
Landmarker para web** no próprio aparelho, em WebAssembly. Entrega ao Dart, por
quadro, os mesmos 478 pontos (com as íris) que o canal nativo do Android
entrega; o resto do aplicativo não sabe qual está em uso
(`lib/src/gaze/platform_gaze*.dart`). Nenhum quadro de imagem sai do arquivo.

O MediaPipe 1.1.1 e o modelo são servidos pelo próprio site, não por CDN:
`scripts/fetch_mediapipe_web.py` os baixa com conferência de SHA-256 para
`web/mediapipe/` (cerca de 30 MB, fora do git). No primeiro acesso o navegador
baixa uns 35 MB ao todo, que ficam em cache.

Ajustes para o navegador, onde o MediaPipe pode rodar a 15 Hz num celular
modesto, em vez dos 30 Hz do Android:

- a calibração mede cada alvo pelo tempo de olhar parado nele, não por um
  número de quadros, e serve igual a 15 ou a 30 Hz (ver abaixo);
- o site não instala service worker (`web/flutter_bootstrap.js`): com ele,
  o navegador continuava servindo a versão anterior depois de cada
  publicação;
- o piso de qualidade da taxa de amostragem é 15 Hz, não 20: a curva de
  degradação sobre o ETDD70 mostra 82% no texto a 15 Hz com 1° de erro.

## Calibração por permanência

Como o botão do Kinect, em que se segura a mão parada até confirmar: cada um
dos nove alvos é um anel que **enche enquanto o olhar fica parado nele** (1,5
s) e esvazia se o olhar sai, os olhos piscam ou o rosto some. A medida do alvo
é a média só desses quadros, o que tira da conta as olhadas para o lado e as
sacadas atrasadas que a calibração antiga, de tempo fixo, misturava.

Desde o primeiro alvo confirmado aparece um **cursor** onde o aparelho acha
que se está olhando, com um mapa provisório que melhora a cada alvo. A partir
do segundo alvo, olhar parado longe do alvo (mais de 8°) não enche. Se um
alvo passa de 6 s sem confirmar, o raio dobra e a exigência de estabilidade
afrouxa um pouco, para ninguém ficar preso. A regra está em
`eyelearn_core/lib/src/dwell_calibration.dart`, testada sem tela.

## Testar o olhar

Para conferir (e mostrar) que o rastreamento funciona, a tela de entrada tem
**Testar o olhar**, que também abre direto em
https://tonbarbos.github.io/EyeLearn/#olhar. A tela calibra como a atividade e
depois mostra uma bolinha onde o aparelho acha que a pessoa está olhando, com
nove números de referência e uma linha de diagnóstico: quadros por segundo,
porcentagem de quadros com olhar válido, erro da calibração e a posição em
graus (`lib/src/ui/gaze_test_screen.dart`). **Não grava nada e não gera
sessão.**

A bolinha **não aparece na atividade de verdade**, de propósito: quem vê o
próprio olhar na tela passa a persegui-lo, e o percurso gravado deixaria de
ser o da leitura. A bolinha é suavizada só na tela; o que a atividade grava é
o olhar sem suavização.

## Os dois pacotes

| Pacote | O que é | Roda sem Flutter? |
|---|---|---|
| `eyelearn_core` | processamento do olhar, calibração, inferência | **sim** — Dart puro, `dart test` |
| `eyelearn_app` | interface, câmera (nativa e web), fluxo de dever de casa | não — precisa do SDK do Flutter |

A separação é deliberada. Tudo que é cálculo está em `eyelearn_core`, sem
nenhuma dependência de Flutter, e por isso tem suíte que roda em qualquer
máquina e na integração contínua — sem emulador, sem Android. `eyelearn_app` só
tem interface e cola de plataforma.

## O modelo atravessa como JSON, não como TensorFlow Lite

O scikit-learn não exporta para TFLite direto: o caminho passa por ONNX e depois
por TensorFlow, três conversões cujo resultado não é verificável sem rodar as
duas pontas. Os três modelos do estudo — regressão logística, SVM radial e
floresta aleatória — têm função de decisão fechada e curta. `eyelearn/export`
escreve essa função explicitamente em JSON, e `model.dart` a reimplementa.

O aplicativo embarca **um modelo por tarefa** (`assets/model_syllables.json`,
`model_text.json`, `model_pseudotext.json`), regressões logísticas treinadas no
ETDD70 real, e usa o da tarefa da atividade. Um modelo único
para as três tarefas acerta 77%; um por tarefa, de 80% a 86% (ver
`relatorio/BASES-DE-DADOS.md`). Os modelos derivam do ETDD70, sob CC BY 4.0.

O resultado é reprodução exata: a regressão logística concorda com o
scikit-learn em 1e-16, o SVM em 3e-15, e a floresta **bit a bit**. Sem
dependência nativa, e com 2 KB de arquivo em vez de meio megabyte.

### Como a floresta chegou a bit a bit

Na primeira execução dos vetores de ouro a floresta divergia em 2,7e-2. A causa:
as árvores do scikit-learn convertem a entrada para **precisão simples** antes de
percorrer, mas guardam os limiares em precisão dupla. Um valor maior que o
limiar em dupla pode ser menor ou igual depois de reduzido a simples, e a
travessia cai em outra folha — erro de até 1,0 na saída daquela árvore. Os dois
lados reproduzem a conversão.

## Vetores de ouro: o teste que atravessa a fronteira

O pipeline existe duas vezes, em Python e em Dart. Nada garante que concordem,
e a divergência não aparece como erro — aparece como predição diferente.

```
scripts/build_mobile_assets.py          Python calcula e congela
          ↓
mobile/eyelearn_core/assets/golden.json   8 casos, estágio por estágio
          ↓
test/golden_test.dart                    Dart afirma que chega aos mesmos números
```

Os casos incluem percursos degenerados de propósito — vazio, uma amostra só,
piscada do início ao fim, buraco no meio — porque é onde as convenções de cada
linguagem divergem.

A direção contrária também é verificada:
`tool/emit_session_fixture.dart` escreve uma sessão, e
`tests/test_session.py::TestCrossLanguageFormat` a lê em Python.

## Captura do olhar

```
câmera → MediaPipe Face Landmarker (nativo) → 478 pontos → canal → Dart
                                                                     ↓
                            deslocamento da íris → calibração → graus
                                                                     ↓
                                        GazeRecorder → GazeTrace → pipeline
```

**Por que canal nativo.** A estimativa de olhar precisa do centro da íris, que
só existe no modelo do MediaPipe com refinamento de íris (478 pontos). Os
pacotes Flutter disponíveis expõem o ML Kit Face Mesh, de 468 pontos sem íris —
dá para obter pose de cabeça, não olhar. Um percurso construído a partir de pose
de cabeça pareceria funcionar e não mediria leitura.

**Nenhum quadro sai do lado nativo.** Cada quadro é convertido, analisado e
descartado; o que atravessa são coordenadas. O `AndroidManifest.xml` não declara
permissão de internet.

**A piscada entra como `NaN`, não é descartada.** Descartá-la encurtaria o vetor
de tempos sem deixar vestígio, e uma piscada de 300 ms viraria uma sacada de
vinte graus entre as fixações que a cercam.

## Precisão: a ressalva que precisa estar no relatório

A calibração geométrica de `GazeCalibration` entrega erro da ordem de **2 a 4
graus**. Valliappan et al. (2020) relatam 0,6 a 1,0 grau para câmera de celular,
mas com uma rede neural treinada, não com ajuste geométrico.

A grade de degradação do estudo parava em 1 grau — ou seja, **não cobria o ponto
de operação do próprio aplicativo**. Foi estendida até 3 graus. Enquanto a curva
não for medida no ETDD70 até ali, o que o aplicativo produz é captura, não
classificação confiável.

## Identidade visual

Duas tipografias, e a separação não é estética:

| Onde | Fonte | Por quê |
|---|---|---|
| Interface | Outfit | geométrica arredondada, o que uma criança reconhece como aplicativo |
| Texto de leitura | Roboto | é o estímulo medido |

**A área de leitura não recebe decoração.** Nem cor de fundo própria, nem
moldura, nem ilustração ao lado, nem o cartão que todas as outras telas usam.
Qualquer elemento visual perto do texto atrai o olhar e contamina o percurso
que o pipeline vai analisar — e a comparação com o ETDD70, que foi gravado com
texto nu sobre fundo liso, deixaria de valer. Todo o capricho visual do
aplicativo para na borda daquele retângulo.

As duas fontes vão embutidas no aplicativo. No caso do Roboto a razão é de
medida: com a fonte variando entre aparelhos, o mesmo texto ocuparia larguras
diferentes e a amplitude das sacadas entre palavras variaria junto.

O mascote e a comemoração são desenhados em código (`CustomPainter` e formas),
não exportados como imagem: acompanham cor e tamanho sem variantes, e o olho
pisca — a única animação de personagem do aplicativo, sem custo de asset. Na
calibração o mascote não aparece: movimento na periferia puxa o olhar, e ali
isso seria medido como erro.

## Pré-visualização no navegador

`lib/main_demo.dart` roda as telas reais com o pipeline real, trocando apenas a
câmera por uma fonte sintética que emite pontos de rosto a 30 Hz, com a turma
fictícia de `assets/demo_class.json` (código e PINs aparecem na tela). Serve
para ver a interface sem câmera.

```bash
cd mobile/eyelearn_app
flutter pub get
flutter run -d chrome -t lib/main_demo.dart       # pré-visualização
python ../../scripts/fetch_mediapipe_web.py       # uma vez, para o app real
flutter run -d chrome                             # o app real, com câmera
```

Foi assim que apareceram dois defeitos que nenhum teste pegava: a calibração
lançava exceção a cada quadro por um `Positioned` dentro de `LayoutBuilder`, e
as linhas do texto quebravam na largura do celular, dobrando a contagem de
retornos de linha que o modelo receberia. Ambos corrigidos, com testes.

## Rodando

```bash
# Núcleo: roda em qualquer máquina
cd mobile/eyelearn_core
dart pub get
dart test                       # 178 testes: diferencial, PIN e link da turma
dart analyze

# Regerar os ativos embarcados (do lado Python)
cd ../..
python scripts/build_mobile_assets.py
python scripts/build_mobile_assets.py --check   # o que a CI roda
python scripts/make_roster_fixture.py           # pacote de turma de exemplo
```

### Aplicativo web (o que as famílias usam)

```bash
python scripts/fetch_mediapipe_web.py
cd mobile/eyelearn_app
flutter build web --release --no-web-resources-cdn --base-href /EyeLearn/
```

A publicação no GitHub Pages é automática a cada envio à `main`
(`.github/workflows/pages.yml`), depois de ligar uma vez **Settings → Pages →
Source: GitHub Actions** no repositório. A câmera só funciona em https (ou em
`localhost`).

### Aplicativo Android (opcional)

```bash
cd mobile/eyelearn_app
flutter pub get
flutter run
```

Antes do primeiro `flutter run`:

1. **O modelo do MediaPipe não vem no repositório.** Baixe `face_landmarker.task`
   da documentação do MediaPipe Tasks Vision e coloque em
   `android/app/src/main/assets/`. Precisa ser a variante com refinamento de
   íris; a sem íris é recusada em tempo de execução pelos dois lados.
2. `flutter create --platforms=android .` para gerar os arquivos de projeto que
   não estão versionados (Gradle wrapper, recursos, ícones). `AndroidManifest.xml`,
   `MainActivity.kt`, `GazePlugin.kt` e `app/build.gradle.kts` já estão escritos
   e não devem ser sobrescritos.
3. **iOS não está implementado.** O `GazePlugin` tem só a versão Android; a
   equivalente em Swift com MediaPipe Tasks Vision para iOS está pendente.

## O que foi e o que não foi verificado

Verificado: `flutter analyze` sem observações; `flutter test` roda 34 testes
de widget, incluindo a entrada na turma pelo link, o PIN e a lista de
atividades. O **build web real** foi aberto num Chromium com câmera falsa
(uma foto de rosto) e percorreu link, código, nome, PIN e atividade até a
calibração, com a câmera aberta e os quadros do MediaPipe (478 pontos, com
íris) chegando ao Dart.

**Não verificado: um celular de verdade.** Falta medir no Safari do iPhone e
no Chrome do Android a taxa de quadros do MediaPipe, a precisão da calibração e
o compartilhamento do arquivo. No ambiente de desenvolvimento, sem GPU, o
MediaPipe rodou a uns 3 quadros por segundo, o que não diz nada sobre um
celular. É o primeiro teste a fazer com o grupo.

O caminho Android nativo (`GazePlugin.kt`, `AndroidManifest.xml`,
`build.gradle.kts`) **nunca foi compilado**, porque o ambiente não tem o SDK
do Android. O navegador cobre o Android também, então o aplicativo nativo é
opcional.

# EyeLearn no celular

Aplicativo do aluno: a criança lê na tela enquanto a câmera frontal acompanha o
olhar. O painel do professor continua no computador, em PyQt6, como descreve a
seção 4.2 do relatório — a tela grande e os gráficos fazem sentido ali, não num
celular.

> **A criança nunca vê resultado.** A tela final diz que ela terminou, e é tudo.
> A saída pedagógica vai para o professor. Mostrar a uma criança de nove anos
> um rótulo vindo de um modelo cujo valor preditivo positivo na prevalência
> escolar é de cerca de 22% seria o oposto do que o projeto se compromete a
> fazer.

## Login do aluno

O professor cadastra a turma no painel e exporta a **lista da turma**
(`turma_*.eyelearn.json`). No celular, um adulto importa o arquivo uma vez, em
**Importar lista da turma**; a lista fica no diretório de documentos do
aplicativo. Depois disso, a tela inicial mostra os nomes: a criança toca no
dela e digita o PIN de quatro dígitos num teclado próprio, de teclas grandes.

- A lista leva só "Ana S.", o código e o hash do PIN. O nome completo fica no
  computador do professor, e a sessão sai do aparelho com o código.
- O PIN é conferido no aparelho, offline, por PBKDF2-SHA256
  (`eyelearn_core/lib/src/roster.dart`). O mesmo hash é gravado pelo Python, e
  `test/roster_test.dart` confere os dois lados contra uma lista gerada por
  `scripts/make_roster_fixture.py`, além dos vetores publicados do PBKDF2.
- Cinco PINs errados bloqueiam aquele aluno por um minuto, dobrando a cada
  novo bloqueio. A mensagem pede para esperar e chamar o professor, sem
  vermelho: errar o PIN não é falha da criança.
- O seletor de arquivos é o do sistema (`file_picker`), sem permissão de
  armazenamento nem de internet.

## Os dois pacotes

| Pacote | O que é | Roda sem Flutter? |
|---|---|---|
| `eyelearn_core` | processamento do olhar, calibração, inferência | **sim** — Dart puro, `dart test` |
| `eyelearn_app` | interface, câmera, canal nativo | não — precisa do SDK do Flutter |

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
câmera por uma fonte sintética que emite pontos de rosto a 30 Hz. Serve para
ver a interface sem Android, sem câmera e sem o modelo do MediaPipe.

```bash
cd mobile/eyelearn_app
flutter create --platforms=web .      # só na primeira vez
flutter pub get
flutter run -d chrome -t lib/main_demo.dart
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
dart test                       # 165 testes, inclui o diferencial e o do PIN
dart analyze

# Regerar os ativos embarcados (do lado Python)
cd ../..
python scripts/build_mobile_assets.py
python scripts/build_mobile_assets.py --check   # o que a CI roda
python scripts/make_roster_fixture.py           # lista de exemplo do PIN
```

### Aplicativo

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

## O que esta sessão não conseguiu verificar

O aplicativo **compila** (`flutter build web`) e `flutter analyze` passa sem
observações; `flutter test` roda 25 testes de widget, entre eles os da tela do
PIN. A pré-visualização no
navegador foi executada e gravada de ponta a ponta.

O que continua sem verificação é o caminho Android: `GazePlugin.kt`, o
`AndroidManifest.xml` e o `build.gradle.kts` **nunca foram compilados**, porque
o ambiente não tem o SDK do Android. Espere ajustes nas versões do MediaPipe
Tasks Vision e do CameraX, e na conversão de quadro (`image.toBitmap()` exige
CameraX recente). O iOS não está implementado. O `file_picker` também só foi
exercitado no navegador.

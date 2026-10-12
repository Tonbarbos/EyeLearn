# Correções a fazer na Metodologia

Pontos que a implementação do pipeline revelou e que precisam ser ajustados no
documento (`Projeto Integrador IV - EyeLearn.pdf`). Cada um foi verificado em
código; o teste que demonstra está indicado.

## 1. A relação metamórfica do espelhamento está errada (seção 4.4)

**O documento diz:** "espelhar o percurso na horizontal não deve mudar a classe
prevista".

**O problema:** essa relação é falsa para este pipeline, e não por defeito de
implementação. O sentido da leitura é informação, não convenção arbitrária.
Espelhar o eixo horizontal troca sacadas progressivas por regressivas, e a
proporção de regressões é uma das características mais discriminantes do
conjunto. Medido no repositório, o espelhamento leva a proporção de regressões
de **0,14 para 0,81** — a transformação não preserva a classe, ela a destrói.

Se o texto ficar como está, ou o grupo escreve um teste que falha legitimamente,
ou remove das características tudo que lê sentido de leitura — e aí perde
justamente o sinal que a literatura de dislexia aponta como mais forte.

**Redação sugerida:**

> Teste metamórfico: técnica proposta por Chen, Cheung e Yiu (1998) justamente
> para casos em que não existe oráculo. Em vez de conferir a saída isolada,
> verificam-se relações entre entradas e saídas. Três relações são verificadas:
> transladar o percurso inteiro na tela não deve alterar nenhuma característica,
> porque todas são relativas; deslocar a origem do eixo do tempo também não,
> porque o instante de início da gravação é detalhe do aparato; e um ruído
> pequeno não deve inverter a predição. O espelhamento horizontal entra como
> relação de **inversão**, não de invariância: ele troca sacadas progressivas por
> regressivas, e a verificação é que as contagens das duas se troquem
> exatamente. Xie et al. (2011) demonstram a aplicação dessas relações
> especificamente a classificadores de aprendizado de máquina.

**Onde está verificado:** `tests/test_metamorphic.py` — `TestSpatialTranslation`,
`TestTimeOrigin`, `TestUniformScaling`, `TestHorizontalMirror`,
`TestNoiseRobustness`.

## 2. O I-DT precisa de uma ressalva (seção 4.3)

**O documento diz:** que a separação em fixações e sacadas usa "os algoritmos
I-VT, baseado em limiar de velocidade, e I-DT, baseado em dispersão, ambos
descritos e comparados por Salvucci e Goldberg (2000)".

**O problema:** a formulação original do I-DT, aplicada literalmente, fragmenta
o percurso de forma sistemática. A janela cresce até entrar na sacada seguinte,
a fixação emitida termina no meio dela, e a janela seguinte — que abrange o
resto da sacada mais o início da fixação de destino — ainda cabe no limiar de
dispersão. Uma fixação única acaba reportada como duas, com os centroides
deslocados na direção da sacada. Medido no repositório sobre um percurso com 24
fixações conhecidas, o I-DT literal reportava **40**.

A implementação ancora a janela no agrupamento antes de crescer, o que recupera
as 24. É um desvio deliberado da formulação do artigo e precisa estar no texto,
porque afeta a comparação entre os dois detectores — que é um dos resultados
do trabalho.

**Acrescentar ao final do item de pré-processamento:**

> A implementação do I-DT inclui um recorte da janela de dispersão antes de
> fechar cada fixação. Sem ele, a janela absorve as amostras iniciais da sacada
> seguinte e fragmenta a fixação de destino, o que inflaria artificialmente a
> quantidade de fixações e encurtaria sua duração média — duas das
> características usadas na classificação.

**Onde está verificado:** `tests/test_events.py` —
`TestFixationCount::test_recovers_exact_count_from_synthetic_scanpath`, rodado
nos dois detectores.

## 3. O retorno de linha não é regressão (seção 4.3)

**O documento diz:** que entre as características está "a proporção de sacadas
regressivas".

**O problema:** o texto não distingue regressão de retorno de linha. O retorno
de linha também é uma sacada grande para a esquerda, mas é o salto normal para o
início da linha seguinte, obrigatório em qualquer leitor. Contá-lo como
regressão infla a medida em todo mundo e apaga a diferença entre os grupos — que
é exatamente o que a característica deveria capturar.

**Redação sugerida para o item:** "a proporção de sacadas regressivas dentro da
linha, excluídos os retornos de linha".

**Onde está verificado:** `tests/test_events.py` —
`TestSaccadeClassification`; `tests/test_features.py` —
`TestRegressionRatio::test_measured_against_within_line_saccades_only`.

## 4. A janela de suavização estava em amostras, não em tempo (seção 4.3)

**O problema:** o pré-processamento suavizava as coordenadas com uma janela de
cinco amostras. Cinco amostras duram 20 ms a 250 Hz — a taxa do equipamento de
bancada do ETDD70 — e **167 ms a 30 Hz**, a taxa de uma câmera comum. Como uma
sacada de leitura dura cerca de 30 ms, uma média móvel de 167 ms atravessa a
sacada inteira e a apaga.

Medido no repositório: a 30 Hz, um percurso com quatro fixações conhecidas era
reportado como **uma**.

O efeito sobre o experimento principal é pior do que a perda de detecção. Como a
janela se alargava no tempo conforme a taxa caía, a curva de degradação estava
medindo *o alargamento da própria suavização* junto com a perda de precisão
espacial — isto é, medindo em parte um artefato do código em vez do fenômeno.

A janela passou a ser definida em milissegundos e convertida para amostras pela
taxa de cada percurso.

**Acrescentar ao item de pré-processamento:** que a janela de suavização é
definida em tempo, e não em número de amostras, precisamente porque o estudo
compara taxas de amostragem diferentes.

**Onde está verificado:** `tests/test_features.py::TestSmoothingWindow`.

## 5. A grade de degradação não cobria o próprio aplicativo (seção 4.3)

**O problema:** a grade parava em 1 grau de erro espacial, que é a faixa que
Valliappan et al. (2020) relatam para câmera de celular — obtida com uma **rede
neural treinada** e calibração individual.

O aplicativo do aluno usa calibração geométrica sobre o deslocamento da íris,
cujo erro é da ordem de **2 a 4 graus**. Medir a acurácia só até 1 grau e
instalar um aplicativo que opera a 3 seria afirmar sobre o sistema algo que o
experimento não mostra.

A grade foi estendida a 2 e 3 graus. **A curva precisa ser medida no ETDD70 até
ali antes de qualquer afirmação sobre o que o aplicativo entrega.** Enquanto
isso, o que ele produz é captura, não classificação confiável.

**Onde está verificado:**
`tests/test_degradation.py::TestWebcamGrid::test_covers_the_geometric_estimator_operating_point`.

## 6. O limite do I-VT na taxa da câmera (nova ressalva para a seção 4.3)

A 30 Hz uma sacada de leitura ocupa **uma amostra**. A velocidade que a
diferença centrada atribui a essa amostra é a amplitude dividida por dois
intervalos: uma sacada de 2 graus dá exatamente 30 graus por segundo, que é o
limiar do I-VT. A detecção fica equilibrada na fronteira e passa a depender do
último bit da aritmética.

Não é defeito a corrigir — é a resolução do método na taxa disponível, e é
exatamente o tipo de limite que o experimento de degradação existe para medir.
Merece um parágrafo no relatório, porque explica por que a degradação temporal
não é inofensiva como a leitura isolada de Vajs et al. (2023) sugeriria.

**Onde está verificado:** `tests/test_features.py::TestWebcamRateLimit`.

## 7. Números que já podem entrar no relatório

Medidos sobre a coorte sintética, não sobre o ETDD70. Servem para mostrar que o
instrumento de medida funciona; os resultados científicos vêm da base real.

| Indicador | Valor |
|---|---|
| Testes automatizados (Python) | 327 |
| Testes automatizados (Dart) | 136 |
| Cobertura de código (com desvios) | 94% |
| Escore de mutação | 72% (713 de 987 mutantes mortos) |
| Inflação de acurácia causada por vazamento de sujeito | 10,4 pontos |
| Relações metamórficas verificadas | 5 |
| Concordância Python–Dart do pipeline | 8 casos, estágio por estágio |

O escore de mutação de 72% é a linha de base, não um alvo atingido: 274
mutantes sobreviveram, concentrados nos módulos de sinal e de degradação. Subir esse número é trabalho de continuidade e dá material direto
para a disciplina de Teste de Software — cada mutante sobrevivente aponta uma
afirmação que a suíte ainda não faz.

A inflação de 10,4 pontos é o número mais útil dos quatro: ela demonstra, com
medida própria, a afirmação da seção 4.4 de que o vazamento por sujeito é o erro
metodológico mais comum nesse tipo de experimento.

## 8. A fronteira de linguagem precisa aparecer na seção 4.4

O aplicativo extrai as características em Dart, no aparelho; o treino as extrai
em Python. São duas implementações do mesmo cálculo, e nada garante que
concordem. Um limiar diferente ou um limite de laço trocado produz um vetor
ligeiramente diferente, o modelo recebe uma entrada que nunca viu, e a predição
sai errada **sem erro nenhum** — não há exceção, não há valor fora de faixa, só
uma resposta diferente.

A estratégia de verificação ganhou, por isso, uma técnica a mais: **teste
diferencial por vetores de ouro**. O Python congela o que calcula, estágio por
estágio, em um arquivo; a suíte Dart afirma que chega aos mesmos números.
Nenhum dos lados é oráculo isolado, mas a divergência entre os dois é sempre
defeito de um deles.

Encontrou dois defeitos reais na primeira execução:

1. As árvores do scikit-learn convertem a entrada para precisão simples antes de
   percorrê-la, mas guardam os limiares em precisão dupla. Sem reproduzir a
   conversão, a travessia cai em outra folha — erro de até 1,0 na saída daquela
   árvore. Depois da correção, a floresta concorda **bit a bit**.
2. O próprio gerador de vetores de ouro gravava as amostras arredondadas e as
   expectativas em precisão plena, de modo que o arquivo era auto-inconsistente.

**Acrescentar como item da seção 4.4:**

> Teste diferencial entre implementações: o pipeline de extração existe em
> Python, onde o modelo é treinado, e em Dart, onde o aparelho o executa. Um
> arquivo de vetores de referência, gerado pela implementação Python, congela a
> saída de cada estágio para um conjunto de percursos — incluindo casos
> degenerados — e a suíte Dart verifica que a sua implementação reproduz os
> mesmos valores. É a única forma de detectar divergência entre as duas, que de
> outro modo se manifestaria apenas como predição diferente, sem erro.

## 9. Saliency4ASD aparece como base secundária mas não tem uso definido

A seção 4.1 lista a base, e a 4.3 não diz o que fazer com ela. Como está, é uma
base citada sem experimento. Duas saídas: ou definir o experimento (treinar no
ETDD70 e medir a transferência das características para outra condição e outro
tipo de tarefa) ou retirá-la do escopo. O repositório hoje implementa só o
ETDD70.

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

## 4. Números que já podem entrar no relatório

Medidos sobre a coorte sintética, não sobre o ETDD70. Servem para mostrar que o
instrumento de medida funciona; os resultados científicos vêm da base real.

| Indicador | Valor |
|---|---|
| Testes automatizados | 241 |
| Cobertura de código (com desvios) | 94% |
| Escore de mutação | 73% (698 de 956 mutantes mortos) |
| Inflação de acurácia causada por vazamento de sujeito | 10,4 pontos |
| Relações metamórficas verificadas | 5 |

O escore de mutação de 73% é a linha de base da primeira suíte, não um alvo
atingido: 258 mutantes sobreviveram, concentrados nos módulos de sinal e de
degradação. Subir esse número é trabalho de continuidade e dá material direto
para a disciplina de Teste de Software — cada mutante sobrevivente aponta uma
afirmação que a suíte ainda não faz.

A inflação de 10,4 pontos é o número mais útil dos quatro: ela demonstra, com
medida própria, a afirmação da seção 4.4 de que o vazamento por sujeito é o erro
metodológico mais comum nesse tipo de experimento.

## 5. Saliency4ASD aparece como base secundária mas não tem uso definido

A seção 4.1 lista a base, e a 4.3 não diz o que fazer com ela. Como está, é uma
base citada sem experimento. Duas saídas: ou definir o experimento (treinar no
ETDD70 e medir a transferência das características para outra condição e outro
tipo de tarefa) ou retirá-la do escopo. O repositório hoje implementa só o
ETDD70.

# Bases de dados: o que é usado, como é treinado, o que é comparado

Texto de apoio para reescrever a seção 4.1 (Fontes de Dados), o trecho de
modelagem da 4.3 e a seção de resultados. Os números abaixo vêm da execução
sobre o ETDD70 real.

## Situação em 13/10/2026

O experimento **rodou sobre o ETDD70 real** (registro Zenodo 13332134, baixado
em 13/10/2026). Resultados completos, com tabelas e gráficos, em
[`resultados/`](resultados/):

- [`resultados/texto-com-sentido/`](resultados/texto-com-sentido/RESULTADOS.md) -- a tarefa principal;
- [`resultados/todas-as-tarefas/`](resultados/todas-as-tarefas/RESULTADOS.md) -- as três juntas e cada uma sozinha.

Para reproduzir (cerca de 25 minutos num notebook):

```bash
python scripts/run_etdd70.py --etdd70 PASTA_DO_DATA_ZIP --labels dyslexia_class_label.csv
python scripts/run_etdd70.py --etdd70 ... --labels ... --task text --out resultados/texto
python scripts/build_mobile_assets.py --etdd70 ... --labels ...   # modelos do celular
```

### O que a base trouxe de diferente do previsto

| Pressuposto do leitor | Real | Tratamento |
|---|---|---|
| uma coordenada por amostra | **binocular** (olho esquerdo e direito) | média dos dois; o que sobrou quando um se perde |
| tempo em milissegundos | **microssegundos** (4000 entre amostras a 250 Hz) | conferido nos dados; a definição do pymovements declara ms e está errada |
| amostra perdida como célula vazia | **0** | zero vira amostra perdida |
| tela de 24" a 60 cm | 1680 x 1050 px a **65 cm** (o artigo diz 60 a 70) | resolução conferida nas imagens dos estímulos |
| largura física da tela | **não publicada** | 47,4 cm, monitor de 22" em 16:10 -- **suposição** |

A largura da tela é a única suposição restante. Errar ela muda todas as medidas
espaciais pelo mesmo fator, o que a padronização do modelo absorve; o que não
absorve é o limiar de velocidade do I-VT (30 °/s) e o ruído da curva, em graus.
Vale confirmar com os autores (contato no registro do Zenodo).

A qualidade da base é alta: a pior gravação tem 93% de amostras válidas, e
nenhuma das 210 foi descartada pelo filtro de 75%.

## Resultados (ETDD70, 70 participantes, validação 5 x 5 por participante)

### Um modelo por tarefa, não um para as três

| Tarefa | Regressão logística | SVM | Floresta aleatória | AUC (logística) |
|---|---|---|---|---|
| Sílabas | 80,3% | 79,1% | 76,6% | 0,92 |
| **Texto com sentido** | **85,1%** | 83,7% | 81,1% | **0,95** |
| Pseudotexto | 82,3% | 85,7% | 84,6% | 0,92 |
| As três juntas | 77,0% | 77,6% | 77,1% | 0,87 |

Juntar as três tarefas num modelo só **piora** o resultado: o padrão de leitura
de sílabas soltas e o de uma história são diferentes demais, e o modelo não
sabe qual está vendo. O aplicativo sabe -- a tarefa vem da atividade que o professor criou --,
então embarca um modelo por tarefa.

A **regressão logística** é a melhor ou empata em duas das três tarefas. Com
70 participantes, os modelos mais flexíveis não têm dados para mostrar
vantagem; a logística é também a única cujos coeficientes se leem.

Referência: os autores da base relatam cerca de 90% com seu melhor modelo; Vajs
et al. (2023), 88,9% em outra base. Os 85,1% daqui usam só as 14 características
do pipeline, as mesmas que o celular calcula.

### Valor preditivo positivo: o número que justifica não diagnosticar

Mesmo no melhor caso (texto, 85,1%), numa escola com 10% de crianças com
dislexia, **de cada 10 crianças que o modelo apontasse, só 4 teriam dislexia**
(VPP 39,7%). É por isso que o sistema não mostra resultado à criança, não
emite diagnóstico e apresenta ao professor a comparação com a turma, não a
pontuação.

### Curva de degradação (texto com sentido, regressão logística)

| Nível | Acurácia | Diferença pareada |
|---|---|---|
| original (250 Hz) | 85,1% | -- |
| 60 Hz | 84,0% | |
| 30 Hz | 78,3% | |
| 30 Hz + 1,0° | 80,6% | -4,6 pontos |
| **30 Hz + 2,0°** | **77,7%** | **-7,4 pontos** (as 5 repetições entre -5,7 e -10,0) |
| 30 Hz + 3,0° | 78,6% | -6,6 pontos |
| 15 Hz + 1,0° | 81,7% | |

Leitura:

1. **A taxa de amostragem, sozinha, pesa pouco.** De 250 para 60 Hz não muda
   nada; 15 Hz com 1° de ruído ainda fica em 82%. Concorda com Vajs et al.
   (2023), que viram 88,9% → 87,8% de 60 para 30 Hz.
2. **No ponto de operação do aplicativo (30 Hz com 2 a 3° de erro), perdem-se
   cerca de 7 pontos**: de 85% para 78%. A perda é consistente -- nas cinco
   repetições da validação, todas negativas, entre 5,7 e 10 pontos.
3. Com as três tarefas juntas a queda é maior: de 77% para 69% (AUC 0,87 →
   0,77). Mais um motivo para o modelo por tarefa.
4. **O ganho possível está na precisão espacial, não na taxa.** Levar o erro de
   2-3° para 1° -- o que a literatura obtém com redes neurais de estimação do
   olhar (Valliappan et al., 2020) -- recupera parte da perda. Esse é o
   trabalho futuro mais promissor do aplicativo.

**E abaixo de 15 Hz?** A primeira sessão num celular real, pelo navegador,
saiu a 11 Hz. Medido de novo no ETDD70 (regressão logística, 5 x 3
partições, 2° de ruído), a taxa quase não pesa até 10 Hz:

| Nível | Texto | Sílabas |
|---|---|---|
| 30 Hz + 2° | 79,5% | 78,6% |
| 20 Hz + 2° | 78,1% | 81,4% |
| 15 Hz + 2° | 81,0% | 77,1% |
| 10 Hz + 2° | 80,5% | 81,4% |

Por isso o piso de qualidade do aplicativo e do painel desceu de 15 para
10 Hz. A ressalva: no ETDD70 a degradação é limpa (sinal bom subamostrado e
com ruído gaussiano); a câmera real tem tremor e movimento de cabeça, e a
sessão real a 11 Hz detectou só 0,2 fixação por segundo, contra 1,8 do
ETDD70 a 15 Hz. A taxa não é o gargalo; a qualidade do sinal é.

**Sobre as faixas nos gráficos:** as barras de erro são a dispersão entre as 25
partições de teste (cada uma com uns 14 participantes), não o intervalo de
confiança da média. Por isso são largas (cerca de 65% a 95%) e se sobrepõem
entre níveis. Para comparar níveis, a medida certa é a diferença pareada nas
mesmas partições, a da tabela acima.

### Modelos no celular

Os três modelos de regressão logística, um por tarefa, treinados nos 70
participantes, estão em `mobile/eyelearn_core/assets/model_<tarefa>.json` e
substituem o modelo de dados sintéticos usado antes. São CC BY 4.0 por derivarem do ETDD70 --
citar Dostálová et al. (2024).

## 4.1 Fontes de dados (texto proposto)

**ETDD70 (Eye-Tracking Dyslexia Dataset)** é a única base de treino e de
avaliação do trabalho. Reúne gravações de rastreamento ocular de 70 estudantes
tchecos de 9 e 10 anos, 35 com diagnóstico de dislexia e 35 sem dificuldade
de leitura, em três tarefas: leitura de sílabas, de texto com sentido e de
pseudotexto. Foi coletada com rastreador de bancada, aprovada pelo comitê de
ética da Universidade Masaryk e publicada no Zenodo (Dostálová et al., 2024).

Usá-la, em vez de coletar dados próprios, tem três razões. Nenhuma criança
precisa ser gravada para treinar o modelo. Os resultados podem ser comparados
com os de outros trabalhos que usaram a mesma base. E, sendo de bancada, ela
permite o experimento principal do trabalho: degradar o sinal até a qualidade
de uma câmera comum e medir o quanto se perde.

**Coleta própria, só para validar a captura.** Gravações por câmera com os
integrantes do grupo verificam se o módulo de captura do aplicativo funciona.
Não entram em treino nem em avaliação.

### O que entra no modelo

Cada gravação passa pelo mesmo pipeline do aplicativo: descarte de piscadas,
conversão para graus, suavização, separação em fixações e sacadas (I-VT) e
extração de 14 características de leitura -- frequência e duração das
fixações, amplitude das sacadas, proporção de regressões, taxa de troca de
linha, tempo total, entre outras. Gravações com mais de 25% de amostras
perdidas são descartadas e contadas no resultado.

É o **mesmo código** que roda no celular: o pipeline existe em Python e em
Dart, e um teste diferencial garante que os dois produzem as mesmas
características. Sem isso, o modelo seria treinado com uma extração e usado
com outra.

## 4.3 Treino e comparação (texto proposto)

**Validação.** Validação cruzada estratificada com separação por participante,
5 partições repetidas 5 vezes. As três gravações de uma criança ficam sempre
do mesmo lado: com uma no treino e outra no teste, o modelo reconheceria a
criança, não o padrão de leitura, e a acurácia apareceria inflada. A suíte de
testes mede essa inflação numa coorte sintética para mostrar que ela existe.

**Métricas.** Acurácia com intervalo de confiança de 95%, sensibilidade,
especificidade, F1 e área sob a curva ROC. E o **valor preditivo positivo a 10%
de prevalência**: a base é balanceada (metade com dislexia), e uma turma real
não é. O VPP diz, das crianças que o modelo apontaria numa escola, quantas de
fato têm dislexia -- é o número que justifica o sistema não mostrar
resultado à criança e não emitir diagnóstico.

**O que é comparado:**

1. **Modelos**, sobre as mesmas partições: regressão logística (linha de
   base), SVM com núcleo RBF e floresta aleatória. A linha de base existe para
   mostrar se um modelo mais complexo ganha de fato alguma coisa.
2. **Tarefas**: cada uma das três sozinha. Diz qual atividade o aplicativo
   deveria priorizar.
3. **Níveis de degradação**: original, 60 Hz, 30 Hz, 30 Hz com ruído de 0,3°,
   0,6°, 1°, 2° e 3°, e 15 Hz com 1°. Os níveis de 2° e 3° são o ponto de
   operação do aplicativo, que calibra o olhar por um ajuste geométrico sobre
   a íris; os de até 1° correspondem ao que a literatura relata para
   rastreamento por câmera com redes neurais (Valliappan et al., 2020).
4. **Literatura**: Vajs et al. (2023) relatam 88,9% a 60 Hz e 87,8% a 30 Hz
   com características interpretáveis. É a referência para o nível "30 Hz" da
   curva.

**Modelo final.** O aplicativo usa um modelo por tarefa, treinado com todos os
participantes depois da avaliação, exportado como JSON e verificado contra o
scikit-learn até a 12ª casa decimal.

### Divergências com a versão atual do relatório a corrigir

- A seção 4.3 cita **XGBoost** e **rede convolucional 1D**, que não foram
  implementados. Com 70 participantes, uma rede convolucional sobre a série
  bruta tem muito mais parâmetros que exemplos, e o XGBoost dificilmente se
  separa da floresta aleatória. Sugestão: tirar os dois e justificar por esse
  argumento, ou implementar o XGBoost como quarto modelo (é pouco código).
- **Busca em grade** de hiperparâmetros não foi implementada; os modelos usam
  parâmetros fixos. Se entrar, precisa ser *aninhada* (dentro de cada partição
  de treino), ou a busca vaza informação do teste.
- **Saliency4ASD** (seção 4.1), **Rojas-Líbano** (objetivos e justificativa) e
  o README citam segundas bases diferentes entre si. Ver abaixo.

## Segunda base

Decidido: **só ETDD70 neste ciclo.** O relatório deve mover a segunda base para
trabalhos futuros, com o motivo: uma base de outra condição (autismo no
Saliency4ASD, TDAH no Rojas-Líbano) e de outra tarefa (observação livre de
imagens, no Saliency4ASD) não mede o classificador de dislexia. Ela só serviria
para verificar se a **detecção de fixações** se mantém em outro equipamento --
um teste do pipeline, não do modelo -- e isso pode vir depois.

## Referências usadas nesta seção

- Dostálová, N. et al. (2024). *ETDD70: Eye-Tracking Dyslexia Dataset.* Zenodo. https://doi.org/10.5281/zenodo.13332134
- Vajs, I. et al. (2023). *Accessible Dyslexia Detection with Real-Time Reading Feedback through Robust Interpretable Eye-Tracking Features.* Brain Sciences.
- Valliappan, N. et al. (2020). *Accelerating eye movement research via accurate and affordable smartphone eye tracking.* Nature Communications.

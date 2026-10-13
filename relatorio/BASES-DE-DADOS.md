# Bases de dados: o que é usado, como é treinado, o que é comparado

Texto de apoio para reescrever a seção 4.1 (Fontes de Dados) e o trecho de
modelagem da 4.3. Separa o que **já está implementado** do que **ainda não
rodou**, para que o relatório não afirme resultado que o projeto não tem.

## Situação em 13/10/2026

| Item | Situação |
|---|---|
| Leitura do ETDD70 (`eyelearn/data/etdd70.py`) | implementada e testada com arquivos no formato esperado |
| Treino, validação cruzada por participante, métricas | implementados e testados |
| Curva de degradação | implementada e testada |
| Roteiro único do experimento (`scripts/run_etdd70.py`) | pronto; ensaiado na coorte sintética |
| **Execução sobre o ETDD70 real** | **não feita** |
| Modelo embarcado no celular | treinado em **dados sintéticos**; o aplicativo e o painel avisam |
| Segunda base | fora do escopo atual; ver "Segunda base" abaixo |

Ou seja: **não há ainda nenhum número de acurácia do projeto sobre dados
reais.** Toda acurácia que aparecer antes da execução sobre o ETDD70 vem da
coorte sintética e não pode ser citada.

Por que não rodou: o ETDD70 não pode ser redistribuído no repositório, e o
ambiente onde o código foi desenvolvido não tem acesso ao Zenodo. Para rodar:

```bash
# 1. baixar https://doi.org/10.5281/zenodo.13332134 e extrair
# 2. montar labels.csv com as colunas subject,label (0 típico, 1 dislexia)
python scripts/run_etdd70.py --etdd70 CAMINHO --labels CAMINHO/labels.csv
# resultados/RESULTADOS.md, *.csv e degradacao.png
python scripts/build_mobile_assets.py --etdd70 CAMINHO --labels CAMINHO/labels.csv
# troca o modelo sintético do celular pelo treinado na base real
```

**Antes de confiar no primeiro resultado**, conferir com a documentação da
base dois pressupostos do leitor, escritos sem acesso aos arquivos:

1. **Nomes de colunas e unidade do tempo.** O leitor espera `time`, `x`, `y`
   com tempo em milissegundos. Se a base usar outros nomes, basta informar um
   `ColumnMap`; não é preciso mudar código.
2. **Geometria da tela.** O padrão é um monitor de 24 polegadas a 60 cm.
   Toda medida espacial (amplitude de sacada, dispersão, ruído da degradação)
   é convertida para graus com esses números. Um valor errado escala todas as
   características espaciais e desloca a curva de degradação inteira.

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

**Modelo final.** O modelo que vai para o celular é treinado com todos os
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

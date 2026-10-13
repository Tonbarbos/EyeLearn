# EyeLearn

Classificação de padrões de leitura a partir de rastreamento ocular por câmera comum.

Projeto acadêmico do curso de Ciência da Computação do Centro Universitário Espírito-Santense, desenvolvido para a disciplina de Projeto Integrador IV

> **Este sistema não faz diagnóstico.** Ele descreve o padrão de leitura observado e sugere adaptações pedagógicas ao professor. Qualquer avaliação clínica é responsabilidade de profissional habilitado.

## O que faz

1. A criança realiza uma atividade de leitura no celular enquanto a câmera frontal acompanha o olhar.
2. O sistema extrai características do percurso do olhar: fixações, sacadas e regressões.
3. Um modelo treinado em bases públicas classifica o padrão observado.
4. O professor vê o resultado em um painel no computador, comparado com a média da turma.

A criança não vê resultado nenhum: o aplicativo diz que ela terminou, e é tudo.

## Bases de dados

Não coletamos dados de crianças. O treino e a avaliação usam apenas bases públicas já anonimizadas.

| Base | Conteúdo | Acesso |
|---|---|---|
| [ETDD70](https://doi.org/10.5281/zenodo.13332134) | 70 estudantes de 9–10 anos (35 com dislexia), 3 tarefas de leitura | Zenodo, aberta para pesquisa |
| [Rojas-Líbano et al. (2019)](https://doi.org/10.6084/m9.figshare.7218725.v3) | 28 crianças com TDAH + 22 controles, EyeLink 1000 a 1 kHz | Figshare, CC BY 4.0 |

## Onde cada parte roda

| Parte | Plataforma | Tecnologia |
|---|---|---|
| Atividade do aluno | celular | Flutter + MediaPipe, inferência no aparelho |
| Painel do professor | computador | PyQt6 + Matplotlib |
| Treino e experimentos | computador | Python, scikit-learn |

A sessão vai do celular ao painel como um arquivo JSON, pela folha de
compartilhamento do sistema. **Não há servidor**: nada trafega pela rede a
partir do aplicativo, e o aplicativo não declara permissão de internet.

## Estrutura

```
eyelearn/
  trace.py                     percurso do olhar: tempo em segundos, coordenadas em graus
  signal/preprocess.py         descarte de piscadas, conversão de unidades, suavização
  signal/events.py             detecção de fixações e sacadas (I-VT e I-DT)
  features/reading.py          características de leitura
  degradation/degrade.py       subamostragem e ruído espacial
  data/etdd70.py               leitura da base
  models/validation.py         validação cruzada com separação por sujeito
  models/train.py              modelos e métricas
  pipeline.py                  do sinal bruto à matriz de características
  experiments/                 curva de degradação
  export/                      modelo portátil e vetores de ouro para o celular
  session.py                   importa as sessões do celular, compara a turma
  storage/                     SQLite local: credenciais (scrypt) e migrações
  panel/                       painel do professor (PyQt6 + Matplotlib)
  synthetic.py                 percursos sintéticos com estrutura conhecida
tests/                         suíte de testes
scripts/                       geração dos ativos embarcados
mobile/
  eyelearn_core/               núcleo em Dart puro, testável sem Flutter
  eyelearn_app/                aplicativo Flutter do aluno
relatorio/                     relatório do Projeto Integrador IV
```

O aplicativo tem documentação própria em [`mobile/README.md`](mobile/README.md).

## Como rodar

```bash
python -m pip install -e ".[test]"
python -m pytest
```

A base não vem no repositório. Baixe o ETDD70 do Zenodo, extraia e aponte o
caminho:

```python
from eyelearn.data.etdd70 import load_dataset
from eyelearn.experiments.degradation_curve import run_degradation_curve

dataset = load_dataset("caminho/para/etdd70", labels="caminho/para/labels.csv")
curva = run_degradation_curve(dataset.filter_by_quality().traces)
print(curva)
```

Confira a geometria do aparato em `ScreenGeometry` antes de rodar: os valores
padrão descrevem um monitor de 24 polegadas a 60 cm, e um erro ali escala
todas as características espaciais por um fator constante.

## Testes

A suíte não depende do ETDD70 — a base não é redistribuível e a integração
contínua não faz download. No lugar dela, `eyelearn/synthetic.py` gera
percursos cuja quantidade de fixações, sacadas e regressões é conhecida por
construção, o que dá ao detector de eventos o oráculo que o dado real não
oferece.

| Arquivo | O que verifica |
|---|---|
| `test_preprocess.py` | descarte de amostras, suavização, velocidade |
| `test_events.py` | I-VT e I-DT contra o gabarito sintético |
| `test_features.py` | aritmética das características |
| `test_degradation.py` | subamostragem e ruído |
| `test_data.py` | contrato de leitura da base |
| `test_validation.py` | separação por sujeito, e a inflação que o vazamento causa |
| `test_models.py` | métricas, matriz de confusão, valor preditivo positivo |
| `test_properties.py` | invariantes sob entrada arbitrária (Hypothesis) |
| `test_metamorphic.py` | relações entre entrada e saída transformadas |
| `test_experiment.py` | estrutura e aritmética da curva de degradação |
| `test_export.py` | o modelo portátil reproduz o scikit-learn |
| `test_session.py` | importação das sessões e comparação intraturma |
| `test_panel.py` | gráfico do painel, e que ele descreve sem diagnosticar |
| `test_storage.py` | hash de senha e PIN, limite de tentativas, migrações atômicas |

```bash
python -m pytest --cov --cov-report=term-missing   # cobertura
mutmut run && mutmut results                       # escore de mutação
```

O núcleo do aplicativo tem suíte própria, em Dart puro, que inclui o **teste
diferencial** contra o Python: o pipeline existe nas duas linguagens, e a
divergência entre elas não apareceria como erro, apenas como predição
diferente.

```bash
cd mobile/eyelearn_core && dart test
python scripts/build_mobile_assets.py --check      # ativos em dia
```

## Painel do professor

```bash
pip install -e ".[panel]"
python -m eyelearn.panel CAMINHO/DAS/SESSOES
```

Importa os arquivos JSON que o celular exporta, compara a turma e sugere
adaptações. Para experimentar sem celular:

```bash
python scripts/make_demo_class.py --out /tmp/turma
python -m eyelearn.panel /tmp/turma
```

O que o painel mostra, e o que ele recusa mostrar:

- **Escore z por característica**, não a pontuação do modelo. A comparação é
  contra a turma da criança, não contra um modelo clínico: o modelo foi
  treinado numa base tcheca, e "lê mais devagar que a maioria dos colegas" é
  acionável pelo professor enquanto "pontuação 0,62" não é.
- **Sugestões de adaptação pedagógica**, nunca um rótulo de condição. Não há no
  painel nenhuma tela, campo ou frase que atribua diagnóstico, e
  `tests/test_panel.py` trata isso como requisito verificável.
- **Gravações de qualidade ruim aparecem marcadas**, não escondidas. Uma sessão
  que some sem explicação levaria o professor a repetir a atividade sem saber
  por quê.
- **Âmbar e violeta no gráfico, não verde e vermelho.** Estar acima da média em
  duração de fixação é uma observação, não um defeito; o semáforo diria o
  contrário. O par passa nos critérios de contraste e de separação para
  daltonismo (ΔE 33 em protanopia), e quem sai da faixa da turma ganha contorno
  — destaque que sobrevive à impressão em preto.

## Tecnologias

**Treino e experimentos**

- **Python 3.11**, **NumPy**, **Pandas**, **Scikit-learn**
- **Pytest**, **Hypothesis**, **Mutmut** — testes

**Aplicativo do aluno (celular)**

- **Flutter** e **Dart** — interface e núcleo de processamento
- **MediaPipe Face Landmarker** — pontos do rosto e centro da íris, no aparelho
- Inferência local a partir de um artefato JSON exportado do scikit-learn, sem
  TensorFlow Lite e sem dependência nativa de aprendizado de máquina

**Painel do professor (computador)**

- **PyQt6** e **Matplotlib**

## Privacidade

Os quadros da câmera são processados na memória do próprio aparelho e descartados logo após a extração das coordenadas do olhar. Nenhuma imagem de rosto é gravada ou enviada pela rede — o aplicativo não declara permissão de internet, e a sessão sai dele como arquivo, por ação de um adulto.

A sessão não carrega nome de criança, apenas um código pseudônimo cuja correspondência fica com o professor, fora do aplicativo. Também não carrega o percurso bruto do olhar: só as características agregadas, que é o que o painel precisa.

Imagem facial é dado biométrico e, portanto, dado pessoal sensível segundo a [Lei Geral de Proteção de Dados](https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm).

## Equipe

Ana Luiza Menelli Taylor · Danton Barbosa Torres Amorim · Felipe Valério Rocha · Karoliny Vicente Franco

Orientação: prof. Howard Cruz Roatti


GPL-3.0

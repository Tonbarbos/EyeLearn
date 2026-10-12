# EyeLearn

Classificação de padrões de leitura a partir de rastreamento ocular por webcam.

Projeto acadêmico do curso de Ciência da Computação do Centro Universitário Espírito-Santense, desenvolvido para a disciplina de Projeto Integrador IV

> **Este sistema não faz diagnóstico.** Ele descreve o padrão de leitura observado e sugere adaptações pedagógicas ao professor. Qualquer avaliação clínica é responsabilidade de profissional habilitado.

## O que faz

1. A criança realiza uma atividade de leitura na tela enquanto a webcam acompanha o olhar.
2. O sistema extrai características do percurso do olhar: fixações, sacadas e regressões.
3. Um modelo treinado em bases públicas classifica o padrão observado.
4. O professor vê o resultado em um painel, comparado com a média da turma.

## Bases de dados

Não coletamos dados de crianças. O treino e a avaliação usam apenas bases públicas já anonimizadas.

| Base | Conteúdo | Acesso |
|---|---|---|
| [ETDD70](https://doi.org/10.5281/zenodo.13332134) | 70 estudantes de 9–10 anos (35 com dislexia), 3 tarefas de leitura | Zenodo, aberta para pesquisa |
| [Rojas-Líbano et al. (2019)](https://doi.org/10.6084/m9.figshare.7218725.v3) | 28 crianças com TDAH + 22 controles, EyeLink 1000 a 1 kHz | Figshare, CC BY 4.0 |

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
  synthetic.py                 percursos sintéticos com estrutura conhecida
tests/                         suíte de testes
relatorio/                     relatório do Projeto Integrador IV
```

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

```bash
python -m pytest --cov --cov-report=term-missing   # cobertura
mutmut run && mutmut results                       # escore de mutação
```

## Tecnologias

- **Python 3.11**
- **OpenCV** e **MediaPipe Face Landmarker** — captura e estimativa do olhar
- **NumPy**, **Pandas**, **Scikit-learn**, **XGBoost** — modelagem
- **PyQt6** e **Matplotlib** — interface do aluno e painel do professor
- **Pytest**, **Hypothesis**, **Mutmut** — testes

## Privacidade

Os quadros da webcam são processados na memória do próprio computador e descartados logo após a extração das coordenadas do olhar. Nenhuma imagem de rosto é gravada ou enviada pela rede.

Imagem facial é dado biométrico e, portanto, dado pessoal sensível segundo a [Lei Geral de Proteção de Dados](https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm).

## Equipe

Ana Luiza Menelli Taylor · Danton Barbosa Torres Amorim · Felipe Valério Rocha · Karoliny Vicente Franco

Orientação: prof. Howard Cruz Roatti


GPL-3.0

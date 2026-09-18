# EyeLearn

Classificação de padrões de leitura a partir de rastreamento ocular por webcam.

Projeto acadêmico do curso de Ciência da Computação do Centro Universitário Espírito-Santense, desenvolvido para as disciplinas de Inteligência Artificial e Teste de Software.

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

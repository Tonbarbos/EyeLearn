# EyeLearn

Classificação de padrões de leitura a partir de rastreamento ocular por câmera comum.

Projeto acadêmico do curso de Ciência da Computação do Centro Universitário Espírito-Santense, desenvolvido para a disciplina de Projeto Integrador IV

> **Este sistema não faz diagnóstico.** Ele descreve o padrão de leitura observado e sugere adaptações pedagógicas ao professor. Qualquer avaliação clínica é responsabilidade de profissional habilitado.

## O que faz

A atividade é **dever de casa** (celular não entra na escola):

1. O professor cria as atividades no painel e manda às famílias um link e um código de turma.
2. Em casa, a criança abre o link no celular (iPhone ou Android, pelo navegador), escolhe o nome, digita o PIN e lê enquanto a câmera frontal acompanha o olhar.
3. O aparelho extrai as características do percurso do olhar (fixações, sacadas, regressões) e o responsável envia o arquivo da sessão ao professor.
4. O professor importa as sessões e vê, no painel, cada criança comparada com a turma.

A criança não vê resultado nenhum: o aplicativo diz que ela terminou, e é tudo.

## Bases de dados

Não coletamos dados de crianças. O treino e a avaliação usam apenas bases públicas já anonimizadas.

| Base | Conteúdo | Acesso |
|---|---|---|
| [ETDD70](https://doi.org/10.5281/zenodo.13332134) | 70 estudantes de 9–10 anos (35 com dislexia), 3 tarefas de leitura | Zenodo, aberta para pesquisa |

É a única base de treino e avaliação. Resultado principal, com validação
cruzada por participante:

| | Acurácia | AUC |
|---|---|---|
| Texto com sentido, sinal do rastreador de bancada | 85,1% | 0,95 |
| Mesmo texto, degradado a 30 Hz com 2° de erro (o do aplicativo) | 77,7% | 0,86 |

Mesmo no melhor caso, numa escola com 10% de prevalência, de cada 10 crianças
apontadas só 4 teriam dislexia -- por isso o sistema não diagnostica. Tabelas,
curva de degradação e discussão em
[`relatorio/BASES-DE-DADOS.md`](relatorio/BASES-DE-DADOS.md) e
[`relatorio/resultados/`](relatorio/resultados/). Para reproduzir:

```bash
python scripts/run_etdd70.py --etdd70 PASTA_DO_DATA_ZIP --labels dyslexia_class_label.csv
```

## Onde cada parte roda

| Parte | Plataforma | Tecnologia |
|---|---|---|
| Atividade do aluno | navegador do celular (iPhone e Android); app Android opcional | Flutter + MediaPipe, tudo no aparelho |
| Painel do professor | navegador do computador, no mesmo site | Flutter web; dados cifrados no próprio navegador |
| Treino e experimentos | computador | Python, scikit-learn |

O aplicativo do aluno fica publicado em **https://tonbarbos.github.io/EyeLearn/**
(GitHub Pages, por `.github/workflows/pages.yml`, a cada envio à `main`). É só
um site estático: **não há servidor com dado de turma**. A turma chega no
link, e a sessão vai do celular ao painel como um arquivo JSON, pelo
compartilhar do sistema.

O painel do professor está no mesmo endereço, em
**https://tonbarbos.github.io/EyeLearn/#professor** (ou pelo botão "Sou
professor" na tela de entrada).

No primeiro acesso o navegador baixa cerca de 35 MB (o aplicativo, o MediaPipe
e o modelo do rosto), que ficam em cache. Vale avisar as famílias para abrir
o link no Wi-Fi.

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
  storage/                     banco SQLite do painel: professores, turmas, alunos, sessões
  panel/                       versão anterior do painel, para computador (PyQt6)
  synthetic.py                 percursos sintéticos com estrutura conhecida
tests/                         suíte de testes
scripts/                       geração dos ativos embarcados
mobile/
  eyelearn_core/               núcleo em Dart puro, testável sem Flutter
  eyelearn_app/                aplicativo Flutter: atividade do aluno e painel do professor
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
from eyelearn.data.etdd70 import load_etdd70
from eyelearn.experiments.degradation_curve import run_degradation_curve

dataset = load_etdd70("caminho/para/data", labels="caminho/para/dyslexia_class_label.csv")
curva = run_degradation_curve(dataset.filter_by_quality().traces)
print(curva)
```

A geometria do aparato do ETDD70 está em `ETDD70_GEOMETRY`; a largura física
da tela não é publicada pelos autores e é uma suposição documentada no
próprio módulo.

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
| `test_storage.py` | banco: senha e PIN, bloqueio, migrações, isolamento entre professores, exclusão |
| `test_panel_accounts.py` | telas de login e de cadastro (precisa de PyQt6) |

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

Abra **https://tonbarbos.github.io/EyeLearn/#professor** no computador. Na
primeira vez, o painel pede seu nome, um usuário e uma senha. Depois:

1. **Nova turma**, e em **Alunos** cadastre as crianças (um nome por linha).
   Cada uma recebe um código e um PIN de 4 dígitos, mostrado uma vez; o painel
   deixa copiar a lista para imprimir os bilhetes.
2. Em **Atividades e link**, crie o dever de casa (leitura, dia de início e
   prazo) e copie a mensagem com o link para o grupo das famílias. O código
   da turma vai à parte (bilhete na agenda ou outra mensagem).
3. Em casa, o responsável abre o link e digita o código uma vez; a criança
   escolhe o nome, digita o PIN e vê as atividades pendentes.
4. As sessões voltam como arquivos (WhatsApp, e-mail). Salve-os no
   computador e importe todos de uma vez em **Sessões**. A lista de
   atividades mostra quantos alunos já entregaram cada uma.
5. Em **Leitura da turma**, cada criança aparece comparada com a turma, por
   característica, com as sugestões de adaptação.

**Onde ficam os dados.** Não há servidor nem conta online. Tudo do professor
fica num *cofre*: um arquivo cifrado com a senha dele (AES-256-GCM, chave
PBKDF2-SHA256 com 200 mil iterações, calculada pelo WebCrypto do navegador),
guardado no armazenamento do site, no próprio navegador
(`lib/src/teacher/`, `mobile/eyelearn_core/lib/src/teacher_vault.dart`).
Duas consequências que o painel explica antes de criar o cofre:

- **Não há como recuperar a senha.** Ninguém além do professor a conhece.
- **O navegador pode apagar os dados do site** (limpeza de histórico, outro
  computador). Por isso o painel pede a **cópia de segurança**: o mesmo cofre
  cifrado, num arquivo, para guardar fora do computador. Ela abre em
  qualquer navegador, com a mesma senha, por "Restaurar uma cópia de
  segurança". O painel lembra quando a cópia está velha.

**O link leva a turma cifrada**, depois do `#` -- parte do endereço que o
navegador não envia ao servidor. O site que serve o aplicativo (GitHub Pages)
nunca vê nome de aluno. A cifra é AES-256-GCM com chave derivada do código da
turma: um link encaminhado para fora do grupo, sem o código, não abre. O link
muda quando o professor cria atividade ou mexe nos alunos e precisa ser
mandado de novo; o código continua o mesmo, e o aplicativo o lembra.

O painel é a porta em Dart do painel Python. Os testes conferem os dois lados
contra os mesmos arquivos: o link gerado no navegador sai igual, byte a byte,
ao que o Python gera com o mesmo sal e nonce, e a comparação com a turma dá os
mesmos escores (`mobile/eyelearn_core/test/teacher_vault_test.dart`,
`class_comparison_test.dart`).

### Versão anterior: painel para computador (PyQt6)

O primeiro painel, em PyQt6 com banco SQLite, continua no repositório
(`eyelearn/panel`, `eyelearn/storage`). Faz o mesmo que o painel web, mas
precisa de Python instalado no computador da escola, e foi isso que o painel
web resolveu. As regras (PIN, códigos, formato do link, comparação) são as
mesmas nos dois.

```bash
pip install -e ".[panel]"
python -m eyelearn.panel
```

O banco é um arquivo SQLite na pasta de dados do usuário
(`%APPDATA%\EyeLearn\eyelearn.db` no Windows, `~/.local/share/eyelearn/` no
Linux); `--db ARQUIVO` usa outro.

Para experimentar com uma turma fictícia já cadastrada (login `demo`, senha
`demonstracao`):

```bash
python scripts/make_demo_class.py --out /tmp/turma --db /tmp/demo.db
python -m eyelearn.panel --db /tmp/demo.db
python -m eyelearn.panel /tmp/turma          # ou só as sessões, sem banco nem login
```

### Banco de dados da versão anterior

O esquema (`eyelearn/storage/schema.py`) parte do banco do projeto anterior,
EyeLearn-Apollo, que usava MySQL com as tabelas `Alunos`, `Sessoes` e
`Diagnosticos`. O que mudou e por quê:

| Antes (MySQL) | Agora (SQLite) | Motivo |
|---|---|---|
| servidor MySQL, senha no código | um arquivo, sem servidor | nada trafega pela rede; nada a configurar na escola |
| sem login: o aluno escolhia o nome numa lista, o professor entrava direto | professor com usuário e senha; aluno com link e código da turma, nome e PIN | um professor não vê os alunos de outro; uma criança não grava sessão no nome da colega |
| tabela `Diagnosticos` ("Possível TDAH", "Possível Dislexia") | não existe | o sistema não diagnostica, e o banco não tem onde gravar rótulo |
| `genero` | não existe | nenhuma parte do pipeline usa (LGPD, art. 6º, III) |
| escola, série e turma repetidas em cada aluno | tabela `turmas` | "5A" e "5º A" viravam duas turmas |
| pontuação, erros, caminho do mapa de calor | JSON da sessão, como veio do celular | as medidas agora são as do percurso do olhar |

Senha e PIN são gravados como hash com sal (scrypt e PBKDF2-SHA256); depois de
cinco erros seguidos, o login fica bloqueado por um minuto, e o bloqueio dobra a
cada repetição. O PIN de quatro dígitos tem dez mil combinações e não resiste a
quem tiver o arquivo do banco: quem o protege é o bloqueio na tela, e o arquivo
ficar no computador do professor.

### O que o painel mostra, e o que ele recusa mostrar

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

**Aplicativo do aluno (navegador do celular)**

- **Flutter** e **Dart** — interface e núcleo de processamento, compilados para web
- **MediaPipe Face Landmarker** (Apache 2.0) — pontos do rosto e centro da íris, no aparelho, em WebAssembly
- **AES-256-GCM** (pointycastle no Dart, cryptography no Python) — a turma cifrada no link
- Inferência local a partir de um artefato JSON exportado do scikit-learn, sem
  TensorFlow Lite e sem dependência nativa de aprendizado de máquina

**Painel do professor (navegador do computador)**

- **Flutter** e **Dart**, compilados para web, no mesmo site do aplicativo do aluno
- **WebCrypto** (PBKDF2) e **AES-256-GCM** — o cofre do professor, cifrado com a senha dele
- Versão anterior: **PyQt6** e **Matplotlib** (`eyelearn/panel`)

## Privacidade

Os quadros da câmera são processados na memória do próprio aparelho e descartados logo após a extração das coordenadas do olhar. Nenhuma imagem de rosto é gravada ou enviada pela rede. No navegador, o MediaPipe roda no aparelho (WebAssembly) e é servido pelo próprio site, sem CDN de terceiros; o site entrega só o aplicativo e não recebe nada de volta. A sessão sai do aparelho como arquivo, por ação de um adulto.

A sessão não carrega nome de criança, apenas um código pseudônimo. Também não carrega o percurso bruto do olhar: só as características agregadas, que é o que o painel precisa.

O nome completo e a data de nascimento ficam só no cofre do professor, no navegador dele, cifrados com a senha que só ele conhece. O link da turma leva, cifrados, o primeiro nome com a inicial do sobrenome ("Ana S."), o código e o PIN em forma de hash -- é o mínimo para a criança se reconhecer na tela. Quem tem o link e o código (as famílias do grupo) consegue ver esses nomes de exibição, como já vê no grupo da turma. Apagar um aluno no painel apaga junto todas as sessões dele (LGPD, art. 18, VI).

Imagem facial é dado biométrico e, portanto, dado pessoal sensível segundo a [Lei Geral de Proteção de Dados](https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm).

## Equipe

Ana Luiza Menelli Taylor · Danton Barbosa Torres Amorim · Felipe Valério Rocha · Karoliny Vicente Franco

Orientação: prof. Howard Cruz Roatti


GPL-3.0

---
layout: post
title: "La code quality dell'informatico pigro"
date: 2026-04-30
categories: [python]
tags: [pytest, ruff, pyright, uv]
repo: bilardi/python-prototype
lang: it

---

![Flow](https://raw.githubusercontent.com/bilardi/python-prototype/master/docs/images/code.quality.vertical.flowchart.png)

## Un repo da rinnovare, tante ricerche da fare

Tempo fa, alla PyCon IT, ho partecipato a un talk che mi ha illuminato su [pytest](https://pypi.org/project/pytest/):

- gestione più semplice dei test, specialmente per i mock
- fixture parametrizzabili al posto del rituale di `setUp` / `tearDown`
- l'`assert` nudo invece dei mille `self.assertEqual`

Vorrei che il mio repo [python-prototype](https://github.com/bilardi/python-prototype/), nato a scopo didattico, fosse anche un po' un template da sfruttare per i prossimi progetti.

Quindi, con la scusa di rimodernare il sistema di testing con pytest e di packaging con [pyproject](https://packaging.python.org/en/latest/guides/writing-pyproject-toml/), stavo pensando di aggiungere dell'altro.

Era da parecchio che sfruttavo [black](https://pypi.org/project/black/) e [pylint](https://pypi.org/project/pylint/), quindi il primo pensiero è stato: ok, integriamo anche formatting e linting. Ma mi sono chiesta: non c'è di meglio che mantenga in automatico lo stile ([PEP 8](https://peps.python.org/pep-0008/)), le docstring ([PEP 257](https://peps.python.org/pep-0257/)) e i type hints ([PEP 484](https://peps.python.org/pep-0484/)) ?

E l'environment, si può modernizzare anche quello ? Con cosa ? Beh, come ci sono le due scuole, emacs e vi, ci sono anche le due scuole, [poetry](https://python-poetry.org/) e [uv](https://docs.astral.sh/uv/) .. senza nemmeno nominare tutti gli altri.

C'era da scegliere qualcosa che coprisse code quality, formatting, packaging e oltre: meno attività lasciate al ricordo o alla lettura del santo README, più probabilità che vengano fatte davvero.

Visto che non esiste un "pacchetto tutto incluso", c'era da testare ciò che era mantenuto e mantenibile, e trovare quello più adatto alle necessità.

## Lo stack scelto oggi

Quattro tool, non dieci:

- **uv**: l'env manager. Un binario in Rust al posto di `pip`, `venv`, `pyenv` e `pipx`. Con poetry, gli ultimi due non sono coperti e vanno installati a parte: meno strumenti satellite intorno.
- **[ruff](https://docs.astral.sh/ruff/)**: formatting e linting. Rimpiazza `black`, `isort`, `flake8` e la gran parte di `pylint`. Un altro binario in Rust.
- **[pyright](https://microsoft.github.io/pyright/)**: il type checker. Scartando [mypy](https://mypy-lang.org/), [pyrefly](https://pyrefly.org/) e [ty](https://github.com/astral-sh/ty). Per il momento.
- **[pre-commit](https://pre-commit.com/)**: git-hook che fa girare ruff e pytest automaticamente prima di ogni commit. Basta .. ricordarsi di impostarlo a inizio progetto !

Il criterio che ha guidato tutte queste scelte è uno solo: **meno sforzo totale**. Meno tool = meno config = meno manutenzione. L'informatico pigro vuole che la toolchain si spacchi prima del commit, se ci si dimentica qualche passaggio. Ma senza esagerare: quanto basta a produrre codice di qualità.

## Storie dal campo

### Pylint e il voto 4.35/10

Il primo giro di pylint su simple-sample fa male: 4.35/10. Un rate da superiori, non da repo didattico. Si scende a correggere il mio strascico JavaScript: `myClass` diventa `my_class` (naming PEP 8), `foo` e `bar` e `foobar` diventano `get_param_processing`, `get_boolean`, `get_reverse_protected_param` (nomi che dicono cosa fanno). Si risale a 9.41/10.

Ma prima di quotare il voto come vittoria, vanno decisi tre casi di warning:

- **W0223**: metodo astratto non implementato in una sottoclasse. Pylint lo segnala come bug da sistemare. Nel mio caso invece DEVE fallire: è parte dell'esempio didattico. Lo tengo.
- **C0301**: linea troppo lunga. Guardo: è un link HTTP in una docstring, non si taglia. Lo ignoro.
- **C0104**: nomi come "foo" e "bar" sono disallowed. Potrei disabilitare la regola globalmente, ma qui preferisco aver speso l'ora di ristrutturazione: le variabili e i metodi devono essere parlanti.

Ognuna di queste decisioni è un "il tool ha ragione sul codice ma non sul contesto". Ed è qui che emerge il limite di pylint: ti dice cosa ha trovato, ma non se serve davvero sistemarlo. La decisione caso per caso resta tua: lui non modifica nulla.

### Pylint non capisce pytest

Mi invento di farmi male, e faccio girare pylint sulla suite di test: arriva un warning nuovo, W0621 `redefining-outer-name`, sulle fixture:

```python
@pytest.fixture
def mci():
    return MyClassInterface()

def test_mci_creation(mci):
    assert isinstance(mci, MyClassInterface)
```

Pylint dice "stai ridefinendo `mci` dello scope esterno". Però il pattern è la base del funzionamento delle fixture: non è una ridefinizione, è l'iniezione del parametro. Pylint legge il codice come se lo eseguisse, ma non sa come pytest lo esegue.

Falso positivo. La fix di circostanza esiste:

```python
@pytest.fixture(name="mci")
def mci_fixture():
    return MyClassInterface()

def test_mci_creation(mci):
    assert isinstance(mci, MyClassInterface)
```

Ma è per far stare zitto pylint, non per migliorare il codice. Non la metto. E qui inizio a pensare che pylint è vecchio per pytest e che bisogna cambiare tool.

### Ruff arriva e prende il posto di black

Provo `ruff check` e `ruff format`. Copre praticamente tutto quello che faceva black per il formatting, e una buona parte di quello che faceva pylint per il linting. Un binario. Config in `pyproject.toml`: una sola sezione al posto di due. Tempo di esecuzione: millisecondi.

Ruff dichiara apertamente il trade-off: è AST-based e lavora sul singolo file, non "legge" la gerarchia delle classi tra file. Quindi l'abstract method non overridden, che a me serve vedere, non lo vede. Ruff è un linter di superficie fatto veloce, non un analista profondo.

Ok. Ruff prende il posto di black e copre buona parte di pylint. Per quello che mi manca (abstract method, consistenza di tipo tra file) mi serve un altro strumento: un type checker.

### Il giro dei type checker

Pylint trovava errori di typing e di scoping (W0621 è un check di stile, non di tipo). Scegliendo un type checker mi concentro sul fronte tipi: il fronte scoping resta fuori da questo giro.

Aggiungo type hints ovunque, altrimenti i type checker darebbero un mare di rossi (non avrebbero niente da controllare): la firma `def get_param_processing(self, param):` diventa `def get_param_processing(self, param: bool) -> bool:`.

Poi lancio mypy, pyrefly, ty, pyright sullo stesso codice per vedere chi identifica cosa.

| Tool | Metodo astratto non implementato | Return None dove type hint dice bool | Altro |
|------|----------------------------------|--------------------------------------|-------|
| mypy | sì | sì | storico, lento |
| pyrefly | in forma diversa | sì | fulmineo, giovane |
| ty | sì (solo interfaccia) | sì | fulmineo, giovane |
| pyright | sì | sì | segnala anche un terzo errore: il metodo viene usato in MyClass |

Pyright trova più cose e ha un ecosistema maturo: Microsoft lo mantiene attivamente, e Pylance (l'estensione Python di VS Code) è costruita sopra pyright. Vince pyright. Pyrefly e ty sono in fase di sviluppo attivo: li rivaluterò più avanti.

### Il workflow che si rompe al primo `make patch`

Setup completato. Ruff passa clean. Pyright passa clean. Pre-commit mi ferma se dimentico qualcosa. Lancio `make patch` per il primo release "vero" .. e:

```
make[1]: bump-my-version: No such file or directory
```

Il Makefile chiamava `bump-my-version` nudo, e le dev-deps del progetto stavano in `tests/requirements-test.txt`, non in `pyproject.toml`. Così chi clonava il repo doveva sapere di fare un `pip install -r tests/requirements-test.txt` oltre a `uv sync`, e il workflow di release assumeva che il venv fosse attivato. Troppa conoscenza implicita, troppo sbatti.

Oramai sono abituata a usare `uv run` e non lancio più `source .venv/bin/activate`, e così mi sono ritrovata a fare qualcosa che "alla vecchia maniera" non mi sarebbe mai successo.

Cosa è servito fare per avere l'ambiente gestito davvero da uv ? Beh, è bastato aggiungere in `pyproject.toml` tutte le dipendenze con:

```bash
uv add --dev -r tests/requirements-test.txt
```

Un comando solo. uv legge il requirements file, scrive tutto in `[dependency-groups].dev` di `pyproject.toml` (lo standard introdotto da [PEP 735](https://peps.python.org/pep-0735/) per le dev-deps), aggiorna `uv.lock`, e installa. Il file `tests/requirements-test.txt` diventa ridondante: un file in meno da gestire.

E poi nel Makefile ho aggiunto `uv run` davanti a ogni comando Python:

```make
release:
    uv run bump-my-version bump $(PART)
    $(MAKE) changelog
    git tag -f v$$(uv run python -c "from simple_sample import __version__; print(__version__)")
    git push && git push --tags --force
```

Ora `make patch` funziona anche da una shell vergine, senza attivare niente. Il venv non è più una convenzione tribale, è implicito in ogni comando.

### Sette sezioni in `pyproject.toml`, una per tool

`pyproject.toml` nasce per il packaging e da lì ha raccolto le sezioni di config dei tool del progetto: sette in totale.

**ruff** parte da `select = ["ALL"]`: abilito tutte le regole disponibili e uso `ignore` per quelle che considero troppo. Filosofia "tutto in default, escludo per nome": man mano che ruff aggiunge regole nuove, le adotto in automatico. E il pacchetto "ALL" non è solo style + lint: include anche regole di naming (PEP 8), docstring (PEP 257), type annotations (PEP 484, con `flake8-annotations`), complessità ciclomatica (`mccabe`), security elementare (`bandit-base`), import order (`isort`). Ruff non è "solo" un formatter + linter, è l'ombrello sotto il quale stanno black + isort + flake8 + pezzi di pylint, pydocstyle e bandit.

**pyright** in `typeCheckingMode = "strict"`: il default `basic` chiude un occhio su molte cose, `strict` pretende type hints completi e ritorni espliciti. È la modalità che fa emergere quegli errori che il giro dei type checker aveva rilevato (e che mypy / pyrefly / ty con la configurazione di default avrebbero perso).

**pytest**: configurazione minimale, `asyncio_mode = "auto"` e `testpaths = ["tests"]`. Il resto sta nei test stessi.

**[dependency-groups].dev**: la lista delle dev-deps con i version constraint (PEP 735). uv legge questa sezione per `uv sync --group dev`.

**packaging** (`[build-system]`, `[project]`, `[tool.setuptools]`), **bumpversion**, **git-cliff**: gestiscono la pipeline di release (metadata + dipendenze runtime + build di wheel e sdist + versioning + CHANGELOG dai conventional commits). Argomento diverso dal code quality, ma necessario allo scopo della modernizzazione e dell'automazione.

**pre-commit** sta in `.pre-commit-config.yaml` (fuori da `pyproject.toml`): punta al repo ufficiale `astral-sh/ruff-pre-commit` per i due hook ruff (check + format) e tiene un local hook che lancia `uv run pytest` per i test. Così anche pre-commit si appoggia a uv per accedere al venv del progetto, esattamente come i target del Makefile.

## Plus

L'informatico pigro aggiunge tool quando realmente servono, quando è il momento di gestire in automatico qualche altro aspetto.

Sempre sulla code quality, cosa si potrebbe aggiungere e quando ?

- **[vulture](https://pypi.org/project/vulture/) e [radon](https://pypi.org/project/radon/)**: dead code a livello di progetto e report di complessità. Quando serve una mappa del codebase, per esempio prima di un refactor importante: ruff vede il singolo file, vulture e radon vedono l'insieme della codebase.
- **[bandit](https://pypi.org/project/bandit/) (SAST), [pip-audit](https://pypi.org/project/pip-audit/) (SCA) e [detect-secrets](https://pypi.org/project/detect-secrets/)**: se il pacchetto diventa un'API o gestisce dati sensibili, ma qui si apre un altro mondo ..
- **mypy in strict mode**: doppio check di pyright. Oggi non conosco l'esempio per il quale dovrei integrarlo, pyright strict copre bene.
- **pyrefly e ty**: da rivalutare specialmente per progetti con molti file. Sono veloci ma giovani.
- **[pre-commit.ci](https://pre-commit.ci/)**: un hook che gira anche in CI su ogni PR. Per un progetto personale con un solo maintainer è overhead, per un repo condiviso avrebbe senso.

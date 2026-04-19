---
title: "Jekyll nel 2026"
date: 2026-04-10
categories: [publishing]
tags: [jekyll, github-actions, cross-posting]
repo: bilardi/diary
---

## Perché questo blog esiste

Scrivo articoli tecnici dei miei progetti: mi serviva un centro di raccolta e pubblicazione, ma non avevo idea di come organizzare qualcosa che funzionasse nel tempo.

Le opzioni:

- **Copiare i markdown a mano in un blog**: funziona una volta, due, e alla terza smetti
- **Piattaforme terze (Medium, dev.to, ..)**: non controlli nulla, il contenuto non è tuo, e rischi sempre di smettere per sfiancamento
- **Un sito statico con automazione**: push il post nel repo del progetto, una GitHub Action lo pubblica

Da buon developer pigro, la terza.

## Perché Jekyll e non qualcosa di moderno

| | Jekyll | Hugo | Astro | Next.js |
|--|--------|------|-------|---------|
| GitHub Pages nativo | sì, zero config | serve Action di build | serve Action di build | serve Action di build + hosting |
| Linguaggio template | Liquid: brutto ma semplice | Go templates: potente, criptico | JSX/MDX: potente, pesante per un blog | React: overkill |
| Build 24 post | ~5s | ~1s | ~3s | ~5s + bundle JS |
| Dipendenze | Ruby + gem github-pages | un binario | Node + npm | Node + npm + framework |
| Manutenzione | quasi zero | quasi zero | aggiornamenti npm | aggiornamenti npm + framework |
| Community | matura, non cresce ma non serve | in crescita | in crescita | enorme ma non per blog |

Hugo è più veloce, Astro è più flessibile, Next.js è più potente. Ma per un blog di 1-2 post al mese con markdown e immagini:

- La velocità di build non conta: 5 secondi o 1 secondo, non cambia nulla
- I componenti interattivi non servono: è testo, codice e immagini
- npm e i suoi aggiornamenti non mi mancano: meno dipendenze, meno sorprese

Jekyll è l'unico che GitHub Pages supporta nativamente. Push e pubblica, senza Action di build, senza hosting esterno, senza un binario Go da aggiornare, senza dipendenze Node. Senza dipendenze Node.

L'unica cosa da aggiornare rispetto al 2019: jQuery 3.2 -> 3.7 e FontAwesome v4 -> v5. Il resto regge.

## E se un giorno Jekyll non bastasse più ?

Il contenuto è markdown. Migrare a Hugo, Astro o qualsiasi altro generatore statico è cambiare il frontmatter e il tema. Il contenuto resta.

La scelta meno effort oggi non ti blocca domani.

## Come gestire due lingue senza plugin

Ogni post esiste in italiano e in inglese. Le opzioni:

- **Tag `it` / `en` insieme agli altri tag**: brutto, mischia metadata di natura diversa
- **Sottocartelle `/it/` e `/en/`**: struttura rigida, Jekyll non le supporta nativamente senza plugin
- **Campo `lang` nel frontmatter + link al gemello**: metadata separato, filtro Liquid, zero plugin

La terza. Ogni post ha `lang: it` (o `en`) e un campo `twin` che punta alla versione nell'altra lingua. Nel template, un \[[IT](/diary/articles/2026-04/jekyll-nel-2026.it)\] / \[[EN](/diary/articles/2026-04/jekyll-in-2026.en)\] sulla pagina per passare dall'una all'altra.

Nessun plugin i18n, nessuna sottocartella, nessuna struttura extra. Due file markdown con un campo in più nel frontmatter e qualche riga di Liquid nel layout.

## Il baseurl che nessuno gestisce

Il tema leonids usa `{{ site.url }}` per i path di CSS e JS. Funziona finché il sito sta nella root del dominio. Quando lo metti sotto un path (`/diary/`, `/resume/`), il browser cerca `/css/main.css` invece di `/diary/css/main.css`.

La fix: `{{ site.url }}{{ site.baseurl }}` al posto di `{{ site.url }}` nei riferimenti ai file statici (`head.html` per il CSS, `js.html` per jQuery).

Non basta aggiungerlo in un punto: il tema usa path assoluti generati da Liquid, non path relativi HTML. Non c'è un `<base>` che risolva tutto.

Ma non finisce lì. Lo stesso pattern mancante era in altri 12 file: navigazione, elenchi dei post, feed RSS, immagini, canonical URL. Il tema originale funzionava perché era pensato per la root del dominio. Sotto un subpath, buona parte dei link non funzionava.

Funziona tutto aggiungendo `{{ site.baseurl }}` in entrambi gli ambienti:

- `baseurl: /diary` -> `/diary/css/main.css` (produzione e locale)
- `baseurl:` vuoto -> `/css/main.css` (siti in root)

La lezione: se forki un tema Jekyll per usarlo sotto un baseurl, grep `site.url` e aggiungi `site.baseurl` ovunque. Non basta il CSS.

Ma le scelte tecniche sono la parte facile.

## Il metodo

Serviva un'immagine di sfondo per la sidebar del blog. Sul sito principale c'era già il glider di Conway: cinque celle del Game of Life che si muovono in diagonale, da sole, senza input esterno. Per il diary andava rivisto con la nuova palette.

Non l'ho disegnato a mano, e non l'ha generato l'AI da sola.

Ho descritto cosa volevo: un glider fatto di nodi, colori verde e arancio, sfondo scuro, ripetibile come tile. L'AI ha generato l'SVG. Ho guardato il risultato nel browser e ho corretto: "questa linea è orfana", "l'angolo è sbagliato". L'AI ha applicato le correzioni e io ho riguardato. Quattro iterazioni per arrivare al risultato: un file SVG di 60 righe.

Poi l'idea era mostrare le 4 fasi dell'animazione: il glider che si trasforma mentre avanza. Sembra semplice ma non lo è: i nodi non si staccano né riattaccano tra una fase e l'altra. Se il nodo arancio è connesso al nodo verde nella fase 1, deve restare connesso nella fase 2, 3, 4. Le connessioni dovevano essere invariate; solo le posizioni dovevano cambiare.

È esattamente come un refactoring: puoi spostare le classi, rinominare i file, cambiare la struttura. Ma le dipendenze restano. Se rompi un collegamento, il sistema si rompe.

La variante a 4 fasi è rimasta un work-in-progress. Il perfezionismo dell'informatico pigro: aggiusti finché non è abbastanza buono, poi "va bene così" e documenti il resto in un GLIDER.md per la prossima sessione.

Il pattern è sempre lo stesso: descrivi, genera, correggi, rigenera. Nessuno dei due avrebbe fatto bene da solo: io non avrei scritto l'SVG a mano e l'AI non avrebbe capito che le connessioni devono essere invariate (non conosce il mio modello mentale). Il processo è un pair programming dove uno scrive e l'altro fa da reviewer.

Questo è l'approccio che l'informatico pigro avrà per tutti i progetti .. anche se dipenderà sempre dal contesto decidere quanto basta.

## Cross-posting

L'ultimo pezzo dell'automazione: pubblicare senza aprire cinque tab.

Per la pubblicazione, serviva una piattaforma developer con API e markdown. Che alternative ci sono:

- **Medium**: API chiusa ai nuovi utenti
- **Hashnode**: dominio custom, backup GitHub, newsletter integrata; ma il blog esiste già, serve solo reach
- **dev.to**: la community developer più grande, API REST gratuita, markdown, canonical URL. Una chiave, una chiamata

Hashnode è un'ottima piattaforma di blogging, ma con GitHub + Jekyll ho già le stesse feature.

La terza è la migliore alternativa, perché serve solo reach.

La GitHub Action crea il post in inglese come draft su dev.to; lo rivedi e pubblichi da lì con il link al blog originale.

L'avventura con il cross-posting automatico sui social (Mastodon, LinkedIn, Twitter, Threads) è in un [post dedicato](https://github.com/bilardi/github-actions-tech-post) perché, da buon developer pigro, preferisco un symlink a un copia-incolla.

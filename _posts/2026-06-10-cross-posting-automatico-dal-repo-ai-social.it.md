---
layout: post
title: "Cross-posting automatico: dal repo ai social"
date: 2026-06-10
categories: [devops]
tags: [GithubActions, CrossPosting, social, api]
repo: bilardi/github-actions-publish
lang: it
pair: 1

---

![cross-posting](https://raw.githubusercontent.com/bilardi/github-actions-publish/master/images/workflow.post.png)

## Scrivere una volta, pubblicare ovunque

Tutto è partito dal blog [bilardi/diary](https://github.com/bilardi/diary), che raccoglie i post tecnici dai repo dei miei progetti e li pubblica committandoli in automatico. Ma pubblicarli sul blog è metà del lavoro: parte del contenuto va anche su Mastodon, LinkedIn, Threads, Twitter e tutto l'articolo su dev.to. A mano, ogni volta, sarebbe un macello.

Da buon developer pigro, volevo qualcosa che gestisse il giro da solo: scrivo il post nel repo, e un workflow di GitHub Actions fa il resto.

Il problema è che ogni social gioca con regole diverse, e quasi nessuno è gratis come sembra. In più, il blog non è l'unico repo che dovrebbe pubblicare sui social, perché organizzo eventi e partecipo a conferenze .. e copiare gli script in ogni repo non scala.

## Centralizzare quanto basta

### Quattro social, tre slot

Mastodon è il più semplice: ha un'API aperta, come [dev.to](https://dev.to), un token che non scade, e con un `curl` il post è pubblicato. Twitter è l'opposto: il piano Free che dava 1.500 tweet al mese non esiste più, e per generare i token di scrittura servono i piani a pagamento, da 200 dollari al mese. LinkedIn e Threads non hanno il problema del costo, ma sono più articolati da gestire. Invece l'automazione di Instagram richiede troppi requisiti prima di capire se il gioco vale la candela.

Possibile che non esista un sistema unico per gestirli tutti ? In realtà ne esistono un sacco, ma pochi hanno la gestione delle bozze, che conta quando la pubblicazione sui social è irreversibile. Dal confronto è emerso [Buffer](https://buffer.com) che offre la gestione di 3 canali gratis. E io che ne ho 4 da coprire, come faccio ?

La risposta è non mettere tutto su Buffer. Mastodon e dev.to hanno le loro API dirette, quindi li escludo a priori. I quattro che vorrei gestire con Buffer sono LinkedIn, Twitter, Threads e Instagram. Instagram, però, non è automatizzabile a costo ragionevole: resta a mano, e i 3 slot gratis bastano per gli altri tre.

| Social | Buffer | Motivo |
|--------|--------|--------|
| dev.to | no | API diretta, token annuale |
| Instagram | no | Meta pretende un account business, una pagina Facebook e un'app review |
| LinkedIn | sì | API OAuth, token a 60 giorni e refresh solo per partner approvati |
| Mastodon | no | API diretta banale, token che non scade |
| Threads | sì | API OAuth, token a 60 giorni con refresh |
| Twitter | sì | nessuna API di scrittura gratis |

Quindi con Buffer non devo entrare in ogni account, e le bozze sono un toccasana perché
- un controllo in più prima di pubblicare non fa mai male
- su Twitter è quasi d'obbligo, perché un tweet pubblicato non si può più modificare

### Blocchi interscambiabili

Ciò che era stato preparato per il blog era troppo custom per funzionare anche per dei post di eventi o talk. Quello che mi serviva era qualcosa che lavorasse a blocchi interscambiabili, a seconda del tipo di post da fare.

Per questo, gli script sono stati centralizzati in un unico repo, [bilardi/github-actions-publish](https://github.com/bilardi/github-actions-publish) che espone un workflow riutilizzabile dagli altri repo, come [bilardi/bilardi-posts-manager](https://github.com/bilardi/bilardi-posts-manager).

Ma come gestire formati differenti con gli stessi script ?

Il pezzo che tiene tutto insieme è un formato intermedio: ogni repo arriva alla lista dei post a modo suo. In questo momento ci sono due parser, uno per tipo di sorgente:
- il parser di default legge i repo evento, con i file divisi in sezioni `# long`/`# medium`/`# short`/`# article`
- il blog ha il suo parser: legge file formattati in modo diverso, ma produce le stesse sezioni

I parser producono lo stesso JSON, e gli script di github-actions-publish lo consumano senza sapere da dove arriva. Così il blog riusa gli stessi script pur avendo un parser tutto suo.

E da buon developer, non poteva mancare il minimo sindacale:
- i test sono end-to-end sui parser, in bash: non è Python, quindi niente `pytest`, e un framework come [sharness](https://github.com/bilardi/see-git-steps/blob/master/test/sharness.test/functional.sh) o [bashunit](https://github.com/bilardi/see-git-steps/blob/master/test/bashunit.test/functional.sh) era troppo per lo scopo
- il dry-run è uno smoke test del giro completo: gira contro le API reali ma non pubblica, comodo soprattutto per Mastodon che è diretto e irreversibile
- il resto è essenziale: lint con `ruff` a comando, release con bash e `git-cliff`

## Quello che la documentazione non dice

### Buffer e le sue sorprese

Dopo aver testato con `curl` la fattibilità, ho implementato in Python con `urllib` e l'accesso a Buffer non andava: perché ?
L'endpoint è dietro Cloudflare, che blocca le richieste di `urllib` di Python con un errore 1010: `curl` passa, `urllib` no. Senza troppi sbatti, ho costruito il payload JSON con `python3` e la chiamata l'ho fatta con `curl`.

Il piano Free permette 100 richieste ogni 24 ore, a finestra mobile. Un giro normale ne usa 5-6, ma una sessione di debug da 10 giri è già a 50-60: in sviluppo si bruciano in fretta.
E no, non ho mockato le sue risposte: ho solo tenuto i giri al minimo. Un mock dell'API sarebbe il modo giusto per testare la pubblicazione senza bruciare le richieste, ma si disallineerebbe a ogni cambio di firma dell'API di Buffer, ed è già successo. La changelog di Buffer non la leggo la mattina mentre bevo il caffè: un mock resterebbe verde mentre la pubblicazione vera si rompe, senza che me ne accorga. Meglio lavorare sull'API reale.

### La dedup a più livelli

Un primo pensiero è stato di non pubblicare due volte lo stesso post su Mastodon: tutto il resto passa per una bozza, quindi si può anche cancellare, ma per Mastodon no, è diretto.
Perciò, lanciare il workflow due volte non doveva creare doppioni, e per nessun canale. Ho implementato la dedup per-canale, non globale: se LinkedIn ha già il post ma Threads no, crea solo Threads.

E come capire che un post è già stato fatto ?

Mi sono basata sul confronto dell'URL pubblicato nel post: se esiste già un post con quell'URL, vuol dire che non è da pubblicare. Questo in realtà può rivelarsi un limite, perché significa che non posso fare più post per lo stesso evento con lo stesso URL, ma me ne sono fatta una ragione: la consistenza prima di tutto.

Con questo sistema però LinkedIn continuava a creare la bozza del post che avevo appena pubblicato, ed è stato un grattacapo per trovare la causa, ma soprattutto una soluzione abbastanza pulita.

All'invio, LinkedIn riscrive il link in un `lnkd.in`: sui post già pubblicati l'URL canonico sparisce dal testo, la dedup non lo trova e riaccoda lo stesso post ad ogni giro .. se non lascio una bozza. Ho provato a passare l'URL come allegato strutturato, che sopravvive alla riscrittura: ma allegandolo Buffer scarta l'immagine e mostra solo la card del link, e l'immagine non è negoziabile. Perciò per i soli canali LinkedIn la dedup confronta le prime righe del corpo del post, che restano intatte, invece dell'URL. È un altro compromesso che ci sta: se modifichi quelle righe su un post già inviato, si riaccoda e pace.

Ma la dedup non si ferma ai post: c'è anche quella degli hashtag di chiusura. Se sono già nel testo, perché riscriverli alla fine ? Si risparmia spazio, soprattutto su Mastodon, Threads e Twitter.
I tag salvati per la chiusura del post sono in minuscolo, ma inline si scrivono anche in maiuscolo: ho scelto di fare il confronto con la parola intera e case-insensitive, altrimenti uscirebbero sia #AWS che #aws.

### La soluzione minimal vince sempre

Per clonare un repo figlio, all'inizio usavo un semplice script bash con il codice dei file scritto dentro, in heredoc. Bastava gestire un file YAML e un `LICENSE`, poi si è aggiunto il `README.md`, ed è lì che è iniziato il problema: nello stesso punto convivevano tre livelli di escape, i backtick del markdown, le variabili letterali e le espressioni `${{ .. }}` di GitHub Actions. Ogni modifica rischiava di rompere la generazione.

La scelta è stata togliere gli heredoc: i contenuti sono diventati file template con dei placeholder, sostituiti con `sed`. Niente più escape annidati: contenuto e logica stanno in posti diversi, ciascuno leggibile per conto suo.

### Il workflow che non si vede

Al primo giro del repo figlio, qualcosa non andava: avevo pushato tutto, ma non potevo far partire il workflow, perché ?

Beh, in realtà mi è successo più volte.

All'inizio pensavo dipendesse dal fatto che il repo era privato: il workflow non compariva nella tab Actions, e davo la colpa a quello. Ho fatto varie prove, dal renderlo pubblico ai nuovi push.

Ma con un altro repo è ricapitato, sebbene l'avessi reso pubblico fin dall'inizio e avessi fatto il primo push con tutto il necessario: il workflow non compariva nella tab Actions lo stesso, quindi non era la visibilità.

La vera causa è nel funzionamento di GitHub Actions: rivalida i workflow solo quando li tocchi con un push. E infatti, bastava fare una modifica: una newline in fondo al file, un push, ed è comparso.

### Dove tengo le immagini

Qui si potrebbe aprire un dibattito enorme, ma stiamo ai fatti.

Stiamo parlando di articoli, post di eventi e talk, .. se ci si organizza bene, potrebbero essere parecchi: versionare le immagini sul repo non è una scelta e nemmeno metterle sul proprio account AWS, specialmente se si collabora a più mani.

Ciascun gruppo di eventi ha il proprio Google Drive, e tengo le immagini lì. Il problema è che il link di condivisione (`drive.google.com/file/d/../view`) non è un URL diretto all'immagine, e Buffer e Mastodon vogliono un URL diretto. Ho provato tre forme di URL:

| Forma | Modalità | Mastodon | Buffer | Perché |
|-------|----------|----------|--------|--------|
| `uc?export=view` | redirect (303) | sì | no | Buffer non segue il 303 |
| `drive.usercontent.google.com/download` | diretto | sì | no | bloccato dalla restrizione CORS |
| `thumbnail?id=..&sz=w1920` | redirect (302) | sì | sì | nessuna restrizione |

Il parser converte il link di condivisione in quest'ultimo formato in automatico: nella configurazione incollo il link come lo copio da Drive, e ci pensa lui.

## Cosa si potrebbe migliorare ?

Alla fine mi son trovata con una linea guida: fuori da Buffer va ciò che ha un'API diretta con bassa manutenzione, e i 3 slot gratis restano per chi non ce l'ha. Oggi fuori c'è solo Mastodon, con il suo token che non scade.

Threads è il candidato naturale a uscirne: [Meta ha un'API](https://developers.facebook.com/docs/threads) che pubblica via codice, e spostarlo libererebbe uno slot Buffer. Solo che non è gratis come Mastodon: i token scadono dopo 60 giorni e vanno rinnovati con un endpoint dedicato, altrimenti tocca rifare l'OAuth a mano. Servirebbe uno step schedulato che rinnova il token e lo risalva. Se un giorno servirà uno slot Buffer per un altro social, sarà il momento di farlo.

Instagram ora è gestito a mano, ma la strada è più lunga: servono un account business, una pagina Facebook e un'app review di Meta. Tutto dipende dallo status quo: diventerà necessario nel momento in cui il peso di postare a mano sarà maggiore di quello di aprire un account Facebook con tutti gli accessori.

E infine i video. Oggi il publish gestisce solo immagini: su nessun canale c'è il video. Per un post evento a volte un breve video renderebbe più di una foto, però ogni piattaforma ha vincoli diversi su formato, durata e peso, e Buffer li tratta in modo diverso dalle immagini. Per ora il video resta fuori.

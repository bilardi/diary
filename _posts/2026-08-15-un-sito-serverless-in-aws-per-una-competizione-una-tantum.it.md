---
layout: post
title: "Un sito serverless in AWS per una competizione una tantum"
date: 2026-08-15
categories: [devops]
tags: [sam, docker, aws, serverless]
repo: bilardi/aws-card-clash
lang: it
pair: 1

---

![Architettura di aws-card-clash su AWS](https://raw.githubusercontent.com/bilardi/aws-card-clash/master/images/architecture.drawio.png)

## Il torneo dura una sera, il sito quanto ?

[AWS Card Clash](https://cardclash.skillbuilder.aws/) è un gioco di carte di AWS: si costruiscono architetture, e si può giocare da soli o contro qualcuno passandogli un join code. Sul web si entra con AWS Builder ID e su mobile senza autenticazione. Volevo organizzarci un torneo per l'AWS User Group locale, e il gioco non gestisce una competizione: non sa chi partecipa, chi ha già incontrato chi, quanti punti ha fatto ognuno. Serviva tutto il contorno che, per il momento, AWS non dà.

Mi serviva un sito per gestire la competizione, che poi sarebbe rimasto fermo per mesi. Uno strumento che, al bisogno, si tira fuori, si usa e si rimette via.

Le prime domande da porsi sono di gestione: **quanto costa il sito mentre nessuno lo usa**, **ha senso ricostruirlo sempre da zero**, e, in caso, **quanto lavoro serve per rimetterlo in piedi** per il torneo successivo. E la risposta è un sistema che torna in piedi nel tempo di un deploy o che rimane silente finché non serve.

Serve una soluzione serverless, a costo zero se non quando ci sono chiamate, che costi qualche dollaro a competizione: ho usato i classici pattern AWS, componendoli a blocchi. I dettagli dei pattern usati sono descritti nel [README](https://github.com/bilardi/aws-card-clash#readme) del progetto.
Per i più curiosi, esiste un portale dedicato ai [pattern AWS](https://serverlessland.com/patterns), utile quando non si ha idea di quale sia la soluzione migliore per il proprio caso.

## Serverless per scelta

### Una definizione sola, che vale in locale e in produzione

Da buon developer pigro sono partita da [Terraform](https://www.terraform.io/), che è ormai il mio default, e ho provato [LocalStack](https://www.localstack.cloud/) per avere in locale un'API il più possibile simile a quella vera. Ho trovato tre muri in fila.

- Ho scaricato l'ultima versione dell'immagine `localstack/localstack:latest`, che non parte però senza un token: sia mai che si paghi per fare testing, quando esistono tanti sistemi opensource. Una licenza gratuita esiste, il piano Hobby, e per un progetto non commerciale come questo sarebbe stata legittima, ma le HTTP API, cioè tutta la nostra API, stanno dal [piano Base](https://docs.localstack.cloud/aws/services/apigateway/) in su
- L'immagine `localstack/localstack:3` della community parte senza token, ma il provider AWS v6 di Terraform non è compatibile: lo è la v5, coetanea dell'immagine
- E il muro decisivo: `apigatewayv2` non è presente nell'immagine community, che non supporta nemmeno il runtime `nodejs22`

L'alternativa era scrivermi un server di sviluppo che costruisse l'evento e lo instradasse verso gli handler. Un centinaio di righe. Righe mie, da mantenere, per emulare ciò che in realtà AWS emula già con [SAM](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html).

La scelta è stata **SAM come unica infrastruttura**, sia in locale sia in produzione: `sam local start-api` da una parte, `sam deploy` dall'altra, un solo template come fonte di verità.

SAM gestisce tutto in meno righe:

| Parte | Terraform | SAM/CloudFormation |
|---|---|---|
| Cognito | ~50 | ~70 |
| S3, con blocco accesso pubblico e origin access control | ~35 | ~45 |
| CloudFront | ~80 | ~95 |
| serverless: Lambda, API Gateway, IAM, DynamoDB | ~165 | ~90 |
| totale | ~330 | ~300 |

SAM è **più verboso** su Cognito, S3 e CloudFront, perché lì è [CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html) puro contro l'HCL di Terraform. Ma è molto più conciso sul serverless, perché `Events` di `AWS::Serverless::Function` genera da sé le rotte, i permessi e il ruolo. A far pendere la bilancia ancora di più verso SAM è stato quello che non è in tabella:

- con Terraform servivano comunque due strumenti, lui per l'infrastruttura e qualcos'altro per avere l'API in locale: LocalStack oppure un server di sviluppo scritto da me
- con SAM è uno solo, che gestisce sia test locali che deploy su AWS

Docker resta in ogni caso, ed è lo stesso con l'una e con l'altra strada: DynamoDB locale, che serve ai test del backend, e Nginx per il frontend.

L'unica differenza tra locale e produzione è l'autenticazione: in locale resta finta, perché nemmeno `sam local` emula l'authorizer di Cognito. Anche LocalStack non l'avrebbe risolta gratis, visto che Cognito sta nel piano a pagamento.

### Come sono composti i blocchi

I blocchi sono quattro. Identità, backend e sito viaggiano insieme, in un deploy solo diviso in tre parti. Il dominio invece è un deploy a parte, per una ragione precisa: è l'unico pezzo che si può spegnere da solo.

Chi arriva dal browser vede un indirizzo solo: davanti c'è una distribuzione CloudFront con due origini, le pagine del frontend in un bucket S3 privato che solo lei può leggere, e le HTTP API del backend sotto `/api`. Stando sotto lo stesso dominio, il browser non chiede permessi CORS fra sito e API: non c'è niente da autorizzare.

Quel `/api` lo toglie una funzione di CloudFront, prima che l'API veda il path: le sue rotte restano `/competitions` e `/users/me`, come se il prefisso non fosse mai esistito. In locale è Nginx che ne fa le veci. Il prefisso serve solo al sito per distinguere le proprie pagine dalle chiamate, e all'API non serve: se un domani l'API si sposta su un indirizzo suo, come api.pandle.net, le rotte non cambiano.

Tutto in `eu-west-1`, con una sola eccezione obbligata: il certificato di CloudFront deve stare in `us-east-1`. E siccome uno stack CloudFormation vive in una regione sola, quel certificato non può stare insieme al resto: è per questo che il deploy del dominio è applicato in Virginia. Spostare tutto avrebbe semplificato i certificati, ma avrebbe messo i dati personali fuori dall'Europa e avrebbe aggiunto latenza ad ogni chiamata dell'API.

### Chi entra

Di aperto non c'è niente: ogni rotta dell'API pretende un token, e senza accesso il sito mostra solo la pagina di login. È un sito minimale, pensato solo per chi partecipa al torneo.

Le alternative erano tre. AWS Builder ID sarebbe stato il più coerente, visto che il gioco si usa con quello, ma non è un'identità con cui ci si possa federare: [Cognito accetta](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-identity-federation.html) Facebook, Google, Amazon e Apple, più OIDC e SAML generici, mentre AWS [descrive il Builder ID](https://docs.aws.amazon.com/signin/latest/userguide/sign-in-aws_builder_id.html) come un profilo personale per accedere ad alcuni dei suoi strumenti. Chiude il cerchio il fatto che al Builder ID stesso si entra con Google, Apple, GitHub o Amazon: chi gioca ha già uno di quegli account.

Facebook si federa, ma configurarlo è molto lavoro, e comunque non è detto che tutti ce l'abbiano. Email e password erano escluse in partenza, perché non volevo gestire dati sensibili. Resta Google, e con il vantaggio che se non hai l'account, te lo fai in pochi clic.

La configurazione di Google si fa una volta sola perché conosce solo l'indirizzo a cui rimandare il browser dopo l'accesso, e quell'indirizzo è di Cognito, non di CloudFront. Se accetto che durante l'accesso si legga un `amazoncognito.com` invece del mio dominio, quell'indirizzo non cambia mai più: posso distruggere e ricostruire tutto quante volte voglio, cambiare l'indirizzo del sito, aggiungere un dominio proprio, e nella console di Google non ci torno nemmeno una volta.

È un baratto esplicito degno di un developer pigro: un indirizzo brutto per tre secondi durante l'accesso, in cambio dell'unica configurazione manuale del progetto che non si ripete mai.

### Quanto costa stare fermi

Senza una competizione attiva **questo sistema non costa niente**: API Gateway e Lambda si pagano a invocazione, DynamoDB on-demand si paga a richiesta, CloudFront a traffico, il sito in S3 è meno di un megabyte, Cognito è gratuito ben oltre i nostri numeri. Quindi se non fai niente, non paghi.

Con una sola eccezione, e da lì viene tutto il resto: **la zona DNS di Route 53 costa mezzo dollaro al mese comunque**, che qualcuno la interroghi oppure no. È l'unico servizio a canone, quindi è l'unica risorsa che ha senso spegnere, ed è anche la più scomoda da riaccendere, perché, se non si gestisce tutto in AWS, una zona nuova ha nameserver nuovi da riportare nel registrar. Per questo il dominio è uno stack a sé, quello in Virginia, che si accende e si spegne da solo, mentre tutto il resto può restare in piedi funzionante con l'indirizzo di CloudFront.

## Le cose che si scoprono solo durante

### Ci si dimentica di SAM se si comincia ad usare Terraform

SAM e Terraform arrivano allo stesso risultato per strade diverse. SAM scrive un template e lo consegna a CloudFormation, che è il servizio di AWS a tenere il conto delle risorse deployate e a decidere da sé in che ordine crearle e distruggerle. Terraform quel conto lo tiene per sé, in un file di stato suo, e parla direttamente con le API di ogni servizio. Le differenze che seguono nascono tutte da qui.

#### Una best practice che complica le cose

Il primo esempio è il giro delle callback. Cognito deve sapere dove rimandare il browser dopo l'accesso, e quell'indirizzo è quello di CloudFront; CloudFront deve sapere dov'è l'API; l'API deve sapere quale pool controlla i token. Messo così è un cerchio, e CloudFormation i cerchi li rifiuta.

Con Terraform il cerchio non c'è, e non per merito suo: perché il grafo lo costruisce risorsa per risorsa, e a quel livello il client ha bisogno della distribuzione, la distribuzione dell'API, e l'API di nessuno dei due. CloudFormation con gli stack annidati lo costruisce stack per stack, quindi se una risorsa dentro Auth ha bisogno di una risorsa dentro Site, tutto Auth deve venire dopo tutto Site.

L'abitudine a dividere i template, presa con Terraform, qui si paga: in un template unico il problema non esisterebbe. La divisione l'ho tenuta lo stesso, perché tre file sono più leggibili di uno lungo, e il cerchio si chiude applicando il deploy due volte: alla prima passata Cognito riceve l'indirizzo del server di sviluppo, che è il valore predefinito del parametro, e intanto la distribuzione nasce; alla seconda il comando legge l'indirizzo vero dagli output dello stack e glielo passa. Dal secondo deploy in poi la seconda passata non trova niente da cambiare.

#### L'angolo cieco di CloudFormation

Il secondo esempio nasce dalla stessa radice, ed è più insidioso perché non dà errore. Le credenziali di Google stanno in Parameter Store e il template le leggeva con un riferimento dinamico. Se si modificava il valore nel parametro e si rifaceva il deploy, Cognito continuava a presentare a Google quello vecchio.

Il riferimento stava in uno stack annidato, e CloudFormation [lo rilegge quando aggiorna quello stack](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/dynamic-references-ssm.html). Dal punto di vista del padre non era cambiato niente, stesso template figlio e stessi parametri, quindi il figlio non è stato toccato e il valore nuovo non è mai stato letto. Di nuovo la granularità: l'unità di rilettura è lo stack, non la risorsa. Terraform con un data source lo risolve a ogni plan, e il problema non ce l'ha.

La soluzione è stata smettere di leggerlo dal template e passarlo come parametro dal comando di deploy: quando il valore cambia, CloudFormation vede una differenza e aggiorna.

#### Le risorse che non sono di nessuno

Il terzo esempio è quello che mi ha fatto perdere più tempo, ed è l'unico in cui ho lo stesso disegno costruito con tutti e due gli strumenti: SAM con [bilardi/aws-card-clash](https://github.com/bilardi/aws-card-clash), Terraform con [bilardi/aws-docker-host](https://github.com/bilardi/aws-docker-host).
Un certificato si valida su DNS: ACM scrive un record dentro la zona e poi chiede al DNS pubblico di confermarlo. In CloudFormation puoi solo dichiarare il certificato indicando la zona, e al record ci pensa appunto ACM: è una delega obbligata che permette di scrivere una sola riga di codice. In Terraform quel record lo scrivi tu, come risorsa esplicita, e sono tre righe in più.

La differenza si vede solo quando si spegne. `make destroy-domain` è morto con `The following resource(s) failed to delete: [HostedZone]`: il certificato era sparito, ma la zona non era vuota, perché dentro c'era ancora il record di validazione. Quel record non appartiene a nessuno stack: l'ha scritto ACM, CloudFormation non sa che esiste, quindi nessuna cancellazione lo porta via, e Route 53 non cancella una zona che contenga qualcosa oltre ai suoi NS e SOA.
Con Terraform non succede, e di nuovo non per merito suo: perché quelle tre righe in più mettono il record nello stato, quindi il destroy lo porta via e la zona resta vuota. La comodità di scrivere una riga in CloudFormation è anche il problema: nascondendo la risorsa, nasconde che qualcuno dovrà cancellarla.

La correzione è uno script che svuota la zona di tutto ciò che non siano gli NS e il SOA, chiamato da `make destroy-domain` prima della cancellazione. Legge la zona dalla risorsa dello stack e non dai suoi output, perché deve funzionare anche su uno stack già rimasto in `DELETE_FAILED` da questo stesso problema.

Della stessa famiglia ci sono i log group. Nessuno li dichiarava, quindi li creava Lambda alla prima invocazione, e non appartenevano allo stack: il destroy non li portava via, lasciando i log orfani. Un costo che resta quando il sito non esiste più, cioè l'esatto contrario dell'idea del progetto.

Il problema si risolve dichiarandoli nello stack, con un nome nostro e una ritenzione decisa da noi, e dicendo alle funzioni di scrivere lì.

#### Quando il primo deploy fallisce

L'ultima differenza si vede la prima volta che un deploy va male. Con SAM o CloudFormation, una `create` andata male lascia lo stack in `ROLLBACK_COMPLETE`, che è terminale: il deploy dopo non riparte, si ferma lì, e bisogna cancellare lo stack vuoto e aspettare che sparisca. Terraform qui è più pratico: uno stato terminale non ce l'ha e si riapplica sopra.

Quando un'operazione fallisce, SAM e CloudFormation preferiscono lasciare qualcosa da guardare piuttosto che cancellare. Esiste un'opzione per cancellare tutto in quel caso, e si aggiunge al comando che crea lo stack: `sam deploy --on-failure DELETE`. Sotto, quando SAM chiama CloudFormation, diventa lo stesso parametro di `create-stack`.

### Punti fermi

Il primo: un progetto che si chiama `aws`-qualcosa, come nel nostro caso `aws-card-clash`, non può nominare come sé stesso tutte le proprie risorse.

- Systems Manager riserva i nomi di parametro che cominciano con `aws` o `ssm`
- Cognito rifiuta il prefisso scelto per la pagina di accesso, cioè la prima parte di quel `amazoncognito.com`, se contiene `aws`, `amazon` o `cognito`. Il controllo di disponibilità del nome passa, il che insegna che disponibile e valido sono due controlli diversi, e per il secondo non c'è un comando: lo scopri quando provi a crearlo

Il secondo: le `CustomErrorResponses` sono la [best practice documentata](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/deploy-a-react-based-single-page-application-to-amazon-s3-and-cloudfront.html) per servire una single page application da S3, cioè "quando l'origine risponde con un errore, servi `index.html` con stato 200", e funzionano finché dietro la distribuzione c'è una origine sola. La nostra ne ha due, il sito e le API, e una regola sugli errori vale per tutta la distribuzione: così anche i 404 dell'API diventavano `index.html` con stato 200. E il backend quei codici li usa per parlare: è con un 404 che dice "non sei iscritto".

Con più origini, quindi, le `CustomErrorResponses` vanno sostituite da una funzione di CloudFront attaccata alla sola strada del sito, che decide prima di andare a cercare qualcosa se servire un file o l'applicazione.

Il criterio è il punto: se l'indirizzo ne contiene uno è un file, tipo `assets/index.css`, e passa intatto; se non lo contiene è un indirizzo dell'applicazione, e diventa `index.html`. Da lì il vincolo: nessun indirizzo del sito può contenere un punto, e l'unica parte variabile è l'identificativo di una competizione, che lo schema di validazione tiene a lettere minuscole, numeri e trattini.

Resta un residuo: un indirizzo senza punto che l'applicazione non conosce torna comunque `index.html` con stato 200. Per dare un 404 vero, la funzione dovrebbe sapere quali indirizzi l'applicazione conosce, cioè tenersi una copia delle sue rotte e aggiornarla a ogni cambio: costa più di quello che risolve.

### Mezzo secondo passato ad aspettare il processore

Il sito sembrava lento, allora ho recuperato i millisecondi dalle righe `REPORT` su CloudWatch: la prima chiamata dopo una pausa, quella che si chiama partenza a freddo (cold start), costava intorno al mezzo secondo, contro le decine di millisecondi di una chiamata a ridosso della precedente. Su tutte e cinque le funzioni, e questo è il dettaglio che ha indirizzato tutto: **una penalità uguale per funzioni che fanno azioni diverse non può essere il lavoro delle query**. È quello che tutte fanno allo stesso modo, cioè caricare interprete e librerie prima di eseguire il proprio codice.

Un dato ha chiuso subito una strada: le funzioni Lambda erano configurate con 256 MB di memoria e ne usavano al massimo 111 MB. Ne avanzava più della metà: il problema stava altrove.

Su Lambda la memoria non compra solo spazio, compra anche la fetta di processore. Alzando la memoria da 256 a 1024 MB, la penalità si è divisa per quattro su tutte e cinque le funzioni, da 410-576 a 93-137 ms, contro un processore moltiplicato per quattro. Era il processore che mancava.

Nel frattempo le prestazioni sono migliorate inaspettatamente per un altro motivo. L'aggiornamento automatico delle pagine era stato portato da dieci a cinque secondi per dimezzare l'attesa prima che una persona si accorga di qualcosa. **Chiedere più spesso rende ogni singola richiesta più economica**: le chiamate a dieci secondi di distanza costavano circa 200 ms, e a cinque secondi quel costo sparisce. Sembra una connessione tenuta aperta e chiusa quando resta ferma troppo a lungo.

Anche quel costo scende dello stesso fattore quattro, da circa 200 a circa 50 ms. Nell'ipotesi della connessione riaperta, il costo ha due parti: i giri di rete per concordare la connessione e i calcoli per scambiarsi le chiavi. Il processore accorcia solo i calcoli, quindi una penalità che si divide per quattro indicherebbe che il peso stava lì, non nel viaggio.

Lambda fattura memoria per tempo, quindi quattro volte la memoria per un quarto del tempo dà lo stesso prodotto. Su una delle cinque funzioni torna esatto: 0,25 GB per 0,414 secondi fa 0,104 GB-secondo, e 1 GB per 0,105 secondi fa 0,105. Lo stesso numero. **Quattro volte la velocità a costo zero.** Qualcosa però si paga: le chiamate calde erano già veloci e non si sono accorciate, e in GB-secondo costano quattro volte tanto. Sono cifre minuscole contro la soglia gratuita, ma la regola "alzare la memoria è gratis" vale sul lavoro legato al processore, non su tutto. Le cinque coppie di misure sono nella tabella di [PERFORMANCE.md](https://github.com/bilardi/aws-card-clash/blob/master/docs/PERFORMANCE.md).

Per chi arriva sul sito, la pagina di una competizione chiama tre funzioni ed è passata da circa 700 ms di sola API a circa 220 ms.

## Cosa manca, e quando varrà la pena

Il dominio, per come è adesso, ha un passaggio che non si automatizza: i nameserver della zona vanno riportati a mano nel registrar esterno, e siccome una zona ricreata ne ha di nuovi, quel passaggio è da fare ogni volta che la si riaccende. Sparirebbe tenendo tutto dentro AWS: se la zona genitore vivesse in Route 53 nello stesso account, la delega sarebbe un record che lo stack crea da sé, e accendere il dominio tornerebbe a essere un solo comando `sam deploy`.

Il dominio è facoltativo: per una serata può bastare l'indirizzo di CloudFront.

Nel sito non esiste il ruolo di chi organizza: chiunque entri è un possibile partecipante, e basta. Tutto quello che serve a chi gestisce il torneo si fa da riga di comando: dal caricare una competizione al far uscire chi è andato via senza dirlo, e qualche intervento, come cancellare una persona, si fa scrivendo direttamente su DynamoDB.

Quello che manca, quindi, è un ruolo: qualcuno che dalla sua pagina possa fare le stesse operazioni senza aprire un terminale. Finché a organizzare è chi ha scritto il sito non è un problema, ma è la prima cosa da aggiungere se lo usa qualcun altro.

Potrebbe valer la pena fare uno stress test con molti utenti per capire quando conviene cambiare pattern AWS.
Finché si parla di tornei da trenta iscritti, la soluzione regge senza sforzo: qualche centinaio di partite, payload da pochi kilobyte, e il numero di viaggi di andata e ritorno verso il database non cambia con la quantità di righe.

Quando le persone diventano molte di più, quello che cresce è la concorrenza, e qui conta sapere come funziona Lambda: AWS crea una copia della funzione, un'istanza, per ogni richiesta che arriva mentre le altre sono ancora in corso. Un'istanza appena creata deve caricarsi tutto prima di poter rispondere, ed è il cold start, cioè l'attesa in più che paga chi arriva per primo. Poi resta lì per un po', e chi arriva subito dopo la trova già pronta.
Riprendendo l'esempio: trenta pagine aperte, con tre chiamate ognuna ogni cinque secondi, fanno una ventina di richieste al secondo, e più richieste si sovrappongono, più istanze sono da accendere, ognuna con il cold start da pagare.

Uno stress test risponderebbe alle domande **quante persone possono aggiornare ogni cinque secondi** e **a che punto conviene smettere di pagare ad invocazione** prima di valutare la sostituzione del pattern API Gateway / Lambda con ALB / ECS Fargate. Con trenta persone la domanda è teorica, con qualche centinaio smette di esserlo.

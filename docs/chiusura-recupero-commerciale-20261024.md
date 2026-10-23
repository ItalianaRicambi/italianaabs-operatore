# Recupero commerciale — 24 ottobre 2026

## Esito del recupero iniziale

Il recupero dei 12.242 ingressi rimasti nello stato `ricevuto` e dei documenti
riaccodati durante la verifica e terminato. Alle 00:39 italiane il registro
mostra zero ingressi da elaborare e zero errori tecnici. Non significa che tutte
le richieste siano risolte: restano 1.683 schede operative, 177 prioritarie e
864 senza pratica associata. Sono conservate richieste, risposte, PDF, revoche
e dichiarazioni di pagamento che non hanno prove sufficienti per un avanzamento.
Le 12 sessioni non disponibili presso K restano un limite della fonte separato.

Il confronto prima/dopo riguarda tutte le 1.733 pratiche, includendo cliente,
stati commerciale e fatturazione, tipo di flusso e stato assistenza. Cambia solo
la pratica 2115: da raccolta dati a preventivo inviato. La prova e il messaggio
originale del 21 ottobre alle 15:56:59 italiane, con PDF, conversazione e offerta
collegati. Le 148 pratiche gia fatturate mantengono stato e cliente. Nessuna
pratica viene eliminata o creata dal recupero e nessuna assistenza viene chiusa.

I lotti iniziali sono stati limitati a 300/500 ingressi mentre venivano
rielaborati i webhook, poi a 1.000/2.000 per gli originali. Ogni lotto ricontrolla
la fatturazione prima del commit. L'ultimo lotto include anche retry di fonti
gia esaminate: i tentativi complessivi non sono un conteggio di eventi distinti.

## Correzione emersa sullo storico

Due PDF identici a documenti gia registrati erano presenti in altre conversazioni.
Il tentativo di riapplicarli sollevava `Messaggio originale non verificato`:
la protezione impediva la riassegnazione ma registrava un errore tecnico.
La migrazione `20261023223829_gestisci_pdf_conversazioni_distinte.sql`, installata
e riletta, conserva tali casi come `pdf_inviato_non_collegato` senza riassegnare
documento, pratica o conversazione. Il divieto di esecuzione anonima resta attivo.
La correzione e verificata sui due casi reali e con replay sintetico.

## Verifiche

- 141 test TypeScript del canale live e della classificazione operativa passati.
- Build Next/TypeScript passata.
- 20 gruppi SQL, suite coda e 11 regressioni passati nel database locale isolato
  con le ACL reali; ripristino passato.
- Rilettura indipendente del database reale: nessuna fixture residua, zero
  ingressi `ricevuto`, zero errori, confronto completo delle pratiche.
- Il tentativo di eseguire l'intera suite sintetica sul database gestito e stato
  rifiutato dal connettore con `Invalid or expired requestState`; non e dichiarato
  superato. Le scritture operative e la migrazione hanno invece funzionato.

## Rilascio e continuita

La PR 32 e stata unita in main al commit
`9cfe35d38499ef68dfb0554c288c3b5cb544115a`. La distribuzione Production
`GyhB1REzV14Xa7BmFFKDnzp4i6pJ` risulta riuscita per quel commit.
Il nuovo test di concorrenza PostgreSQL 17 e passato anche sul commit finale
`a06943d30cdbb5f83cf623bd746bf32254122f27` (run `40040435028`).

Il controllo e attivo (`attivo=true`), cron ogni minuto. Primo ciclo autonomo
verificato nel database: run 46655, inizio 2026-10-23 23:36:00 UTC, completato
alle 23:36:04 UTC; 250 esiti elaborati, nessun errore. Rilettura indipendente:
zero ingressi ricevuti, zero ritardi e zero errori. Restano le stesse 1.683
schede operative: le prove mancanti non diventano conferme per effetto del retry.

La pagina Production `/keplero/pratiche` richiede l'accesso operatore e riporta
al login in assenza di sessione, verificato anche nel browser. La sessione
autenticata dell'utente non e disponibile nel browser di collaudo: questa
verifica non certifica una nuova navigazione autenticata in produzione, ne
un invio dal vero strumento K. Il collegamento Vercel continua a rispondere
403; l'integrazione GitHub e stata il canale di rilascio.
Non sono introdotti invii ai clienti e la routine email verso WhatsApp rimane
sospesa. La sincronizzazione oraria delle fatture resta un processo separato.

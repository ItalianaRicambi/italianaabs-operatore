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

Il recupero manuale e completato. Restano in corso il rilascio della PR 32 tramite
GitHub/Vercel e la successiva attivazione del controllo periodico, da verificare
con un'esecuzione autonoma e una nuova lettura del registro. Il collegamento
Vercel continua a rispondere 403; l'integrazione GitHub e il canale di rilascio.
Non sono introdotti invii ai clienti e la routine email verso WhatsApp rimane
sospesa. La sincronizzazione oraria delle fatture resta un processo separato.

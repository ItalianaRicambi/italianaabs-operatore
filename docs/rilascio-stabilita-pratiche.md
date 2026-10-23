# Stato del rilascio — 23 ottobre 2026

Implementazione preparata, **non distribuita né attivata**. Le due tabelle
principali non risultano presenti nel database reale nella verifica finale.
Il tentativo di migrazione attraverso il connettore è fallito con
`Invalid or expired requestState`; anche l'editor del browser ha restituito
`credential_observation_restricted`. Nessun comando Run è stato eseguito nel
browser per questa migrazione. Il rilascio resta fermo prima delle scritture.

## Cosa cambia

- Relazione esplicita tra conversazioni e pratiche, inclusi i veicoli secondari.
- Stesso controllo dell'invio per PDF nuovi, storici e copie equivalenti:
  originale effettivo, direzione, data, targa, byte e pratica compatibili.
- Un punto di acquisizione dell'ordine controlla offerta letta, alternativa,
  consenso, scadenza esplicita, episodio e blocchi dell'operatore. Un flag AI
  positivo da solo non acquisisce l'ordine.
- Consenso generico e scelta breve possono arrivare in messaggi successivi;
  la scelta verificata e le date restano stabili al replay.
- Registro degli ingressi e dei loro esiti, storico delle revisioni, coda
  paginata con una scheda per pratica o conversazione ancora da associare.
- Una richiesta senza targa conserva anche il contenuto ricevuto. Una richiesta
  tecnica incompleta resta lavorabile senza dichiarare completa la diagnosi.
- La risposta HTTP distingue intenzione riconosciuta e ordine salvato.
  Il messaggio principale si basa sulla ricevuta letta dal database.
- I controlli mostrano arresti ed errori sia del riconciliatore sia del recupero
  degli originali. La mancata lettura della coda non appare come assenza di lavoro.

La routine email → WhatsApp resta sospesa. Non sono introdotti invii al cliente.

## Verifiche eseguite

La struttura del database reale è stata letta da catalogo, senza importare dati
dei clienti: 51 tabelle, 181 funzioni, vincoli, 73 indici aggiuntivi e 9 viste.
La migrazione è stata eseguita in un PostgreSQL isolato tramite PGlite; cron e
identità del servizio sono predisposti solo per il collaudo locale. Questo
verifica SQL, trigger e comportamento, ma non sostituisce il collaudo nella
versione PostgreSQL gestita da Supabase, il funzionamento del cron remoto,
la concorrenza reale o il percorso HTTP e K.

Superati:

- 127 test TypeScript del canale live, compresa la ricevuta di registrazione;
- compilazione Next e controllo TypeScript;
- lint dei nuovi moduli;
- 18 gruppi di prove in `supabase/tests/affidabilita_pratiche.sql`;
- 11 suite SQL precedenti: conferme letterali, plico e instradamento,
  consenso originale e PDF tardivi, guardie delle offerte, ingresso PDF,
  scelte e ritiri, intenzione e fiscali, documenti e prove d'invio,
  preventivo storico, recupero originali, scelta conclusa e prefissi fiscali.

Tre fixture precedenti ora contengono le prove richieste dal nuovo contratto:
offerte lette con alternative, scelta precedente verificata prima dei dati
fiscali, originale effettivo per la prova PDF. Le nuove prove verificano anche
il rifiuto del percorso privo di questi requisiti; le aspettative non vengono
rese positive sulla sola base di uno stato manuale o di un riepilogo AI.

Non è certificata l'intera matrice della specifica. Restano da eseguire sul
sistema integrato: concorrenza, timeout dopo commit, interruzione dei worker,
confronto delle classificazioni reali e verifica delle risposte effettive di K.

## Sequenza di rilascio

1. Ripristinare un canale autorizzato di scrittura su Supabase. Rileggere le
   definizioni delle sette funzioni sostituite e fermarsi se sono cambiate
   rispetto allo snapshot di questa lavorazione.
2. Su un ambiente Supabase di prova, applicare atomicamente
   `20261023093042_stabilizza_pratiche_keplero.sql`, con riconciliatore sospeso.
   Eseguire la nuova suite e le 11 regressioni in transazioni annullate,
   controllare ACL, RLS, advisor e cron. Nessun invio esterno nei test.
3. Verificare anteprima autenticata, webhook con ricevuta, una richiesta
   incompleta, un PDF storico e due veicoli nella stessa chat. Provare anche
   errore del registro e worker fermo. La pagina non deve indicare tutto regolare.
4. Rivedere le classificazioni sulle pratiche attive, senza promuovere in massa
   flag AI. Verificare le varianti e il carico della coda; conservare le differenze
   come eccezioni motivate. Esaminare i casi già recuperati senza sovrascriverli.
5. Applicare la migrazione di produzione, quindi distribuire l'applicazione.
   L'app nuova richiede le nuove RPC: **non distribuirla prima dello schema**.
6. Verificare il contratto dal vero strumento usato da K: `ricevuta` conferma
   la registrazione dell'ingresso; solo `ordine_registrato` autorizza a dire che
   l'ordine è acquisito. I requisiti amministrativi rimangono distinti.
7. Attivare `keplero_stato_riconciliazione.attivo` solo dopo i controlli.
   Eseguire i primi lotti in modo controllato, rileggere gli esiti e i casi
   campione, misurare errori, arretrato, fonti senza associazione e tempi.

Il cron nuovo è predisposto ogni minuto ma restituisce `sospeso` finché il
controllo non è attivo. Il backfill comprende gli ultimi 30 giorni di eventi e
originali e tutti i documenti già acquisiti; il recupero storico ulteriore va
selezionato per le pratiche rilevanti. Gli ingressi futuri non hanno quel taglio.

## Ripristino

`supabase/rollback/stabilizza_pratiche_keplero.sql` sospende il nuovo controllo,
rimuove il suo cron e i nuovi trigger, ripristina le sette funzioni precedenti
e conserva tabelle, prove e storico per l'analisi. È da applicare come
proprietario della migrazione; l'applicazione va riportata alla versione
precedente e i dati commerciali vanno riletti, senza annullare ordini reali.
La sospensione del solo cron non disabilita i trigger: non equivale al ripristino.

## Confine della copertura

Il recupero degli originali usa ancora K come fonte. Un messaggio WhatsApp mai
consegnato a K non può essere trovato rileggendo K. Non è stata aggiunta una
fonte WhatsApp indipendente. Le formule «tutte le varianti» o «stabile al 100%»
non sono una garanzia tecnicamente sostenibile: il sistema deve conservare e
rendere lavorabili anche le varianti che non interpreta automaticamente.

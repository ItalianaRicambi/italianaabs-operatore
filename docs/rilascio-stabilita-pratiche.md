# Stato del rilascio — 23 ottobre 2026

**Correzione coda installata e verificata nel database reale alle 23:31, ora italiana.**
Il pacchetto corretto ha completato anche le prove prima del commit. La lettura
indipendente conferma migrazione `20261023205350`, nuova colonna, 569 schede
operative e 1.487 attese automatiche, totale invariato di 2.056. Nessuna fixture
residua; accessi anon/authenticated negati e servizio autorizzato. Il registro
commerciale conserva zero errori e dieci esiti elaborati; recupero generale
ancora sospeso. Il timeout transitorio degli originali si è recuperato; restano
dodici sessioni non disponibili dalla fonte K. Si procede a pubblicare il codice
della coda in anteprima mediante l’integrazione GitHub → Vercel.

**Anteprima autenticata verificata alle 22:26 circa, ora italiana.**
Il commit `9b7a0f0b80594842a127a047a72155127cd9b374` ha ricreato l'anteprima
tramite l'integrazione GitHub dopo la configurazione delle variabili Preview.
Vercel segnala distribuzione riuscita. Le richieste senza sessione tornano al
login; l'utente ha verificato accesso come Operatore 1, Dashboard collegata a
Supabase, elenco di 14 schede e dettaglio dei 24 eventi della pratica 2293.
Le letture indipendenti del database confermano questi conteggi. La pratica
2293 risulta già `preventivo_inviato`; i suoi eventi attendono la riconciliazione.
Le nuove credenziali Preview e la chiave Supabase separata sono state inserite
dall'utente direttamente nelle rispettive impostazioni; nessun valore è nel repo.

**Patch concorrenza installata e riletta nel database reale.**
L'installer ha applicato la sola modifica dei lock, simulato dieci fonti e
annullato gli effetti della simulazione. La migrazione `20261023144505` risulta
installata; i lock condiviso sul lotto/esclusivo sulla chat e le ACL sono
confermati dal catalogo. Il riconciliatore resta sospeso.

**Primo lotto reale di dieci documenti completato alle 22:46, ora italiana.**
La lettura indipendente conferma dieci esiti elaborati, nessun nuovo errore:
un preventivo inviato riconosciuto (pratica 2191), sette PDF da associare e due
documenti senza prova sufficiente dell'invio. I casi campione 1684, 1960, 2108,
2087, 2168, 2170, 2196 e 2293 mantengono gli stati commerciali precedenti.
Non si associano i sette PDF sulla sola coincidenza della targa.

Il ricalcolo della coda ha evidenziato un difetto: anche gli ingressi ricevuti
ma ancora da valutare diventavano schede apparentemente operative. Su 2.056
schede, la nuova proiezione letta in sola lettura distingue 1.487 attese
automatiche e 569 schede operative: 560 richieste di preventivo già presenti e
nove documenti da associare. Nessuna scheda viene eliminata o risolta.
La migrazione `20261023205350_separa_attese_automatiche_coda.sql` aggiunge
`attesa_automazione` alla vista e separa i conteggi. Le richieste esplicite
anche senza targa, le anomalie valutate, le priorità urgenti, le assegnazioni e
i motivi nuovi restano operativi. L'applicazione aggiunge due elenchi distinti.
La proiezione aggrega le fonti una sola volta; la lettura sullo storico reale
restituisce gli stessi conteggi senza le ripetute ricerche per singola scheda.

**Correzione coda installata; verifica della nuova anteprima in corso.**
Il primo tentativo remoto è stato fermato dal precontrollo: il file non
normalizzava i ritorni a capo CRLF presenti nella funzione installata tramite
Windows. Il database conferma migrazione assente, vista precedente, nessuna
fixture e riconciliatore sospeso. La versione corretta normalizza soltanto CRLF
in LF prima dell'impronta, mantenendo il confronto esatto del resto del codice.
La stessa espressione verificata in sola lettura sul database remoto coincide
con l'impronta attesa. Il pacchetto completo passa in locale sia LF sia CRLF;
una modifica reale al predicato della funzione viene ancora rifiutata e annulla
la transazione senza modifiche a vista o storico migrazioni. Usare il pacchetto
corretto `patch_coda_operatore_v2.txt`, che sostituisce il precedente.

`patch_coda_operatore_v2.txt` esegue la migrazione, collauda le varianti con ACL
reali dentro un savepoint, annulla tutte le fixture e conserva la patch.
Il pacchetto completo e il ripristino passano nel database locale isolato;
passano nuovamente i 19 gruppi e le 11 regressioni, oltre alla nuova suite
`attese_automatiche_coda.sql`. Compilazione Next/TypeScript e lint dei tre file
applicativi modificati passano. Queste prove non sostituiscono la verifica
successiva sul database gestito e sull'anteprima autenticata.
La nuova vista è ora installata e riletta nel database; si pubblica il codice
app che la interroga. Nessun altro lotto viene eseguito prima di questa verifica.

**Migrazione V2 installata in produzione alle 16:36 circa, ora italiana.**
L'esito finale e una lettura indipendente confermano la versione `20261023093042`,
le nuove tabelle, le funzioni e l'assenza delle fixture `test_affidabilita`.
I 19 gruppi e le 11 regressioni sono passati prima del commit remoto.
Il riconciliatore resta `attivo=false`; il cron è predisposto e quattro esecuzioni
di controllo sono riuscite senza avviare la riconciliazione.
**La nuova applicazione non è in produzione e il recupero generale non è attivo.**
Non rieseguire l'installer V2: sostituisce funzioni e crea tabelle già presenti.

Il primo tentativo completo era stato annullato dal collaudo dei permessi.
Rimane indisponibile il canale di scrittura automatica Supabase
(`Invalid or expired requestState`). Il browser automatico restituisce ancora
`credential_observation_restricted`, anche aprendo la Dashboard in una nuova
scheda. Vercel restituisce 403 per il team `italiana-ricambi` e l'elenco dei team
autorizzati è vuoto. Il plugin risulta installato: manca l'accesso del collegamento
al team, non un'ulteriore autorizzazione dell'utente a svolgere il progetto.

## Controlli successivi all'installazione

- RPC e helper nuovi non eseguibili da `anon` o `authenticated`; search path
  fissato; registro privato non esposto direttamente al servizio.
- Nessun nuovo avviso di sicurezza sulle funzioni introdotte. Gli avvisi su RLS
  senza policy sono attesi per queste tabelle riservate al backend; gli avvisi
  sulle funzioni precedenti rimangono da trattare separatamente.
- Circa 12.009 fonti nel registro, ancora da elaborare; zero errori nel nuovo
  registro. Questo non significa che siano già state riconciliate.
- Pratiche 1684, 1960 e 2108 fatturate; 2087, 2168 e 2170 con offerta letta e
  preventivo inviato; 2196 ordine acquisito/da fatturare con fiscali incompleti.
- Il recupero originali preesistente segnala 12 sessioni `non_disponibile` e
  otto `registro_57014`. Nei log delle 16:37, tre richieste scadono mentre attendono
  il lock esclusivo della stessa riga `keplero_recupero_originali`; altre scadono
  poco dopo averlo ottenuto. Il client avvia otto sessioni in parallelo, ma la
  registrazione le serializza sul controllo globale. Non è ancora dimostrato
  che questa contesa sia l'unica causa dei timeout. Alla rilettura delle 16:51,
  le otto sessioni sono state recuperate automaticamente: nessun errore 57014
  residuo. Restano le 12 sessioni non disponibili dalla fonte. I timeout erano
  sovrapposti all'installazione e ai suoi test: non provano un guasto permanente
  introdotto dalla migrazione.

La correzione `20261023144505_parallelizza_registro_originali.sql` è
**applicata e riletta**. Usa un lock condiviso sul lotto e un lock esclusivo sulla
singola chat: chat diverse possono registrare insieme, la stessa chat non può
essere registrata due volte contemporaneamente e il lotto non può essere
modificato durante la registrazione. La suite commerciale con ACL reali passa
anche dopo questa correzione. La prova su PostgreSQL nativo è definita in
`scripts/test_concorrenza_originali.py` e nel workflow dedicato è **passata**
su PostgreSQL 17 nativo (run `39973112806`, job `120480668678`, commit
`fac600c55008ac21d56cbca8c73496a63f5424fb`). Verifica anche che la versione precedente riproduca
il blocco, otto transazioni aperte insieme, il vincolo sulla stessa chat,
la protezione del lotto, i lease invalidi e il replay senza duplicati.

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
Il primo tentativo nel database reale è stato annullato dal test del flag AI:
la valutazione tentava di leggere direttamente un registro privato. La correzione
espone solo stato ed esito mediante una funzione riservata al backend, senza
concedere accesso diretto alla tabella. Il riconciliatore esegue i recuperi come
proprietario, tramite la sola RPC riservata.

La migrazione è stata nuovamente eseguita con le ACL effettive di 180 coppie
relazione/ruolo, 543 coppie funzione/ruolo e le colonne identity reali,
in un PostgreSQL isolato tramite PGlite; cron è predisposto solo per il collaudo locale. Il precedente ambiente
locale aveva permessi più ampi sul registro privato; questo limite è corretto
e la suite ora verifica anche il divieto di accesso diretto del servizio. Questo
verifica SQL, trigger e comportamento, ma non sostituisce il collaudo nella
versione PostgreSQL gestita da Supabase, il funzionamento del cron remoto,
la concorrenza reale o il percorso HTTP e K.

Superati:

- 127 test TypeScript del canale live, compresa la ricevuta di registrazione;
- compilazione Next e controllo TypeScript;
- lint dei nuovi moduli;
- 19 gruppi di prove in `supabase/tests/affidabilita_pratiche.sql`;
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

1. La migrazione V2 è già applicata e riletta: non rieseguirla. Le impostazioni
   Preview sono state completate manualmente e l'integrazione GitHub permette
   di distribuire l'anteprima anche mentre il collegamento Vercel restituisce 403.
   Il canale di scrittura Supabase automatico rimane indisponibile.
2. Il test nativo dei lock e la patch concorrenza sono completati. Installare
   la correzione della coda con il pacchetto collaudato, rileggere i conteggi e
   pubblicare la nuova anteprima. Restano dodici sessioni indisponibili dalla
   fonte K, distinte dagli errori del nuovo registro.
3. Accesso autenticato, Dashboard, coda e dettaglio eventi verificati
   nell'anteprima. Restano webhook con ricevuta, una richiesta
   incompleta, un PDF storico e due veicoli nella stessa chat. Provare anche
   errore del registro e worker fermo. La pagina non deve indicare tutto regolare.
4. Rivedere le classificazioni sulle pratiche attive, senza promuovere in massa
   flag AI. Verificare le varianti e il carico della coda; conservare le differenze
   come eccezioni motivate. Esaminare i casi già recuperati senza sovrascriverli.
5. Con le migrazioni installate e verificate, distribuire l'applicazione.
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

Se installata la correzione della coda, ripristinare prima
`supabase/rollback/separa_attese_automatiche_coda.sql`: mantiene la colonna
aggiunta per la compatibilità dell'app e non elimina schede.
Per annullare anche la correzione della concorrenza, applicare poi
`supabase/rollback/parallelizza_registro_originali.sql`.
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

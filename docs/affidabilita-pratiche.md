# Affidabilità del percorso richiesta → preventivo → ordine

Analisi del 23 ottobre 2026. Stato: diagnosi verificata e due pratiche corrette;
la sostituzione del motore descritta sotto è una specifica da implementare e
collaudare, **non è attiva**. Nessuna nuova regola generale è stata distribuita
con questa analisi. La routine email → WhatsApp resta in attesa.

## Risultato richiesto

Ogni evento effettivamente ricevuto deve avere un esito registrato: applicato,
già applicato, irrilevante con motivazione, in attesa di un requisito, oppure
in verifica con un responsabile. Nessun evento può essere considerato concluso
soltanto perché K ha risposto al cliente o perché una chiamata HTTP è riuscita.

Non è possibile garantire il 100% di interpretazione del linguaggio naturale,
delle immagini o di disponibilità dei fornitori. Si deve invece progettare e
misurare la completezza del percorso per gli eventi acquisiti e rendere visibili
anche i guasti del controllo. Una fonte non acquisita non può essere recuperata
con un'altra lettura della stessa fonte incompleta.

## Evidenze verificate nel sistema reale

| Caso | Causa verificata | Correzione eseguita e riletta |
| --- | --- | --- |
| Pratica 2196 | Conferma esplicita già riconosciuta dal webhook. PDF storico nella stessa chat, medesima targa e byte, non collegato a causa della finestra temporale rispetto alla creazione della pratica. | Collegamento storico verificato e tracciato; unica alternativa RI da 447 EUR, ordine acquisito e da fatturare. Date originali di invio e consenso conservate. Controlli amministrativi separati, anagrafica non dichiarata pronta. |
| Pratica 2170 | Targa leggibile nel libretto originale ma assente nei dati estratti da K. La pratica rimaneva in raccolta dati; il PDF inviato successivamente non poteva abbinarsi. | Targa e veicolo verificati dal libretto; invio originale del PDF verificato, alternative registrate; stato preventivo inviato. Nessun ordine dedotto. |

Entrambe le correzioni sono state provate con `service_role` in transazioni
annullate, poi salvate e rilette con una query indipendente. Le prove originali
e le azioni di manutenzione sono nel database; i dati fiscali e personali non
sono riprodotti in questo documento.

Le protezioni contro le regressioni esistono già (`proteggi_stati_avanzati`).
Nei due casi il passaggio corretto non era mai avvenuto. Aggiungere un'altra
protezione contro le regressioni non risolve queste due cause.

Il canale HTTP restituisce già il riconoscimento dell'intenzione e l'esito
dell'avanzamento, ma anche `ok: true` quando la ricezione è riuscita e l'ordine
non è acquisito. Il contratto va reso inequivocabile e collaudato anche lato K:
`ricevuto` non significa `ordine registrato`.

Lettura delle funzioni effettivamente distribuite, dei trigger e dei registri:

- regole ripartite tra route HTTP, trigger, lettura PDF, recupero originali e
  manutenzione; esiste già un coordinatore serializzato per la manutenzione;
- abbinamento dei documenti dipendente da targa e finestre temporali, senza un
  riferimento stabile alla pratica per i documenti storici;
- gli originali possono essere acquisiti correttamente senza risolvere il
  collegamento tra offerta e pratica;
- copie di documenti equivalenti possono aumentare il numero di candidati;
- il controllo degli originali esamina soprattutto messaggi candidati: non è
  un rendiconto di tutti gli eventi entranti;
- la pagina degli originali mostra le ultime 200 verifiche per messaggio,
  invece di una coda completa ordinata per priorità della pratica.

Nello snapshot iniziale erano presenti 904 verifiche aperte: 395 PDF, 347
segnalazioni di collegamento all'offerta mancante, 115 segnalazioni contenenti
parole di pagamento e altri casi. **Non sono 904 ordini persi.** Anche una
domanda sul bonifico può generare un avviso. I numeri sono uno snapshot e
cambiano durante l'operatività.

Una ricerca supplementare sugli ultimi sette giorni, dopo le due correzioni,
ha trovato altre due pratiche con flag AI positivo ma senza ordine acquisito.
La lettura dei testi ha mostrato richieste informative o proposte da valutare,
non una conferma univoca. Non sono state promosse automaticamente. Questo
controllo non certifica l'assenza di altri ordini persi: i falsi negativi del
flag non compaiono nella ricerca.

## Un solo motore autorizzato a decidere gli avanzamenti

Conservare i registri e le protezioni utili già presenti. Sostituire per passi
le decisioni distribuite con una funzione transazionale unica. Webhook,
importazioni, operatori e recuperi devono inviare comandi o fatti verificabili
a questo motore; non devono applicare versioni differenti delle stesse regole.

La chiave di lavoro è l'episodio della pratica. La chat e il telefono possono
contenere più veicoli o interventi. Per nuove offerte usare esplicitamente
`pratica_id`, `episodio_id`, `offerta_id`, `versione`, `opzione_id`; conservare
questi riferimenti nel documento e nei metadati di invio. Un riferimento nel
nome del file aiuta, ma non sostituisce un collegamento verificato.

Per il patrimonio storico, collegare congiuntamente messaggio di invio,
conversazione, documento verificato, veicolo e componente. Se i risultati sono
più di uno, conservare il caso nella coda; non scegliere il più recente per
telefono, nome o targa. Non rendere globalmente illimitata la finestra per
risolvere il singolo caso storico.

### Fatti e dimensioni distinti

| Fatto verificato | Effetto commerciale | Requisiti o coda separata |
| --- | --- | --- |
| Richiesta di preventivo | Presa in carico immediata, anche incompleta | Dati tecnici mancanti, immagini da leggere |
| Dati tecnici sufficienti | Da preventivare se non esiste già offerta inviata pertinente | Identificativi discordanti da verificare |
| Preventivo generato | Preventivo pronto | Generazione non prova l'invio |
| Preventivo effettivamente inviato | Preventivo inviato | Versione e prova di invio collegate |
| Accettazione univoca di offerta/opzione | Ordine acquisito, da fatturare | Anagrafica e indirizzi incompleti non cancellano l'ordine |
| Consenso con più opzioni o condizioni | Accettazione da chiarire, azione persistente | Nessuna scelta economica arbitraria |
| Anagrafica completa e verificata | Pronto alla fatturazione | Rimane distinto dall'acquisizione dell'ordine |
| Proforma | Documento amministrativo distinto | Non equivale a fattura emessa o pagamento ricevuto |
| Fattura effettivamente emessa | Fatturato | Numero, documento e prova, senza deduzioni dalla chat |
| Revoca o modifica successiva | Revisione esplicita e tracciata | Nessuna cancellazione automatica silenziosa |
| Nuovo veicolo o post vendita | Nuovo episodio collegato | Non retrocedere la vendita già conclusa |

I dati devono accumularsi con la propria fonte. Un messaggio successivo vuoto
non cancella una targa verificata. Un indirizzo di ritiro non sostituisce quello
fiscale. Una domanda sulla spedizione non revoca un consenso precedente.

### Contratto di registrazione proposto

Ogni esito contiene almeno `evento_id`, `pratica_id`, `episodio_id`,
`versione_stato`, `esito`, `stato_effettivo`, `requisiti_mancanti`, `anomalia_id`
e riferimenti alle prove. Esiti ammessi:

- `applicato`: modifica salvata e verificata;
- `gia_applicato`: stesso evento già registrato, nessun duplicato;
- `in_attesa`: requisito oggettivo mancante e lavoro persistente;
- `da_verificare`: dubbio di identificazione o interpretazione;
- `irrilevante`: motivazione verificabile, non semplice assenza di parole chiave.

K può dire «ordine registrato» solo quando lo stato effettivo salvato lo
conferma. Negli altri casi comunica la ricezione e la verifica necessaria.
La promessa operativa non deve dipendere dal flag AI o dal codice HTTP 200.

Usare chiavi uniche per fonte e ID originale, blocco della pratica, controllo
della versione, cronologia append-only e coda delle operazioni successive
nella stessa transazione. I retry devono produrre una sola transizione
effettiva. Per invii esterni distinguere tentativo, invio verificato ed esito
sconosciuto; un timeout non autorizza a inviare due volte o a dichiarare inviato.

I lock e i vincoli del database servono a prevenire duplicazioni e scritture
concorrenti; non rendono corretta da soli l'interpretazione di un messaggio.
Riferimenti tecnici: documentazione PostgreSQL su
[lock](https://www.postgresql.org/docs/current/explicit-locking.html) e
[vincoli](https://www.postgresql.org/docs/current/ddl-constraints.html).

## Riconciliazione indipendente e coda per pratica

Il controllo deve partire dal registro di tutti gli ingressi ricevuti e dalle
prove di invio, non solo dalle classificazioni prodotte da K. Per ogni evento
verifica la presenza di un esito e la coerenza con la pratica. Il riconciliatore
non deve diventare un secondo motore con regole commerciali proprie: inoltra
al motore unico i lavori mancanti e conserva le eccezioni.

Una scheda operativa per episodio raggruppa tutte le anomalie e mostra la più
urgente: consenso non acquisito, PDF inviato non collegato, richiesta senza
presa in carico, immagine non letta, dati discordanti, fonte non disponibile.
Ogni causa conserva prima rilevazione, ultimo controllo, prove, responsabile,
scadenza, prossimo tentativo ed esito. La presa in carico di un operatore non
equivale alla soluzione; la chiusura richiede una verifica dell'esito concreto.
Paginazione e conteggi completi impediscono che il limite della pagina nasconda
le pratiche più vecchie o urgenti. Chiudere un avviso su un evento non chiude
automaticamente anomalie nuove dello stesso episodio.

Gli avvisi di pagamento, PDF già correttamente registrati e semplici duplicati
non devono sommergere i consensi bloccati. L'assenza di una modifica attesa
deve restare visibile anche se K ha risposto al cliente.

Per sapere se una chat WhatsApp è mancata anche a Keplero serve un confronto
con una fonte WhatsApp indipendente, supportata e autorizzata dal fornitore.
Due letture delle API di K non coprono quel guasto. Prima di dichiarare coperto
questo punto occorre verificare accesso, completezza e continuità degli ID della
fonte indipendente con un messaggio di prova reale. Finché manca, la copertura
va dichiarata limitata ai messaggi che K rende disponibili.

## Collaudo richiesto prima del cambio del motore

La tabella è una matrice di accettazione **da eseguire** sul nuovo motore.
Non rappresenta test già superati dalla versione attuale.

| Scenario | Esito atteso |
| --- | --- |
| Prima richiesta senza targa | Lavoro persistente, raccolta dati; nessuna richiesta persa |
| Targa solo nella foto del libretto | Fonte immagine conservata; lettura verificata oppure coda immagini |
| OCR incerto o immagine non disponibile | Nessun dato inventato, anomalia con azione concreta |
| Dati distribuiti su molti messaggi | Accumulo senza cancellazione dei dati già verificati |
| Ultimo messaggio è «grazie» o parla di spedizione | Conservazione del consenso e dell'ordine precedenti |
| Flag AI positivo su richiesta informativa | Nessun ordine; esito motivato |
| Flag AI negativo con consenso letterale | Originale valutato, aggiornamento o eccezione persistente |
| PDF creato e non inviato | Preventivo pronto, nessuna prova di invio inventata |
| PDF inviato da operatore mentre K è fermo | Stesso percorso di registrazione e riconciliazione |
| PDF storico, pratica nata dopo settimane | Collegamento esplicito verificabile o singola anomalia |
| Stesso PDF rinominato, copiato o reimportato | Prova originale distinta dalla versione economica; nessun duplicato di ordine |
| Documento modificato con stesso nome | Nuova versione; nessuna sostituzione retroattiva delle prove |
| Due veicoli nella stessa chat | Episodi distinti, nessuna scelta implicita per telefono |
| Targa corretta ma componente diverso | Nessun abbinamento automatico ambiguo |
| Più offerte e più alternative | Consenso riferito alla versione e opzione corrette |
| Accettazione generica con unica opzione | Ordine acquisito sulla proposta inviata verificata |
| Accettazione generica con due opzioni | Consenso da chiarire; non scegliere prezzo o servizio |
| Consenso condizionato, domanda o negazione | Nessun ordine arbitrario, motivazione e lavoro conservati |
| Testo mai visto prima | Esito esplicito o verifica; mai perdita per assenza di regex |
| Consenso arrivato prima dell'importazione PDF | Attesa del requisito, poi rivalutazione con date originali |
| Offerta con scadenza esplicita superata | Verifica commerciale; non azzerare la data di invio |
| Offerta senza validità indicata | Non inventare una scadenza |
| Dati fiscali incompleti o discordanti | Ordine conservato, fatturazione bloccata separatamente |
| Ritiro e fatturazione con indirizzi diversi | Campi separati e fonti visibili |
| Dichiarazione di bonifico o domanda sul bonifico | Nessuna quietanza o fattura dedotta |
| Proforma esistente | Non segnare fatturato |
| Revoca o cambiamento di opzione | Revisione tracciata; nessun annullamento silenzioso |
| Fattura esistente e nuovo messaggio tecnico | Fattura preservata, nuovo episodio se necessario |
| Evento duplicato, riavvio o retry tardivo | Una sola modifica effettiva, stesso esito consultabile |
| Due aggiornamenti simultanei e correzione operatore | Conflitto gestito; dati protetti non sovrascritti |
| Timeout dopo commit | Lettura dell'esito con la chiave originale, nessuna duplicazione |
| Job fermo, errore parser o registro non leggibile | Stato di controllo degradato, mai «nessuna anomalia» per errore |
| Messaggio non acquisito da K | Rilevazione solo se esiste fonte indipendente verificata; limite esplicito altrimenti |

Per ogni scenario verificare insieme stato finale, prove, esito dell'evento,
coda operativa, risposta consentita a K e assenza di duplicati dopo replay.
I dati reali dei casi recuperati vanno anonimizzati nei test del repository.

## Rilascio e criteri misurabili

1. Censire tutti i punti che scrivono gli stati e definire il contratto unico;
   mantenere i blocchi operatore, i controlli fiscali e i casi terminali.
2. Introdurre registrazione degli ingressi, esiti e coda persistente senza
   cambiare ancora gli avanzamenti. Confrontare tutti i canali disponibili.
3. Far calcolare il nuovo motore in sola lettura sugli stessi eventi, con
   differenze motivate e riproducibili rispetto al sistema attuale.
4. Superare la matrice, inclusi ritardi, retry e aggiornamenti concorrenti.
   Provare anche il guasto del riconciliatore e la segnalazione del suo arresto.
5. Spostare gli avanzamenti al motore unico, per canale/episodio, con percorso
   di rollback. Disabilitare le vecchie scritture equivalenti per quel percorso;
   evitare due motori attivi sulla stessa pratica.
6. Riconciliare le pratiche attive e il patrimonio storico rilevante a lotti,
   senza applicare in massa flag AI o consensi ambigui. Misurare il lavoro
   arretrato e la sua età, non soltanto il numero di messaggi letti.

Obiettivi di servizio proposti, da collaudare e configurare:

- ogni ingresso acquisito conservato prima di rispondere che è registrato;
- per ogni ingresso, un esito oppure un lavoro persistente ancora aperto;
- presa in carico e riconciliazione ordinaria entro cinque minuti dalla
  ricezione, con anomalia tecnica persistente al superamento; il ritardo di
  discovery della fonte va misurato separatamente;
- contatori completi di ingressi senza esito, ordini potenziali bloccati,
  documenti inviati non collegati, lavori scaduti e ultimo ciclo riuscito;
- nessuna chiusura per semplice risposta inviata al cliente;
- passaggio al nuovo motore solo con matrice superata e differenze della fase
  di confronto spiegate. Nessuna dichiarazione di affidabilità «100%» basata
  sui soli due recuperi manuali o su una suite di frasi note.

La garanzia operativa da perseguire è l'assenza di perdite silenziose entro i
confini delle fonti acquisite, con verifiche e recuperi misurabili. Le ambiguità
restano eccezioni gestite; non diventano né pratiche dimenticate né ordini
inventati.

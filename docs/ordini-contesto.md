# Recupero ordini da conversazione

Problema: l'invio dei dati fiscali dopo l'accettazione e la richiesta di apertura
pratica poteva essere trattato come aggiornamento anagrafico. Un preventivo
scaduto o il limite di 30 giorni degli originali lasciavano il consenso senza
avanzamento commerciale.

Il controllo aggiuntivo usa messaggi originali, ordinati cronologicamente dopo
l'ultima offerta. Richiede intenzione positiva, richiesta operativa di dati e
risposta fiscale. La scelta deve corrispondere a una sola opzione dell'offerta.
Una scelta del proprio dispositivo è sufficiente solo con una sola opzione di
riparazione. Non usa il solo riepilogo AI per confermare.

L'aggiornamento di scelta, stato e audit è atomico. Ordine acquisito e da
fatturare persistono; uno slittamento di smontaggio/ritiro non è una rinuncia.
Un prezzo scaduto produce una sospensione amministrativa e un avviso urgente,
non la perdita dell'ordine. I dati già ricevuti ma non correttamente estratti
generano lavoro per l'operatore, senza nuova richiesta automatica al cliente.

Ambiguità di conversazione, servizio, blocco operatore, messaggi modificati e
rinuncia successiva richiedono verifica. Le attività compaiono nella categoria
esistente Richiamata post-preventivo, con priorità urgente e testo VERIFICA
ORDINE. Nessuna fattura o spedizione è emessa da questo controllo.

## Esecuzione e osservabilità

- Trigger sui messaggi originali e sui collegamenti accodano la pratica.
- Cron `controllo-ordini-contesto` ogni minuto, massimo 50 pratiche.
- Riconciliazione indipendente delle offerte aperte anche precedenti a 30 giorni.
- Ricontrollo giornaliero, retry degli errori ogni cinque minuti, audit persistente
  in `private.controlli_ordini_contesto`; errori anche nelle attività operatore.
- Mutazioni protette da lock e chiamate ripetute idempotenti.
- Funzioni private, accesso pubblico/anonimo/autenticato revocato.

Il tempo complessivo comprende anche l'importazione preesistente degli originali
da Keplero. Il controllo non può interpretare messaggi non ancora importati;
registra `originali_non_collegati` e segnala dati fiscali riconosciuti nel payload
quando gli originali mancano. Non è una garanzia di comprensione universale:
formulazioni non riconosciute restano da verificare, mai inventate come ordini.

## Verifica e ripristino

`supabase/tests/ordini_contesto.sql`: 15 casi sintetici in transazione con rollback.
Verifiche integrative sul caso reale, sempre con rollback prima dell'attivazione:
avanzamento da fatturare, conferma persistita, prezzo sospeso, nessuna richiesta
dati, replay senza duplicati, due pratiche nella stessa conversazione e blocco
operatore. Il caso reale è anteriore a 30 giorni rispetto all'offerta e ha anche
un messaggio recente di rinvio logistico.

Per sospendere senza cancellare dati o ordini:

```sql
select cron.unschedule('controllo-ordini-contesto');
```

Le righe della coda rimangono disponibili. Per riattivare usare la stessa
`cron.schedule` della migrazione di attivazione. Non retrocedere automaticamente
gli ordini già acquisiti: rivederli con le prove in `scelte_cliente.evidenza` e
`azioni_operatore`.

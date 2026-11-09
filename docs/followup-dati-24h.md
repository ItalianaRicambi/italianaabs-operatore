# Follow-up dati mancanti — stato del 9 novembre 2026

**Implementazione parziale, invii disabilitati. Non attivare i trigger di silenzio.**

La console Keplero mostra APPROVATO / Utilità / IT per entrambi i modelli `italianaabs_dati_preventivo_24h` e `italianaabs_dati_fatturazione_24h`. Non sono stati creati duplicati. Le automazioni esistenti restano disabilitate:

- Preventivo: `5107ac52-284d-4c76-b09d-951e85b9a2e8`; trigger silenzio 1440 minuti, filtro risposta e template incompleti.
- Fatturazione: `cb6a0de3-f443-463c-a3ee-6de18d426b20`; solo trigger silenzio 1440 minuti.

L'approvazione non dimostra che il reminder sia inviabile. Il trigger generico può scattare dopo un messaggio che non richiede dati e non può essere usato come data della richiesta.

## Preparazione completata

Il ramo `codex/followup-dati-24h`, basato su `bacb589`, conserva la policy pura e 19 test sintetici. Nessun endpoint, cron o trasporto richiama ancora la policy. Le modifiche degli altri checkout sono state lasciate intatte.

La migrazione `20261109123445_registro_followup_dati_disabilitato.sql` è applicata al progetto `kfzvulpuorvxycyqezlp`. Aggiunge solo tre tabelle e tre funzioni servizio, senza modificare pratiche, documenti, prezzi, fatture o trasporti. Stato verificato: `enabled=false`, `transport_verified=false`, `accept_requests_after=null`, `calendar_confirmed_through=null`, zero richieste e zero invii.

Il registro conserva richiesta originale, data di invio, impronta e campi richiesti. La registrazione richiede un originale in uscita con prova di invio e un cutover esplicito. Il claim usa `INSERT ... ON CONFLICT DO NOTHING` e una chiave unica permanente pratica/fase. Non esiste un lease che riapra l'invio dopo timeout. Claim, invio ambiguo e annullamento non liberano lo slot. Una conferma tardiva può chiudere un esito ambiguo con ID messaggio e data, senza ritentare il trasporto. Nuove richieste mirate non creano un secondo slot.

`policy.ts` richiede attestazioni esplicite del futuro adattatore server: lettura completa e recente degli originali e degli allegati, fase, dati mancanti, anagrafica verificata, blocchi e documenti. Questi booleani **non devono essere accettati da payload client o dal solo riassunto AI**. L'adattatore deve produrli da prove attuali. La funzione di claim non è da sola un'autorizzazione all'invio.

Orari letti dalla funzione aziendale `public.minuti_lavorativi_trascorsi`: lunedì–giovedì 09:00–12:30 e 14:00–18:30; venerdì 09:00–13:30; Europe/Rome. Il timer è 24 ore trascorse in UTC, poi la prima apertura. `chiusure_aziendali` contiene al controllo solo la chiusura 08–30 agosto 2026. La copertura futura del calendario non è stata certificata.

ABS-002090 e ABS-002447 sono ordini con dati amministrativi mancanti e richiesta segnata `inviata`, ma `richiesta_amministrativa_inviata_at` è NULL. Non inventare la data né accodarle retroattivamente: recuperare l'originale reale o attendere una nuova richiesta mirata realmente inviata dopo il cutover.

## Collaudo eseguito, senza messaggi cliente

- 19 test Node: confine delle 24h, pausa pranzo, venerdì, weekend, chiusure, cambio ora legale/solare, dati parziali, dati completi, rinuncia, fattura/proforma, blocchi, originali/allegati incompleti, flag sconosciuti, esclusione storico, esito ambiguo, regola 48h.
- ESLint e TypeScript senza errori.
- `supabase/tests/followup_dati.sql` eseguito su Supabase in transazione e annullato: prova e data originali, cutover, replay, chiave unica, transizioni di esito e permessi. Nessun record di prova persistente, nessun invio.
- Security advisor: le tre tabelle hanno RLS e nessuna policy client, intenzionalmente. `anon`/`authenticated` non hanno privilegi; solo `service_role` usa il registro. L'avviso informativo RLS senza policy non richiede di aprire l'accesso.
- **Non ancora eseguito**: concorrenza con due worker reali, risposta arrivata fra claim e chiamata al provider, contratto invio/conferma e timeout Keplero, prova del percorso end-to-end e della segnalazione operatore. I test della chiave unica non sostituiscono questi collaudi.

## Passaggi mancanti prima dell'attivazione

1. **Trasporto supportato e verificabile.** Ottenere/validare il contratto Keplero per inviare esattamente questi template, con variabili numero pratica e soli campi mancanti, conferma e ID messaggio. Verificare ritentativi automatici, code differite e riconciliazione di esiti ambigui. La documentazione pubblica cercata non ha fornito questo contratto; il ticket supporto del 21/10 documenta lettura, identità e timestamp, ma non l'invio template. L'UI espone un trigger Webhook e il nodo Modello WhatsApp, senza che siano state collaudate garanzie di retry o ritorno ID. Non dedurre un endpoint privato e non inviare messaggi di prova ai clienti.
2. **Registrazione mirata delle richieste realmente inviate.** Collegare la lettura originale alla richiesta esatta e alla pratica/fase, con campi verificati; le date manuali e i messaggi generici non bastano. Il supporto conferma che per i messaggi in uscita non esisteva un webhook automatico al 21/10: usare polling documentato o nuova funzionalità ufficialmente verificata. Non servono duplicati dei template.
3. **Adattatore server di verifica finale.** Rileggere tutte le pagine della conversazione e gli allegati aggiornati subito prima dell'invio; ricontrollare anagrafica/Fatture in Cloud, documenti, rinunce, chiusure, blocchi e dati residui. I controlli cached del worker originali esistente non sono sufficienti: legge fino a otto PDF candidati per lotto e non valuta tutti i possibili dati in immagini/audio/allegati. Qualsiasi lettura incompleta o risposta da verificare deve fermare il reminder.
4. **Scheduler e calendario.** Collegare una selezione di sole richieste posteriori al cutover, data+24h e fascia lavorativa. Confermare copertura di festività/chiusure. Se il provider differisce l'invio, ripetere il controllo finale all'effettiva ripresa; una verifica precedente alla coda non basta.
5. **Segnalazione dopo altre 48h.** La regola di eleggibilità è testata, ma manca la creazione persistente e idempotente dell'attività visibile all'operatore, con stop su risposta e senza invio aggiuntivo. Non sostituirla con un reminder personale ChatGPT.
6. **Code e collaudo integrato.** Collegare le attese delle richieste registrate alle code esistenti senza rimuovere i blocchi operatore. Provare concorrenza, riavvii, cambi di dati dopo claim, documenti tardivi, retry e ack persi con provider simulato/sandbox. Solo dopo questi test attivare il percorso completo; non abilitare semplicemente le due bozze native.

L'automazione ChatGPT di completamento è `Automation_975858fb99788191b8174f6c97315d3d`. Il risultato NON è completo: non comunicare che i follow-up sono operativi e non disattivare le automazioni operative. In successivi controlli evitare notifiche ripetute senza novità.

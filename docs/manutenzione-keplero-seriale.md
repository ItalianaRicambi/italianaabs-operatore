# Esclusione reciproca tra manutenzione e recupero PDF

Il 27 ottobre 2026 alle 10:15:02 UTC PostgreSQL ha rilevato un deadlock tra
`private.esegui_manutenzione_keplero()` e `private.ritenta_documenti_preventivo()`.
Il recupero PDF era stato aggiunto dopo il coordinatore e partiva allo stesso minuto,
senza partecipare al suo advisory lock. Entrambe le transazioni bloccavano pratiche.

Il recupero PDF acquisisce ora il medesimo lock transazionale `(20261015,94749)`
prima di leggere i documenti. Se occupato ritorna zero senza attendere o modificare
righe; il tentativo rimane disponibile al ciclo successivo. La frequenza resta di
cinque minuti, con avvio ai minuti 3, 8, 13… per ridurre le rinunce. Il lock protegge
anche chiamate manuali e partenze ritardate. Non si prolunga la transazione della
manutenzione inglobando un'altra fase.

Il coordinatore registra `durata_ms` per ogni fase e `sqlstate` in caso di errore,
conservando risultati, ordine e gestione delle eccezioni esistenti. I sette job che
richiamano il coordinatore mantengono la deduplicazione per finestra già presente.

## Verifica

`scripts/test_concorrenza_manutenzione.py` usa PostgreSQL 17 isolato, le due funzioni
reali estratte dalle migrazioni e dipendenze fittizie prive di effetti esterni.
La versione precedente consente il recupero PDF mentre una transazione di
manutenzione è aperta; quella corretta impedisce la sovrapposizione in entrambe le
direzioni e impedisce anche due recuperi PDF contemporanei. Dopo il rilascio viene
verificato l'abbinamento/conferma dei documenti eleggibili, la mancata ripetizione,
la telemetria delle fasi anche con un errore simulato, e i privilegi pubblici.

La pipeline `Concorrenza manutenzione e PDF` esegue il collaudo sulla PR.

## Limiti e verifica successiva

La modifica elimina la coppia di transazioni responsabile del deadlock osservato.
Non dimostra di eliminare ogni timeout operatore: il timeout delle 15:30 UTC sulla
pratica 2409 avveniva attendendo un row lock, ma il suo blocker non è stato
identificato. Le durate per fase permettono di restringere questa seconda indagine.
Non viene ripetuta l'azione della pratica 2409, risultata salvata successivamente.

Dopo l'applicazione verificare job 72 attivo con il nuovo calendario, esiti cron,
`private.keplero_manutenzione_esecuzioni.risultati`, errori DB e code pendenti.
Per rollback ripristinare le due definizioni dalle migrazioni precedenti e il
calendario `*/5 * * * *`; questo riapre la possibilità di sovrapposizione.

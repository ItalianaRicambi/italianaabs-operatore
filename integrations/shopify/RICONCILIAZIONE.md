# Riconciliazione Shopify (sola lettura remota)

Endpoint autenticato `/api/cron/shopify`, Production, ogni 5 minuti. Nessuna modifica a Shopify, pratiche, fatture o messaggi.

Credenziali server-only: SHOPIFY_CLIENT_ID, SHOPIFY_CLIENT_SECRET, CRON_SECRET. Nessun valore nel repository o nei log. Token client credentials rinnovato prima della scadenza; scope restituito deve essere esclusivamente read_orders. Negozio fissato nel codice. Redirect vietati.

Ogni esecuzione rilegge tutte le pagine degli ordini creati negli ultimi 60 giorni, non soltanto gli aggiornamenti successivi al controllo precedente: nessun salto dovuto a checkpoint o indicizzazione tardiva. Snapshot separati in ordini_shopify_api, idempotenti per ID/versione; eventi originali conservati. Ordini locali più vecchi non eliminati. La copertura non include ordini oltre il limite read_orders o cancellati/non più accessibili.

Lease database di 5 minuti, durata funzione 240 secondi, scansione interrotta prima di 200 secondi al cambio pagina. Limiti espliciti: 10.000 ordini per esecuzione, 50 righe per ordine. Il superamento produce errore visibile, mai successo parziale. La prossima esecuzione riparte dall'intera finestra. Gli snapshot già validati restano disponibili in caso di fallimento.

Nella fusione fonti vince la versione Shopify più recente, API a parità di versione. Annullamenti non riaperti, collegamenti esatti e conflitti del registro originale preservati; differenze finanziarie alla stessa versione finiscono in verifica. Hold/scheduled/stati ignoti non sono ordini automaticamente pronti.

shopify_sync_stato conserva ultimo avvio, ultimo successo completo, errore sanificato, numero ordini e limite temporale. UI rossa senza successo, in errore, o oltre 15 minuti dall'ultimo successo. Nessun segreto, messaggio remoto arbitrario o dato cliente negli errori.

Collaudo: unit test normalizzazione/fusione/salute, SQL rollback lease/idempotenza/ordine versioni/annullamenti/ACL, build Next e prima esecuzione reale. Test del webhook preesistente invariati. Non dichiarare attivo il recupero finché un'esecuzione reale completa non è registrata.

Documentazione: https://shopify.dev/docs/apps/build/authentication-authorization/client-credentials-grant e https://shopify.dev/docs/api/admin-graphql/2026-10/queries/orders ; https://vercel.com/docs/cron-jobs/manage-cron-jobs .

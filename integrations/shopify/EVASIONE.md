# Coda evasione ordini — 16 novembre 2026

La coda /ordini e il riquadro della home separano evasione e fatturazione.
Shopify è una sorgente autonoma: nessun abbinamento per nome, telefono o targa.
Gli ordini reali non evasi restano visibili anche con pratica_id nullo.
Collegamenti esatti (ID Shopify o pratica_id del registro) evitano doppio conteggio.
Annullamenti/prove/rimborsi totali della sorgente non riaprono il duplicato locale.

## Evasione

- Webhook ordini: conservato fulfillment_status, distinto da financial_status.
- Sono accettati anche orders/fulfilled e orders/partially_fulfilled, sempre con HMAC.
- Stato assente/sconosciuto e conflitti: verifica, mai evasione presunta.
- Evaso non attesta la consegna al destinatario.
- Nessun limite silenzioso di 200 righe: lettura paginata.
- Nuovi ordini commerciali acquisiti: registro evasione indipendente dalla fattura.
- Storico fatturato senza prova: da_verificare, non urgente e non automaticamente evaso.
- Chiusura manuale con prova/motivazione, sessione operatore, controllo revisione e audit.
- Per Shopify lo stato si modifica nel sistema originale, non con una chiusura locale.

## Conferme non acquisite

I messaggi letterali candidati alimentano verifiche persistenti (non ordini).
Il caricamento iniziale usa private.inizio_finestra_controllo_keplero(now(),48).
Le verifiche non scadono con la finestra; i retry identici non le duplicano né riaprono.
La coda segnala possibili revoche successive e blocchi; richiede verifica dell'offerta.
Non utilizza i flag del riconoscitore né riepiloghi come prova di accettazione.
Una scelta isolata Programma scambio, un bonifico o una domanda sul ritiro non bastano.
Acquisizione della pratica o chiusura motivata operatore rimuovono il sospetto dalla coda attiva.

## Limite ancora aperto — recupero eventi persi

Il 16/11 è stato confrontato l'intero elenco restituito da Shopify (10 ordini,
nessuna pagina ulteriore) con il registro: 6 reali attivi, 2 non evasi e 4 evasi.
Le sei revisioni identiche sono state arricchite con il solo stato di evasione,
con controllo di revisione; importi, fatture e Shopify non sono stati modificati.
La produzione ha SHOPIFY_WEBHOOK_SECRET ma nessuna credenziale Admin API per
riconciliazione periodica. Non estrarre o riutilizzare le credenziali del plugin.
Prima di dichiarare copertura completa occorre autorizzare/configurare un accesso
server Shopify read_orders, concordare la riconciliazione e collaudare recupero,
paginazione, errori e allarme di mancata esecuzione. Non è stato aggiunto un cron.
La UI espone il limite e gli errori di lettura; nessun elenco vuoto significa
automaticamente che tutti gli ordini sono acquisiti.

## Verifiche

- node --experimental-strip-types --test app/lib/*.test.ts
- npm run build
- ORDER_FLOW_SSR_ONLY=1 node scripts/test-coda-ordini-ui.mjs (HTTP/SSR, dati sintetici)
- Browser: node scripts/test-coda-ordini-ui.mjs, richiede Playwright/Chromium e permessi socket locali. Il browser non è stato collaudato in questo ambiente perché il sandbox ne impedisce l'avvio.
- ESLint file modificati
- supabase/tests/coda_evasione_ordini.sql (rollback)
- supabase/tests/shopify_annullamenti_stesso_istante.sql (rollback)
- integrations/shopify/test_registro.sql (rollback)

Nessun invio al cliente o modifica a importi, pagamenti o documenti fiscali.
La migrazione è additiva; per rollback UI ripristinare il deployment precedente,
conservando i nuovi registri e l'audit. Non cancellare le evidenze raccolte.

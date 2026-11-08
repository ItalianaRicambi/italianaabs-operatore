# Ordini accettati e fatture nella chat

La home corrente e la vista classica mostrano un avviso persistente per gli ordini commerciali acquisiti non ancora fatturati. La scheda pratica distingue emissione pronta, dati mancanti e verifica operatore. La home aggiorna i dati ogni minuto quando la scheda è visibile e l'operatore non sta compilando un campo.

Il worker controlla due anagrafiche e due PDF per lotto. Cerca clienti in Fatture in Cloud tramite identificativi fiscali, email o telefono e accetta solo corrispondenze esatte senza conflitti. Integra campi locali vuoti e conserva blocchi e dati già presenti. Una ricerca incompleta o fallita non significa cliente nuovo. I messaggi già raccolti continuano ad alimentare il flusso amministrativo esistente.

Una fattura deve essere un PDF in uscita su WhatsApp, leggibile nel formato aziendale, con targa univoca e destinatario fiscale coerente. Numero, data, totale, valuta e targa vengono confrontati con Fatture in Cloud. Serve una sola pratica compatibile nella conversazione; blocchi, sospensioni e anagrafiche in verifica impediscono il cambio automatico. Proforma e fatture di altre pratiche non chiudono l'avviso. La rilettura è idempotente; la registrazione conserva documento, impronta e provenienza. Pagamenti e logistica non vengono completati da questa automazione.

## Distribuzione e funzionamento

- UI sul ramo principale della dashboard.
- Worker `/api/fatture-in-cloud/controlli` nel deployment privato FIC esistente, dove risiedono già le credenziali, senza copiarle o allargarne l'ambito.
- `FIC_AUTOMAZIONI_ENABLED=true` solo nel deployment FIC autorizzato.
- Cron `controlli-anagrafiche-fatture-chat` ogni cinque minuti, con ticket monouso e lease di quattro minuti.
- Il recupero chat Keplero resta indipendente e alimenta il registro originale. Il tempo totale dipende dal giro di lettura chat e dalla coda dei controlli, non è istantaneo.
- `fic_worker_controlli.automatico=false` arresta le nuove chiamate; le pratiche restano consultabili e lavorabili manualmente.
- Si considerano gli allegati degli ultimi trenta giorni. Errori temporanei si riprovano; documenti non riconosciuti richiedono verifica manuale.

## Collaudo

Test TypeScript: identità, paginazione completa, destinatario, tipo documento, targa, importo, URL e direzione dei messaggi, avvisi e blocchi.
Test SQL in transazione annullata: anagrafica riusata, RPC riservate, fattura valida, messaggi in ingresso, assenza di prova WhatsApp, blocchi/sospensioni, proforma, destinatario e targa diversi, replay senza duplicati e logistica invariata.

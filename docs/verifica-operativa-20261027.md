# Verifica operativa del 27 ottobre 2026

## Correzione del collegamento alle nuove pratiche

I log di produzione segnalavano `42501` nella RPC
`attiva_pratica_conversazione_keplero`: il ruolo backend non disponeva di
DELETE su `keplero_live_links`. La funzione SECURITY INVOKER usa tale
operazione per sostituire il collegamento provvisorio del nuovo veicolo.

La migrazione `20261027115118_consenti_attivazione_pratica_keplero.sql`
è applicata in produzione. Aggiunge esclusivamente il permesso mancante a
`service_role`; RLS e permessi dei ruoli client restano invariati.

Verifica: errore riprodotto prima della modifica, prova transazionale della
correzione su un collegamento coinvolto, regressione SQL con il ruolo reale
del backend, replay idempotente e confronto completo delle due pratiche.
Le prove sono state annullate; rilettura indipendente: zero fixture residue,
DELETE solo per il backend, RLS attiva. La correzione previene l'errore futuro;
non riassegna retroattivamente conversazioni senza verifica della cronologia.

## Riconciliazione documentale

La pratica 1878 risultava ancora preventivo inviato. Il PDF originale della
fattura 518/2026 del 16 ottobre prova la vendita, identifica univocamente
veicolo, destinatario fiscale e ordine, con totale 477,60 EUR dopo lo sconto.
Una correzione tracciata ha recuperato l'ordine e registrato la fattura mediante
la RPC riservata. Prima prova con rollback, poi salvataggio e rilettura:
ordine acquisito, fatturato, documento e cliente collegati. La data dell'ordine
ricostruita dalla fattura ha precisione al giorno; non è un orario di consenso.
Nessun pagamento o completamento logistico è stato dedotto.

La pratica 2083 resta da chiarire: il messaggio indica programma scambio ma
l'offerta comprende PS e PSMI a prezzi differenti. Nessuna opzione scelta
arbitrariamente.

## Limiti della verifica e attività ancora aperte

Il database risponde e le ultime tre distribuzioni Vercel risultano READY.
Restano timeout nei log della mattina e un deadlock alle 10:15 UTC nel retry dei
documenti. Il ciclo di manutenzione delle 11:50 UTC è completato senza errori
nelle singole fasi. Questo snapshot non certifica risolti tutti i timeout.

Nove pratiche aggiornate nell'ultima settimana risultano preventivo inviato
senza un importo positivo nel preventivo o nelle opzioni: 2155, 2205, 838,
2201, 2182, 2180, 1964, 2086, 2081. Sono casi da confrontare con i documenti
originali, non prezzi da ricostruire per analogia.

Rimangono da completare l'automatismo di classificazione dei clienti Shopify,
il collaudo IVA B2B e la verifica finale del catalogo. La fatturazione
automatica resta fuori da questo intervento, come richiesto.

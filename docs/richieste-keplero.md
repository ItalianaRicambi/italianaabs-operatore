# Richieste di preventivo e assistenza

Il canale live distingue la richiesta di un nuovo preventivo dal problema su un
prodotto già acquistato. Le sole parole «garanzia», «montaggio» e «codifica» non
provano un post vendita. I dati tecnici mancanti restano visibili nella raccolta
dati commerciale; non impediscono di registrare una richiesta di assistenza.

Una nuova richiesta tecnica dopo la chiusura apre un episodio in
`assistenze_rientri`, visibile nella coda operativa, senza sovrascrivere lo stato
chiuso dall'operatore o la vendita/fatturazione. L'origine si collega soltanto con
identificativi compatibili e un risultato univoco. Il tecnico valuta il problema
e l'eventuale garanzia; l'apertura non prenota il corriere. I messaggi precedenti
a una chiusura non riaprono episodi e i replay non duplicano quelli attivi.

«Potete farmi contattare dal tecnico» registra anche la richiamata. La negazione
e l'intenzione del cliente di richiamare personalmente non la registrano.
Un preventivo dichiarato non ricevuto resta documentato come inviato, con una
segnalazione distinta per verificare destinatario e prova di invio.

## Recupero e concorrenza

I sette job di manutenzione restano attivi e chiamano lo stesso coordinatore.
Un lock transazionale comune impedisce la sovrapposizione; il registro privato
deduplica la finestra di cinque minuti. Il coordinatore esegue tutte le fasi in
ordine, isolando gli errori di ciascuna. Il worker email mantiene il proprio job.

Gli eventi falliti vengono ripresi in lotti da 100, senza limite alle sole
ultime 48 ore e senza riscrivere i messaggi originali. Il recupero usa le stesse
regole dei trigger, acquisisce il lock sulla pratica prima del registro eventi
e conserva gli errori se una fase successiva fallisce. Gli errori degli eventi
e delle fasi di manutenzione compaiono nel controllo coerenza della dashboard.
Il registro delle esecuzioni distingue una finestra esaminata dalle singole
fasi riuscite o fallite. Un evento recuperato può ancora richiedere una verifica
manuale: per esempio immagini descritte ma prive del file originale.

## Verifica

`node --test app/api/keplero/live/*.test.ts` verifica classificazione e regole
esistenti. `supabase/tests/recupero_richieste_keplero.sql` usa una transazione
annullata per verificare replay, chiusure, dati mancanti, errore in una fase
successiva, recupero e intake con il ruolo effettivo `service_role`.
Le funzioni di manutenzione restano private e non eseguibili dai ruoli pubblici.

## Scelte concluse e anagrafica fiscale

«Il cliente ha scelto per il Programma Scambio Made in Italy» esprime una
decisione conclusa, anche quando K la riporta in terza persona e il flag ordine
è rimasto falso. Webhook e recupero SQL riconoscono la stessa formulazione;
la scelta viene collegata alle alternative dell'offerta. Domande, negazioni,
semplici preferenze e scelte subordinate a disponibilità o verifiche non
acquisiscono l'ordine, neppure con un flag AI positivo. La data dell'ordine
recuperato resta quella dell'evento originale.

Gli identificativi italiani `IT` + 11 cifre vengono confrontati e registrati
nel formato nazionale, preservando il testo fiscale originale. Il confronto
normalizza anche i dati già acquisiti: il prefisso o gli spazi non generano
conflitti fittizi. Numeri diversi rimangono discordanti e i prefissi esteri
vengono conservati. La creazione del cliente richiede sempre tutti i dati
fiscali necessari, rispetta i blocchi dell'operatore e riusa gli identificativi
univoci esistenti; la presenza di dati fiscali da sola non conferma un ordine.

`supabase/tests/scelta_conclusa_e_prefissi_fiscali.sql` verifica con rollback e
con il ruolo `service_role` l'intero passaggio da offerta a scelta PSMI e coda
fatturazione, le condizioni, i dati discordanti, i replay e la conservazione
di fatture e scelte protette dall'operatore.

# Controllo delle chat in attesa

Stato al 21 ottobre 2026: il solo miglioramento del worker per isolare gli errori di abbinamento dei PDF è pubblicato. La pagina `/keplero/risposte` e la migrazione `controllo_risposte_keplero` sono una proposta ancora da applicare e collaudare nel database. Non pubblicare la pagina prima del collaudo SQL.

Il caso osservato su WhatsApp non compare nella ricerca della console K per numero o nome. Le impostazioni mostrano canale connesso, nessun numero in lista nera e recupero AI dopo 15 minuti. Questo non dimostra perché il messaggio non sia stato acquisito: la riconciliazione con la casella WhatsApp e la verifica del fornitore restano necessarie. Il polling K non può scoprire messaggi assenti dal servizio.

La proposta legge gli originali conservati e segnala l'ultimo messaggio cliente, dopo 15 minuti, in assenza di una successiva risposta verificabile. Per WhatsApp si richiede `delivered`/`read`, oppure una risposta proveniente dalla coesistenza WhatsApp. `sent`, `pending` e `failed` non chiudono l'attesa. In caso di canale ignoto si applica la stessa regola prudente. Il controllo misura presenza e consegna, non l'adeguatezza semantica della risposta.

Una verifica operatore richiede una motivazione e conserva identità e orario. Un nuovo messaggio o una revisione del messaggio precedente riaprono il controllo. Le segnalazioni esterne sono separate dagli originali K: non devono inventare ID messaggio o conversazione. Le letture incomplete, gli errori e l'elenco fermo sono espliciti nel pannello.

Gli snapshot rifiutati dal normalizzatore vengono conservati senza interpretarli solo dopo l'applicazione della migrazione. Il worker pubblicato tenta tale conservazione, ma continua a segnalare errore se la funzione non è ancora disponibile. L'originale validato resta immutabile; le ricevute di consegna sono aggiornate in un campo separato.

## Errore riprodotto e corretto

`registra_pdf_originale_k` può propagare `P0001: Messaggio originale non verificato` quando il documento è associato a una pratica la cui conversazione non coincide con quella del messaggio. Il rifiuto protegge dall'abbinamento errato e deve restare. Il worker ora conserva il rifiuto come verifica del documento e prosegue la lettura della chat; gli errori tecnici continuano a fallire il lotto. Non riapre verifiche archiviate o stati già acquisiti.

## Verifica

- 226 test Node superati e build Next completata.
- Errore della prova PDF riprodotto mediante transazione annullata, senza aggiornamenti applicati.
- Migrazione non applicata: il connettore ha restituito `Invalid or expired requestState` anche sul tentativo ridotto. Nessuna nuova tabella/funzione risultava creata dopo i tentativi.
- Prima di pubblicare il pannello: applicare la migrazione; eseguire i casi SQL di consegna fallita, consegna successiva, risposta manuale, nuovo messaggio, revisione, permessi e isolamento delle sessioni.
- Nessun messaggio inviato ai clienti e nessuna segnalazione inviata al fornitore durante questa verifica.

## Preparazione dell’attivazione

Il 21 ottobre è stato riprovato il collegamento: lettura SQL disponibile, applicazione migrazione ancora respinta con `Invalid or expired requestState`. Il plugin risulta installato/attivo e il servizio MCP è raggiungibile (401 senza autenticazione, come previsto); il percorso CLI non dispone di un accesso configurato. Nessuna nuova tabella/funzione del controllo risulta creata.

Prima dell’attivazione sono stati aggiunti:

- Verifica dell’impronta letta dall’operatore: una pagina precedente alla revisione del cliente non può archiviare il nuovo testo.
- Revisione cliente sempre sottoposta a verifica esplicita, perché l’orario dell’edit non è documentato dalla sorgente e una vecchia risposta non ne dimostra la gestione.
- Ricontrollo delle consegne delle chat ancora in attesa anche senza nuovi messaggi, rispettando il ritardo tra i tentativi.
- Registrazione motivata dell’esito delle segnalazioni esterne, conservando testo e nota iniziali.

226 test Node e build Next superati sulla versione aggiornata. I nuovi casi SQL sono predisposti per revisione, pagina obsoleta, consegna e gestione esterna; devono essere eseguiti nel database prima del merge e della pubblicazione.

## Applicazione dalla console in caso di blocco degli strumenti

La console è stata autenticata, ma il controllo del browser ha successivamente restituito `native credential state cannot be safely resumed`. Il tentativo diretto di applicazione è stato interrotto; la verifica SQL successiva ha confermato che tabella, funzione e voce di migrazione sono ancora assenti.

Lo script `supabase/manual/attiva_controllo_risposte_keplero.sql` esegue, in un'unica transazione, la migrazione e il collaudo già predisposto. Usa un savepoint per eliminare i soli dati di prova, registra la versione della migrazione e conferma la modifica solo se il collaudo passa. Non invia messaggi e non pubblica il pannello.

Dopo l'esecuzione, verificare tabella/funzione/storico tramite SQL, eseguire il controllo con il ruolo di servizio, poi completare PR 29 e verificare la distribuzione di produzione.

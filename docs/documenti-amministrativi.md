# Allineamento amministrativo della pratica

Una sospensione per dati cliente mancanti non viene rimossa dai messaggi AI. Per confermare i dati ricevuti, il modulo anagrafica della scheda recupera una bozza dai messaggi della stessa pratica e conserva i valori discordanti da verificare, senza scegliere un identificativo arbitrario. L’indirizzo di ritiro o spedizione non viene usato come indirizzo fiscale.

La conferma dell’operatore crea e collega l’anagrafica, verifica la completezza reale e riabilita la fatturazione nella stessa transazione. I rifiuti della validazione sono visibili nel modulo e i valori inseriti restano disponibili. Le anagrafiche già esistenti vanno ricercate e collegate; non vengono duplicate né sovrascritte automaticamente.

La voce **Registra fattura o pro-forma già emessa** legge il PDF originale (massimo 3 MB e 30 pagine), controllando il tipo, il numero, la data, il totale, la targa e il blocco del destinatario. Il lettore riconosce il formato aziendale con intestazione `Fattura nr.` o `Pro Forma nr.`, con dati italiani o svizzeri. Documenti scansionati, formati diversi, più targhe o intestazioni discordanti richiedono verifica manuale e non cambiano lo stato.

Il documento verificato usa la RPC `registra_documento_amministrativo_verificato`, riservata al backend con ruolo `service_role`. Prima del salvataggio verifica l’ordine e l’identità fiscale, crea o collega una sola anagrafica completa e riabilita esplicitamente la fatturazione. L’inserimento del documento e l’aggiornamento della pratica sono atomici. Numero, tipo e data impediscono registrazioni duplicate; lo stesso documento non può essere applicato a un’altra pratica.

- Una **fattura** imposta Fatturata e completa la richiesta amministrativa, conservando la data originale del documento (precisione di giorno).
- Una **pro-forma** completa i dati amministrativi e mantiene Da fatturare; non equivale a una fattura o a un pagamento.
- Ricezione, lavorazione, assistenza e ritiri restano flussi distinti e non vengono chiusi da questa operazione.

I documenti registrati, con numero e data, sono visibili nella scheda. Il testo del PDF, l’impronta e i riferimenti della fonte vengono conservati; un collegamento al PDF è mostrato quando disponibile. Il caricamento manuale non crea un nuovo servizio di sincronizzazione automatica con Fatture in Cloud o Drive.

Validazione: test del lettore PDF e delle bozze da chat, lettura di un PDF originale, build dell’applicazione e `supabase/tests/documenti_amministrativi_verificati.sql` eseguito con rollback. Il test SQL verifica fattura, pro-forma, sospensione, identità fiscale, idempotenza, targa errata, accesso limitato al backend e protezione dalle regressioni.

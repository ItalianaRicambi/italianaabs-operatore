# Recupero delle conferme originali K

L'intake AI è affiancato dalla lettura originale, secondo la risposta di Keplero Support del 21/10/2026. Ogni minuto un worker con ticket monouso e lease prende fino a otto conversazioni da elaborare. Ogni cinque minuti aggiorna l'elenco degli assistenti WhatsApp e Italiana ABS, comprese le chat gestite a mano. Legge tutte le pagine: aperte e chiuse sono due gruppi distinti e non consentono un arresto sulla prima data vecchia.

Sono accodate le conversazioni con attività negli ultimi trenta giorni. Nuove attività, errori e letture non completate rimangono da elaborare; gli errori dell'elenco non avanzano la data di copertura. Una risposta con formato non valido viene segnalata e non trattata come elenco vuoto. La frequenza effettiva di lettura di una chat dipende dalla coda; una coda iniziale numerosa richiede più lotti.

Prima di leggere PDF o applicare regole il worker conserva i messaggi originali con ID, timestamp, direzione, metadati e impronta. I tentativi ripetuti non duplicano le verifiche. Le revisioni conservano il primo originale. Un errore di regola lascia l'originale e un avviso, mentre errori di lettura restano nel registro della sessione.

Cliente: sender=user. Messaggi WhatsApp Coexistence: sender=assistant, sender_type=user, metadata.origin=whatsapp_coexistence; la presenza prova l'invio. Per gli altri messaggi in uscita il confronto automatico del PDF richiede whatsapp_message.status delivered/read. PDF con nome-targa esatto vengono letti solo dal percorso HTTPS Keplero ammesso, senza redirect, fino a 3 MB. La chiave API resta sul server.

L'ordine viene recuperato solo con PDF originale e offerta collegata univocamente, consenso letterale, alternativa unica e nessun blocco o stato concluso. Non basta ricevere dati fiscali, una ricevuta o un generico assenso all'indirizzo. Le conferme ambigue e i dati amministrativi ricevuti generano una verifica; fatture e pagamenti non vengono confermati automaticamente. Un nuovo PDF senza pratica univoca rimane da abbinare. L'assenza di una pratica non nasconde la verifica della chat.

La dashboard mostra lo stato del controllo e un accesso alle verifiche. Un controllo fermo o un elenco in errore è visibile. Archiviare una verifica non modifica la pratica. I ruoli pubblici non accedono a originali, ticket o funzioni di elaborazione.

La migrazione parte con automatico=false. Attivazione solo dopo test SQL in rollback, compilazione, pubblicazione, 401 senza ticket e lettura reale verificata. Test: originaliKeplero.test.ts, conversazioniKeplero.test.ts, supabase/tests/recupero_originali_keplero.sql.

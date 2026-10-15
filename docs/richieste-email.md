# Richieste email da Keplero

L’automazione «Email info - Dashboard Operatore», assistente Italiana ABS, ascolta `email_received` della casella info@italianaabs.com e POSTa a `/api/keplero/email`. Usa l’autorizzazione già prevista per la Dashboard (`x-keplero-secret`). Body: mailbox fisso, sender=`{{trigger.sender_email}}`, subject=`{{trigger.subject}}`, content=`{{trigger.email_content}}`, conversation_id=`{{trigger.session_id}}`.

Il registro `richieste_email` salva l’originale prima dell’elaborazione e mostra classificazione, pratica, errori e collegamento a K. Accesso DB esclusivo del servizio, RLS senza policy pubbliche. Operazioni UI solo con sessione operatore. Nessun invio email ai clienti.

Le richieste operative passano dal motore esistente `/api/keplero/live`. I test espliciti restano nel registro senza pratiche. Un fingerprint SHA256 su casella, mittente, conversazione, oggetto e testo evita retry duplicati. Il trigger non espone Message-ID: due consegne con tutti questi dati identici nella stessa conversazione vengono conservate come un unico record con conteggio consegne.

Le targhe vengono estratte con etichetta «targa» oppure da una riga contenente soltanto la targa italiana, anche con punto finale. Targhe differenti restano ambigue e la cronologia citata è esclusa dall’estrazione. I DTC usano il formato letterale. Non si inventano codici dispositivo, prezzi o diagnosi. Il trigger espone testo ma non l’elenco degli allegati: URL di file espliciti possono essere associati; allegati menzionati ma assenti sono segnalati. L’originale in K resta consultabile. L’assenza di foto/codici non promuove la richiesta automaticamente a dati completi.

La pratica restituita da `/api/keplero/live` viene letta da `result.pratica_id`; gli esiti diretti sono supportati. Identificativi discordanti restano da verificare. Il collegamento alimenta anche `email_cliente` senza sovrascrivere dati protetti dall’operatore.

Una risposta con la sola targa aggiorna l'identità e il messaggio corrente, senza sovrascrivere la descrizione del guasto precedente. I link contenuti solo nella cronologia citata non vengono trattati come nuovi file ricevuti.

## Limite verificato del trigger email

Nell'esecuzione reale del 14/10/2026 ore 12:45 relativa a Barbarini, il risultato del trigger contiene `subject`, `session_id`, `sender_email`, `email_content`, `sender_domain`. I tre JPEG sono visibili nella conversazione email, ma non compaiono nell'output del trigger: non sono disponibili byte, URL di download o una distinta degli allegati. I blocchi disponibili nell'automazione non espongono un recupero degli allegati email.

La lettura delle immagini in chat non prova il trasferimento degli allegati email. L'assistenza Keplero ha già documentato un'API alternativa nelle risposte del 1 e dell'8 ottobre 2026, ticket #16491: `GET https://v2.api.keplero.ai/v2/sessions/{session_id}/messages?page=1&perPage=100`, autorizzazione `Authorization: Bearer <chiave>`. La chiave è destinata esclusivamente al server della Dashboard, variabile `KEPLERO_API_KEY`; non va inserita nel payload del webhook, nel codice del client, in Git o nei log.

La risposta documentata contiene `data` e `pagination` con `page`, `perPage`, `total`; le pagine partono da 1 e i messaggi sono dal più recente al più vecchio. L'assistenza indica che i messaggi `image` e `file` hanno `content` con prefisso `attachment:` e URL del file. Il client server `leggiMessaggiConversazioneKeplero` implementa questo protocollo, senza redirect, cache o URL di host configurabili, con timeout e limiti sui dati. Non esegue il contenuto dei messaggi, non scarica ancora i file e non altera le pratiche.

**Stato del collegamento:** il client è preparato; il flusso automatico di allegati e lettura non è ancora attivo. Il 15/10/2026 la variabile `KEPLERO_API_KEY` è stata inserita dall'amministratore come segreto di produzione su Vercel. La presenza della variabile non prova ancora l'autorizzazione dell'API. Va verificata la struttura reale dei messaggi email e la relazione fra messaggio originale e allegati. I file di un'intera conversazione non vanno attribuiti al messaggio corrente o a una vettura senza prova. La paginazione non è uno snapshot: una variazione di `total` interrompe il recupero; anche a totale invariato servono verifiche di identità dei messaggi prima di qualsiasi associazione.

Il successivo collaudo deve provare immagine ruotata, PDF, file illeggibile, risposta senza allegati, retry senza duplicati e una seconda vettura nella stessa conversazione. Fino ad allora gli allegati vanno verificati nella conversazione originale; non si deve dichiarare completo il percorso automatico né chiedere al cliente file già presenti in K.

Un lease di due minuti impedisce elaborazioni concorrenti. Gli errori lasciano il messaggio nel registro, con riprova protetta. Le richieste non operative restano da classificare. Il controllo periodico K copre anche gli eventi con channel=email; la sezione Richieste email rende visibili anche le email escluse o non associate.

## Verifica riservata della risposta originale

`GET /api/keplero/email/{id_richiesta_email}/messaggi` recupera gli originali della conversazione associata al registro email. Richiede una sessione operatore valida, non accetta URL arbitrari né chiavi dalla richiesta e non modifica dati o stati. Risposte senza cache, nessuna chiave o body del provider negli errori. Non è un endpoint pubblico per gli allegati e non effettua OCR. Il collaudo con risposta reale è ancora da eseguire; senza sessione operatore risponde 401 prima di interrogare database o Keplero.

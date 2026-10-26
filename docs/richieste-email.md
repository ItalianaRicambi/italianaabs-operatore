# Richieste email da Keplero

## Casella ordini

Il ricevitore `/api/keplero/email` accetta anche `ordini@italianaabs.com`, con la stessa autorizzazione server. L'automazione dedicata deve selezionare esclusivamente quell'account e inviare `mailbox` fisso a `ordini@italianaabs.com`; le altre quattro variabili restano quelle del trigger email originale.

Le email ordini vengono conservate nel registro e restano **da classificare**, con casella di destinazione visibile. Non vengono inoltrate al motore delle pratiche: il testo di una notifica non prova il pagamento, il consenso del cliente o l'identità dell'ordine. Il registro **Ordini Shopify**, alimentato dai webhook firmati, resta la fonte per gli ordini e i pagamenti del negozio. Richieste, variazioni e messaggi non Shopify restano visibili per la verifica dell'operatore. I test interni espliciti e le notifiche tecniche mantengono l'esclusione già prevista. Nessuna risposta email o WhatsApp viene inviata da questo flusso.

L'attivazione in Keplero e la ricezione di un evento reale devono essere verificate separatamente dal rilascio del codice. Non ricollegare la casella a un secondo assistente per aggirare questa configurazione: il registro della Dashboard è condiviso dagli operatori.

## Casella info

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

## Verifica riservata degli allegati

La pagina `/email/{id_richiesta_email}/allegati`, raggiungibile dal registro con «Verifica allegati in K», recupera lato server i messaggi della conversazione e mostra solo conteggi e metadati dei file nel formato documentato. Richiede la sessione operatore; non espone l'intera risposta del provider né la chiave. Il precedente endpoint di lettura JSON è stato rimosso per ridurre i dati esposti.

Sono accettati soltanto messaggi `image` o `file` con `content` che inizia con `attachment:` e URL HTTPS sul dominio esatto `v2.api.keplero.ai`, percorso `/v2/session-attachments/`, senza credenziali. La pagina non scarica, non esegue e non attribuisce automaticamente file o istruzioni contenute nei messaggi. Un elenco vuoto non prova l'assenza di allegati email. Nessuna modifica a pratica, completezza o stati; OCR e collegamento certo al singolo messaggio email restano da verificare sul formato reale.

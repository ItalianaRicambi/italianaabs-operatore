# Richieste email da Keplero

L’automazione «Email info - Dashboard Operatore», assistente Italiana ABS, ascolta `email_received` della casella info@italianaabs.com e POSTa a `/api/keplero/email`. Usa l’autorizzazione già prevista per la Dashboard (`x-keplero-secret`). Body: mailbox fisso, sender=`{{trigger.sender_email}}`, subject=`{{trigger.subject}}`, content=`{{trigger.email_content}}`, conversation_id=`{{trigger.session_id}}`.

Il registro `richieste_email` salva l’originale prima dell’elaborazione e mostra classificazione, pratica, errori e collegamento a K. Accesso DB esclusivo del servizio, RLS senza policy pubbliche. Operazioni UI solo con sessione operatore. Nessun invio email ai clienti.

Le richieste operative passano dal motore esistente `/api/keplero/live`. I test espliciti restano nel registro senza pratiche. Un fingerprint SHA256 su casella, mittente, conversazione, oggetto e testo evita retry duplicati. Il trigger non espone Message-ID: due consegne con tutti questi dati identici nella stessa conversazione vengono conservate come un unico record con conteggio consegne.

Le targhe vengono estratte con etichetta «targa» oppure da una riga contenente soltanto la targa italiana, anche con punto finale. Targhe differenti restano ambigue e la cronologia citata è esclusa dall’estrazione. I DTC usano il formato letterale. Non si inventano codici dispositivo, prezzi o diagnosi. Il trigger espone testo ma non l’elenco degli allegati: URL di file espliciti possono essere associati; allegati menzionati ma assenti sono segnalati. L’originale in K resta consultabile. L’assenza di foto/codici non promuove la richiesta automaticamente a dati completi.

La pratica restituita da `/api/keplero/live` viene letta da `result.pratica_id`; gli esiti diretti sono supportati. Identificativi discordanti restano da verificare. Il collegamento alimenta anche `email_cliente` senza sovrascrivere dati protetti dall’operatore.

Una risposta con la sola targa aggiorna l'identità e il messaggio corrente, senza sovrascrivere la descrizione del guasto precedente. I link contenuti solo nella cronologia citata non vengono trattati come nuovi file ricevuti.

## Limite verificato del trigger email

Nell'esecuzione reale del 14/10/2026 ore 12:45 relativa a Barbarini, il risultato del trigger contiene `subject`, `session_id`, `sender_email`, `email_content`, `sender_domain`. I tre JPEG sono visibili nella conversazione email, ma non compaiono nell'output del trigger: non sono disponibili byte, URL di download o una distinta degli allegati. I blocchi disponibili nell'automazione non espongono un recupero degli allegati email.

La lettura delle immagini in chat non prova il trasferimento degli allegati email. Per attivare la lettura automatica futura serve il passaggio dei file dal provider (metadati e download autorizzato) o un accesso diretto autorizzato alla casella. Finché questo manca, gli allegati vanno verificati nella conversazione originale; non si deve dichiarare completo il percorso automatico e non si devono chiedere al cliente file già presenti in K.

Requisito da sottoporre a Keplero: includere nell'evento email l'ID originale del messaggio e, per ogni allegato, ID stabile, nome, MIME, dimensione e modalità documentata di download autenticato o URL firmato con scadenza; in alternativa, fornire un endpoint autorizzato per recuperare questi elementi tramite `session_id` e ID messaggio. Il recupero non deve dipendere da un cookie del browser operatore. Il collaudo deve provare immagine ruotata, PDF, file illeggibile, risposta senza allegati, retry senza duplicati e una seconda vettura nella stessa conversazione.

Un lease di due minuti impedisce elaborazioni concorrenti. Gli errori lasciano il messaggio nel registro, con riprova protetta. Le richieste non operative restano da classificare. Il controllo periodico K copre anche gli eventi con channel=email; la sezione Richieste email rende visibili anche le email escluse o non associate.

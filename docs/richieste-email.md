# Richieste email da Keplero

L’automazione «Email info - Dashboard Operatore», assistente Italiana ABS, ascolta `email_received` della casella info@italianaabs.com e POSTa a `/api/keplero/email`. Usa l’autorizzazione già prevista per la Dashboard (`x-keplero-secret`). Body: mailbox fisso, sender=`{{trigger.sender_email}}`, subject=`{{trigger.subject}}`, content=`{{trigger.email_content}}`, conversation_id=`{{trigger.session_id}}`.

Il registro `richieste_email` salva l’originale prima dell’elaborazione e mostra classificazione, pratica, errori e collegamento a K. Accesso DB esclusivo del servizio, RLS senza policy pubbliche. Operazioni UI solo con sessione operatore. Nessun invio email ai clienti.

Le richieste operative passano dal motore esistente `/api/keplero/live`. I test espliciti restano nel registro senza pratiche. Un fingerprint SHA256 su casella, mittente, conversazione, oggetto e testo evita retry duplicati. Il trigger non espone Message-ID: due consegne con tutti questi dati identici nella stessa conversazione vengono conservate come un unico record con conteggio consegne.

Le targhe vengono estratte solo con etichetta «targa», i DTC con formato letterale. Non si inventano codici dispositivo, prezzi o diagnosi. Il trigger espone testo ma non l’elenco degli allegati: URL di file espliciti possono essere associati; allegati menzionati ma assenti sono segnalati. L’originale in K resta consultabile. L’assenza di foto/codici non promuove la richiesta automaticamente a dati completi.

Un lease di due minuti impedisce elaborazioni concorrenti. Gli errori lasciano il messaggio nel registro, con riprova protetta. Le richieste non operative restano da classificare. Il controllo periodico K copre anche gli eventi con channel=email; la sezione Richieste email rende visibili anche le email escluse o non associate.

# Avvisi email logistici

Mittente e Reply-To: **spedizioni@italianaabs.com**, nome visualizzato **ItalianaABS - Italiana Ricambi**, firma **Ufficio logistico**.

La pagina `/logistica/email`, raggiungibile dalla barra operatore, collega la casella, invia una prova interna al titolare, consente attivazione/sospensione e mostra gli ultimi 200 avvisi. Richiede la sessione operatore firmata già utilizzata dalla dashboard.

## Collegamento e attivazione

1. Inserire la password della casella **spedizioni** nella schermata protetta. Non usare la password di info o quella del pannello di hosting.
2. **Collega e invia prova** verifica SMTP e invia esclusivamente al recapito interno già verificato `paolo.ardizzoia78@gmail.com`. Salva il collegamento cifrato nel Supabase Vault; non restituisce la password al browser.
3. Verificare la ricezione, spuntare la conferma e selezionare **Attiva avvisi automatici**. Per l’attivazione è necessario un collaudo SMTP negli ultimi 7 giorni. Una sostituzione riuscita della password sospende gli automatismi fino alla nuova attivazione.

SMTP: `mail.italianaabs.com:587`, STARTTLS obbligatorio, certificati verificati, TLS almeno 1.2. Credenziali e lettura Vault sono riservate al backend; nessun nuovo segreto da inserire nelle variabili pubbliche Vercel. La casella non è collegata all’assistente Keplero con firma commerciale.

## Presa prenotata GLS

Il trigger sull’attività crea un avviso solo per una prenotazione confermata e classificata come lavorazione, verifica in garanzia o Programma Scambio. Le pratiche precedenti alla migrazione **non vengono accodate**. Richieste cliente non confermate, abbinamenti ambigui e ritiri da classificare non avviano email.

Ogni variazione rilevante crea una revisione. Gli avvisi precedenti ancora da inviare sono annullati; una correzione usa un oggetto e un testo espliciti di aggiornamento. Un aggiornamento irrilevante dell’attività non genera un’altra mail.

Prima dell’invio vengono ricontrollati attività, pratica, codice P3 completo, data, archiviazione e destinatario. Si usa l’email della pratica o quella del cliente già collegato. Se entrambe sono presenti devono coincidere. Anagrafiche da verificare o duplicate, email mancanti/multiple, date trascorse e codici incompleti sono trattenuti per l’operatore. Correggere i dati nella pratica/anagrafica e selezionare **Verifica nuovamente i dati e rimetti in coda**. Non si cercano destinatari per similitudine di nome.

Il testo comprende tutte le istruzioni approvate su codice esterno, bigliettino con targa, imballaggio e rimozione di staffe/supporti. **Oggi/domani** vengono calcolati in **Europe/Rome al momento dell’invio**, sempre con data assoluta gg/mm/aaaa. Nessuna mail di avviso implica presa fisica effettuata, ricezione in officina o chiusura della garanzia.

## Worker e prevenzione dei duplicati

Supabase Cron richiama ogni 5 minuti `POST /api/logistica/email` tramite pg_net. Usa un ticket casuale monouso valido 2 minuti; la RPC riservata al servizio lo consuma atomicamente. Nel database privato è conservata soltanto l’impronta SHA-256. Gli header della coda pg_net non contengono credenziali SMTP o segreti permanenti. Le ACL dell’estensione sono gestite da Supabase. Lo scheduler non richiama HTTP finché gli avvisi sono sospesi. Non dipende dal piano Cron di Vercel e non usa la sessione di un browser.

La prenotazione e l’accodamento sono nella stessa transazione. Il claim blocca attività e riga in coda con `SKIP LOCKED`, registra token del tentativo e Message-ID prima di SMTP. Ogni chiamata elabora al massimo 2 avvisi. Aggiornamenti e conferme tardive richiedono il token corretto.

- **Accettata dal server di posta** prova l’accettazione SMTP, non la consegna nella casella del cliente. I bounce non sono ancora sincronizzati.
- **Invio non riuscito** consente rivalutazione manuale quando vi è un rifiuto SMTP esplicito o un errore sicuramente precedente a DATA.
- **Esito incerto** non viene mai ripetuto automaticamente. Un timeout dopo DATA, un’interruzione del worker o un errore DB dopo SMTP possono aver già inviato la mail. Verificare il Message-ID con il servizio di posta prima di risolvere il caso. Anche una successiva correzione della stessa presa resta trattenuta finché l’esito precedente non è chiarito.

È possibile una modifica della prenotazione tra il claim e l’accettazione SMTP: il registro conserva l’avviso già avviato e la successiva revisione, senza pretendere di annullare un messaggio già in transito. Questo è il limite della transazione DB rispetto a un servizio SMTP esterno.

Per risolvere un esito incerto usare **Registra il controllo dell’esito incerto**: indicare il riscontro del servizio di posta e confermare il controllo del Message-ID. La verifica è registrata con l’operatore. Se il messaggio non è stato inviato, la rimessa in coda richiede comunque una rivalutazione separata; registrare la verifica non avvia un invio.

## MBE e monitoraggio GLS

Il tracking MBE e la lettura continuativa degli esiti dal portale GLS richiedono ancora una fonte dati utilizzabile dal backend. Questa implementazione invia la **prenotazione** già confermata dal flusso esistente; non simula un’integrazione MBE o una verifica della presa fisica.

## Verifiche

- `node --experimental-strip-types --test app/lib/emailLogistica.test.ts app/lib/prenotazioniPrese.test.ts`
- `npx tsc --noEmit` e `npm run build`
- `supabase/tests/notifiche_email_logistica.sql`: fixture sintetiche interamente in rollback, senza SMTP; tre tipi di ritiro, revisioni, cancellazioni, destinatari discordanti/duplicati, claim singolo, token errati e lease scaduto.
- Verificare gli advisor Supabase dopo la migrazione e l’HTTP 401 del worker senza credenziali.

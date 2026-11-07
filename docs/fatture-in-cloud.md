# Fatture in Cloud: consultazione privata

Consultazione tramite API ufficiali, esclusivamente GET, per la sola azienda Italiana Ricambi (partita IVA verificata prima di ogni ricerca), con registro privato dei documenti normalizzati. Non emette fatture e non modifica pratiche o pagamenti. Il token personale creato in Fatture in Cloud deve avere soltanto i permessi in lettura concordati: Clienti, Preventivi, Ordini, Fatture e Proforma.

## Configurazione e prova

Nel progetto Vercel `italianaabs-operatore`, aggiungere come variabili lato server:

| Variabile | Valore / uso |
| --- | --- |
| `FIC_ACCESS_TOKEN` | Token personale completo. Inserirlo esclusivamente nell'interfaccia protetta Vercel; mai nel repository, nelle chat, negli URL o in variabili `NEXT_PUBLIC_*`. |
| `FIC_COMPANY_ID` | `29153`, da verificare tramite `/user/companies` insieme alla partita IVA `02439670031`. Non è l'App ID né il Client ID. |

Per iniziare, applicarle solo all'ambiente Preview e al branch `codex/fatture-in-cloud-lettura`, poi effettuare un nuovo deployment di quel branch. Non copiare token di produzione nel computer locale. La pagina richiede la normale sessione operatore della dashboard. La mancanza delle variabili mostra «Completa il collegamento», senza tentare richieste API.

1. Aprire `/fatture-in-cloud` dopo l'accesso operatore.
2. Premere «Verifica accesso all'azienda». Questo verifica identità e token, non tutti i permessi sui documenti.
3. Cercare separatamente fatture, preventivi, ordini e proforma in un intervallo noto; confrontare numeri, clienti e importi con Fatture in Cloud.
4. Verificare una targa e un codice con punteggiatura diversa. Il filtro testuale è locale, sui documenti recuperati nel periodo, comprese righe e note.
5. Prima del rilascio: testare la negazione degli accessi anonimi, una risposta 403 (permesso mancante) e 429 (quota). Nessuno di questi casi deve diventare «nessun documento».

Massimo 31 giorni e dieci pagine da 50 documenti per ricerca, con timeout complessivo di 45 secondi. Se esistono altre pagine, i risultati sono esplicitamente parziali. Nessuna cache condivisa di documenti; nessun log di contenuti o credenziali. I dati restituiti sono una selezione esplicita dei campi, senza URL di download o token presenti nelle risposte del fornitore. È normale che una ricerca per codice/targa non trovi documenti nei quali quei dati non sono stati scritti.

Endpoint riservato alla sessione operatore: `GET /api/fatture-in-cloud?azione=verifica`; per la ricerca: `tipo=invoice|quote|order|proforma&dal=YYYY-MM-DD&al=YYYY-MM-DD&cerca=...`. Non è un endpoint MCP e non è accessibile da ChatGPT con il solo token FIC.

## Registro e proposte di abbinamento

`/fatture-in-cloud/registro` richiede la sessione operatore. La sincronizzazione manuale acquisisce un tipo e un periodo completo, al massimo 31 giorni/500 documenti. Il registro separa Preview e Production, conserva ID e data di verifica, evita duplicati e segnala documenti non più rilevati. Snapshot incompleti o superati da un aggiornamento concorrente non vengono salvati. Nessuna cancellazione automatica e nessun trigger verso l'importazione PDF o le pratiche.

La pagina mostra gli ultimi 100 documenti. Propone una pratica commerciale soltanto con targa e almeno un identificativo fiscale concordanti, senza identificativi in conflitto; esclude pratiche posteriori e archivi test/duplicati. Riferimenti espliciti alla pratica restringono la selezione. Più targhe o più candidati richiedono revisione. Sono suggerimenti, non aggiornamenti di stato: un proforma resta un proforma anche se pagato.

Le migrazioni `20261107185928` e `20261107190702` sono state applicate al progetto collegato. Tabelle e RPC FIC sono accessibili solo al server. Prima di predisporre OAuth è stato inoltre revocato l'accesso anonimo/autenticato a 16 RPC preesistenti con privilegi elevati, mantenendo il ruolo server e i corpi delle funzioni.

Gli esiti delle importazioni sono conservati soltanto nel registro privato. Le prove Preview non modificano la dashboard di produzione.

## ChatGPT: implementato, attivazione ancora da completare

`/mcp` espone due strumenti di sola lettura con SDK MCP ufficiale: `fic_cerca_documenti` e `fic_leggi_documento`. La ricerca restituisce al massimo 50 risultati sintetici per chiamata con indicazione esplicita dei limiti; il dettaglio limita righe e testi e segnala troncamenti. Il token FIC rimane nel backend. Token JWT OAuth verificati con firma asimmetrica, issuer, audience dedicata alla risorsa, client ID, scadenza, scope e lista di utenti autorizzati. Quota 30 richieste/minuto/utente.

Senza configurazione completa, MCP e discovery rispondono 503 senza dati. La pagina `/oauth/consent` usa Supabase Auth e richiede un account preabilitato; verifica client e callback esatti prima di autorizzare. Non offre registrazione libera. Non utilizzare il PIN della dashboard o il token FIC come credenziale ChatGPT.

Variabili server da configurare solo dopo aver registrato l'app OAuth e l'utente:

| Variabile | Uso |
| --- | --- |
| `FIC_MCP_RESOURCE_URL` | URL HTTPS stabile completo di `/mcp`; deve coincidere con `aud` del token e con la risorsa ChatGPT. |
| `FIC_MCP_ISSUER` | Issuer esatto del server OAuth, da discovery. |
| `FIC_MCP_JWKS_URL` | JWKS del medesimo provider, con chiavi RS256/ES256. |
| `FIC_MCP_CLIENT_ID` | Identificativo del client OAuth privato registrato per ChatGPT. |
| `FIC_MCP_USER_IDS` | UUID degli utenti autorizzati, separati da virgole. |
| `FIC_AUTH_PUBLISHABLE_KEY` | Chiave pubblicabile Supabase `sb_publishable_…`, resa al client esclusivamente nella pagina di consenso. Mai la chiave server. |
| `FIC_MCP_REDIRECT_URIS` | Callback HTTPS esatti mostrati nella configurazione ChatGPT, separati da virgole. |

Per completare: abilitare il server OAuth Supabase, verificare la firma asimmetrica, registrare il client con il callback effettivamente fornito da ChatGPT, creare/verificare l'account autorizzato e configurare un access-token hook che emetta l'audience dedicata solo per quel client. Il valore generico Supabase `authenticated` non è accettato come audience MCP. Impostare la pagina di consenso HTTPS stabile, configurare le variabili, distribuire e verificare l'intero flusso PKCE, consenso, chiamata strumenti e revoca dall'account ChatGPT. Non considerare il solo test JWT una prova di compatibilità completa con il provider.

Configurazione OAuth, hook, utente e connessione ChatGPT non sono ancora attivati. Il codice resta in anteprima e la PR in bozza finché il flusso reale non è verificato.

## Sincronizzazione pianificata: predisposta, non attiva

`GET /api/fatture-in-cloud/cron` è predisposto per un futuro scheduler: richiede `FIC_SYNC_ENABLED=true` e `Authorization: Bearer <CRON_SECRET>` con segreto di almeno 32 caratteri. Sincronizza separatamente i quattro tipi negli ultimi 31 giorni italiani; un fallimento restituisce 503 e indica i soli tipi già completati. I documenti anteriori alla finestra richiedono una sincronizzazione manuale del periodo.

Non è stato configurato alcun cron né abilitata questa variabile. Prima dell'attivazione servono frequenza concordata, budget API adeguato e prova del recupero errori. L'endpoint non equivale a un processo automatico già in esecuzione.

## Verifiche e limiti del rilascio

Test del client FIC (azienda, paginazione, errori/quote, dettaglio), abbinamenti conservativi, JWT negativi e trasporto MCP. Prova SQL con rollback per idempotenza, snapshot concorrenti, segnalazione assenze e permessi. Build TypeScript/Next e controlli delle rotte senza autenticazione. Il registro remoto con sessione operatore e il flusso OAuth completo richiedono ancora collaudo interattivo.

Il riscontro dell'assistenza FIC conferma la fattibilità tecnica ma non chiarisce la clausola contrattuale sui fornitori esterni; il quesito resta distinto dalla configurazione tecnica.

## Documentazione verificata

- https://developers.fattureincloud.it/docs/basics/company-scoped-methods/
- https://developers.fattureincloud.it/docs/basics/customize-response/
- https://developers.fattureincloud.it/docs/basics/filter-results/queries/
- https://github.com/fattureincloud/openapi-fattureincloud
- https://developers.openai.com/api/docs/guides/custom-mcp-server
- https://developers.openai.com/plugins/build/auth

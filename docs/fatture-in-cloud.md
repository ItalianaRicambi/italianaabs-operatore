# Fatture in Cloud: consultazione privata

Prima fase: consultazione diretta tramite API ufficiali, esclusivamente GET, per la sola azienda Italiana Ricambi (partita IVA verificata prima di ogni ricerca). Non registra documenti, non emette fatture, non modifica pratiche o pagamenti e non attiva cron. Il token personale creato in Fatture in Cloud deve avere soltanto i permessi in lettura concordati: Clienti, Preventivi, Ordini, Fatture e Proforma.

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

## Passaggi successivi

- Sincronizzazione: dopo il test reale, registrare gli ID FIC, lo stato e la prova di abbinamento in tabelle dedicate. Abbinare prioritariamente ID pratica/riferimento ordine; usare targa e cliente come controlli. Codice dispositivo o solo nome non bastano per una chiusura automatica. Un proforma o preventivo pagato non va classificato automaticamente come fattura. Gestire annullamenti, rettifiche e concorrenza con l'importazione PDF già presente prima di attivare aggiornamenti di stato.
- ChatGPT: realizzare un server MCP che richiami lo stesso client di sola lettura. Autenticare il chiamante tramite OAuth 2.1 e provider d'identità verificato; il token FIC resta nel backend e non è il token di autenticazione MCP. Non pubblicare strumenti anonimi né URL contenenti segreti. Servono discovery OAuth, verifica audience/issuer/scopes e installazione della connessione privata nell'account ChatGPT. Questo passaggio non è ancora implementato.
- Il riscontro ricevuto dall'assistenza conferma la fattibilità tecnica, ma non chiarisce la clausola contrattuale sui fornitori esterni. Il quesito resta distinto dalla configurazione tecnica.

## Documentazione verificata

- https://developers.fattureincloud.it/docs/basics/company-scoped-methods/
- https://developers.fattureincloud.it/docs/basics/customize-response/
- https://developers.fattureincloud.it/docs/basics/filter-results/queries/
- https://github.com/fattureincloud/openapi-fattureincloud
- https://developers.openai.com/api/docs/guides/custom-mcp-server
- https://developers.openai.com/plugins/build/auth

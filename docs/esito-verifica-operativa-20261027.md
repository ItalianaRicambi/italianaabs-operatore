# Esito della verifica operativa — 27 ottobre 2026

Questo aggiornamento integra gli snapshot precedenti della stessa giornata.

## Correzioni pubblicate e recuperi verificati
- PR #37: permesso backend mancante per attivare le nuove pratiche Keplero. Riproduzione prima della correzione, regressione con ruolo reale, rollback delle fixture e verifica permessi completati. Nessuna riassegnazione retroattiva automatica.
- PR #38: lettura titoli Programma Scambio spezzati su due righe, modello SBC rigorosamente riconoscibile e separatori numerici. 23 test superati; compilazione webpack/TypeScript e build Vercel riuscite. Il build locale Turbopack aveva una limitazione legata al collegamento esterno di node_modules.
- Pratica 1878: fattura originale 518/2026 del 16 ottobre, EUR 477,60, verificata e riconciliata. Ora ordine acquisito/fatturato. Non sono stati dedotti pagamento o spedizione.
- Il controllo orario già esistente delle fatture considera anche le anomalie di fattura non allineata, pur quando la pratica è ancora a preventivo. La promozione automatica da preventivo a ordine resta vietata senza verifica.

| Pratica | Importi recuperati | Evidenza |
|---|---|---|
| 2155 | PS ECU EUR 397 | PDF originale, rilettura dello stesso documento |
| 1964 | PS SBC EUR 1197 | PDF originale, rilettura dello stesso documento |
| 2180 | PS SBC EUR 1197 | PDF originale, rilettura dello stesso documento |
| 2182 | PS SBC EUR 1197 | PDF originale, rilettura dello stesso documento |
| 838 | RE EUR 497; PS EUR 597 | PDF associato e data invio esistente |
| 2201 | RI EUR 547 | PDF targa CY657RL (FR), azione operatore 4095 |
| 2081 | RC FTE EUR 1247 | PDF CG01972, BMW 1200 LT, azione operatore 3824 |

Tutti i recuperi sono stati provati con rollback prima del salvataggio e riletti dopo. Stato commerciale e data invio originaria sono rimasti invariati. Le condizioni dei documenti, inclusi reso e limitazioni tecniche, sono conservate. Per 2081 il testo del PDF riletto coincide con quello registrato al netto degli spazi. Un primo tentativo transazionale ha restituito un errore di sessione del connettore: la rilettura ha confermato nessun recupero persistito; la successiva prova con timeout espliciti è riuscita prima del commit.

## Checkout Shopify verificato senza inoltrare ordini
- Spedizione e fatturazione possono avere indirizzi differenti, verificati con soli dati di collaudo.
- Francia: articolo EUR 447 + spedizione EUR 35, totale EUR 482.
- Partita IVA francese volutamente non valida: messaggio di errore e IVA mantenuta.
- Germania: articolo EUR 447 + spedizione EUR 40, totale EUR 487 senza esenzione.
- Partita IVA UE pubblica convalidata dal checkout: articolo EUR 366,39, spedizione EUR 40, imposte EUR 0, totale EUR 406,39.
- La partita IVA usata esclusivamente nel test proviene dall'impressum ufficiale BMW: https://www.bmw.de/de/footer/metanavigation/legal-notice-pool/imprint.html
- Il risultato prova il comportamento tecnico del checkout, non una verifica fiscale completa dell'identità dell'acquirente o di tutti i casi di destinazione.
- Nessun ordine inviato, nessuna email di cliente e nessun dato di pagamento inseriti. Indirizzi e IVA di collaudo rimossi, carrello verificato vuoto.
- Il precedente collaudo ha verificato il blocco per Helgoland. Non equivale a una verifica di tutti i CAP esclusi.

## Catalogo: controllo strutturale completo
1330 prodotti letti con paginazione completa: 1323 DRAFT, 6 ACTIVE, 1 ARCHIVED.
Tutte le schede hanno descrizione e tutte le varianti hanno prezzo positivo; nessuna paginazione varianti residua. Tutte le immagini principali presenti sono READY.
Due schede senza immagine: prodotto TEST INTERNO e servizio Riprogrammazione a banco ABS ATE.
22 varianti di sette schede in bozza hanno SKU assente:
- Centralina ABS LANCIA P68157545AB 25021219224 28526565033 (gid://shopify/Product/16459573363037), 4 varianti.
- Centralina ABS SEAT Alhambra 5N0614109CF A002E049 54086984H A002E067 (gid://shopify/Product/16569878872413), 3 varianti.
- Centralina ABS SEAT 1J0907379R 10094903373 1J0614417A 100204021343 (gid://shopify/Product/16578327937373), 3 varianti.
- Centralina ABS Fiat 51879520 0265260047 0265805024 (gid://shopify/Product/16578388427101), 3 varianti.
- Centralina ABS MINI 10020600604 34516758801 10096008633 6758803 (gid://shopify/Product/16578440364381), 3 varianti.
- Centralina ABS Volkswagen 5Q0614517K 10022002474 5Q0907379L 10062235281 (gid://shopify/Product/16581745213789), 3 varianti.
- Centralina ABS Alfa Romeo 54084738G 15314106D 51797046 (gid://shopify/Product/16581749539165), 3 varianti.
Il controllo strutturale non certifica la corrispondenza tecnica di ogni fotografia e codice. Il catalogo non è stato pubblicato in massa e la protezione del negozio è rimasta attiva.

## Questioni aperte
- 2075 / 2086: due pratiche attive DL682LM, stesso cliente e conversazione; il preventivo è già collegato a 2075. In 2086 l'operatore ha corretto CG01972 in DL682LM dopo il cambio stato. Non è stato scelto arbitrariamente il duplicato da archiviare.
- 2205 / 2206: due pratiche attive DF956GC; il preventivo è collegato a 2206. L'operatore ha corretto CS397AB in DF956GC su 2205 dopo il cambio stato. Stesso criterio prudenziale.
- 2083: conferma generica Programma Scambio ma proposta con PS EUR 697 e PSMI EUR 647. Scelta ancora da chiarire.
- 2155: il PDF richiede reso ECU; la richiesta del cliente indica indisponibilità della ECU originale. Condizione da chiarire prima dell'ordine.
- Classificazione clienti Shopify: due operatori classificati; otto clienti senza identità fiscale verificata associata, tre profili interni esclusi. Nessuna corrispondenza email esatta con le anagrafiche attuali del database per gli otto. Il riconoscimento partner richiede un collegamento certo alla lista ufficiale. L'automatismo prima del primo acquisto non è stato implementato: i dati fiscali del carrello oggi sono attributi ordine, non una classificazione cliente già disponibile al momento di applicare lo sconto.
- SKU mancanti da collegare alla codifica di magazzino; nessun codice commerciale inventato.
- La causa completa dei timeout della mattina e del deadlock cron delle 10:15 UTC non è certificata risolta. Il successivo ciclo di manutenzione era riuscito e nell'ultimo controllo dei log Vercel su 30 minuti non erano presenti errori.
- Generazione automatica fatture/Fatture in Cloud rinviata per istruzione dell'utente.

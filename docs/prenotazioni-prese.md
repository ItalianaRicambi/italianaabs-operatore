# Prenotazioni prese GLS

Il ritiro mantiene il suo tipo: lavorazione, verifica in garanzia o restituzione per programma scambio. Data prevista e codice completo appartengono all'attività del singolo ritiro. Lo stato `programmata` viene mostrato come **Presa prenotata**; non equivale a pacco ritirato, ricevuto o assistenza chiusa.

- Le conferme GLS email vengono elaborate dall'automazione Gmail **Prenotazioni prese GLS**, attiva sulla casella collegata. Il trigger legge oggetti contenenti GLS, presa o ritiro; il contenuto e il mittente autenticato vengono verificati prima dell'aggiornamento. Le notifiche di spedizione non sono prenotazioni. Il dominio verificato è `gls-italy.com`.
- Abbinamento automatico solo con targa/telefono del destinatario espliciti o codice già presente in un unico ritiro aperto. Altri casi compaiono in **Conferme prese da verificare**; l'operatore sceglie l'attività, verifica la prenotazione e conferma.
- Il messaggio aziendale WhatsApp si incolla nella scheda: **Registra la presa dal messaggio o dalla conferma GLS → Leggi data e codice → Conferma presa prenotata**. I payload attuali di K contengono i messaggi cliente, non tutti i messaggi aziendali in uscita; questi ultimi richiedono l'importazione dell'operatore.
- Le risposte cliente con data e codice precompilano la scheda e richiedono verifica. Non confermano da sole una prenotazione.
- `fonte_id` rende idempotente la ricezione. Email vecchie, ritiri già completati, tipi non classificati e correzioni operatore restano protetti. Le revisioni email conflittuali richiedono verifica.
- Il job database `riprova-prenotazioni-prese` riprova ogni cinque minuti fino a 100 conferme email pendenti ricevute negli ultimi trenta giorni. L'email può precedere l'attività di K. La coda conserva gli eventuali errori.

Le RPC e la tabella di ricezione sono accessibili soltanto al servizio backend. Le azioni della dashboard richiedono una sessione operatore valida e registrano l'identità effettiva. Non inserire credenziali in prompt, client o automazione.

## Verifica

- `node --experimental-strip-types --test app/lib/prenotazioniPrese.test.ts`
- `npx tsc --noEmit` e `npm run build`
- `node tests/prenotazioni-prese-http.cjs` dopo la build: HTTP/SSR con Supabase simulato e sessione isolata, senza credenziali o dati reali.
- `supabase/tests/prenotazioni_prese.sql`: fixture sintetiche con rollback, tutti i tipi di ritiro, conferma cliente, retry, revisioni, protezione operatore, ambiguità, email anticipata e separazione degli episodi.
- Regressione `supabase/tests/offerte_scelte_ritiri.sql` e `supabase/tests/attivita_apertura_pratica.sql`.

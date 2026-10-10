# Monitoraggio prese GLS

La dashboard `/gls` registra controlli verificati del portale, mostra gli eventi originali, il motivo del mancato ritiro, la destinazione e il collegamento alla singola attività. Il controllo ha sempre data e ora. Una prenotazione passata senza esito diventa **Esito da verificare**, mai automaticamente **Non effettuata**.

## Destinazioni confermate dal titolare

- ALB Meccatronica: altre lavorazioni auto.
- Judmax: moto.
- Monika Bednarska, Germania: Audi/VW 01130 e ATE Freemont/Dodge C2200.
- Italiana Ricambi: principalmente rientri Programma Scambio, storni ordine e altri resi. Non dedurre il motivo dalla sola destinazione; mantenere la classificazione della pratica, compresa l'eventuale verifica in garanzia.

## Stati e abbinamento

Gli esiti sono derivati dallo storico: `Ritiro Inserito` e `Ritiro preso in carico` non significano ritiro fisico. `Ritiro Effettuato` è la prova della presa. Le spedizioni possono avere uno storico che include la presa originaria: conservare codice della presa e codice spedizione distinti.

Abbinamento automatico solo con codice completo univoco già presente nell'attività, mittente coerente, data uguale, episodio coerente e destinazione conosciuta. Codici compatti e con spazio sono equivalenti. Ambiguità, nuove prese, cambio di data, tipo non classificato, destinazione o mittente non coerenti vanno in coda. L'operatore può verificare e confermare il preciso ritiro; le azioni richiedono la sessione e tracciano l'identità effettiva.

La conferma del ritiro completa soltanto l'attività di presa. Per una lavorazione allinea il riepilogo logistico a `ritirato`. Per garanzia/scambio non altera il ritiro storico della lavorazione, non registra ricezione e non chiude assistenza, garanzia o reso. Esiti annullati/non effettuati restano visibili per verifica e nuova prenotazione; non cancellano la richiesta del cliente. Una nuova prenotazione rimuove dall'attività il vecchio esito GLS, conservando lo storico nella tabella dedicata. Correzioni, retry, controlli vecchi e attività chiuse dall'operatore sono protetti.

Se lo storico contiene eventi di spedizione successivi a un esito di presa ma manca `Ritiro Effettuato`, la dashboard segnala **Storico GLS incoerente / Esito da verificare**. Una consegna successiva a "merce non presente" non permette di applicare con certezza l'esito della presa: conservare tutti gli eventi e lasciare aperta la richiesta operativa.

## Collegamento continuativo: blocco effettivo

Non è stato attivato un job che simuli l'accesso futuro al browser. Il login interattivo non fornisce automaticamente credenziali a un worker backend. La schermata dichiara **Aggiornamento automatico GLS da configurare**.

Le fonti ufficiali consultate descrivono il Track & Trace XML delle **spedizioni** per numero spedizione/DDT/ID collo, e ILS `PickUpRequest` per **creare** un ritiro. `ListSped` e la chiusura giornaliera non provano una presa fisica. Nessuna di queste informazioni documenta da sola la lettura dello stato e delle motivazioni di una **presa**.

Richiedere alla sede Novara il servizio per leggere elenco e dettaglio dei ritiri del contratto 6178, inclusi codice presa, data prevista/riprogrammata, mittente/destinatario, esiti datati, motivazioni e numero spedizione associato. Servono documentazione e abilitazione dell'accesso tecnico; inserire le credenziali soltanto nei segreti backend, mai in chat, repository, client o prompt. Prima di attivare un polling reale, collaudare prenotazione futura, presa effettuata, merce assente e annullamento contro i dettagli visibili del portale e configurare stato/errori/ultimo controllo del worker nella dashboard. L'avviso va aggiornato solo quando questo canale è realmente funzionante.

Fonti:
- https://labelservice.gls-italy.com/ilsWebService.asmx
- https://weblabeling.gls-italy.com/help/doc/MU40-Track_n_Trace_rev4.pdf

## Contratto dati del backend

RPC service-only `registra_esito_presa_gls(p_dati jsonb,p_attivita_id uuid default null,p_operatore text default null)`; nessun accesso anonimo. `p_dati`: fonte `portale_gls` o `api_gls`, `fonte_id` univoco immutabile per controllo, contratto, riferimento presa, data_ritiro ISO, mittente, destinatario, numero_spedizione opzionale, testo originale, verificata_at ISO e array eventi `{at,luogo,stato,note}`. Gli orari degli eventi sono ISO con offset/UTC. Il chiamante backend deve verificare account e provenienza; un campo fonte non autentica il mittente. Nessun endpoint pubblico accetta questi dati.

L'importazione dell'operatore copia il dettaglio del portale dopo una verifica esplicita. `GLS_CONTRATTO`, solo server, può specificare il contratto; il valore predefinito è quello verificato 6178. Nessuna password è richiesta dalla schermata.

## Collaudi

Parser e fuso italiano, stati scaduti, SQL con rollback per tutti i tipi di presa e protezioni, TypeScript, build Next e HTTP/SSR con database sintetico. Non usare dati di clienti reali nelle fixture.

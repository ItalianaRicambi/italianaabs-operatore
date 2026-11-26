# Routine dei resi Programma Scambio

Eseguire la riconciliazione in Europe/Rome con Fatture in Cloud Italiana Ricambi, ordini Shopify, DDT, MBE/DHL, registri e prese GLS, originali delle chat WhatsApp Keplero e posta aziendale. Registro in Supabase, progetto della dashboard. La coda persistente è v_resi_scambio, lo storico è resi_scambio_eventi. La dashboard operatore è /resi.

## Ingresso e aggiornamenti

- La coorte verificata al 26/11/2026 è caricata dal registro delle pratiche aperte. Trattare anche le fatture successive, incluse quelle arrivate in ritardo o corrette: confrontare l'archivio delle fatture definitive con la fonte Fatture in Cloud per intervalli completi di massimo 31 giorni. Rileggere le modifiche dalla precedente copertura con sovrapposizione, recuperando i giorni saltati. Verificare Shopify anche quando mancano pratica o DDT. Ignorare proforma, riparazioni, garanzie e servizi annullati. Non reimportare automaticamente le pratiche della revisione storica già dichiarate rese o escluse. Una rettifica sostanziale va in verifica.
- Accettare solo righe con sigla autonoma MBO, EB, BDM, PSMI, MBMI o ARMI, veicolo e componente identificabili. Per ogni singola fornitura creare resi_scambio in verifica, con fattura completa di anno, data_fattura, cliente, veicolo normalizzato, componente (codice principale in fattura), sigla e fonte. Identità fattura, veicolo e componente: utilizzare INSERT ON CONFLICT DO NOTHING. Cercare anche varianti del codice prima di inserire. Quantità multiple o riferimenti discordanti richiedono verifica per unità. Collegare pratica_id solo se l'abbinamento è comprovato anche dal documento/ordine.
- Ricostruire l'ultima spedizione del sostitutivo al cliente con data effettiva. Registrare evento spedizione con data ISO e nota che identifica la prova, poi attiva dopo verifica completa. Senza partenza documentata mantenere verifica. Non attribuire al cliente le spedizioni in ingresso al laboratorio.
- Per ogni pratica aperta (incluse prese, verifiche, accordi, assistenza e tentativi incerti) controllare risposte WhatsApp e mail, chiamate annotate, invii manuali o precedenti, reso dichiarato e codice GLS. Attribuire i ritiri con fattura/ordine/targa/componente: la sola officina è insufficiente. Se reso o prenotazione sono certi, evento reso o presa con nota e riferimento. Presa fallita o annullata: verifica e concordare il nuovo ritiro. Problema tecnico: assistenza; restituzione dichiarata o pezzo pronto: verifica e passaggio alla logistica. Un accordo o una rettifica dell'operatore prevalgono finché nuovi riscontri ne giustificano la modifica. Una rettifica tecnica non riavvia i solleciti senza verifica.
- Risposte: montaggio con data precisa -> evento montaggio(data della sostituzione, nota). «Settimana prossima» -> venerdì della settimana indicata e poi tre giorni lavorativi, esplicitando la data al cliente. «Vi faccio sapere appena riesco» -> vago(data risposta), quattro giorni lavorativi. «Appena lo smonto ve lo mando» senza data -> accordo(data risposta + sette giorni di calendario, slittando al giorno utile), riprendere alla data concordata. Registrare il messaggio originale e la data; non reinterpretare la stessa risposta a ogni controllo. In caso di appuntamento o accordo ancora aperto, mantenerlo. Alla sua scadenza verificare lo stato della fornitura. Per un accordo di ricontatto inviare solo il promemoria concordato: prima dei sei mesi abilitare l'invio alla data con evento ricontatto; al termine dei sei mesi passare al riesame.
- Registrare i solleciti storici pertinenti con storico_invio(data, prova). Elaborare in ordine cronologico, rispettando la risposta successiva. La finestra di 15 giorni parte dall'ultimo invio riuscito. Esito incerto, traccia mancante o recapito dubbio -> fermare l'invio e mostrare il motivo. Una fonte inaccessibile rende incompleta la verifica. Saltare i giorni di chiusura per l'invio e recuperare la scadenza al primo giorno utile.
- Eventi via evento_reso_scambio(p_id,p_revisione,p_tipo,p_chiave,p_autore,p_dati). Autore Routine resi. Chiave stabile per prova e azione, p_dati oggetto JSON. Rileggere la revisione in caso di conflitto e rivalutare la nuova informazione. Le decisioni e le comunicazioni di decadenza sono riservate all'operatore.

## Invio

1. Selezionare soltanto attesa/montaggio, prossima entro oggi, spedizione certa, sei_mesi nel futuro, senza unico_tentativo. Il calendario SQL applica 20 giorni lavorativi dopo la spedizione, 3 dopo un montaggio o 4 dopo un'attesa vaga, 15 dopo l'ultimo invio riuscito. Bloccare spedizioni annullate o non consegnate e problemi tecnici. Se la stessa verifica identifica una modifica, registrarla prima dell'invio.
2. Usare la chat WhatsApp Keplero della fornitura. Per ordini diretti Shopify privi di chat verificata, utilizzare l'email dell'ordine o l'email verificata in Fatture in Cloud. Conservare lo stesso thread e il mittente aziendale. Verificare tutte le risposte anche sull'altro canale. Se WhatsApp esiste ma richiede un modello, usare un modello Utility italiano pertinente approvato per il reso, con tutte le variabili verificate. Se manca, gestire la creazione/approvazione tramite la console e mantenere il caso pendente. Usare esclusivamente il canale adatto, mai ripiegare su altri modelli o inviare due volte.
3. Dopo l'ultima lettura delle fonti, acquisire tramite evento tentativo con revisione corrente, chiave univoca per tentativo, canale WhatsApp/Email, destinatario verificato, testo finale e verifica (ID e data delle fonti). Solo il processo che ha appena acquisito il token può spedire. Prima del click/submit rileggere il registro e interrompere in caso di revisione o stato cambiato. Dopo un tentativo incerto ricostruire la ricevuta dalla fonte: nessun retry su assenza di prova. Se il canale certifica mancata accettazione, registrare rifiutato con token e prova; in caso di invio confermato registrare inviato con token e prova (ID messaggio, thread, esito). Non marcare come consegnato un semplice invio. Ripristinare l'assegnazione originaria della chat se modificata. Rifiuti permanenti -> verifica. Per registrazioni storiche usare l'effettiva data di invio verificata anche se l'esito viene riconciliato in un giorno successivo.
4. Al raggiungimento di sei mesi dalla spedizione sospendere gli invii. La dashboard apre il riesame. Nessun messaggio di decadenza o risoluzione parte dalla routine. Riepilogare inviati, errori, tentativi incerti, ritiri ed eccezioni con fattura e targa. Non dichiarare completata una finestra letta solo parzialmente.

## Testi cliente

Personalizzare intestatario, fattura completa, data, veicolo e, per un montaggio concordato, data comunicata. Usare il singolare di cortesia per il cliente privato. Per Shopify email usare come oggetto «Programma Scambio – ritiro centralina ABS – targa [TARGA] – fattura [FATTURA]».

**Primo messaggio**

Buongiorno,
vi contattiamo in merito alla centralina ABS fornita in Programma Scambio per il veicolo targato [TARGA], con fattura n. [FATTURA] del [DATA], intestata a [CLIENTE].

Ci auguriamo che la sostituzione sia andata bene e che la vettura funzioni regolarmente. Se avete riscontrato difficoltà, vi invitiamo a contattarci così possiamo aiutarvi a risolverle.

Vi ricordiamo che la restituzione della vecchia centralina ABS è un obbligo previsto dal contratto di acquisto in Programma Scambio.

Possiamo organizzare il ritiro con GLS? Se la vecchia centralina è pronta, vi chiediamo di confermarci l’indirizzo e indicarci un giorno comodo per il ritiro. Se dovete ancora effettuare la sostituzione, fateci sapere quando prevedete che il pezzo sarà disponibile. Se invece è già stato ritirato, vi chiediamo di comunicarci la data, così possiamo aggiornare la pratica.

In caso di persistente mancata restituzione, Italiana Ricambi si riserva di chiedere la risoluzione del contratto per inadempimento.

Vi ringraziamo per la collaborazione e vi porgiamo cordiali saluti.
Italiana Ricambi

**Dopo la data prevista**

Buongiorno, ci avevate indicato il [MONTAGGIO] per la sostituzione della centralina ABS del veicolo [TARGA], fattura [FATTURA] del [DATA], intestata a [CLIENTE]. È andato tutto bene? Se la vecchia centralina è pronta, ci confermate l’indirizzo e un giorno comodo per il ritiro con GLS? Se il montaggio è slittato, indicateci pure la nuova data. Grazie, Italiana Ricambi

**Promemoria**

Buongiorno, torniamo a scrivervi per il ritiro della vecchia centralina ABS del veicolo [TARGA], fattura [FATTURA] del [DATA], intestata a [CLIENTE]. Possiamo prenotare il ritiro con GLS? Se il pezzo è pronto, ci bastano l’indirizzo e un giorno utile. Se attendete ancora il montaggio, potete indicarci una data orientativa. Se il ritiro è già avvenuto, ci comunicate la data o il codice di presa? Grazie per la collaborazione, Italiana Ricambi

Per un accordo generico usare il promemoria adattando l'apertura in «Come concordato, vi ricontattiamo per il ritiro…». Per i solleciti successivi ricordare l'obbligo contrattuale di restituzione e chiedere se esistono impedimenti.

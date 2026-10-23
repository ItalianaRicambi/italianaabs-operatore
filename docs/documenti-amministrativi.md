# Allineamento amministrativo della pratica

Una sospensione per dati cliente mancanti non viene rimossa dai messaggi AI. Per confermare i dati ricevuti, il modulo anagrafica della scheda recupera una bozza dai messaggi della stessa pratica e conserva i valori discordanti da verificare, senza scegliere un identificativo arbitrario. L’indirizzo di ritiro o spedizione non viene usato come indirizzo fiscale.

La conferma dell’operatore crea e collega l’anagrafica, verifica la completezza reale e riabilita la fatturazione nella stessa transazione. I rifiuti della validazione sono visibili nel modulo e i valori inseriti restano disponibili. Le anagrafiche già esistenti vanno ricercate e collegate; non vengono duplicate né sovrascritte automaticamente.

La voce **Registra fattura o pro-forma già emessa** legge il PDF originale (massimo 3 MB e 30 pagine), controllando il tipo, il numero, la data, il totale, la targa e il blocco del destinatario. Il lettore riconosce il formato aziendale con intestazione `Fattura nr.` o `Pro Forma nr.`, con dati italiani o svizzeri. Documenti scansionati, formati diversi, più targhe o intestazioni discordanti richiedono verifica manuale e non cambiano lo stato.

Il documento verificato usa la RPC `registra_documento_amministrativo_verificato`, riservata al backend con ruolo `service_role`. Prima del salvataggio verifica l’ordine e l’identità fiscale, crea o collega una sola anagrafica completa e riabilita esplicitamente la fatturazione. L’inserimento del documento e l’aggiornamento della pratica sono atomici. Numero, tipo e data impediscono registrazioni duplicate; lo stesso documento non può essere applicato a un’altra pratica.

- Una **fattura** imposta Fatturata e completa la richiesta amministrativa, conservando la data originale del documento (precisione di giorno).
- Una **pro-forma** completa i dati amministrativi e mantiene Da fatturare; non equivale a una fattura o a un pagamento.
- Ricezione, lavorazione, assistenza e ritiri restano flussi distinti e non vengono chiusi da questa operazione.

I documenti registrati, con numero e data, sono visibili nella scheda. Il testo del PDF, l’impronta e i riferimenti della fonte vengono conservati; un collegamento al PDF è mostrato quando disponibile. Il caricamento manuale resta distinto dal controllo automatico Drive descritto sotto; non è un collegamento diretto a Fatture in Cloud.

Validazione: test del lettore PDF e delle bozze da chat, lettura di un PDF originale, build dell’applicazione e `supabase/tests/documenti_amministrativi_verificati.sql` eseguito con rollback. Il test SQL verifica fattura, pro-forma, sospensione, identità fiscale, idempotenza, targa errata, accesso limitato al backend e protezione dalle regressioni.


## Controllo automatico della cartella Fatture

Nella verifica notturna del 23–24 ottobre è emerso che il controllo Drive
concordato non era attivo: il codice disponeva del caricamento manuale e della
RPC di registrazione, ma non di un lettore periodico delle fatture. Il registro
conteneva soltanto quattro fatture e tre proforme. Le pratiche segnalate non
avevano alcun documento amministrativo collegato; il solo ricalcolo della coda
non poteva correggerle. Questo limite è distinto dalla sospensione del recupero
generale degli eventi commerciali.

La lettura dei PDF originali in Fatture/2026/10 ha permesso di registrare quattro
fatture già emesse e due proforme. Una lettura indipendente conferma quattro
pratiche fatturate e due con amministrazione pronta ma ancora da fatturare.
Un collegamento automatico a un vecchio cliente è stato corretto una tantum
mediante il destinatario della fattura attuale, conservando l'anagrafica
precedente e tracciando lo stato prima/dopo. Il rientro assistenza resta aperto.
Restano tre ordini con amministrazione da completare: per uno è stato trovato
solo un DDT, mentre per gli altri manca una fattura nella ricerca puntuale.
La ricerca non equivale a un inventario completo di tutti i documenti.

È stata creata e attivata l'automazione ChatGPT **Allinea fatture e pratiche**,
con controllo orario tramite Google Drive e Supabase collegati e stato
persistente con protezione di versione. Legge gli ordini aperti e i documenti
originali nelle sottocartelle reali dell'anno; verifica tipo, emittente, targa,
numero, data, totale, destinatario fiscale e cronologia dell'episodio.
Registra soltanto documenti univoci attraverso la RPC riservata, rilegge ogni
scrittura e conserva i riferimenti della prova. DDT, ricevute, note di credito,
scansioni illeggibili, episodi multipli e identificativi fiscali discordanti
rimangono da verificare. Il controllo periodico non sostituisce clienti già
collegati e non modifica direttamente stati o anagrafiche; la correzione
puntuale precedente non autorizza future sostituzioni automatiche.
Non invia messaggi ai clienti e non deduce pagamenti o chiusure di assistenza.
Segnala solo nuovi errori, conflitti o copertura incompleta, evitando duplicati.

L'attivazione della pianificazione è confermata dal servizio. Il percorso
lettura documento → RPC → rilettura è stato verificato sui sei documenti reali;
la prima esecuzione autonoma pianificata rimane da osservare separatamente.
Le scritture del connettore Supabase, prima bloccate da requestState, hanno
funzionato in questa sessione. Il riconciliatore generale resta sospeso.

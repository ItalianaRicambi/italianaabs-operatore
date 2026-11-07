# Chiusura delle richieste di assistenza

Regola confermata da Norberto il 7 novembre 2026: assistenza risolta non significa necessariamente riparazione eseguita. Può essere concordata una sostituzione, anche con ritiro successivo, oppure un rimborso quando non è disponibile un sostitutivo. Questi esiti non devono essere dedotti o registrati automaticamente.

## Correzione attiva

L'azione `assistenza_risolta` chiude, nella stessa transazione, l'eventuale richiesta collegata ancora `da_prendere_in_carico`, senza presa in carico, esito tecnico o attività collegate pendenti. Conserva le note precedenti e registra `assistenza_chiusura_amministrativa` nello storico. Non crea prove di riparazione, sostituzione o rimborso.

Le attività indipendenti restano visibili. Ritiri collegati pendenti e rientri tecnici già avviati bloccano questa scorciatoia: rimane disponibile il percorso esistente di gestione del rientro. Nessuna modifica a tale percorso o ai suoi requisiti. Il replay di una risoluzione conserva la data precedente e non chiude episodi successivi.

L'interfaccia esistente aggiorna home e scheda dopo il comando e legge senza cache. Non è necessaria una modifica del frontend per attivare la correzione.

## Riallineamento autorizzato

Pratiche 97, 923, 1086, 1134, 1309, 2488: chiuse solo le richieste anteriori alla risoluzione esplicita già registrata, con assenza di eventi successivi e attività collegate aperte. Le date della risoluzione sono conservate. Lo script in `supabase/repairs` verifica le condizioni e interrompe l'intera operazione se sono cambiate; non va esteso ad altri casi senza nuova verifica.

Gli episodi successivi di 1061 e 2144 sono preservati. Nessuna modifica alle pratiche più vecchie 867, 1133 e 1287 in questo intervento.

## Verifica

- Test SQL su PostgreSQL locale embedded (PGlite 0.3.14), con definizione della funzione e colonne ricavate dal database: chiusura, audit, note, replay, episodio successivo, blocco tecnico, ritiro pendente, attività indipendente, permessi, pratica senza episodio.
- 280 test TypeScript e 6 test DOM passati.
- Lettura dopo il riallineamento e proiezione con `prossimaAzione`: sei pratiche concluse/non urgenti; due episodi successivi ancora da lavorare.
- ACL conservati: esecuzione riservata al backend; nessun nuovo avviso di sicurezza, controllo salute senza rilievi. Gli avvisi preesistenti non sono corretti da questo intervento.

## Possibile evoluzione (non implementata)

Separare esplicitamente l'esito dell'assistenza (riparazione, sostituzione, rimborso, assistenza senza rientro) dalle attività residue (spedizione, recupero componente, gestione amministrativa). Non automatizzare rimborsi o cancellare ritiri solo perché il cliente ha ottenuto una soluzione.

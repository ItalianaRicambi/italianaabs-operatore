# Lettura prezzi dei preventivi ECU e SBC

Il lettore non riconosceva il titolo ECU con «Programma Scambio» su due righe
né il modello di fornitura SBC con reso obbligatorio e prezzo `1.197.00`.
Ora ricompone esclusivamente la continuazione esatta del titolo e riconosce
il modello SBC soltanto con titolo, fornitura europea e reso esplicitamente
obbligatorio. Conserva garanzia, disponibilità e condizioni del reso.
Numeri malformati, più alternative, prezzi discordanti o prove insufficienti
restano da verificare.

23 test del lettore e dell'ingresso preventivi passati. Riletti i quattro
testi originali già conservati: impronte e contenuto immutati; risultati
confrontati con i PDF originali su Drive. Collaudo SQL con rollback tramite
`registra_documento_preventivo_auto`, poi salvataggio e rilettura indipendente.

| Pratica | Servizio | Importo IVA inclusa |
| --- | --- | --- |
| 2155 | PS ECU | 397,00 EUR |
| 1964 | PS SBC | 1.197,00 EUR |
| 2180 | PS SBC | 1.197,00 EUR |
| 2182 | PS SBC | 1.197,00 EUR |

I documenti risultano inviati e collegati. Tutte e quattro le pratiche
conservano lo stato preventivo inviato e le date precedenti: nessuna
accettazione, fattura o pagamento è stata dedotta dalla lettura del prezzo.
La restituzione della ECU resta condizione dell'offerta anche quando il
cliente dichiara di non possederla; un ordine richiede chiarimento commerciale.

La build locale con webpack passa (avviso preesistente di unpdf su import.meta).
Turbopack locale non accetta il collegamento alle dipendenze esterne al worktree;
il controllo della build standard viene svolto nell'anteprima Vercel.

Restano cinque casi del controllo iniziale: 838, 2081, 2086, 2201, 2205.
Per 2086 e 2205 esistono offerte collegate ad altre schede nella medesima chat;
nessuna riassegnazione effettuata senza verificare la cronologia dei veicoli.

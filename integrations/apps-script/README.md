# Collegamento dei PDF privati al registro offerte

Attivo e collaudato il 9 ottobre 2026 nel progetto Google esistente. La notifica in `Codice.gs` avvolge il proprio oggetto con `preparaPayloadOffertaCompleta`; il file `DocumentoOfferta.gs` è stato aggiunto al progetto. Il collaudo su un PDF già registrato ha restituito `stato: "letta"` con tre alternative e `duplicato: true` al secondo invio.

La prima lettura mantiene la data di invio già registrata in `preventivi`, anche se il contenuto arriva successivamente. Le versioni successive mantengono la data del proprio invio. Il test `supabase/tests/offerte_data_prima_lettura.sql` verifica anche il recupero di una conferma precedente alla lettura, l'idempotenza e la conservazione del consenso a seguito di revisione.

Il recupero dei PDF si può suddividere in gruppi mirati per rispettare il limite di esecuzione Google. Un HTTP 409 per pratica ambigua, assente o bloccata dall'operatore conserva comunque il contenuto ricevuto; non forzare gli abbinamenti. Un HTTP 500 da timeout richiede invece di verificare l'acquisizione prima di ritentare.

Nel progetto Apps Script già collegato al foglio “Keplero - Preventivi emessi”, aggiungere `DocumentoOfferta.gs`.
Nella funzione esistente che notifica `/api/preventivi/emesso`, passare il payload a `preparaPayloadOffertaCompleta` immediatamente prima di `JSON.stringify`.

```javascript
payload: JSON.stringify(preparaPayloadOffertaCompleta(payload))
```

La modifica usa l'accesso Drive già autorizzato nel progetto. URL, chiave privata, registro, cartelle e trigger attuali restano gli stessi. Non cambiare la condivisione dei PDF. Non registrare il payload completo nei log.

Verificare su un PDF della cartella già elaborata: il webhook conserva l'id del preventivo e restituisce `lettura_offerta.stato: "letta"`. Un secondo invio dello stesso documento deve restituire `duplicato: true`. Un documento scansionato o con alternative incoerenti deve restituire `da_verificare` e comparire nella dashboard, anche se il preventivo è già stato contabilizzato.

Il webhook accetta anche `testo_pdf` o un array `opzioni` con numero, servizio, prezzo, IVA e condizioni. I dati vengono conservati anche se il PDF non è ancora abbinato alla pratica; il recupero del collegamento gira ogni cinque minuti.

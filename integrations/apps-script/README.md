# Collegamento dei PDF privati al registro offerte

Nel progetto Apps Script già collegato al foglio “Keplero - Preventivi emessi”, aggiungere `DocumentoOfferta.gs`.
Nella funzione esistente che notifica `/api/preventivi/emesso`, passare il payload a `preparaPayloadOffertaCompleta` immediatamente prima di `JSON.stringify`.

```javascript
payload: JSON.stringify(preparaPayloadOffertaCompleta(payload))
```

La modifica usa l'accesso Drive già autorizzato nel progetto. URL, chiave privata, registro, cartelle e trigger attuali restano gli stessi. Non cambiare la condivisione dei PDF. Non registrare il payload completo nei log.

Verificare su un PDF della cartella già elaborata: il webhook conserva l'id del preventivo e restituisce `lettura_offerta.stato: "letta"`. Un secondo invio dello stesso documento deve restituire `duplicato: true`. Un documento scansionato o con alternative incoerenti deve restituire `da_verificare` e comparire nella dashboard, anche se il preventivo è già stato contabilizzato.

Il webhook accetta anche `testo_pdf` o un array `opzioni` con numero, servizio, prezzo, IVA e condizioni. I dati vengono conservati anche se il PDF non è ancora abbinato alla pratica; il recupero del collegamento gira ogni cinque minuti.

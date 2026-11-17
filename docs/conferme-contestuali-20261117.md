# Conferme rimaste fuori dagli ordini — 17 novembre 2026

## Causa e protezione
Il riconoscitore della coda scartava l'intero messaggio se conteneva un punto
interrogativo, anche dopo una scelta affermativa distinta. Inoltre non rilevava
formule contestuali come «Ok facciamo quello originale della macchina».

Una funzione separata, usata esclusivamente per la coda di verifica, considera
le frasi affermative e le scelte esplicite. Il riconoscitore stretto e i criteri
di acquisizione automatica restano invariati. Non basta una domanda, un bonifico,
un condizionale o «Programma scambio» isolato. Le revoche restano evidenziate.
La coda non modifica stato, finanze, anagrafica, logistica o blocchi operatore.
Backfill e trigger live/originali rispettano la finestra con weekend sospeso;
nessuna variazione della frequenza. I messaggi non trasmessi e i collegamenti
ambigui richiedono verifica: non è una garanzia di copertura assoluta.

## Verifica manuale autorizzata
- ABS-002596: originale 51277809, 13/11 12:44 Europe/Rome; scelta del dispositivo
  originale, offerta EB049KP e successiva organizzazione del ritiro. La precedente
  correzione operatore del 10/11 precede l'accettazione e viene preservata.
- ABS-002763: originale 51827910, 16/11 16:49; accettazione 397 EUR, opzione idraulica
  specificata in 51812202. Esiste anche ABS-002714 della stessa vettura, contatto
  officina: non creare un secondo ordine e non archiviare automaticamente.
- ABS-002748: originali 51776600 e 51780745, 16/11 15:12 e 15:27; volontà di
  procedere sulla lavorazione del proprio ABS e «Ordine fatto». Nessun ordine
  corrispondente nella lettura Shopify; non attestare il pagamento né inventare ID.
- ABS-002760: confronto con Shopify #1010, stessa identità fiscale e codici
  dispositivo, variante Programma Scambio Made in Italy. Distinguere collegamento
  interno da modifiche all'ordine Shopify. Titolo FIAT nel catalogo vs Suzuki
  nella pratica: non modificare automaticamente catalogo o dati tecnici.

EF19904 e CC704HM usano formule condizionali: non acquisire automaticamente.
I riepiloghi del modello non sostituiscono gli originali.

## Collaudo
`PGLITE_MODULE=<modulo esterno> node scripts/test-conferme-originali-db.mjs`
usa PostgreSQL isolato e dati sintetici: positivi singolari/plurali, domanda
successiva, falsi positivi, duplicati, blocchi, revoche e finestra weekend.

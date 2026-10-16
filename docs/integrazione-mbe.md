# MBE · importazione e tracking

Prima fase in sola lettura: nessuna creazione spedizione, acquisto etichetta, prenotazione presa o messaggio al cliente. Conferma MBE originale: email del centro Galliate del 14 ottobre 2026. L'email tracking è inviata da MBE se l'email destinatario viene inserita nella spedizione; la dashboard non la duplica.

## Configurazione

1. Impostare esclusivamente nelle variabili **server** di Vercel `MBE_API_USERNAME` e `MBE_API_PASSWORD`, credenziali MBE Online abilitate alle API dal centro. Nessun prefisso NEXT_PUBLIC, nessuna credenziale in chat, repository o log. Distribuire nuovamente l'app dopo il salvataggio.
2. Accedere come operatore a `/mbe`, premere **Verifica collegamento e sincronizza**. Il successo richiede tutte le pagine e tutti i tracking validi, seguiti da un unico commit nel database. Se non riesce, non attivare il controllo automatico; verificare con MBE credenziali e permessi API.
3. Solo dopo il collaudo riuscito, **Attiva aggiornamento ogni 15 minuti**. La migrazione lascia il servizio sospeso. Possibile sospensione dalla stessa pagina; le email GLS e le altre automazioni non vengono modificate.

`ShipmentsListV3Request` legge gli ultimi 30 giorni, con date in Europe/Rome (massimo 40 pagine / 1000 spedizioni). `TrackingRequest` verifica anche le spedizioni già acquisite più vecchie non ancora consegnate, in gruppi di massimo 100 codici. Gli abbinamenti pendenti vengono rivalutati anche oltre il periodo di importazione quando viene registrata una pratica. Oltre i limiti o con risposte incomplete si conserva l'ultimo risultato completo, mostrando l'errore; nessun import parziale. Una lease di tre minuti impedisce sovrapposizioni e scritture da esecuzioni scadute. Il cron usa ticket monouso con scadenza; nessuna password MBE negli header di pg_net.

## Abbinamento e significato degli stati

Il campo MBE `ShipmentInfo.Referring` deve contenere `ABS-000123` oppure `ABS-000123 — XX000XX`. Si cerca il numero esatto e univoco della pratica; se c'è la targa deve corrispondere. Sola targa, nome, indirizzo, telefono e il campo tecnico `InternalReferenceID` non sono criteri di abbinamento. Riferimenti liberi, mancanti, multipli o discordanti restano nel registro. Un riferimento modificato non sposta una spedizione già collegata: rimane una verifica visibile. Le destinazioni cliente/laboratorio/rientro richiedono classificazione operatore e vengono conservate durante le sincronizzazioni.

La data della spedizione restituita da MBE è una data di registrazione, non la prova del ritiro. `ShipmentToBeClosed=true` è indicato come «Da chiudere in MBE». `WAITING_DELIVERY` è mostrato come «Consegna in attesa (MBE)», senza dedurre una partenza. `PARTIALLY_DELIVERED` resta una consegna parziale; `NOT_AVAILABLE` non viene convertito in uno stato fisico. `DELIVERED` e `DeliveryDate` sono informazioni del corriere, non accettazione tecnica del laboratorio. Nessuna funzione aggiorna stati commerciali, fatture, prese GLS, assistenze o programma scambio.

Si conservano codici master e dei colli separati, riferimenti, nominativi/città/paese di mittente e destinatario, stati e variazioni osservate. Non si acquisiscono prezzi, firme di consegna, email, indirizzi completi o etichette temporanee. Non è stato inventato un URL pubblico di tracking. Le osservazioni riportano l'ora di lettura, non un'ora di evento logistico non fornita da MBE.

## Fonti tecniche verificate

- [Autenticazione e servizio](https://sites.google.com/fortidia.com/eship-api-documentation/introduction/authentication-process-and-service-information)
- [ShipmentsListV3Request](https://sites.google.com/fortidia.com/eship-api-documentation/shipment-shipping/shipmentslistv3request)
- [TrackingRequest](https://sites.google.com/fortidia.com/eship-api-documentation/main-workflows/tracking/trackingrequest)
- [WSDL produzione](https://api.mbeonline.it/ws/e-link.wsdl), endpoint fisso `https://api.mbeonline.it/ws`, SOAP 1.1, namespace `http://www.onlinembe.eu/ws/`, HTTP Basic, SOAPAction vuota.

Il WSDL richiede ancora il nodo Credentials, deprecato per autenticazione: viene emesso vuoto, mentre le credenziali viaggiano esclusivamente nell'header HTTP Basic su HTTPS. Il collaudo reale deve verificare anche questa compatibilità con l'account del centro. Gli stati/elementi sono derivati dal WSDL, ma un test locale non dimostra l'abilitazione dell'account MBE.

Il servizio push MBE è documentato ma non configurato: la sua registrazione modifica il callback dell'account e richiede un collaudo separato. L'integrazione non dipende dalla chiave Keplero.

## Verifiche

`node --experimental-strip-types --test app/lib/mbe.test.ts`, `npx tsc --noEmit`, ESLint e build Next. Test SQL in transazione con rollback: riferimenti esatti, targa discordante, mancante e mutata; duplicati senza nuove osservazioni; classificazione preservata; errori e lease; nessuna variazione degli stati della pratica. I test non chiamano il servizio MBE reale e non producono spedizioni o notifiche.

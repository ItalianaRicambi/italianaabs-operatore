# Ordini Shopify e controllo IVA

La validazione VIES e il calcolo IVA restano affidati a Shopify Tax nel checkout
nativo e devono essere collaudati. Il campo Partita IVA del negozio è già
facoltativo: la sua presenza non certifica il funzionamento completo della
routine fiscale. Il mercato UE è stato configurato con
`INCLUDES_TAXES_IN_PRICE_BASED_ON_COUNTRY` il 25 ottobre 2026; la sede attiva di
evasione è italiana. L'Italia conserva la configurazione ereditata.

**Mercato UE temporaneamente in bozza:** il calcolo Shopify del 25 ottobre,
con la variante reale `66311307952477`, `taxExempt=false`, indirizzi tedeschi
e nessun cliente/Partita IVA, restituisce €366,39 e IVA zero. La stessa variante
con indirizzi italiani restituisce €447,00 e IVA €80,61. Sono calcoli senza
creazione di ordini o pagamenti; non sostituiscono il checkout completo.
Controllare Impostazioni → Imposte e dazi → Unione Europea, soprattutto la
riscossione IVA sulle vendite transfrontaliere, prima di riattivare il mercato.
Non scegliere OSS o il regime nazionale senza conferma del regime effettivo.
Listini di spedizione e regole BoomGate rimangono configurati.

Il ricevitore `/api/shopify/ordini` accetta soltanto eventi HTTPS firmati per
`j4mqgv-am.myshopify.com`: `orders/create`, `orders/updated`, `orders/paid`,
`orders/cancelled`. Non accetta notifiche email o dichiarazioni del bot come
prova del pagamento o dell'esenzione. La firma HMAC viene verificata sui byte
originali e la chiave è esclusivamente lato server.

## Attivazione ancora necessaria

1. La migrazione `20261025222248_ordini_shopify_controllo_iva` è già applicata;
   pubblicare il commit dell'applicazione.
2. Nelle impostazioni Notifiche/Webhook di Shopify, creare gli eventi indicati
   verso `https://italianaabs-operatore.vercel.app/api/shopify/ordini` in JSON.
3. Salvare **direttamente in Vercel**, senza inviarla in chat, la chiave di firma
   mostrata da Shopify per questi webhook come `SHOPIFY_WEBHOOK_SECRET` negli
   ambienti previsti. Le sottoscrizioni create da un'app usano il segreto di
   quell'app: non usare una chiave diversa da quella che firma questi eventi.
4. Ridistribuire il commit per caricare la variabile. Inviare una prova nativa
   Shopify, verificare ricezione e firma, poi un evento operativo controllato.
   Il flag `test` deve rimanere vero per le simulazioni: non inquinare i contatori.

La dashboard indica esplicitamente quando il collegamento non è configurato o
non ha ancora ricevuto eventi. Non presentare la routine come attiva prima del
collaudo di questo percorso. L'accesso al team Vercel è stato ripristinato e
l'anteprima del codice è READY. La prova remota conferma il redirect operatore
e la risposta 503 del ricevitore senza chiave. Il merge in produzione è stato
fermato dalla revisione automatica, che richiede consenso esplicito alla
pubblicazione mentre configurazione webhook e collaudo IVA UE sono aperti.

## Regole fiscali

- IVA addebitata: viene mostrato l'importo realmente registrato da Shopify.
- `tax_exempt=true` insieme a IVA zero: "IVA non addebitata da Shopify", con
  verifica operatore prima della fatturazione.
- IVA zero senza flag, dati mancanti/discordanti, o azienda estera con IVA
  addebitata: controllo richiesto.
- La Partita IVA contenuta negli attributi ordine è una **dichiarazione**. La
  Partita IVA nativa potrebbe essere salvata soltanto nel profilo cliente: se
  non arriva nell'evento, l'operatore deve consultare Shopify. Non inventarla.
- Un fallimento VIES non è deducibile dall'IVA addebitata. Il webhook ordini
  non espone l'esito storico del controllo VIES del checkout. L'interfaccia lo
  dichiara; non chiama un importo zero "VIES valido".
- L'assenza della ragione sociale non qualifica automaticamente un cliente
  come privato verificato.
- Nessuna modifica a fatture, customer.taxExempt o aliquote su iniziativa del
  bot. Nessuna integrazione Fatture in Cloud in questa fase.
- La guida Shopify richiede di attivare anche le fatture IVA native quando si
  attiva la validazione al checkout. Verificare questa impostazione con
  l'operatore: non abilitarla tacitamente, dato che la fatturazione automatica
  è stata rinviata. La validazione nativa resta da confermare.

PS/PSMI richiedono `financial_status=paid`; RE/RI consentono la stesura prima
del pagamento. Varianti non riconosciute, rimborsi parziali e aggiornamenti
discordanti richiedono l'operatore. Non vengono creati documenti d'ordine o
nuove pratiche in automatico. Le pratiche già collegate tramite un riferimento
Shopify univoco possono essere mostrate senza alterarne lo stato.

Le consegne duplicate sono idempotenti. Gli eventi più vecchi non sovrascrivono
il registro. Due payload discordanti con la stessa data Shopify conservano
il precedente e accendono un controllo; un evento successivo lo risolve.

## Collaudo

`node --experimental-strip-types --test app/lib/ordiniShopify.test.ts`

Eseguire anche TypeScript, lint sui file modificati e il test SQL transazionale
prima della pubblicazione. Al checkout verificare azienda UE con Partita IVA
VIES valida, Partita IVA invalida o servizio VIES indisponibile, cliente senza
Partita IVA, e fatturazione/spedizione diverse. Confrontare imponibile, IVA e
totale. Non usare Partite IVA di terzi casuali per simulare acquisti e non
concludere pagamenti reali durante il collaudo.

Verifiche già eseguite sul commit preparato: 12 test unitari, TypeScript,
lint sui file modificati, build di produzione Next.js e test SQL transazionale
con rollback. Verificati RLS e accesso riservato al ruolo server. Le prove HTTP
coprono accesso operatore, negozio/firma errati, payload incompleto, limite
dimensione e risposta 503 quando il database non è disponibile. Nessun ordine
operativo o pagamento è stato creato durante questi test.

Ancora da collaudare: pubblicazione Vercel, chiave webhook, consegna firmata
Shopify → registro → dashboard e casi fiscali nel checkout nativo.

Riferimenti:
- https://help.shopify.com/en/manual/taxes/shopify-tax/vat-validate
- https://help.shopify.com/en/manual/international/pricing/dynamic-tax-inclusive-pricing
- https://help.shopify.com/en/manual/taxes/eu/eu-tax-setup
- https://shopify.dev/docs/apps/build/webhooks/subscribe/https

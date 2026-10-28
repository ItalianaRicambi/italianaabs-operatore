-- Transazione di prova: nessun ordine o pagamento reale viene creato.
begin;
set local role service_role;
do $$
declare
  base jsonb := '{"shop":"j4mqgv-am.myshopify.com","ordine_id":"99999999999999999997","aggiornato_shopify_at":"2026-10-28T17:16:49Z","test":false,"annullato":false,"stato_pagamento":"paid","totale":88400,"iva":15941,"valuta":"EUR","articoli":[{"titolo":"TEST","quantita":1}],"servizi":["PS","CODIFICA"]}';
  attiva jsonb := '{"attivo":true,"pronto_ordine":true,"pagamento_richiesto":true,"verifica_iva":false}';
  chiusa jsonb := '{"attivo":false,"pronto_ordine":false,"pagamento_richiesto":true,"verifica_iva":false}';
  annullata jsonb;
  r jsonb;
begin
  annullata := base || '{"annullato":true,"totale":0,"iva":0}';
  perform public.registra_ordine_shopify(base,attiva);
  r := public.registra_ordine_shopify(annullata,chiusa);
  assert r->>'esito' = 'registrato', 'Annullamento con stesso timestamp e importi correnti azzerati';
  assert (select not attivo and not pronto_ordine and not conflitto and dati->>'annullato'='true' from public.ordini_shopify where ordine_id=base->>'ordine_id');
  r := public.registra_ordine_shopify(base,attiva);
  assert r->>'esito' = 'evento_pre_annullamento', 'Consegna inversa non riattiva';
  r := public.registra_ordine_shopify(annullata,chiusa);
  assert r->>'esito' = 'duplicato', 'Retry annullamento idempotente';
  assert (select not attivo and not pronto_ordine and not conflitto from public.ordini_shopify where ordine_id=base->>'ordine_id');

  base := base || '{"ordine_id":"99999999999999999996"}';
  annullata := base || '{"annullato":true,"totale":0,"iva":0}';
  perform public.registra_ordine_shopify(annullata,chiusa);
  r := public.registra_ordine_shopify(base,attiva);
  assert r->>'esito' = 'evento_pre_annullamento', 'Annullamento arrivato per primo';
  r := public.registra_ordine_shopify(base || '{"aggiornato_shopify_at":"2026-10-28T17:16:48Z"}',attiva);
  assert r->>'esito' = 'evento_superato', 'Evento più vecchio scartato';
  r := public.registra_ordine_shopify(base || '{"aggiornato_shopify_at":"2026-10-28T17:16:50Z"}',attiva);
  assert r->>'esito' = 'conflitto_da_verificare', 'Neppure un timestamp successivo riapre un annullamento irreversibile';
  assert (select not attivo and dati->>'annullato'='true' from public.ordini_shopify where ordine_id=base->>'ordine_id');

  base := base || '{"ordine_id":"99999999999999999995"}';
  perform public.registra_ordine_shopify(base,attiva);
  r := public.registra_ordine_shopify(base || '{"totale":1}',attiva);
  assert r->>'esito' = 'conflitto_da_verificare', 'Importi discordanti senza annullamento restano bloccati';
  r := public.registra_ordine_shopify(base || '{"annullato":true,"valuta":"USD"}',chiusa);
  assert r->>'esito' = 'conflitto_da_verificare', 'Nessuna scelta arbitraria tra valute';
  assert (select conflitto and not attivo and not pronto_ordine from public.ordini_shopify where ordine_id=base->>'ordine_id');

  base := base || '{"ordine_id":"99999999999999999994","test":true}';
  perform public.registra_ordine_shopify(base,chiusa);
  r := public.registra_ordine_shopify(base || '{"annullato":true,"totale":0,"iva":0}',chiusa);
  assert r->>'esito' = 'registrato', 'Caso di collaudo #1003';
  assert (select not attivo and not pronto_ordine and not conflitto from public.ordini_shopify where ordine_id=base->>'ordine_id');
end $$;
reset role;
rollback;

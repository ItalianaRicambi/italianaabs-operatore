begin;
set local role service_role;
do $$
declare
  d jsonb := '{"shop":"j4mqgv-am.myshopify.com","ordine_id":"99999999999999999999","aggiornato_shopify_at":"2026-10-25T20:00:00Z","stato_pagamento":"pending"}';
  v jsonb := '{"attivo":true,"pronto_ordine":false,"pagamento_richiesto":true,"verifica_iva":true}';
  r jsonb;
  n integer;
begin
  r := public.registra_ordine_shopify(d,v);
  assert r->>'esito' = 'registrato', 'Prima ricezione';
  r := public.registra_ordine_shopify(d,v);
  assert r->>'esito' = 'duplicato', 'Retry idempotente';
  select count(*) into n from public.ordini_shopify where ordine_id = d->>'ordine_id';
  assert n = 1, 'Un solo ordine';
  r := public.registra_ordine_shopify(d || '{"aggiornato_shopify_at":"2026-10-25T19:00:00Z","stato_pagamento":"paid"}',v || '{"pronto_ordine":true}');
  assert r->>'esito' = 'evento_superato', 'Un vecchio pagamento non sostituisce il presente';
  r := public.registra_ordine_shopify(d || '{"stato_pagamento":"paid"}',v || '{"pronto_ordine":true}');
  assert r->>'esito' = 'conflitto_da_verificare', 'Revisione uguale discordante';
  assert (select conflitto and not pronto_ordine from public.ordini_shopify where ordine_id = d->>'ordine_id'), 'Conflitto visibile';
  r := public.registra_ordine_shopify(d || '{"aggiornato_shopify_at":"2026-10-25T21:00:00Z","stato_pagamento":"paid"}',v || '{"pronto_ordine":true}');
  assert r->>'esito' = 'registrato', 'Aggiornamento successivo';
  assert (select not conflitto and pronto_ordine from public.ordini_shopify where ordine_id = d->>'ordine_id'), 'Aggiornamento risolve il conflitto';
  r := public.registra_ordine_shopify(d || '{"aggiornato_shopify_at":"2026-10-25T22:00:00Z","test":true}',v || '{"attivo":false,"pronto_ordine":false}');
  assert (select not attivo from public.ordini_shopify where ordine_id = d->>'ordine_id'), 'Prove fuori coda';
end;
$$;
reset role;
do $$ begin
  assert not has_table_privilege('anon','public.ordini_shopify','SELECT'), 'Registro privato anon';
  assert not has_table_privilege('authenticated','public.ordini_shopify','SELECT'), 'Registro privato client';
  assert not has_function_privilege('anon','public.registra_ordine_shopify(jsonb,jsonb)','EXECUTE'), 'Scrittura privata';
  assert not has_function_privilege('authenticated','public.stato_ordini_shopify()','EXECUTE'), 'Contatori privati';
  assert (select relrowsecurity from pg_class where oid = 'public.ordini_shopify'::regclass), 'RLS attiva';
end $$;
rollback;

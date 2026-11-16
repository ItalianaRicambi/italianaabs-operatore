begin;
set local role service_role;
do $$
declare t uuid; o jsonb; v jsonb;
begin
 t:=public.inizia_sync_shopify();
 assert t is not null;
 assert public.inizia_sync_shopify() is null, 'concurrent run must not acquire lease';
 o:=jsonb_build_object('ordine_id','99999999999999999999','shop','j4mqgv-am.myshopify.com',
 'aggiornato_shopify_at',now()-interval '1 minute','test',true,'annullato',false,'articoli','[]'::jsonb);
 perform public.registra_snapshot_shopify(t,o);
 perform public.registra_snapshot_shopify(t,o);
 assert (select count(*)=1 from public.ordini_shopify_api where ordine_id=o->>'ordine_id');
 perform public.registra_snapshot_shopify(t,o||jsonb_build_object('aggiornato_shopify_at',now()-interval '1 hour','annullato',true));
 assert (select dati->>'annullato'='false' from public.ordini_shopify_api where ordine_id=o->>'ordine_id');
 perform public.registra_snapshot_shopify(t,o||'{"annullato":true}'::jsonb);
 perform public.registra_snapshot_shopify(t,o||jsonb_build_object('aggiornato_shopify_at',now(),'annullato',false));
 assert (select dati->>'annullato'='true' from public.ordini_shopify_api where ordine_id=o->>'ordine_id');
 perform public.termina_sync_shopify(t,null,1,now()-interval '60 days');
 v:=public.stato_sync_shopify();
 assert v->>'ultimo_successo_at' is not null;
 t:=public.inizia_sync_shopify();
 perform public.termina_sync_shopify(t,'collaudo errore',0,now());
 assert public.stato_sync_shopify()->>'ultimo_successo_at'=v->>'ultimo_successo_at';
 assert public.stato_sync_shopify()->>'errore'='collaudo errore';
 assert not has_table_privilege('anon','public.ordini_shopify_api','select');
 assert not has_table_privilege('authenticated','public.ordini_shopify_api','select');
 assert not has_function_privilege('anon','public.registra_snapshot_shopify(uuid,jsonb)','execute');
 assert not has_function_privilege('authenticated','public.inizia_sync_shopify()','execute');
end $$;
rollback;

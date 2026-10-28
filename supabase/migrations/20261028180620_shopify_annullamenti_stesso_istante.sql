-- Risolve soltanto il riordino certo degli eventi di annullamento.
create or replace function public.registra_ordine_shopify(p_dati jsonb, p_valutazione jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_shop text := p_dati->>'shop';
  v_order text := p_dati->>'ordine_id';
  v_at timestamptz;
  v_row public.ordini_shopify;
  v_pratica uuid;
  v_count integer;
begin
  if v_shop is distinct from 'j4mqgv-am.myshopify.com'
     or coalesce(v_order,'') !~ '^[0-9]{1,20}$'
     or jsonb_typeof(p_dati) is distinct from 'object'
     or jsonb_typeof(p_valutazione) is distinct from 'object'
     or octet_length(p_dati::text) > 1000000
     or jsonb_typeof(p_valutazione->'attivo') is distinct from 'boolean'
     or jsonb_typeof(p_valutazione->'pronto_ordine') is distinct from 'boolean'
     or jsonb_typeof(p_valutazione->'pagamento_richiesto') is distinct from 'boolean'
     or jsonb_typeof(p_valutazione->'verifica_iva') is distinct from 'boolean'
  then raise exception 'Dati Shopify non validi'; end if;
  v_at := (p_dati->>'aggiornato_shopify_at')::timestamptz;
  if v_at is null then raise exception 'Revisione Shopify mancante'; end if;

  -- Serializza anche la prima consegna concorrente, quando la riga non esiste.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shopify:' || v_shop || ':' || v_order, 0));
  select * into v_row from public.ordini_shopify where shop = v_shop and ordine_id = v_order for update;
  if found then
    if v_at < v_row.aggiornato_shopify_at then
      return jsonb_build_object('esito','evento_superato','id',v_row.id);
    elsif v_row.dati->'annullato' = 'true'::jsonb and p_dati->'annullato' = 'false'::jsonb
      and v_at > v_row.aggiornato_shopify_at then
      update public.ordini_shopify set conflitto = true, pronto_ordine = false, attivo = false, ricevuto_at = now() where id = v_row.id;
      return jsonb_build_object('esito','conflitto_da_verificare','id',v_row.id);
    elsif v_at = v_row.aggiornato_shopify_at then
      if v_row.dati = p_dati then
        return jsonb_build_object('esito','duplicato','id',v_row.id);
      end if;
      -- Annullamento irreversibile: a parità di timestamp prevale il suo
      -- snapshot, ma solo se identità, righe e stato del pagamento coincidono.
      -- Gli importi correnti possono azzerarsi durante l'annullamento.
      if (v_row.dati - array['annullato','totale','iva']) = (p_dati - array['annullato','totale','iva'])
         and v_row.dati->'annullato' = 'true'::jsonb and p_dati->'annullato' = 'false'::jsonb then
        return jsonb_build_object('esito','evento_pre_annullamento','id',v_row.id);
      elsif ((v_row.dati - array['annullato','totale','iva']) = (p_dati - array['annullato','totale','iva'])
         and v_row.dati->'annullato' = 'false'::jsonb and p_dati->'annullato' = 'true'::jsonb
         and p_valutazione->'attivo' = 'false'::jsonb and p_valutazione->'pronto_ordine' = 'false'::jsonb) is not true then
        update public.ordini_shopify set conflitto = true, pronto_ordine = false,
          attivo = case when p_dati->'annullato' = 'true'::jsonb then false else attivo end,
          ricevuto_at = now() where id = v_row.id;
        return jsonb_build_object('esito','conflitto_da_verificare','id',v_row.id);
      end if;
    end if;
  end if;
  -- Nessun abbinamento per nome, email o targa; il riferimento deve essere univoco.
  select count(*), (array_agg(id))[1] into v_count, v_pratica from public.pratiche
    where shopify_order_id in (v_order, 'gid://shopify/Order/' || v_order);
  if v_count <> 1 then v_pratica := null; end if;
  insert into public.ordini_shopify (shop,ordine_id,aggiornato_shopify_at,dati,valutazione,attivo,pronto_ordine,pagamento_richiesto,verifica_iva,pratica_id)
  values (v_shop,v_order,v_at,p_dati,p_valutazione,(p_valutazione->>'attivo')::boolean,
    (p_valutazione->>'pronto_ordine')::boolean,(p_valutazione->>'pagamento_richiesto')::boolean,(p_valutazione->>'verifica_iva')::boolean,v_pratica)
  on conflict (shop,ordine_id) do update set aggiornato_shopify_at = excluded.aggiornato_shopify_at,
    dati = excluded.dati, valutazione = excluded.valutazione, attivo = excluded.attivo,
    pronto_ordine = excluded.pronto_ordine, pagamento_richiesto = excluded.pagamento_richiesto,
    verifica_iva = excluded.verifica_iva, pratica_id = coalesce(excluded.pratica_id, public.ordini_shopify.pratica_id),
    conflitto = false, ricevuto_at = now()
  returning * into v_row;
  return jsonb_build_object('esito','registrato','id',v_row.id);
end;
$$;
revoke all on function public.registra_ordine_shopify(jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.registra_ordine_shopify(jsonb,jsonb) to service_role;


-- Only the authenticated server may resolve an existing private WhatsApp session.
create function public.pratiche_tracking_whatsapp(p_sessione uuid)
returns table(targa text, telefono text, ordine_id text, numero_ordine text, mbe jsonb)
language sql stable security invoker set search_path = '' as $$
  select p.targa, p.telefono, o.ordine_id, o.dati->>'numero',
    coalesce((select jsonb_agg(jsonb_build_object('master',m.tracking_mbe,'corriere',m.tracking_corriere,
          'corriere_stato',m.tracking_corriere_stato,'colli',m.colli_corriere) order by m.tracking_mbe)
      from public.mbe_spedizioni m
      where m.pratica_id=p.id and m.abbinamento='abbinata'
        and m.tipo_destinazione='cliente' and m.bozza is false),'[]'::jsonb)
  from public.keplero_sessioni_originali s
  join public.keplero_pratiche_conversazioni pc on pc.sessione=s.sessione
  join public.pratiche p on p.id=pc.pratica_id
  left join public.ordini_shopify o on o.pratica_id=p.id
  where s.sessione=p_sessione and s.assistente='2aef20d3-5ef8-4c81-8f21-bd450f22960c'
    and p.ordine_annullato_cliente_at is null
    and (p.shopify_order_id is null or p.shopify_order_id=o.ordine_id)
    and (o.id is null or (o.attivo and not o.conflitto and o.dati->>'test'='false' and o.dati->>'annullato'='false'))
    and not exists (select 1 from public.contatti_operativi c where c.attivo
      and public.normalizza_telefono_cliente(c.telefono_normalizzato)=public.normalizza_telefono_cliente(p.telefono))
    and exists (select 1 from public.keplero_originali k where k.sessione=s.sessione
      and k.direzione='entrata' and k.originale->'metadata'->>'wa_message_id' is not null)
$$;
revoke all on function public.pratiche_tracking_whatsapp(uuid) from public,anon,authenticated;
grant execute on function public.pratiche_tracking_whatsapp(uuid) to service_role;

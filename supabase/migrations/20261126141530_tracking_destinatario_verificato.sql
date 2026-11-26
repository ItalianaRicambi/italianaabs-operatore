-- A verified delivery contact may use a different chat from the workshop's practice.
create table public.tracking_whatsapp_destinatari (
  ordine_row_id uuid primary key references public.ordini_shopify(id),
  sessione uuid not null references public.keplero_sessioni_originali(sessione),
  telefono text not null check (telefono ~ '^\+[1-9][0-9]{7,14}$'),
  verificato_at timestamptz not null default now()
);
alter table public.tracking_whatsapp_destinatari enable row level security;
revoke all on public.tracking_whatsapp_destinatari from public,anon,authenticated;
grant select on public.tracking_whatsapp_destinatari to service_role;

create or replace function public.pratiche_tracking_whatsapp(p_sessione uuid)
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
    and not exists (select 1 from public.tracking_whatsapp_destinatari d where d.ordine_row_id=o.id)
    and exists (select 1 from public.keplero_originali k where k.sessione=s.sessione
      and k.direzione='entrata' and k.originale->'metadata'->>'wa_message_id' is not null)
  union all
  select p.targa,d.telefono,o.ordine_id,o.dati->>'numero','[]'::jsonb
  from public.tracking_whatsapp_destinatari d
  join public.keplero_sessioni_originali s on s.sessione=d.sessione
  join public.ordini_shopify o on o.id=d.ordine_row_id
  left join public.pratiche p on p.id=o.pratica_id
  where d.sessione=p_sessione and s.assistente='2aef20d3-5ef8-4c81-8f21-bd450f22960c'
    and o.attivo and not o.conflitto and o.dati->>'test'='false' and o.dati->>'annullato'='false'
    and p.ordine_annullato_cliente_at is null
    and not exists (select 1 from public.contatti_operativi c where c.attivo
      and public.normalizza_telefono_cliente(c.telefono_normalizzato)=public.normalizza_telefono_cliente(d.telefono))
$$;

-- Separate read-only Shopify observations; never modifies commercial practices or webhook evidence.
create table public.shopify_sync_stato (
 id boolean primary key default true check(id),
 ultimo_avvio_at timestamptz, ultimo_successo_at timestamptz,
 errore text, ordini_letti integer not null default 0,
 finestra_da timestamptz, lease_token uuid, lease_fino timestamptz
);
insert into public.shopify_sync_stato(id) values(true);
create table public.ordini_shopify_api (
 ordine_id text primary key check(ordine_id ~ '^[0-9]{1,20}$'),
 dati jsonb not null check(dati->>'shop'='j4mqgv-am.myshopify.com' and dati->>'ordine_id'=ordine_id),
 aggiornato_shopify_at timestamptz not null,
 verificato_at timestamptz not null default now()
);
alter table public.shopify_sync_stato enable row level security;
alter table public.ordini_shopify_api enable row level security;
revoke all on public.shopify_sync_stato, public.ordini_shopify_api from public, anon, authenticated;
grant select,insert,update on public.shopify_sync_stato,public.ordini_shopify_api to service_role;

create function public.inizia_sync_shopify() returns uuid
language plpgsql security invoker set search_path='' as $$
declare t uuid:=gen_random_uuid();
begin
 update public.shopify_sync_stato set lease_token=t, lease_fino=now()+interval '5 minutes',ultimo_avvio_at=now()
 where id and (lease_fino is null or lease_fino<now());
 if not found then return null; end if;
 return t;
end $$;

create function public.registra_snapshot_shopify(p_token uuid,p_dati jsonb) returns boolean
language plpgsql security invoker set search_path='' as $$
declare versione timestamptz;
begin
 perform 1 from public.shopify_sync_stato where id and lease_token=p_token and lease_fino>now() for update;
 if not found then raise exception 'Lease non valida'; end if;
 if p_dati->>'shop' is distinct from 'j4mqgv-am.myshopify.com'
 or not coalesce(p_dati->>'ordine_id' ~ '^[0-9]{1,20}$',false)
 or jsonb_typeof(p_dati->'test') is distinct from 'boolean'
 or jsonb_typeof(p_dati->'annullato') is distinct from 'boolean'
 or jsonb_typeof(p_dati->'articoli') is distinct from 'array'
 then raise exception 'Snapshot non valido'; end if;
 versione:=(p_dati->>'aggiornato_shopify_at')::timestamptz;
 if versione is null or versione>now()+interval '5 minutes' then raise exception 'Versione non valida'; end if;
 insert into public.ordini_shopify_api(ordine_id,dati,aggiornato_shopify_at)
 values(p_dati->>'ordine_id',p_dati,versione)
 on conflict(ordine_id) do update set
 dati=case when public.ordini_shopify_api.dati->>'annullato'='true' then jsonb_set(excluded.dati,'{annullato}','true') else excluded.dati end,
 aggiornato_shopify_at=excluded.aggiornato_shopify_at,verificato_at=now()
 where excluded.aggiornato_shopify_at>=public.ordini_shopify_api.aggiornato_shopify_at;
 return true;
end $$;

create function public.termina_sync_shopify(p_token uuid,p_errore text,p_ordini integer,p_da timestamptz) returns boolean
language plpgsql security invoker set search_path='' as $$
begin
 if p_ordini<0 or length(p_errore)>300 then raise exception 'Esito non valido'; end if;
 update public.shopify_sync_stato set errore=p_errore,
 ultimo_successo_at=case when p_errore is null then now() else ultimo_successo_at end,
 ordini_letti=case when p_errore is null then p_ordini else ordini_letti end,
 finestra_da=case when p_errore is null then p_da else finestra_da end,
 lease_token=null,lease_fino=null
 where id and lease_token=p_token and lease_fino>now();
 if not found then raise exception 'Lease non valida'; end if;
 return true;
end $$;

create function public.stato_sync_shopify() returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('ultimo_avvio_at',ultimo_avvio_at,'ultimo_successo_at',ultimo_successo_at,
 'errore',errore,'ordini_letti',ordini_letti,'finestra_da',finestra_da) from public.shopify_sync_stato where id;
$$;
revoke all on function public.inizia_sync_shopify(),public.registra_snapshot_shopify(uuid,jsonb),public.termina_sync_shopify(uuid,text,integer,timestamptz),public.stato_sync_shopify() from public,anon,authenticated;
grant execute on function public.inizia_sync_shopify(),public.registra_snapshot_shopify(uuid,jsonb),public.termina_sync_shopify(uuid,text,integer,timestamptz),public.stato_sync_shopify() to service_role;

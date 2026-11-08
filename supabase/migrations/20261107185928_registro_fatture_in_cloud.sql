-- Registro FIC separato dall'importazione PDF: nessun trigger modifica le pratiche.
create table public.fic_documenti (
  ambiente text not null check (ambiente in ('preview','production')),
  azienda_id bigint not null default 29153 check (azienda_id=29153),
  documento_id bigint not null check (documento_id>0),
  tipo text not null check (tipo in ('invoice','quote','order','proforma')),
  data_documento date not null,
  documento jsonb not null check (jsonb_typeof(documento)='object'),
  presente boolean not null default true,
  verificato_at timestamptz not null,
  primary key(ambiente,azienda_id,documento_id)
);
create index fic_documenti_periodo on public.fic_documenti(ambiente,tipo,data_documento);
create table public.fic_sincronizzazioni (
  id bigint generated always as identity primary key,
  ambiente text not null check (ambiente in ('preview','production')),
  tipo text not null check (tipo in ('invoice','quote','order','proforma')),
  dal date not null, al date not null,
  avvio timestamptz not null, conclusa timestamptz not null default now(),
  documenti integer not null, non_rilevati integer not null,
  check (al>=dal and al-dal<=30)
);
create index fic_sincronizzazioni_recenti on public.fic_sincronizzazioni(ambiente,tipo,avvio desc);
alter table public.fic_documenti enable row level security;
alter table public.fic_sincronizzazioni enable row level security;
revoke all on public.fic_documenti,public.fic_sincronizzazioni from public,anon,authenticated;
grant select,insert,update on public.fic_documenti,public.fic_sincronizzazioni to service_role;
grant usage,select on sequence public.fic_sincronizzazioni_id_seq to service_role;

create function public.fic_registra_snapshot(p_ambiente text,p_tipo text,p_dal date,p_al date,
  p_avvio timestamptz,p_documenti jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare n integer; mancanti integer;
begin
  if p_ambiente is null or p_ambiente not in ('preview','production')
    or p_tipo is null or p_tipo not in ('invoice','quote','order','proforma')
    or p_dal is null or p_al is null or p_al<p_dal or p_al-p_dal>30
    or p_avvio is null or p_avvio>now()+interval '5 minutes' or p_avvio<now()-interval '10 minutes'
    or p_documenti is null or jsonb_typeof(p_documenti)<>'array' then
    raise exception 'Snapshot non valido';
  end if;
  n:=jsonb_array_length(p_documenti);
  if n>500 or exists(select 1 from jsonb_array_elements(p_documenti) d where
    coalesce(d->>'tipo','')<>p_tipo or coalesce(d->>'id','')!~'^[1-9][0-9]{0,14}$'
    or coalesce(d->>'data','')!~'^\d{4}-\d{2}-\d{2}$'
    or (d->>'data')::date not between p_dal and p_al)
    or (select count(distinct d->>'id') from jsonb_array_elements(p_documenti) d)<>n then
    raise exception 'Documenti incompleti o duplicati';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('fic:'||p_ambiente,0));
  if exists(select 1 from public.fic_sincronizzazioni s where s.ambiente=p_ambiente and s.tipo=p_tipo
    and s.avvio>p_avvio and s.dal<=p_al and s.al>=p_dal) then
    raise exception 'Snapshot superato da una sincronizzazione più recente';
  end if;
  insert into public.fic_documenti(ambiente,documento_id,tipo,data_documento,documento,verificato_at)
    select p_ambiente,(d->>'id')::bigint,p_tipo,(d->>'data')::date,d,p_avvio
    from jsonb_array_elements(p_documenti) d
    on conflict(ambiente,azienda_id,documento_id) do update set tipo=excluded.tipo,
      data_documento=excluded.data_documento,documento=excluded.documento,presente=true,
      verificato_at=excluded.verificato_at
    where public.fic_documenti.verificato_at<=excluded.verificato_at;
  update public.fic_documenti d set presente=false,verificato_at=p_avvio
    where d.ambiente=p_ambiente and d.tipo=p_tipo and d.data_documento between p_dal and p_al
      and d.verificato_at<=p_avvio and not exists(select 1 from jsonb_array_elements(p_documenti) e where (e->>'id')::bigint=d.documento_id);
  get diagnostics mancanti=row_count;
  insert into public.fic_sincronizzazioni(ambiente,tipo,dal,al,avvio,documenti,non_rilevati)
    values(p_ambiente,p_tipo,p_dal,p_al,p_avvio,n,mancanti);
  return jsonb_build_object('documenti',n,'non_rilevati',mancanti);
end; $$;
revoke all on function public.fic_registra_snapshot(text,text,date,date,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.fic_registra_snapshot(text,text,date,date,timestamptz,jsonb) to service_role;

-- Quota per identità OAuth autorizzata. Nessun token o contenuto viene registrato.
create table public.fic_mcp_quote(user_id uuid not null, minuto timestamptz not null, richieste integer not null,
 primary key(user_id,minuto));
alter table public.fic_mcp_quote enable row level security;
revoke all on public.fic_mcp_quote from public,anon,authenticated;
grant select,insert,update,delete on public.fic_mcp_quote to service_role;
create function public.fic_mcp_consuma_quota(p_user_id uuid) returns boolean
language plpgsql security invoker set search_path='' as $$
declare n integer;
begin
  delete from public.fic_mcp_quote where minuto<now()-interval '2 days';
  insert into public.fic_mcp_quote values(p_user_id,date_trunc('minute',now()),1)
  on conflict(user_id,minuto) do update set richieste=public.fic_mcp_quote.richieste+1 returning richieste into n;
  return n<=30;
end; $$;
revoke all on function public.fic_mcp_consuma_quota(uuid) from public,anon,authenticated;
grant execute on function public.fic_mcp_consuma_quota(uuid) to service_role;

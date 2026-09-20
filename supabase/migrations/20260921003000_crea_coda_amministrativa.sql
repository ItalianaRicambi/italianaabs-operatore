do $$
begin
  create type public.stato_amministrativo as enum (
    'non_applicabile',
    'cliente_riconosciuto',
    'dati_mancanti',
    'corrispondenza_ambigua',
    'pronto_fatturazione',
    'completato'
  );
exception
  when duplicate_object then null;
end
$$;

alter table public.pratiche
  add column if not exists cliente_id uuid,
  add column if not exists stato_amministrativo public.stato_amministrativo
    not null default 'non_applicabile',
  add column if not exists stato_amministrativo_at timestamptz,
  add column if not exists nota_amministrativa text;

do $$
begin
  alter table public.pratiche
    add constraint pratiche_cliente_id_fkey
    foreign key (cliente_id)
    references public.clienti(id)
    on delete restrict;
exception
  when duplicate_object then null;
end
$$;

create index if not exists idx_pratiche_cliente_id
  on public.pratiche (cliente_id)
  where cliente_id is not null;

create index if not exists idx_pratiche_coda_amministrativa
  on public.pratiche (stato_amministrativo, ordine_acquisito_at)
  where stato_amministrativo not in ('non_applicabile', 'completato');

create or replace function public.sincronizza_coda_amministrativa()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.stato_fatturazione = 'da_fatturare' then
    if new.stato_amministrativo in ('non_applicabile', 'completato') then
      new.stato_amministrativo := 'dati_mancanti';
      new.stato_amministrativo_at := coalesce(new.ordine_acquisito_at, now());
    end if;
  elsif new.stato_fatturazione = 'fatturato' then
    new.stato_amministrativo := 'completato';
    new.stato_amministrativo_at := coalesce(new.data_fattura, now());
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sincronizza_coda_amministrativa on public.pratiche;

create trigger trg_sincronizza_coda_amministrativa
before insert or update of stato_fatturazione
on public.pratiche
for each row
execute function public.sincronizza_coda_amministrativa();

update public.pratiche
set
  stato_amministrativo = 'dati_mancanti',
  stato_amministrativo_at = coalesce(ordine_acquisito_at, updated_at, now())
where stato_fatturazione = 'da_fatturare'
  and stato_amministrativo = 'non_applicabile';

comment on column public.pratiche.cliente_id is
  'Cliente fiscale collegato alla pratica; nessun collegamento viene creato automaticamente da questa migrazione.';
comment on column public.pratiche.stato_amministrativo is
  'Stato amministrativo indipendente dagli stati commerciale, assistenza e fatturazione.';
comment on column public.pratiche.nota_amministrativa is
  'Motivo operativo o dati mancanti mostrati nella coda amministrativa.';

revoke all on function public.sincronizza_coda_amministrativa() from public;
grant execute on function public.sincronizza_coda_amministrativa() to service_role;

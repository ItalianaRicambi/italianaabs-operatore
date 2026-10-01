-- Distingue fornitori e contatti interni dai clienti. La rubrica e consultata
-- dal webhook e la protezione finale nel database copre anche altri writer.

create table if not exists public.contatti_operativi (
  id uuid primary key default gen_random_uuid(),
  telefono_normalizzato text not null unique
    check (telefono_normalizzato ~ '^[0-9]+$'),
  nome text not null,
  ruolo text not null check (ruolo in ('fornitore', 'interno')),
  attivo boolean not null default true,
  blocca_automazioni_commerciali boolean not null default true,
  note text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.contatti_operativi enable row level security;

revoke all on table public.contatti_operativi
  from public, anon, authenticated;
grant select, insert, update, delete on table public.contatti_operativi
  to service_role;

drop trigger if exists trg_contatti_operativi_updated_at
  on public.contatti_operativi;
create trigger trg_contatti_operativi_updated_at
before update on public.contatti_operativi
for each row execute function public.set_updated_at();

create or replace function private.normalizza_telefono_operativo(p_telefono text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_telefono text := regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g');
begin
  if left(v_telefono, 2) = '00' then
    v_telefono := substr(v_telefono, 3);
  end if;

  if v_telefono ~ '^3[0-9]{9}$' then
    v_telefono := '39' || v_telefono;
  end if;

  return v_telefono;
end;
$$;

revoke all on function private.normalizza_telefono_operativo(text)
  from public, anon, authenticated;

create or replace function private.proteggi_contatti_operativi()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contatto public.contatti_operativi%rowtype;
begin
  if new.telefono is null
     or new.tipo_flusso is distinct from 'commerciale'::public.tipo_flusso
     or new.fonte_classificazione = 'operatore'::public.fonte_dato
  then
    return new;
  end if;

  select *
  into v_contatto
  from public.contatti_operativi
  where telefono_normalizzato = private.normalizza_telefono_operativo(new.telefono)
    and attivo
    and blocca_automazioni_commerciali
  limit 1;

  if not found then
    return new;
  end if;

  -- Non altera ordini, pratiche chiuse o fatture gia esistenti. La regola
  -- impedisce soltanto che un'automazione interpreti il fornitore come cliente.
  if new.stato_commerciale in (
       'ordine_acquisito'::public.stato_commerciale,
       'perso'::public.stato_commerciale,
       'chiuso'::public.stato_commerciale,
       'rifiutato'::public.stato_commerciale
     )
     or new.stato_fatturazione in (
       'da_fatturare'::public.stato_fatturazione,
       'fatturato'::public.stato_fatturazione
     )
  then
    return new;
  end if;

  new.stato_commerciale := 'richiesta_verifica'::public.stato_commerciale;
  new.stato_completezza := 'dati_contestati_operatore'::public.stato_completezza;
  new.fonte_classificazione := 'sistema'::public.fonte_dato;
  new.fonte_completezza := 'sistema'::public.fonte_dato;
  new.blocco_classificazione_operatore := true;
  new.da_preventivare_at := null;
  new.promozione_automatica_at := null;
  new.nota_incompletezza := format(
    'Contatto operativo riconosciuto (%s: %s): non trattare come richiesta commerciale cliente.',
    v_contatto.ruolo,
    v_contatto.nome
  );

  return new;
end;
$$;

revoke all on function private.proteggi_contatti_operativi()
  from public, anon, authenticated;

drop trigger if exists trg_zz_proteggi_contatti_operativi
  on public.pratiche;
create trigger trg_zz_proteggi_contatti_operativi
before insert or update of telefono, tipo_flusso, stato_commerciale,
  stato_completezza, fonte_classificazione, fonte_completezza
on public.pratiche
for each row execute function private.proteggi_contatti_operativi();

insert into public.contatti_operativi (
  telefono_normalizzato,
  nome,
  ruolo,
  attivo,
  blocca_automazioni_commerciali,
  note
) values (
  '393939237173',
  'Giacomo Sismi',
  'fornitore',
  true,
  true,
  'Segnalato dall operatore il 30/09/2026: offerte del fornitore da non classificare come preventivi cliente.'
)
on conflict (telefono_normalizzato) do update set
  nome = excluded.nome,
  ruolo = excluded.ruolo,
  attivo = excluded.attivo,
  blocca_automazioni_commerciali = excluded.blocca_automazioni_commerciali,
  note = excluded.note,
  updated_at = now();

comment on table public.contatti_operativi is
  'Rubrica dei fornitori e contatti interni esclusi dalle automazioni commerciali cliente.';
comment on function private.proteggi_contatti_operativi() is
  'Ultima protezione DB: impedisce la promozione automatica dei contatti operativi nelle code commerciali cliente.';

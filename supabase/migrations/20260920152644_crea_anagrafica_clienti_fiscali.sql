create table if not exists public.clienti_importazioni (
  id uuid primary key default gen_random_uuid(),
  fonte text not null default 'fatture_in_cloud'
    check (fonte in ('fatture_in_cloud', 'manuale', 'altro')),
  nome_file text not null,
  file_sha256 text not null
    check (file_sha256 ~ '^[0-9a-f]{64}$'),
  righe_origine integer not null check (righe_origine >= 0),
  righe_inserite integer not null default 0 check (righe_inserite >= 0),
  stato text not null default 'in_corso'
    check (stato in ('in_corso', 'completata', 'fallita')),
  riepilogo jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (fonte, file_sha256)
);

create table if not exists public.clienti (
  id uuid primary key default gen_random_uuid(),
  fonte text not null default 'fatture_in_cloud'
    check (fonte in ('fatture_in_cloud', 'manuale', 'altro')),
  external_id text,
  source_record_key text not null check (btrim(source_record_key) <> ''),
  codice_interno text,
  denominazione text not null check (btrim(denominazione) <> ''),
  indirizzo_fatturazione text,
  comune text,
  cap text,
  provincia text,
  paese text,
  email text,
  telefono text,
  partita_iva text,
  codice_fiscale text,
  pec text,
  codice_sdi text,
  indirizzo_spedizione text,
  partita_iva_normalizzata text not null default '',
  codice_fiscale_normalizzato text not null default '',
  email_normalizzata text not null default '',
  telefono_normalizzato text not null default '',
  dati_fiscali_completi boolean not null default false,
  campi_amministrativi_mancanti text[] not null default '{}'::text[],
  da_verificare boolean not null default false,
  motivi_verifica text[] not null default '{}'::text[],
  possibile_duplicato boolean not null default false,
  chiavi_duplicate text[] not null default '{}'::text[],
  source_fingerprint text not null check (source_fingerprint ~ '^[0-9a-f]{64}$'),
  source_row_number integer not null check (source_row_number >= 2),
  importazione_id uuid not null references public.clienti_importazioni(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (fonte, source_record_key),
  unique (importazione_id, source_row_number)
);

create index if not exists idx_clienti_partita_iva_normalizzata
  on public.clienti (partita_iva_normalizzata)
  where partita_iva_normalizzata <> '';

create index if not exists idx_clienti_codice_fiscale_normalizzato
  on public.clienti (codice_fiscale_normalizzato)
  where codice_fiscale_normalizzato <> '';

create index if not exists idx_clienti_email_normalizzata
  on public.clienti (email_normalizzata)
  where email_normalizzata <> '';

create index if not exists idx_clienti_telefono_normalizzato
  on public.clienti (telefono_normalizzato)
  where telefono_normalizzato <> '';

create index if not exists idx_clienti_da_verificare
  on public.clienti (da_verificare, possibile_duplicato)
  where da_verificare or possibile_duplicato;

create index if not exists idx_clienti_dati_fiscali_incompleti
  on public.clienti (dati_fiscali_completi)
  where not dati_fiscali_completi;

alter table public.clienti_importazioni enable row level security;
alter table public.clienti enable row level security;

revoke all on table public.clienti_importazioni from public, anon, authenticated;
revoke all on table public.clienti from public, anon, authenticated;

grant select, insert, update, delete on table public.clienti_importazioni to service_role;
grant select, insert, update, delete on table public.clienti to service_role;

comment on table public.clienti is
  'Anagrafica fiscale clienti, separata dagli stati commerciali e tecnici delle pratiche. Accesso solo server-side.';
comment on column public.clienti.source_record_key is
  'Chiave tecnica stabile dell export; non implica fusione tra clienti simili.';
comment on column public.clienti.dati_fiscali_completi is
  'Completezza amministrativa per fatturazione, indipendente dallo stato commerciale della pratica.';
comment on column public.clienti.possibile_duplicato is
  'Segnalazione per revisione manuale: i record non vengono uniti automaticamente.';

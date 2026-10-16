-- MBE: importazione in sola lettura. Nessuna transizione delle pratiche.
create table public.mbe_spedizioni (
 tracking_mbe text primary key check(length(tracking_mbe) between 1 and 20),
 riferimento text not null default '', data_spedizione date not null,
 corriere text not null default '', tracking_corriere text not null default '',
 colli_mbe jsonb not null default '[]', colli_corriere jsonb not null default '[]',
 mittente jsonb not null, destinatario jsonb not null, bozza boolean,
 pratica_id uuid references public.pratiche(id),
 abbinamento text not null check(abbinamento in ('abbinata','da_abbinare','da_verificare')),
 motivo text not null,
 tipo_destinazione text not null default 'da_classificare' check(tipo_destinazione in ('cliente','laboratorio','rientro','da_classificare')),
 classificata_da text, classificata_at timestamptz,
 stato text check(stato in ('DELIVERED','PARTIALLY_DELIVERED','WAITING_DELIVERY','NOT_AVAILABLE','EXCEPTION')),
 data_consegna date, descrizione text not null default '',
 prima_lettura_at timestamptz not null default now(), ultima_lettura_at timestamptz not null default now(),
 impronta text not null
);
create index mbe_spedizioni_pratica_idx on public.mbe_spedizioni(pratica_id);
create table public.mbe_osservazioni (
 id bigint generated always as identity primary key,
 tracking_mbe text not null references public.mbe_spedizioni(tracking_mbe),
 osservata_at timestamptz not null default now(), contenuto jsonb not null, impronta text not null
);
create index mbe_osservazioni_tracking_idx on public.mbe_osservazioni(tracking_mbe,osservata_at desc);
create table public.mbe_collegamento (
 id boolean primary key default true check(id), automatico boolean not null default false,
 ultimo_tentativo_at timestamptz, ultimo_successo_at timestamptz, ultimo_errore text,
 importate integer not null default 0, controllate integer not null default 0,
 lease uuid, lease_scade_at timestamptz
);
insert into public.mbe_collegamento(id) values(true);
alter table public.mbe_spedizioni enable row level security;
alter table public.mbe_osservazioni enable row level security;
alter table public.mbe_collegamento enable row level security;
revoke all on public.mbe_spedizioni,public.mbe_osservazioni,public.mbe_collegamento from public,anon,authenticated;
grant select,insert,update,delete on public.mbe_spedizioni,public.mbe_osservazioni,public.mbe_collegamento to service_role;
grant usage,select on sequence public.mbe_osservazioni_id_seq to service_role;

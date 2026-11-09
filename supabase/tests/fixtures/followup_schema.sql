-- Schema minimo ISOLATO per i test PGlite, mai da applicare a Supabase.
-- Non replica trigger, anagrafica FIC o interfacce della produzione.
create role anon;
create role authenticated;
create role service_role bypassrls;
create schema private;
grant usage on schema public,private to service_role;
create table public.pratiche (
 id uuid primary key default gen_random_uuid(), keplero_conversation_id text, targa text,telefono text,nome_cliente text,
 tipo_flusso text not null default 'commerciale',stato_commerciale text not null default 'raccolta_dati',stato_completezza text not null default 'dati_mancanti',
 updated_at timestamptz not null default now(),blocco_operatore boolean not null default false,blocco_classificazione_operatore boolean not null default false,
 campi_bloccati_operatore text[] not null default '{}',stato_fatturazione text not null default 'non_fatturare',data_fattura date,
 dati_raw jsonb not null default '{}',ultimo_messaggio_cliente_at timestamptz,preventivo_inviato_at timestamptz,
 stato_amministrativo text not null default 'dati_mancanti',cliente_id uuid
);
create table public.keplero_originali(sessione uuid,messaggio_id text,data_messaggio timestamptz not null,data_originale text,
 direzione text not null,tipo text not null,testo text not null,impronta text not null,candidato boolean,revoca boolean,
 originale jsonb not null,modificato boolean not null default false,primary key(sessione,messaggio_id));
create table public.preventivi(id uuid primary key default gen_random_uuid(),pratica_id uuid);
create table public.keplero_verifiche_originali(sessione uuid,esito text);
create table public.chiusure_aziendali(data_inizio date,data_fine date);
create function private.verifica_dati_cliente_fatturazione(uuid) returns jsonb language sql as $$select '{"completi":false}'::jsonb$$;
create table public.attivita_operatore (
 id uuid primary key default gen_random_uuid(),tipo text not null constraint attivita_operatore_tipo_check check(tipo in ('ritiro_programma_scambio','ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_da_classificare','ritiro_altro_reso','richiamata_post_preventivo','richiamata_post_vendita','richiamata_da_classificare')),
 stato text not null default 'da_gestire',priorita text,pratica_id uuid not null references public.pratiche,external_key text,evidenza text,fonte text,metadati jsonb
);
grant all on all tables in schema public to service_role;

-- Fondazione disabilitata: nessun cron, trigger di invio o modifica delle pratiche.
-- L'attivazione richiede ancora adattatore Keplero, revisione allegati e collaudo end-to-end.
create table public.followup_dati_config (
 id boolean primary key default true check(id),
 enabled boolean not null default false,
 transport_verified boolean not null default false,
 accept_requests_after timestamptz,
 calendar_confirmed_through date,
 check (not enabled or (transport_verified and accept_requests_after is not null and calendar_confirmed_through is not null))
);
insert into public.followup_dati_config(id) values(true);
create table public.followup_dati_richieste (
 id uuid primary key default gen_random_uuid(),
 pratica_id uuid not null references public.pratiche(id),
 fase text not null check(fase in ('preventivo','fatturazione')),
 sessione uuid not null,
 messaggio_id text not null,
 inviata_at timestamptz not null,
 impronta text not null check(impronta ~ '^[a-f0-9]{64}$'),
 campi text[] not null check(cardinality(campi) between 1 and 20),
 registrata_at timestamptz not null default now(),
 foreign key(sessione,messaggio_id) references public.keplero_originali(sessione,messaggio_id),
 unique(pratica_id,fase,sessione,messaggio_id),
 unique(id,pratica_id,fase)
);
create table public.followup_dati_invii (
 pratica_id uuid not null references public.pratiche(id),
 fase text not null check(fase in ('preventivo','fatturazione')),
 richiesta_id uuid not null,
 claim uuid not null unique default gen_random_uuid(),
 stato text not null default 'claimed' check(stato in ('claimed','sent','ambiguous','cancelled')),
 claimed_at timestamptz not null default clock_timestamp(),
 verificata_at timestamptz not null,
 impronta_verifica text not null check(impronta_verifica ~ '^[a-f0-9]{64}$'),
 campi text[] not null check(cardinality(campi) between 1 and 20),
 provider_message_id text unique,
 inviata_at timestamptz,
 conferma jsonb,
 primary key(pratica_id,fase),
 foreign key(richiesta_id,pratica_id,fase) references public.followup_dati_richieste(id,pratica_id,fase),
 check(stato<>'sent' or (nullif(btrim(provider_message_id),'') is not null and inviata_at is not null and conferma is not null))
);
alter table public.followup_dati_config enable row level security;
alter table public.followup_dati_richieste enable row level security;
alter table public.followup_dati_invii enable row level security;
revoke all on public.followup_dati_config,public.followup_dati_richieste,public.followup_dati_invii from public,anon,authenticated;
grant select,insert,update on public.followup_dati_config,public.followup_dati_richieste,public.followup_dati_invii to service_role;

-- Richiede l'originale in uscita già verificato; non usa data di importazione o ultimo messaggio.
create function public.registra_richiesta_followup_dati(p_pratica uuid,p_fase text,p_sessione uuid,p_messaggio text,p_campi text[])
returns uuid language plpgsql security invoker set search_path='' as $$
declare m public.keplero_originali%rowtype; p public.pratiche%rowtype; r public.followup_dati_richieste%rowtype; cutoff timestamptz; campi text[];
begin
 select accept_requests_after into cutoff from public.followup_dati_config where id;
 if cutoff is null then return null;end if;
 if p_fase is null or p_fase not in ('preventivo','fatturazione') then raise exception 'Fase non valida';end if;
 select array_agg(distinct c order by c) into campi from unnest(p_campi) c where nullif(btrim(c),'') is not null;
 if coalesce(cardinality(campi),0)=0 or cardinality(campi)>20 or not (campi <@ case when p_fase='preventivo'
  then array['targa','codici','foto','guasto','diagnosi']
  else array['denominazione','indirizzo_fatturazione','cap','comune','provincia','nazione','partita_iva_o_codice_fiscale','partita_iva','codice_fiscale','sdi_o_pec'] end)
 then raise exception 'Campi non validi';end if;
 select * into p from public.pratiche where id=p_pratica;
 if p.id is null or p.keplero_conversation_id is distinct from p_sessione::text then return null;end if;
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio;
 if m.messaggio_id is null or m.direzione<>'uscita' or m.tipo<>'text' or m.modificato or m.data_messaggio<cutoff or m.data_messaggio>clock_timestamp()
  or coalesce(m.originale->>'sender','')<>'assistant'
  or not (coalesce(m.originale#>>'{whatsapp_message,status}','') in ('delivered','read')
   or (coalesce(m.originale->>'sender_type','')='user' and coalesce(m.originale#>>'{metadata,origin}','')='whatsapp_coexistence'))
 then return null;end if;
 insert into public.followup_dati_richieste(pratica_id,fase,sessione,messaggio_id,inviata_at,impronta,campi)
 values(p_pratica,p_fase,p_sessione,p_messaggio,m.data_messaggio,m.impronta,campi)
 on conflict(pratica_id,fase,sessione,messaggio_id) do nothing;
 select * into r from public.followup_dati_richieste where pratica_id=p_pratica and fase=p_fase and sessione=p_sessione and messaggio_id=p_messaggio;
 if r.impronta<>m.impronta or r.campi<>campi or r.inviata_at<>m.data_messaggio then raise exception 'Richiesta originale modificata';end if;
 return r.id;
end; $$;

-- Acquisizione atomica di uno slot PER PRATICA/FASE, senza lease o scadenza riutilizzabile.
-- Non autorizza da sola il trasporto: il chiamante deve applicare policy.ts e la rilettura live.
create function public.claim_followup_dati(p_richiesta uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[])
returns uuid language plpgsql security invoker set search_path='' as $$
declare r public.followup_dati_richieste%rowtype; p public.pratiche%rowtype; cfg public.followup_dati_config%rowtype;
 token uuid; d date; t time; dow integer; current_time_utc timestamptz:=clock_timestamp();
begin
 select * into cfg from public.followup_dati_config where id;
 if not found or not cfg.enabled or not cfg.transport_verified then return null;end if;
 select * into r from public.followup_dati_richieste where id=p_richiesta;
 if not found or r.inviata_at<cfg.accept_requests_after or current_time_utc<r.inviata_at+interval '24 hours' then return null;end if;
 select * into p from public.pratiche where id=r.pratica_id for update;
 if not found or p.updated_at is distinct from p_pratica_updated_at or p.blocco_operatore or p.blocco_classificazione_operatore
  or cardinality(p.campi_bloccati_operatore)>0 or p.tipo_flusso<>'commerciale'
  or p.stato_commerciale in ('rifiutato','chiuso') or p.stato_fatturazione='fatturato' or p.data_fattura is not null
  or p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='true'
  or p.ultimo_messaggio_cliente_at>=r.inviata_at then return null;end if;
 if r.fase='preventivo' and (p.stato_completezza<>'dati_mancanti' or p.stato_commerciale not in ('nuova','raccolta_dati','richiesta_verifica')
  or p.preventivo_inviato_at is not null or exists(select 1 from public.preventivi where pratica_id=p.id)) then return null;end if;
 if r.fase='fatturazione' and (p.stato_commerciale<>'ordine_acquisito' or p.stato_amministrativo<>'dati_mancanti'
  or private.verifica_dati_cliente_fatturazione(p.cliente_id)->>'completi'='true') then return null;end if;
 if exists(select 1 from public.followup_dati_richieste newer where newer.pratica_id=r.pratica_id and newer.fase=r.fase and newer.inviata_at>r.inviata_at)
  or exists(select 1 from public.keplero_originali where sessione=r.sessione and data_messaggio>=r.inviata_at and direzione in ('entrata','ignota'))
  or exists(select 1 from public.keplero_verifiche_originali where sessione=r.sessione and esito='da_verificare')
  or not exists(select 1 from public.keplero_originali where sessione=r.sessione and messaggio_id=r.messaggio_id and impronta=r.impronta and not modificato)
 then return null;end if;
 if p_verificata_at is null or p_verificata_at<current_time_utc-interval '15 seconds' or p_verificata_at>current_time_utc
  or p_impronta is null or p_impronta!~'^[a-f0-9]{64}$' or coalesce(cardinality(p_campi),0)=0 or not (p_campi<@r.campi) then return null;end if;
 d:=(current_time_utc at time zone 'Europe/Rome')::date;t:=(current_time_utc at time zone 'Europe/Rome')::time;dow:=extract(isodow from d);
 if d>cfg.calendar_confirmed_through or exists(select 1 from public.chiusure_aziendali where d between data_inizio and data_fine)
  or not ((dow between 1 and 4 and ((t>=time '09:00' and t<time '12:30') or (t>=time '14:00' and t<time '18:30')))
   or (dow=5 and t>=time '09:00' and t<time '13:30')) then return null;end if;
 insert into public.followup_dati_invii(pratica_id,fase,richiesta_id,verificata_at,impronta_verifica,campi)
 values(r.pratica_id,r.fase,r.id,p_verificata_at,p_impronta,p_campi)
 on conflict(pratica_id,fase) do nothing returning claim into token;
 return token;
end; $$;

create function public.esito_followup_dati(p_claim uuid,p_stato text,p_message_id text default null,p_inviata_at timestamptz default null,p_conferma jsonb default null)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if p_stato is null or p_stato not in ('sent','ambiguous','cancelled') then return false;end if;
 if p_stato='sent' and (nullif(btrim(p_message_id),'') is null or length(p_message_id)>300 or p_inviata_at is null or p_inviata_at>clock_timestamp() or p_conferma is null) then return false;end if;
 update public.followup_dati_invii set stato=p_stato,provider_message_id=case when p_stato='sent' then p_message_id end,
 inviata_at=case when p_stato='sent' then p_inviata_at end,conferma=case when p_stato='sent' then p_conferma end
 where claim=p_claim and (stato='claimed' or (stato='ambiguous' and p_stato='sent'))
 and (p_stato<>'sent' or p_inviata_at>=claimed_at);
 return found;
end; $$;
revoke all on function public.registra_richiesta_followup_dati(uuid,text,uuid,text,text[]),public.claim_followup_dati(uuid,timestamptz,timestamptz,text,text[]),public.esito_followup_dati(uuid,text,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.registra_richiesta_followup_dati(uuid,text,uuid,text,text[]),public.claim_followup_dati(uuid,timestamptz,timestamptz,text,text[]),public.esito_followup_dati(uuid,text,text,timestamptz,jsonb) to service_role;
comment on table public.followup_dati_invii is 'Slot permanente pratica/fase. Claim o esito ambiguo non autorizzano retry. Nessun invio finché adattatore e controlli non sono collaudati.';

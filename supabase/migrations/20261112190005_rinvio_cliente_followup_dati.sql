-- Rinvio esplicito del cliente. Mantiene disabilitati invio, configurazione e cron.
-- Solo una prenotazione senza tentativo registrato può essere rilasciata e riacquisita.
alter table public.followup_dati_invii drop constraint followup_dati_invii_stato_check;
alter table public.followup_dati_invii add constraint followup_dati_invii_stato_check
 check (stato in ('claimed','sent','ambiguous','cancelled','deferred'));
alter table public.followup_dati_invii add constraint followup_dati_invii_rinvio_senza_tentativo
 check (stato <> 'deferred' or (tentativo_at is null and tentativo is null and provider_message_id is null and inviata_at is null));

-- Il server interpreta i testi live; il DB verifica ogni originale, la scadenza
-- e l'assenza di risposte nuove, modificate o non comprese nella revisione.
create function private.followup_dati_risposte_verificate(
 p_richiesta public.followup_dati_richieste, p_ultimo_messaggio timestamptz, p_rinvio jsonb
) returns boolean language plpgsql security invoker set search_path='' as $$
declare
 risposte jsonb;
 scadenza timestamptz;
 ultima_risposta timestamptz;
 quanti integer;
begin
 if p_rinvio is null then
  return (p_ultimo_messaggio is null or p_ultimo_messaggio < p_richiesta.inviata_at)
   and not exists(select 1 from public.keplero_originali m
    where m.sessione=p_richiesta.sessione and m.data_messaggio>=p_richiesta.inviata_at
     and m.direzione in ('entrata','ignota'))
   and not exists(select 1 from public.keplero_verifiche_originali v
    where v.sessione=p_richiesta.sessione and v.esito='da_verificare');
 end if;

 risposte := p_rinvio->'messages';
 if jsonb_typeof(risposte) is distinct from 'array' then return false;end if;
 if jsonb_array_length(risposte) not between 1 and 5000
  or coalesce(p_rinvio->>'notBefore','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z$'
  or coalesce(p_rinvio->>'conversationFingerprint','') !~ '^[a-f0-9]{64}$' then return false;end if;
 begin
  scadenza := (p_rinvio->>'notBefore')::timestamptz;
 exception when invalid_datetime_format or datetime_field_overflow then return false;
 end;
 if scadenza <= p_richiesta.inviata_at or clock_timestamp() < scadenza then return false;end if;

 with reviewed as (
  select distinct m.messaggio_id, m.data_messaggio
  from jsonb_array_elements(risposte) proof
  join public.keplero_originali m on m.sessione=p_richiesta.sessione
   and m.messaggio_id=proof->>'id' and m.impronta=proof->>'fingerprint'
  where m.data_messaggio>=p_richiesta.inviata_at and m.direzione='entrata'
   and m.tipo='text' and not m.modificato and not m.revoca
 )
 select count(*), max(data_messaggio) into quanti, ultima_risposta from reviewed;
 if quanti <> jsonb_array_length(risposte) or ultima_risposta >= scadenza
  or p_ultimo_messaggio > ultima_risposta then return false;end if;

 return not exists(select 1 from public.keplero_originali m
  where m.sessione=p_richiesta.sessione and m.data_messaggio>=p_richiesta.inviata_at
   and m.direzione in ('entrata','ignota')
   and (m.direzione='ignota' or not exists(select 1 from jsonb_array_elements(risposte) proof
    where proof->>'id'=m.messaggio_id and proof->>'fingerprint'=m.impronta)))
  and not exists(select 1 from public.keplero_verifiche_originali v
   where v.sessione=p_richiesta.sessione and v.esito='da_verificare'
    and not exists(select 1 from jsonb_array_elements(risposte) proof where proof->>'id'=v.messaggio_id));
end; $$;

create or replace function private.followup_dati_stato_valido(p_richiesta uuid,p_versione timestamptz,p_letta_at timestamptz,p_rinvio jsonb)
returns boolean language plpgsql security invoker set search_path='' as $$
declare r public.followup_dati_richieste%rowtype; p public.pratiche%rowtype; c public.followup_dati_config%rowtype;
begin
 select * into c from public.followup_dati_config where id;
 if not found or not c.enabled or not c.transport_verified or c.accept_requests_after is null then return false;end if;
 select * into r from public.followup_dati_richieste where id=p_richiesta;
 if not found or r.inviata_at<c.accept_requests_after then return false;end if;
 select * into p from public.pratiche where id=r.pratica_id for update;
 if not found or p.updated_at is distinct from p_versione or p.keplero_conversation_id is distinct from r.sessione::text
  or p.blocco_operatore or p.blocco_classificazione_operatore or cardinality(p.campi_bloccati_operatore)>0
  or p.tipo_flusso is distinct from 'commerciale' or p.stato_commerciale in ('rifiutato','chiuso')
  or p.stato_fatturazione='fatturato' or p.data_fattura is not null
  or p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='true'
  or not private.followup_dati_risposte_verificate(r,p.ultimo_messaggio_cliente_at,p_rinvio) then return false;end if;
 if p_letta_at is null or p_letta_at<clock_timestamp()-interval '15 seconds' or p_letta_at>clock_timestamp() then return false;end if;
 if r.fase='preventivo' and (p.stato_completezza is distinct from 'dati_mancanti'
  or p.stato_commerciale not in ('nuova','raccolta_dati','richiesta_verifica') or p.preventivo_inviato_at is not null
  or exists(select 1 from public.preventivi where pratica_id=p.id)) then return false;end if;
 if r.fase='fatturazione' and (p.stato_commerciale is distinct from 'ordine_acquisito' or p.stato_amministrativo is distinct from 'dati_mancanti'
  or private.verifica_dati_cliente_fatturazione(p.cliente_id)->>'completi'='true') then return false;end if;
 if exists(select 1 from public.followup_dati_richieste x where x.pratica_id=r.pratica_id and x.fase=r.fase and x.inviata_at>r.inviata_at)
  or not exists(select 1 from public.keplero_originali where sessione=r.sessione and messaggio_id=r.messaggio_id and impronta=r.impronta and not modificato)
 then return false;end if;
 return true;
end; $$;

create or replace function public.claim_followup_dati(p_richiesta uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[],p_rinvio jsonb)
returns uuid language plpgsql security invoker set search_path='' as $$
declare r public.followup_dati_richieste%rowtype; cfg public.followup_dati_config%rowtype;
 token uuid; current_time_utc timestamptz:=clock_timestamp();
begin
 select * into cfg from public.followup_dati_config where id;
 if not found or not cfg.enabled or not cfg.transport_verified then return null;end if;
 select * into r from public.followup_dati_richieste where id=p_richiesta;
 if not found or r.inviata_at<cfg.accept_requests_after or current_time_utc<r.inviata_at+interval '24 hours' then return null;end if;
 if not private.followup_dati_stato_valido(r.id,p_pratica_updated_at,p_verificata_at,p_rinvio) then return null;end if;
 if p_verificata_at is null or p_verificata_at<current_time_utc-interval '15 seconds' or p_verificata_at>current_time_utc
  or p_impronta is null or p_impronta!~'^[a-f0-9]{64}$'
  or (p_rinvio is not null and p_impronta is distinct from p_rinvio->>'conversationFingerprint')
  or coalesce(cardinality(p_campi),0)=0 or not (p_campi<@r.campi) then return null;end if;
 if not private.followup_dati_fascia_aperta(clock_timestamp()) then return null;end if;
 insert into public.followup_dati_invii(pratica_id,fase,richiesta_id,verificata_at,impronta_verifica,campi)
 values(r.pratica_id,r.fase,r.id,p_verificata_at,p_impronta,p_campi)
 on conflict(pratica_id,fase) do update
 set richiesta_id=excluded.richiesta_id,claim=excluded.claim,stato='claimed',claimed_at=excluded.claimed_at,
  verificata_at=excluded.verificata_at,impronta_verifica=excluded.impronta_verifica,campi=excluded.campi
 where public.followup_dati_invii.stato='deferred'
 returning claim into token;
 return token;
end; $$;

create or replace function public.inizia_invio_followup_dati(p_claim uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[],p_tentativo jsonb,p_rinvio jsonb)
returns boolean language plpgsql security invoker set search_path='' as $$
declare i public.followup_dati_invii%rowtype; r public.followup_dati_richieste%rowtype;
 started timestamptz;
begin
 select * into i from public.followup_dati_invii where claim=p_claim;
 if not found or i.stato<>'claimed' or i.tentativo_at is not null then return false;end if;
 if not private.followup_dati_stato_valido(i.richiesta_id,p_pratica_updated_at,p_verificata_at,p_rinvio) then return false;end if;
 select * into i from public.followup_dati_invii where claim=p_claim for update;
 if not found or i.stato<>'claimed' or i.tentativo_at is not null then return false;end if;
 select * into r from public.followup_dati_richieste where id=i.richiesta_id;
 if clock_timestamp()<r.inviata_at+interval '24 hours' or p_impronta is null or p_impronta!~'^[a-f0-9]{64}$'
  or (p_rinvio is not null and p_impronta is distinct from p_rinvio->>'conversationFingerprint')
  or coalesce(cardinality(p_campi),0)=0 or not(p_campi<@r.campi) or p_campi is distinct from i.campi then return false;end if;
 if jsonb_typeof(p_tentativo) is distinct from 'object' or length(p_tentativo::text)>200000
  or p_tentativo->>'session' is distinct from r.sessione::text or p_tentativo->>'phase' is distinct from i.fase
  or coalesce(p_tentativo->>'to','')!~'^\+[1-9][0-9]{7,14}$'
  or jsonb_typeof(p_tentativo->'beforeIds') is distinct from 'array'
  or jsonb_typeof(p_tentativo->'variables') is distinct from 'array'
  or coalesce(p_tentativo->>'expectedText','')='' then return false;end if;
 if jsonb_array_length(p_tentativo->'variables')<>2 then return false;end if;
 begin started:=(p_tentativo->>'startedAt')::timestamptz;exception when others then return false;end;
 if started is null or started<clock_timestamp()-interval '15 seconds' or started>clock_timestamp() then return false;end if;
 if not private.followup_dati_fascia_aperta(clock_timestamp()) then return false;end if;
 update public.followup_dati_invii set tentativo_at=clock_timestamp(),tentativo=p_tentativo,
  verificata_at=p_verificata_at,impronta_verifica=p_impronta where claim=p_claim and tentativo_at is null and stato='claimed';
 return found;
end; $$;

create or replace function public.segnala_followup_dati(p_pratica uuid,p_fase text,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_rinvio jsonb)
returns boolean language plpgsql security invoker set search_path='' as $$
declare i public.followup_dati_invii%rowtype; r public.followup_dati_richieste%rowtype; activity uuid;
begin
 select * into i from public.followup_dati_invii where pratica_id=p_pratica and fase=p_fase;
 if not found or i.stato<>'sent' or i.provider_message_id is null or i.attivita_id is not null then return false;end if;
 select * into r from public.followup_dati_richieste where pratica_id=p_pratica and fase=p_fase order by inviata_at desc,registrata_at desc limit 1;
 if not found or not private.followup_dati_stato_valido(r.id,p_pratica_updated_at,p_verificata_at,p_rinvio)
  or clock_timestamp()<greatest(i.inviata_at,r.inviata_at,(p_rinvio->>'notBefore')::timestamptz)+interval '48 hours' then return false;end if;
 select * into i from public.followup_dati_invii where pratica_id=p_pratica and fase=p_fase for update;
 if i.stato<>'sent' or i.attivita_id is not null then return false;end if;
 insert into public.attivita_operatore(tipo,stato,priorita,pratica_id,external_key,evidenza,fonte,metadati)
 values('followup_dati_'||p_fase,'da_gestire','alta',p_pratica,'followup-dati:'||p_pratica||':'||p_fase,
 'Dati ancora mancanti dopo il promemoria: verificare la pratica. Non inviare un secondo sollecito automatico.',
 'routine_controllo_k',jsonb_build_object('followup_claim',i.claim,'provider_message_id',i.provider_message_id,'inviata_at',i.inviata_at))
 on conflict do nothing returning id into activity;
 if activity is null then select id into activity from public.attivita_operatore where pratica_id=p_pratica and tipo='followup_dati_'||p_fase;end if;
 update public.followup_dati_invii set attivita_id=activity where claim=i.claim;
 return activity is not null;
end; $$;

-- Le firme precedenti conservano il comportamento con risposte non revisionate.
create or replace function private.followup_dati_stato_valido(p_richiesta uuid,p_versione timestamptz,p_letta_at timestamptz)
returns boolean language sql security invoker set search_path='' as $$
 select private.followup_dati_stato_valido(p_richiesta,p_versione,p_letta_at,null);
$$;
create or replace function public.claim_followup_dati(p_richiesta uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[])
returns uuid language sql security invoker set search_path='' as $$
 select public.claim_followup_dati(p_richiesta,p_pratica_updated_at,p_verificata_at,p_impronta,p_campi,null);
$$;
create or replace function public.inizia_invio_followup_dati(p_claim uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[],p_tentativo jsonb)
returns boolean language sql security invoker set search_path='' as $$
 select public.inizia_invio_followup_dati(p_claim,p_pratica_updated_at,p_verificata_at,p_impronta,p_campi,p_tentativo,null);
$$;
create or replace function public.segnala_followup_dati(p_pratica uuid,p_fase text,p_pratica_updated_at timestamptz,p_verificata_at timestamptz)
returns boolean language sql security invoker set search_path='' as $$
 select public.segnala_followup_dati(p_pratica,p_fase,p_pratica_updated_at,p_verificata_at,null);
$$;

create function public.rilascia_claim_followup_dati(p_claim uuid)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 update public.followup_dati_invii set stato='deferred'
 where claim=p_claim and stato='claimed' and tentativo_at is null;
 return found;
end; $$;

revoke all on function
 private.followup_dati_risposte_verificate(public.followup_dati_richieste,timestamptz,jsonb),
 private.followup_dati_stato_valido(uuid,timestamptz,timestamptz,jsonb),
 public.claim_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb),
 public.inizia_invio_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb,jsonb),
 public.segnala_followup_dati(uuid,text,timestamptz,timestamptz,jsonb),
 public.rilascia_claim_followup_dati(uuid)
 from public,anon,authenticated;
grant execute on function
 private.followup_dati_risposte_verificate(public.followup_dati_richieste,timestamptz,jsonb),
 private.followup_dati_stato_valido(uuid,timestamptz,timestamptz,jsonb),
 public.claim_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb),
 public.inizia_invio_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb,jsonb),
 public.segnala_followup_dati(uuid,text,timestamptz,timestamptz,jsonb),
 public.rilascia_claim_followup_dati(uuid)
 to service_role;

-- Estensione disabilitata. Non abilita config, cron o bozze Keplero.
alter table public.followup_dati_invii
 add column tentativo_at timestamptz,
 add column tentativo jsonb,
 add column attivita_id uuid references public.attivita_operatore(id);

-- Guardia comune alla seconda verifica e alla segnalazione. Non sostituisce
-- la revisione semantica live di TUTTI gli originali/allegati/anagrafica.
create function private.followup_dati_stato_valido(p_richiesta uuid,p_versione timestamptz,p_letta_at timestamptz)
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
  or p.ultimo_messaggio_cliente_at>=r.inviata_at then return false;end if;
 if p_letta_at is null or p_letta_at<clock_timestamp()-interval '15 seconds' or p_letta_at>clock_timestamp() then return false;end if;
 if r.fase='preventivo' and (p.stato_completezza is distinct from 'dati_mancanti'
  or p.stato_commerciale not in ('nuova','raccolta_dati','richiesta_verifica') or p.preventivo_inviato_at is not null
  or exists(select 1 from public.preventivi where pratica_id=p.id)) then return false;end if;
 if r.fase='fatturazione' and (p.stato_commerciale is distinct from 'ordine_acquisito' or p.stato_amministrativo is distinct from 'dati_mancanti'
  or private.verifica_dati_cliente_fatturazione(p.cliente_id)->>'completi'='true') then return false;end if;
 if exists(select 1 from public.followup_dati_richieste x where x.pratica_id=r.pratica_id and x.fase=r.fase and x.inviata_at>r.inviata_at)
  or exists(select 1 from public.keplero_originali where sessione=r.sessione and data_messaggio>=r.inviata_at and direzione in ('entrata','ignota'))
  or exists(select 1 from public.keplero_verifiche_originali where sessione=r.sessione and esito='da_verificare')
  or not exists(select 1 from public.keplero_originali where sessione=r.sessione and messaggio_id=r.messaggio_id and impronta=r.impronta and not modificato)
 then return false;end if;
 return true;
end; $$;

-- CAS permanente. Un processo morto DOPO questa scrittura non ripete il POST.
create function public.inizia_invio_followup_dati(p_claim uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[],p_tentativo jsonb)
returns boolean language plpgsql security invoker set search_path='' as $$
declare i public.followup_dati_invii%rowtype; r public.followup_dati_richieste%rowtype;
 c public.followup_dati_config%rowtype; d date; t time; dow integer; started timestamptz;
begin
 select * into i from public.followup_dati_invii where claim=p_claim;
 if not found or i.stato<>'claimed' or i.tentativo_at is not null then return false;end if;
 if not private.followup_dati_stato_valido(i.richiesta_id,p_pratica_updated_at,p_verificata_at) then return false;end if;
 select * into i from public.followup_dati_invii where claim=p_claim for update;
 if i.stato<>'claimed' or i.tentativo_at is not null then return false;end if;
 select * into r from public.followup_dati_richieste where id=i.richiesta_id;
 select * into c from public.followup_dati_config where id;
 if clock_timestamp()<r.inviata_at+interval '24 hours' or p_impronta is null or p_impronta!~'^[a-f0-9]{64}$'
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
 d:=(clock_timestamp() at time zone 'Europe/Rome')::date;t:=(clock_timestamp() at time zone 'Europe/Rome')::time;dow:=extract(isodow from d);
 if c.calendar_confirmed_through is null or d>c.calendar_confirmed_through
  or exists(select 1 from public.chiusure_aziendali where d between data_inizio and data_fine)
  or not ((dow between 1 and 4 and ((t>=time '09:00' and t<time '12:30') or (t>=time '14:00' and t<time '18:30')))
   or (dow=5 and t>=time '09:00' and t<time '13:30')) then return false;end if;
 update public.followup_dati_invii set tentativo_at=clock_timestamp(),tentativo=p_tentativo,
  verificata_at=p_verificata_at,impronta_verifica=p_impronta where claim=p_claim and tentativo_at is null and stato='claimed';
 return found;
end; $$;

-- Solo attività interna dopo altre 48h. Il vincolo permanente include anche le
-- attività già completate: non si riaprono ad ogni passaggio del worker.
alter table public.attivita_operatore drop constraint attivita_operatore_tipo_check;
alter table public.attivita_operatore add constraint attivita_operatore_tipo_check check(tipo in (
 'ritiro_programma_scambio','ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_da_classificare','ritiro_altro_reso',
 'richiamata_post_preventivo','richiamata_post_vendita','richiamata_da_classificare','followup_dati_preventivo','followup_dati_fatturazione'));
create unique index uq_attivita_followup_dati on public.attivita_operatore(pratica_id,tipo)
 where tipo in ('followup_dati_preventivo','followup_dati_fatturazione');
create function public.segnala_followup_dati(p_pratica uuid,p_fase text,p_pratica_updated_at timestamptz,p_verificata_at timestamptz)
returns boolean language plpgsql security invoker set search_path='' as $$
declare i public.followup_dati_invii%rowtype; r public.followup_dati_richieste%rowtype; activity uuid;
begin
 select * into i from public.followup_dati_invii where pratica_id=p_pratica and fase=p_fase;
 if not found or i.stato<>'sent' or i.provider_message_id is null or i.attivita_id is not null then return false;end if;
 select * into r from public.followup_dati_richieste where pratica_id=p_pratica and fase=p_fase order by inviata_at desc,registrata_at desc limit 1;
 if not found or not private.followup_dati_stato_valido(r.id,p_pratica_updated_at,p_verificata_at)
  or clock_timestamp()<greatest(i.inviata_at,r.inviata_at)+interval '48 hours' then return false;end if;
 select * into i from public.followup_dati_invii where pratica_id=p_pratica and fase=p_fase for update;
 if i.stato<>'sent' or i.attivita_id is not null then return false;end if;
 insert into public.attivita_operatore(tipo,stato,priorita,pratica_id,external_key,evidenza,fonte,metadati)
 values('followup_dati_'||p_fase,'da_gestire','alta',p_pratica,'followup-dati:'||p_pratica||':'||p_fase,
 'Nessuna risposta dopo il promemoria dati mancanti: verificare la pratica. Non inviare un secondo sollecito automatico.',
 'routine_controllo_k',jsonb_build_object('followup_claim',i.claim,'provider_message_id',i.provider_message_id,'inviata_at',i.inviata_at))
 on conflict do nothing returning id into activity;
 if activity is null then select id into activity from public.attivita_operatore where pratica_id=p_pratica and tipo='followup_dati_'||p_fase;end if;
 update public.followup_dati_invii set attivita_id=activity where claim=i.claim;
 return activity is not null;
end; $$;
revoke all on function private.followup_dati_stato_valido(uuid,timestamptz,timestamptz),public.inizia_invio_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb),public.segnala_followup_dati(uuid,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function private.followup_dati_stato_valido(uuid,timestamptz,timestamptz),public.inizia_invio_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb),public.segnala_followup_dati(uuid,text,timestamptz,timestamptz) to service_role;

-- Keplero può restituire timestamp con precisione al secondo.
create or replace function public.esito_followup_dati(p_claim uuid,p_stato text,p_message_id text default null,p_inviata_at timestamptz default null,p_conferma jsonb default null)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if p_stato is null or p_stato not in ('sent','ambiguous','cancelled') then return false;end if;
 if p_stato='sent' and (nullif(btrim(p_message_id),'') is null or length(p_message_id)>300 or p_inviata_at is null or p_inviata_at>clock_timestamp() or p_conferma is null) then return false;end if;
 update public.followup_dati_invii set stato=p_stato,provider_message_id=case when p_stato='sent' then p_message_id end,
 inviata_at=case when p_stato='sent' then p_inviata_at end,conferma=case when p_stato='sent' then p_conferma end
 where claim=p_claim and (stato='claimed' or (stato='ambiguous' and p_stato='sent'))
 and (p_stato<>'sent' or p_inviata_at>=date_trunc('second',claimed_at));
 return found;
end; $$;

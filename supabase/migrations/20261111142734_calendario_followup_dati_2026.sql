-- Calendario dei soli follow-up, confermato da Norberto l'11/11/2026.
-- Nessuna modifica a chiusure_aziendali, trasporti o altri processi.
-- Non abilita invii, cron, trasporto o cutover.
create table public.followup_dati_chiusure (
 data_inizio date not null,
 data_fine date not null,
 descrizione text not null,
 primary key(data_inizio,data_fine),
 check(data_inizio<=data_fine)
);
alter table public.followup_dati_chiusure enable row level security;
revoke all on public.followup_dati_chiusure from public,anon,authenticated;
grant select,insert,update,delete on public.followup_dati_chiusure to service_role;
insert into public.followup_dati_chiusure(data_inizio,data_fine,descrizione) values
 ('2026-01-01','2026-01-01','Capodanno'),
 ('2026-01-06','2026-01-06','Epifania'),
 ('2026-04-05','2026-04-06','Pasqua e lunedì dell’Angelo'),
 ('2026-04-25','2026-04-25','Liberazione'),
 ('2026-05-01','2026-05-01','Festa del Lavoro'),
 ('2026-06-02','2026-06-02','Festa della Repubblica'),
 ('2026-08-15','2026-08-15','Assunzione'),
 ('2026-11-01','2026-11-01','Ognissanti'),
 ('2026-12-07','2026-12-08','Ponte Immacolata, conferma Norberto 11/11/2026'),
 ('2026-12-24','2026-12-26','Chiusura Natale, conferma Norberto 11/11/2026'),
 ('2026-12-31','2026-12-31','Chiusura 31 dicembre, conferma Norberto 11/11/2026');
update public.followup_dati_config set calendar_confirmed_through='2026-12-31' where id;

-- Fonte atomica del calendario per il server, inclusi eventuali nuovi blocchi
-- aziendali generali. Non restituisce credenziali o dati personali.
create function public.configurazione_followup_dati()
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('enabled',c.enabled,'transportVerified',c.transport_verified,
  'acceptRequestsAfter',c.accept_requests_after,
  'calendar',jsonb_build_object('confirmedThrough',c.calendar_confirmed_through,'closures',
   (select coalesce(jsonb_agg(jsonb_build_object('from',data_inizio,'through',data_fine) order by data_inizio,data_fine),'[]'::jsonb)
    from (select data_inizio,data_fine from public.followup_dati_chiusure
     union select data_inizio,data_fine from public.chiusure_aziendali) closures)))
 from public.followup_dati_config c where c.id;
$$;

-- Guardia comune: claim E inizio invio usano le stesse chiusure e gli stessi
-- confini inclusivi/esclusivi della policy TypeScript in Europe/Rome.
create function private.followup_dati_fascia_aperta(p_now timestamptz)
returns boolean language sql stable security invoker set search_path='' as $$
 with local_time as (select (p_now at time zone 'Europe/Rome')::date d,
  (p_now at time zone 'Europe/Rome')::time t,
  extract(isodow from p_now at time zone 'Europe/Rome') dow)
 select coalesce((select c.calendar_confirmed_through is not null and l.d<=c.calendar_confirmed_through
  and not exists(select 1 from public.followup_dati_chiusure x where l.d between x.data_inizio and x.data_fine)
  and not exists(select 1 from public.chiusure_aziendali x where l.d between x.data_inizio and x.data_fine)
  and ((l.dow between 1 and 4 and ((l.t>=time '09:00' and l.t<time '12:30') or (l.t>=time '14:00' and l.t<time '18:30')))
   or (l.dow=5 and l.t>=time '09:00' and l.t<time '13:30'))
 from public.followup_dati_config c cross join local_time l where c.id),false);
$$;
revoke all on function public.configurazione_followup_dati(),private.followup_dati_fascia_aperta(timestamptz) from public,anon,authenticated;
grant execute on function public.configurazione_followup_dati(),private.followup_dati_fascia_aperta(timestamptz) to service_role;

create or replace function public.claim_followup_dati(p_richiesta uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[])
returns uuid language plpgsql security invoker set search_path='' as $$
declare r public.followup_dati_richieste%rowtype; p public.pratiche%rowtype; cfg public.followup_dati_config%rowtype;
 token uuid; current_time_utc timestamptz:=clock_timestamp();
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
 if not private.followup_dati_fascia_aperta(clock_timestamp()) then return null;end if;
 insert into public.followup_dati_invii(pratica_id,fase,richiesta_id,verificata_at,impronta_verifica,campi)
 values(r.pratica_id,r.fase,r.id,p_verificata_at,p_impronta,p_campi)
 on conflict(pratica_id,fase) do nothing returning claim into token;
 return token;
end; $$;

create or replace function public.inizia_invio_followup_dati(p_claim uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[],p_tentativo jsonb)
returns boolean language plpgsql security invoker set search_path='' as $$
declare i public.followup_dati_invii%rowtype; r public.followup_dati_richieste%rowtype;
 started timestamptz;
begin
 select * into i from public.followup_dati_invii where claim=p_claim;
 if not found or i.stato<>'claimed' or i.tentativo_at is not null then return false;end if;
 if not private.followup_dati_stato_valido(i.richiesta_id,p_pratica_updated_at,p_verificata_at) then return false;end if;
 select * into i from public.followup_dati_invii where claim=p_claim for update;
 if i.stato<>'claimed' or i.tentativo_at is not null then return false;end if;
 select * into r from public.followup_dati_richieste where id=i.richiesta_id;
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
 if not private.followup_dati_fascia_aperta(clock_timestamp()) then return false;end if;
 update public.followup_dati_invii set tentativo_at=clock_timestamp(),tentativo=p_tentativo,
  verificata_at=p_verificata_at,impronta_verifica=p_impronta where claim=p_claim and tentativo_at is null and stato='claimed';
 return found;
end; $$;

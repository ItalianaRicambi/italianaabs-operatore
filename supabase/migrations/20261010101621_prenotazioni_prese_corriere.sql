-- Una prenotazione è riferita a un singolo ritiro; il vecchio stato logistico
-- della pratica non è prova della presa di un nuovo pacco.
create table public.prenotazioni_prese_ricevute (
  id uuid primary key default gen_random_uuid(),
  fonte text not null check (fonte in ('email_gls','messaggio_operatore','cliente')),
  fonte_id text not null,
  ricevuta_at timestamptz not null,
  corriere text not null,
  riferimento text not null,
  data_ritiro date not null,
  testo text not null,
  confermata boolean not null default false,
  operatore text,
  targa text,
  telefono text,
  pratica_id uuid references public.pratiche(id),
  attivita_id uuid references public.attivita_operatore(id),
  esito text not null default 'da_abbinare',
  applicata_at timestamptz,
  criteri jsonb not null default '{}'::jsonb,
  errore text,
  unique (fonte,fonte_id)
);
alter table public.prenotazioni_prese_ricevute enable row level security;
revoke all on public.prenotazioni_prese_ricevute from public,anon,authenticated;
grant select,insert,update on public.prenotazioni_prese_ricevute to service_role;
create index prenotazioni_prese_coda on public.prenotazioni_prese_ricevute(esito,ricevuta_at);

create or replace function public.registra_prenotazione_presa(p_dati jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  d public.prenotazioni_prese_ricevute%rowtype;
  a public.attivita_operatore%rowtype;
  v_ids uuid[]; v_pratica uuid; v_attivita uuid; v_esito text;
  v_fonte text:=p_dati->>'fonte'; v_fonte_id text:=p_dati->>'fonte_id';
  v_riferimento text:=upper(regexp_replace(trim(coalesce(p_dati->>'riferimento','')),'\s+',' ','g'));
  v_targa text:=nullif(upper(regexp_replace(coalesce(p_dati->>'targa',''),'[^A-Za-z0-9]','','g')),'');
  v_telefono text:=nullif(regexp_replace(coalesce(p_dati->>'telefono',''),'[^0-9]','','g'),'');
  v_data date:=(p_dati->>'data_ritiro')::date;
  v_at timestamptz:=coalesce((p_dati->>'ricevuta_at')::timestamptz,now());
  v_confermata boolean:=coalesce((p_dati->>'confermata')::boolean,false);
  v_prima jsonb;
begin
  if v_fonte not in ('email_gls','messaggio_operatore','cliente') or nullif(v_fonte_id,'') is null
    or length(v_fonte_id)>250 or length(coalesce(p_dati->>'testo','')) not between 1 and 30000
    or v_data is null or length(v_riferimento) not between 6 and 80
    or upper(coalesce(p_dati->>'corriere',''))<>'GLS' then
    raise exception 'Prenotazione incompleta: fonte, testo, data, corriere e codice richiesti';
  end if;
  if v_at>now()+interval '5 minutes' then raise exception 'Data ricezione futura non valida'; end if;
  if v_fonte='cliente' then v_confermata:=false; end if;
  if v_fonte='messaggio_operatore' and nullif(p_dati->>'operatore','') is null then
    raise exception 'Operatore richiesto per confermare il proprio messaggio';
  end if;
  if v_fonte='email_gls' and v_confermata and (
    coalesce(p_dati#>>'{verifica_email,dominio}','')<>'gls-italy.com'
    or coalesce(p_dati#>>'{verifica_email,autenticata}','false')<>'true') then
    raise exception 'Conferma GLS priva di verifica del mittente';
  end if;
  v_pratica:=nullif(p_dati->>'pratica_id','')::uuid;
  v_attivita:=nullif(p_dati->>'attivita_id','')::uuid;
  if v_pratica is null and v_attivita is null and v_targa is null and v_telefono is null and v_fonte<>'email_gls' then
    raise exception 'Manca un riferimento per abbinare la presa';
  end if;
  insert into public.prenotazioni_prese_ricevute(fonte,fonte_id,ricevuta_at,corriere,riferimento,data_ritiro,testo,confermata,operatore,targa,telefono,criteri)
  values(v_fonte,v_fonte_id,v_at,'GLS',v_riferimento,v_data,p_dati->>'testo',v_confermata,p_dati->>'operatore',v_targa,v_telefono,jsonb_strip_nulls(jsonb_build_object('pratica_id',v_pratica,'attivita_id',v_attivita,'targa',v_targa,'telefono',v_telefono)))
  on conflict(fonte,fonte_id) do nothing;
  select * into d from public.prenotazioni_prese_ricevute where fonte=v_fonte and fonte_id=v_fonte_id for update;
  if d.riferimento<>v_riferimento or d.data_ritiro<>v_data or d.confermata<>v_confermata then
    raise exception 'Identificativo della fonte riutilizzato con dati diversi';
  end if;
  if d.applicata_at is not null then return jsonb_build_object('ok',true,'duplicato',true,'esito',d.esito,'attivita_id',d.attivita_id); end if;

  select array_agg(x.id order by x.id) into v_ids from public.attivita_operatore x
  join public.pratiche p on p.id=x.pratica_id
  where x.tipo like 'ritiro_%' and x.stato in ('da_gestire','da_collegare','programmata')
    and (v_attivita is null or x.id=v_attivita)
    and (v_pratica is null or x.pratica_id=v_pratica)
    and (v_targa is null or upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g'))=v_targa)
    and (v_telefono is null or right(regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g'),10)=right(v_telefono,10))
    and (v_pratica is not null or v_attivita is not null or v_targa is not null or v_telefono is not null
      or x.riferimento_ritiro=v_riferimento or x.metadati#>>'{prenotazione_rilevata,riferimento}'=v_riferimento)
    and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
    and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
  if coalesce(cardinality(v_ids),0)<>1 then
    v_esito:=case when coalesce(cardinality(v_ids),0)=0 then 'da_abbinare' else 'abbinamento_ambiguo' end;
    update public.prenotazioni_prese_ricevute set esito=v_esito where id=d.id;
    return jsonb_build_object('ok',true,'esito',v_esito,'ricevuta',true,'candidati',coalesce(cardinality(v_ids),0));
  end if;
  select * into a from public.attivita_operatore where id=v_ids[1];
  perform 1 from public.pratiche where id=a.pratica_id for update;
  select * into a from public.attivita_operatore where id=v_ids[1] for update;
  if a.stato not in ('da_gestire','da_collegare','programmata') then raise exception 'Il ritiro è già stato completato o annullato'; end if;
  update public.prenotazioni_prese_ricevute set pratica_id=a.pratica_id,attivita_id=a.id where id=d.id;
  if v_fonte in ('email_gls','cliente') and (v_at<a.richiesta_at-interval '1 day' or v_data<(a.richiesta_at at time zone 'Europe/Rome')::date) then
    update public.prenotazioni_prese_ricevute set esito='messaggio_precedente' where id=d.id;
    return jsonb_build_object('ok',true,'esito','messaggio_precedente','attivita_id',a.id);
  end if;
  if not v_confermata then
    if a.stato<>'programmata' and (a.metadati#>>'{prenotazione_rilevata,ricevuta_at}' is null or v_at>=(a.metadati#>>'{prenotazione_rilevata,ricevuta_at}')::timestamptz) then
      update public.attivita_operatore set metadati=metadati||jsonb_build_object('prenotazione_rilevata',
        jsonb_build_object('riferimento',v_riferimento,'data_ritiro',v_data,'corriere','GLS','testo',p_dati->>'testo','fonte_id',v_fonte_id,'ricevuta_at',v_at)),updated_at=now()
      where id=a.id;
    end if;
    update public.prenotazioni_prese_ricevute set esito='da_confermare' where id=d.id;
    return jsonb_build_object('ok',true,'esito','da_confermare','attivita_id',a.id);
  end if;
  if a.tipo='ritiro_da_classificare' or a.pratica_origine_id is null then v_esito:='ritiro_da_classificare';
  elsif v_fonte='email_gls' and (v_at<a.richiesta_at-interval '1 day'
    or v_data<(a.richiesta_at at time zone 'Europe/Rome')::date) then v_esito:='messaggio_precedente';
  elsif a.metadati->>'ritiro_gia_effettuato_segnalato'='true' then v_esito:='ritiro_effettuato_da_verificare';
  elsif a.stato='programmata' and a.riferimento_ritiro=v_riferimento and a.data_ritiro_prevista=v_data then
    update public.prenotazioni_prese_ricevute set esito='gia_registrata',applicata_at=now() where id=d.id;
    return jsonb_build_object('ok',true,'esito','gia_registrata','duplicato',true,'attivita_id',a.id);
  elsif a.metadati->>'prenotazione_ricevuta_at' is not null and v_at<(a.metadati->>'prenotazione_ricevuta_at')::timestamptz then v_esito:='messaggio_precedente';
  elsif v_fonte='email_gls' and a.metadati->>'prenotazione_protetta_operatore'='true'
    and (a.riferimento_ritiro is distinct from v_riferimento or a.data_ritiro_prevista is distinct from v_data) then v_esito:='modifica_da_verificare';
  end if;
  if v_esito is not null then
    update public.prenotazioni_prese_ricevute set esito=v_esito where id=d.id;
    return jsonb_build_object('ok',true,'esito',v_esito,'attivita_id',a.id);
  end if;
  v_prima:=to_jsonb(a);
  update public.attivita_operatore set stato='programmata',programmata_at=coalesce(programmata_at,now()),
    riferimento_ritiro=v_riferimento,data_ritiro_prevista=v_data,
    presa_in_carico_at=case when v_fonte='messaggio_operatore' then coalesce(presa_in_carico_at,now()) else presa_in_carico_at end,
    operatore=case when v_fonte='messaggio_operatore' then p_dati->>'operatore' else operatore end,
    metadati=(metadati-'prenotazione_rilevata')||jsonb_build_object('prenotazione_confermata',true,'prenotazione_fonte',v_fonte,
      'prenotazione_ricevuta_at',v_at,'prenotazione_protetta_operatore',v_fonte='messaggio_operatore',
      'prenotazione_segnalata_cliente',false,'ritiro_gia_effettuato_segnalato',false),updated_at=now()
  where id=a.id;
  update public.assistenze_rientri set stato=case when stato in ('da_prendere_in_carico','verifica_tecnica','ritiro_da_prenotare','ritiro_prenotato') then 'ritiro_prenotato' else stato end,updated_at=now()
  where id=a.assistenza_rientro_id and chiusa_at is null;
  -- Allinea il riepilogo del ritiro lavorazione senza alterare fatture, ordini
  -- o il ritiro storico della lavorazione quando ora si tratta di un rientro.
  if a.tipo='ritiro_lavorazione' then
    update public.pratiche set stato_logistica='ritiro_programmato',
      ritiro_richiesto_at=a.richiesta_at,ritiro_programmato_at=now() where id=a.pratica_id;
  end if;
  update public.prenotazioni_prese_ricevute set esito='presa_prenotata',applicata_at=now() where id=d.id;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  values(a.pratica_id,'prenotazione_presa_registrata',p_dati->>'testo',v_prima,
    jsonb_build_object('attivita_id',a.id,'prenotazione_id',d.id,'fonte',v_fonte,'riferimento',v_riferimento,'data_ritiro',v_data),
    coalesce(p_dati->>'operatore','Automazione conferme GLS'));
  return jsonb_build_object('ok',true,'esito','presa_prenotata','attivita_id',a.id,'pratica_id',a.pratica_id);
end; $$;
revoke all on function public.registra_prenotazione_presa(jsonb) from public,anon,authenticated;
grant execute on function public.registra_prenotazione_presa(jsonb) to service_role;

create or replace function private.precompila_presa_evento(p_event_id bigint)
returns void language plpgsql security invoker set search_path='' as $$
declare e public.keplero_live_events%rowtype; a uuid; t text; m text[]; v_data date; v_codice text; n integer;
begin
  select * into e from public.keplero_live_events where id=p_event_id;
  if not found or e.pratica_id is null then return; end if;
  t:=coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio','');
  if t!~* '\mGLS\M' or t!~* '(presa|ritiro|corriere|prenotaz)' then return; end if;
  select count(*) into n from regexp_matches(t,'\m([0-9]{1,2})[/.]([0-9]{1,2})[/.]([0-9]{4})\M','g');
  if n<>1 then return; end if;
  m:=regexp_match(t,'\m([0-9]{1,2})[/.]([0-9]{1,2})[/.]([0-9]{4})\M');
  begin v_data:=make_date(m[3]::integer,m[2]::integer,m[1]::integer); exception when others then return; end;
  select count(*) into n from regexp_matches(t,'(?:codice|cod\.?|riferimento)[[:space:]]*(?:[:=-][[:space:]]*)?(?:\([^)]{0,150}\)[[:space:]]*)?((?:[A-Z]{1,3}[0-9]?[[:space:]]*[-/]?[[:space:]]*)?[0-9]{6,15})\M','gi');
  if n<>1 then return; end if;
  m:=regexp_match(t,'(?:codice|cod\.?|riferimento)[[:space:]]*(?:[:=-][[:space:]]*)?(?:\([^)]{0,150}\)[[:space:]]*)?((?:[A-Z]{1,3}[0-9]?[[:space:]]*[-/]?[[:space:]]*)?[0-9]{6,15})\M','i');
  v_codice:=m[1];
  perform public.registra_prenotazione_presa(jsonb_build_object('fonte','cliente','fonte_id','evento:'||e.id,
    'corriere','GLS','riferimento',v_codice,'data_ritiro',v_data,'testo',t,'pratica_id',e.pratica_id,'ricevuta_at',e.created_at));
end; $$;

create or replace function private.trg_precompila_presa()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform private.precompila_presa_evento(new.id);
  return new;
exception when others then
  insert into private.keplero_event_processing(event_id,pratica_id,versione_regole,stato,decisione,errore)
  values(new.id,new.pratica_id,'prenotazioni-prese-v1','errore','{}'::jsonb,sqlerrm)
  on conflict(event_id) do update set stato='errore',errore='prenotazioni-prese-v1: '||excluded.errore,updated_at=now();
  return new;
end; $$;
revoke all on function private.trg_precompila_presa() from public,anon,authenticated;
revoke all on function private.precompila_presa_evento(bigint) from public,anon,authenticated;
create trigger zzz_precompila_presa after insert or update of pratica_id,payload on public.keplero_live_events
for each row execute function private.trg_precompila_presa();
CREATE OR REPLACE FUNCTION private.rileva_rientro_evento(p_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype; a public.attivita_operatore%rowtype;
 c public.assistenze_rientri%rowtype; t text; v_origine uuid; v_num integer; v_problema boolean; v_ritiro boolean;
 v_tipo text; v_servizio text; v_nuova boolean:=false; v_gia_ritirato boolean; v_prenotato_segnalato boolean;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id for update;
 if not found or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then return '{}'::jsonb; end if;
 if nullif(e.payload->>'targa','') is not null and upper(regexp_replace(e.payload->>'targa','[^A-Za-z0-9]','','g'))<>upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) then return '{}'::jsonb; end if;
 t:=lower(translate(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),'àèéìòù’','aeeiou'''));
 if t='' then return '{}'::jsonb; end if;
 v_origine:=p.pratica_origine_id;
 if v_origine is null and (p.stato_commerciale::text='ordine_acquisito' or p.stato_fatturazione::text='fatturato') then v_origine:=p.id; end if;
 if v_origine is null and nullif(p.targa,'') is not null then
  select count(*),min(x.id::text)::uuid into v_num,v_origine from public.pratiche x
  where x.id<>p.id and upper(regexp_replace(coalesce(x.targa,''),'[^A-Za-z0-9]','','g'))=upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))
   and (x.stato_commerciale::text='ordine_acquisito' or x.stato_fatturazione::text='fatturato')
   and (x.cliente_id=p.cliente_id or (nullif(p.telefono,'') is not null and regexp_replace(x.telefono,'[^0-9]','','g')=regexp_replace(p.telefono,'[^0-9]','','g')))
   and coalesce(x.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
   and coalesce(x.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
  if v_num<>1 then v_origine:=null; end if;
 end if;
 select * into c from public.assistenze_rientri where pratica_id=p.id and chiusa_at is null for update;
 -- Il problema deve riguardare un intervento/prodotto precedente, oppure essere una richiesta esplicita di garanzia.
 v_problema:= t~'(in garanzia|rientro.{0,25}garanzia|dopo.{0,35}(vostra riparazione|vostro intervento)|(?:ricambio|pezzo|dispositivo|centralina|modulo).{0,40}(ricevuto da voi|fornito da voi|fornito).{0,70}(difett|non funzion|errato))'
  or (((p.stato_fatturazione::text='fatturato' and coalesce(p.data_fattura,p.ordine_acquisito_at,p.created_at)<=e.created_at) or p.tipo_assistenza::text in ('post_riparazione','garanzia') or e.payload->>'tipo_assistenza' in ('post_riparazione','post_scambio','post_installazione'))
   and t~'(non.{0,30}(risolto|funziona)|stess[oa].{0,20}(difetto|problema)|problema.{0,30}(persiste|rimane)|dopo.{0,25}(montaggio|riparazione|sostituzione)|(?:pezzo|modulo|pompa).{0,25}(difettoso|sbagliato)|(?:ricevuto|montato|installato).{0,100}(errore|spia|difett)|rivoglio.{0,35}(mio|originale))');
 v_ritiro:=(t~'(pacc(o|hetto).{0,70}(pront|ritir)|pront[ioa].{0,45}(ritir|restitu|rientr)|(restitu|rientr).{0,70}(pompa|abs|centralina|prodotto|pezzo)|(?:organizz|prenot|programmar).{0,50}(ritiro|corriere)|(?:quando passa|quando passera|non e ancora passato).{0,30}corriere)' or private.richiesta_restituzione_vecchio(t))
  and t!~'(non.{0,15}(pronto|pronta)|non.{0,15}(ritirare|prenotare)|se.{0,30}(pacco|ritiro)|ipotetico)';
 if v_problema and c.id is null then
  -- Non rielabora un vecchio messaggio appartenente a un episodio già chiuso.
  if exists(select 1 from public.assistenze_rientri where pratica_id=p.id and chiusa_at is not null and chiusa_at>=e.created_at) then return '{}'::jsonb; end if;
  insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evento_id,evidenza,aperta_at)
  values(p.id,v_origine,e.id,coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),e.created_at)
  returning * into c;
  v_nuova:=true;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  values(p.id,'apertura_assistenza_rientro','Segnalazione post intervento: verifica urgente. Ammissibilità della garanzia da valutare dal tecnico.',
   '{}'::jsonb,to_jsonb(c),'routine_controllo_k');
 end if;
 v_gia_ritirato:=t~'(gia.{0,30}(ritirat|fatto ritir)|ritirat.{0,20}gia|avete.{0,25}ritirat)';
 v_prenotato_segnalato:=t~'(gls|corriere).{0,60}(codice|numero|prenotazione).{0,40}[0-9]{5,}';
 if v_gia_ritirato or v_prenotato_segnalato then
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',v_gia_ritirato,'prenotazione_segnalata_cliente',v_prenotato_segnalato,'evidenza_ritiro_effettuato',t,'evento_ritiro_effettuato',e.id)
   where pratica_id=p.id and tipo like 'ritiro_%' and stato in ('da_gestire','da_collegare','programmata')
    and coalesce((metadati->>'evento_prenotazione_verificato')::bigint,0)<e.id;
  if v_gia_ritirato then return jsonb_build_object('assistenza_id',c.id,'esito','ritiro_gia_effettuato_da_verificare'); end if;
 end if;
 if not v_ritiro then return jsonb_build_object('assistenza_id',c.id,'aperta',v_nuova); end if;
 select * into a from public.attivita_operatore where pratica_id=p.id and tipo like 'ritiro_%'
  and stato in ('da_gestire','da_collegare','programmata') for update;
 if not found and exists(select 1 from public.attivita_operatore where pratica_id=p.id and tipo like 'ritiro_%'
  and (evento_keplero_id=e.id or coalesce(completata_at,annullata_at)>=e.created_at)) then return jsonb_build_object('esito','episodio_gia_gestito'); end if;
 select servizio into v_servizio from public.v_scelte_cliente where pratica_id=coalesce(v_origine,p.id) and stato='confermata';
 if c.id is not null then v_tipo:='ritiro_verifica_garanzia';
 elsif t~'(reso|rientro|restitu).{0,50}(rimborso|recesso)|rimborso.{0,50}(reso|rientro)' then v_tipo:='ritiro_altro_reso';
 elsif private.richiesta_restituzione_vecchio(t) or t~'(vecchi[oa].{0,40}(restitu|ritir|scambio)|(?:restitu|ritir).{0,40}vecchi[oa])' then v_tipo:='ritiro_programma_scambio';
 elsif v_servizio in ('RI','RE') and not exists(select 1 from public.attivita_operatore where pratica_id=p.id and tipo='ritiro_lavorazione' and completata_at<e.created_at) then v_tipo:='ritiro_lavorazione';
 else v_tipo:='ritiro_da_classificare'; end if;
 if a.id is null then
  insert into public.attivita_operatore(tipo,stato,priorita,pratica_id,pratica_origine_id,assistenza_rientro_id,
   evento_keplero_id,external_key,evidenza,fonte,metadati,richiesta_at)
  values(v_tipo,case when v_origine is null then 'da_collegare' else 'da_gestire' end,
   case when c.id is null then 'alta' else 'urgente' end,p.id,v_origine,c.id,e.id,e.external_key,
   coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),
   'keplero_live',jsonb_build_object('regola','ritiro_contestuale_v2','scelta_servizio',v_servizio),e.created_at) returning * into a;
 else
  -- La prima data, l'evidenza originale e la prenotazione non cambiano con i messaggi successivi.
  update public.attivita_operatore set
   tipo=case when blocco_classificazione then tipo when c.id is not null then 'ritiro_verifica_garanzia'
    when tipo='ritiro_da_classificare' or metadati->>'regola'='rientro_prodotto_v1' then v_tipo else tipo end,
   priorita=case when c.id is not null then 'urgente' else priorita end,
   assistenza_rientro_id=coalesce(assistenza_rientro_id,c.id),pratica_origine_id=coalesce(pratica_origine_id,v_origine),
   stato=case when stato='da_collegare' and v_origine is not null then 'da_gestire' else stato end,
   metadati=metadati||jsonb_build_object('ultimo_evento_ritiro',e.id,'ultima_evidenza',t),updated_at=now()
  where id=a.id returning * into a;
 end if;
 if v_prenotato_segnalato then
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',v_gia_ritirato,'prenotazione_segnalata_cliente',v_prenotato_segnalato,'evidenza_ritiro_effettuato',t,'evento_ritiro_effettuato',e.id)
   where id=a.id and coalesce((metadati->>'evento_prenotazione_verificato')::bigint,0)<e.id;
 end if;
 if c.id is not null and c.stato in ('da_prendere_in_carico','verifica_tecnica') and c.presa_in_carico_at is not null then
  update public.assistenze_rientri set stato='ritiro_da_prenotare',updated_at=now() where id=c.id;
 end if;
 return jsonb_build_object('assistenza_id',c.id,'attivita_id',a.id,'tipo',a.tipo,'stato',a.stato,
  'domanda',case when a.tipo='ritiro_da_classificare' then 'Il pacco contiene il vecchio dispositivo da restituire per lo scambio oppure quello ricevuto da noi che presenta il problema?' end);
end; $function$;


-- Un messaggio può arrivare prima che K abbia creato l'attività da abbinare.
create or replace function private.riprova_prenotazioni_prese()
returns integer language plpgsql security invoker set search_path='' as $$
declare d public.prenotazioni_prese_ricevute%rowtype; n integer:=0;
begin
  for d in select * from public.prenotazioni_prese_ricevute
    where fonte='email_gls' and esito in ('da_abbinare','abbinamento_ambiguo','ritiro_da_classificare') and applicata_at is null
      and ricevuta_at>now()-interval '30 days'
    order by ricevuta_at,id limit 100 for update skip locked
  loop
    begin
      perform public.registra_prenotazione_presa(d.criteri||jsonb_build_object(
        'fonte',d.fonte,'fonte_id',d.fonte_id,'corriere',d.corriere,'riferimento',d.riferimento,
        'data_ritiro',d.data_ritiro,'testo',d.testo,'confermata',d.confermata,'operatore',d.operatore,
        'ricevuta_at',d.ricevuta_at,'verifica_email',jsonb_build_object('dominio','gls-italy.com','autenticata',d.confermata)));
      update public.prenotazioni_prese_ricevute set errore=null where id=d.id;
      n:=n+1;
    exception when others then
      update public.prenotazioni_prese_ricevute set errore=sqlerrm where id=d.id;
    end;
  end loop;
  return n;
end; $$;
revoke all on function private.riprova_prenotazioni_prese() from public,anon,authenticated;
select cron.schedule('riprova-prenotazioni-prese','*/5 * * * *','select private.riprova_prenotazioni_prese();');
CREATE OR REPLACE FUNCTION public.gestisci_ritiro_assistenza(p_pratica_id uuid, p_attivita_id uuid DEFAULT NULL::uuid, p_assistenza_id uuid DEFAULT NULL::uuid, p_azione text DEFAULT NULL::text, p_tipo text DEFAULT NULL::text, p_nota text DEFAULT NULL::text, p_riferimento text DEFAULT NULL::text, p_data_ritiro date DEFAULT NULL::date, p_operatore text DEFAULT NULL::text, p_origine_numero bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare a public.attivita_operatore%rowtype; c public.assistenze_rientri%rowtype; v_prima jsonb; v_origine uuid;
begin
 if nullif(trim(p_operatore),'') is null then raise exception 'Operatore richiesto'; end if;
 perform 1 from public.pratiche where id=p_pratica_id for update;
 if not found then raise exception 'Pratica non trovata'; end if;
 if p_attivita_id is not null then
  select * into a from public.attivita_operatore where id=p_attivita_id and pratica_id=p_pratica_id for update;
  if not found or a.tipo not like 'ritiro_%' or a.stato in ('annullata','completata') then raise exception 'Ritiro non attivo o estraneo alla pratica'; end if;
  v_prima:=to_jsonb(a); p_assistenza_id:=coalesce(p_assistenza_id,a.assistenza_rientro_id);
 end if;
 if p_assistenza_id is not null then
  select * into c from public.assistenze_rientri where id=p_assistenza_id and pratica_id=p_pratica_id for update;
  if not found or c.chiusa_at is not null then raise exception 'Assistenza non attiva o estranea alla pratica'; end if;
  v_prima:=coalesce(v_prima,to_jsonb(c));
 end if;
 if a.id is null and c.id is null then raise exception 'Selezionare ritiro o assistenza'; end if;
 if p_origine_numero is not null then
  if (a.id is null and c.id is null) or nullif(trim(p_nota),'') is null then raise exception 'Assistenza o ritiro e motivazione del collegamento richiesti'; end if;
  select x.id into v_origine from public.pratiche x join public.pratiche y on y.id=p_pratica_id
  where x.numero_pratica=p_origine_numero and (x.stato_commerciale::text='ordine_acquisito' or x.stato_fatturazione::text='fatturato')
   and (nullif(y.targa,'') is null or upper(x.targa)=upper(y.targa));
  if v_origine is null then raise exception 'Ordine non trovato o targa incompatibile'; end if;
  update public.attivita_operatore set pratica_origine_id=v_origine,stato=case when stato='da_collegare' then 'da_gestire' else stato end where id=a.id;
  a.pratica_origine_id:=v_origine;
  update public.assistenze_rientri set pratica_origine_id=v_origine where id=c.id;
 end if;
 if p_azione='collega_origine' then
  if p_origine_numero is null then raise exception 'Numero ordine di origine richiesto'; end if;
 elsif p_azione='prendi_in_carico' then
  update public.attivita_operatore set presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,updated_at=now() where id=a.id;
  update public.assistenze_rientri set presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,
   stato=case when stato='da_prendere_in_carico' then case when a.id is null then 'verifica_tecnica' else 'ritiro_da_prenotare' end else stato end,updated_at=now() where id=c.id;
 elsif p_azione='classifica' then
  if a.id is null or p_tipo not in ('ritiro_lavorazione','ritiro_programma_scambio','ritiro_verifica_garanzia','ritiro_da_classificare','ritiro_altro_reso') or nullif(trim(p_nota),'') is null then raise exception 'Tipo e motivazione richiesti'; end if;
  if p_tipo='ritiro_verifica_garanzia' and c.id is null then
   insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evidenza,aperta_at,operatore,presa_in_carico_at,stato)
   values(p_pratica_id,a.pratica_origine_id,p_nota,a.richiesta_at,p_operatore,now(),'ritiro_da_prenotare') returning * into c;
  end if;
  update public.attivita_operatore set tipo=p_tipo,blocco_classificazione=true,nota=p_nota,operatore=p_operatore,
   priorita=case when p_tipo='ritiro_verifica_garanzia' then 'urgente' else priorita end,assistenza_rientro_id=coalesce(assistenza_rientro_id,c.id),updated_at=now() where id=a.id;
 elsif p_azione='verifica_prenotazione' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Registrare la verifica effettuata'; end if;
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',false,'verifica_prenotazione',p_nota,'evento_prenotazione_verificato',coalesce((metadati->>'evento_ritiro_effettuato')::bigint,0)),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
 elsif p_azione='programma' then
  if a.metadati->>'ritiro_gia_effettuato_segnalato'='true' then raise exception 'Il cliente segnala un ritiro già effettuato: verificarlo prima di prenotare nuovamente'; end if;
  if a.id is null or a.pratica_origine_id is null or a.tipo='ritiro_da_classificare' then raise exception 'Classificare e collegare prima il ritiro'; end if;
  if nullif(trim(p_riferimento),'') is null or p_data_ritiro is null then raise exception 'Riferimento prenotazione e data richiesti'; end if;
  update public.attivita_operatore set stato='programmata',programmata_at=coalesce(programmata_at,now()),
   riferimento_ritiro=p_riferimento,data_ritiro_prevista=p_data_ritiro,metadati=(metadati-'prenotazione_rilevata')||jsonb_build_object('prenotazione_fonte','messaggio_operatore','prenotazione_confermata',true,'prenotazione_protetta_operatore',true,'prenotazione_ricevuta_at',now()),presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,nota=p_nota,updated_at=now() where id=a.id;
  update public.assistenze_rientri set stato=case when stato in ('da_prendere_in_carico','verifica_tecnica','ritiro_da_prenotare','ritiro_prenotato') then 'ritiro_prenotato' else stato end,presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,updated_at=now() where id=c.id;
 elsif p_azione='completa' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Registrare la prova del ritiro effettuato'; end if;
  update public.attivita_operatore set stato='completata',completata_at=now(),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
  -- Ritiro effettuato non equivale a ricezione in laboratorio o risoluzione del guasto.
 elsif p_azione='annulla' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Motivazione richiesta'; end if;
  update public.attivita_operatore set stato='annullata',annullata_at=now(),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
 elsif p_azione in ('verifica_tecnica','ritiro_da_prenotare','ricevuto','in_lavorazione','esito_comunicato','chiudi') then
  if c.id is null or c.presa_in_carico_at is null then raise exception 'Prendere prima in carico l’assistenza'; end if;
  if p_azione='chiudi' and exists(select 1 from public.attivita_operatore where assistenza_rientro_id=c.id and stato in ('da_gestire','da_collegare','programmata')) then raise exception 'Completare o annullare prima il ritiro ancora aperto'; end if;
  if p_azione='chiudi' and (c.stato<>'esito_comunicato' or nullif(trim(p_nota),'') is null) then raise exception 'Comunicare e registrare prima l’esito tecnico'; end if;
  if p_azione='esito_comunicato' and nullif(trim(p_nota),'') is null then raise exception 'Esito tecnico obbligatorio'; end if;
  update public.assistenze_rientri set stato=case when p_azione='chiudi' then 'chiusa' else p_azione end,
   nota=coalesce(nullif(trim(p_nota),''),nota),esito_tecnico=case when p_azione='esito_comunicato' then p_nota else esito_tecnico end,
   chiusa_at=case when p_azione='chiudi' then now() else null end,operatore=p_operatore,updated_at=now() where id=c.id;
 else raise exception 'Azione non riconosciuta'; end if;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p_pratica_id,'ritiro_assistenza_'||p_azione,p_nota,v_prima,
  jsonb_build_object('attivita',(select to_jsonb(x) from public.attivita_operatore x where id=a.id),
   'assistenza',(select to_jsonb(x) from public.assistenze_rientri x where id=c.id)),p_operatore);
 return jsonb_build_object('ok',true,'azione',p_azione);
end; $function$;

create or replace function public.conferma_abbinamento_presa(p_id uuid,p_attivita_id uuid,p_operatore text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.prenotazioni_prese_ricevute%rowtype; r jsonb;
begin
 if nullif(trim(p_operatore),'') is null then raise exception 'Operatore richiesto'; end if;
 select * into d from public.prenotazioni_prese_ricevute where id=p_id for update;
 if not found or d.fonte<>'email_gls' then raise exception 'Conferma email non trovata'; end if;
 if d.applicata_at is not null then return jsonb_build_object('ok',true,'esito','gia_registrata'); end if;
 r:=public.registra_prenotazione_presa(jsonb_build_object('fonte','messaggio_operatore',
   'fonte_id','verifica-email:'||d.id||':'||p_attivita_id,'corriere',d.corriere,
   'riferimento',d.riferimento,'data_ritiro',d.data_ritiro,'testo',d.testo,
   'confermata',true,'operatore',p_operatore,'attivita_id',p_attivita_id));
 if r->>'esito' in ('presa_prenotata','gia_registrata') then
   update public.prenotazioni_prese_ricevute set esito='verificata_operatore',applicata_at=now(),
    attivita_id=p_attivita_id,pratica_id=(select pratica_id from public.attivita_operatore where id=p_attivita_id),operatore=p_operatore where id=d.id;
 end if;
 return r;
end; $$;
revoke all on function public.conferma_abbinamento_presa(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.conferma_abbinamento_presa(uuid,uuid,text) to service_role;
notify pgrst, 'reload schema';

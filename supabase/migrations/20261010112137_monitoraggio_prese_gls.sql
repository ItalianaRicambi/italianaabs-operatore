-- Esiti verificati del portale/API GLS. La lettura programmata del portale
-- non è simulata: finché manca il canale API, ogni controllo ha la sua data.
create table public.esiti_prese_gls (
 id uuid primary key default gen_random_uuid(),
 fonte text not null check (fonte in ('portale_gls','api_gls')),
 fonte_id text not null unique,
 contratto text not null, riferimento text not null, data_ritiro date not null,
 mittente text not null, destinatario text not null, destinazione text not null,
 numero_spedizione text, eventi jsonb not null, testo text not null,
 stato text not null check (stato in ('prenotata','effettuata','non_effettuata','annullata','da_verificare')),
 motivo text, evento_at timestamptz, ritirato_at timestamptz,
 verificata_at timestamptz not null, ricevuta_at timestamptz not null default now(),
 esito_abbinamento text not null default 'da_abbinare',
 pratica_id uuid references public.pratiche(id),
 attivita_id uuid references public.attivita_operatore(id), operatore text
);
alter table public.esiti_prese_gls enable row level security;
revoke all on public.esiti_prese_gls from public,anon,authenticated;
grant select,insert,update on public.esiti_prese_gls to service_role;
create index esiti_prese_gls_codice on public.esiti_prese_gls(contratto,riferimento,verificata_at desc,ricevuta_at desc);
create index esiti_prese_gls_pratica on public.esiti_prese_gls(pratica_id);
create index esiti_prese_gls_attivita on public.esiti_prese_gls(attivita_id);

create function private.gls_normalizza(t text) returns text
language sql immutable security invoker set search_path='' as $$
 select trim(regexp_replace(lower(translate(coalesce(t,''),'àèéìòù','aeeiou')),'[^a-z0-9]+',' ','g'));
$$;
revoke all on function private.gls_normalizza(text) from public,anon,authenticated;
grant execute on function private.gls_normalizza(text) to service_role;

create function public.registra_esito_presa_gls(p_dati jsonb,p_attivita_id uuid default null,p_operatore text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 v_id uuid; v_ids uuid[]; a public.attivita_operatore%rowtype; p public.pratiche%rowtype;
 v_ref text:=upper(regexp_replace(coalesce(p_dati->>'riferimento',''),'[^A-Za-z0-9]','','g'));
 v_check timestamptz:=(p_dati->>'verificata_at')::timestamptz;
 v_data date:=(p_dati->>'data_ritiro')::date;
 v_stato text:='da_verificare'; v_motivo text; v_evento timestamptz; v_ritirato timestamptz;
 v_dest text; v_esito text; v_nome text; v_prima jsonb; v_gls jsonb; v_latest jsonb;
begin
 if coalesce(p_dati->>'fonte','') not in ('portale_gls','api_gls')
  or length(coalesce(p_dati->>'fonte_id','')) not between 1 and 250
  or coalesce(p_dati->>'contratto','')!~'^[0-9]{1,15}$'
  or v_ref!~'^[A-Z][A-Z0-9][0-9]{6,15}$' or v_data is null or v_check is null
  or v_check>now()+interval '5 minutes'
  or length(coalesce(p_dati->>'mittente','')) not between 1 and 1000
  or length(coalesce(p_dati->>'destinatario','')) not between 1 and 1000
  or length(coalesce(p_dati->>'testo','')) not between 1 and 100000
  or jsonb_typeof(p_dati->'eventi') is distinct from 'array'
 then raise exception 'Esito GLS incompleto o non verificato'; end if;
 if jsonb_array_length(p_dati->'eventi') not between 1 and 500 then raise exception 'Storico GLS mancante o troppo lungo'; end if;
 if exists(select 1 from jsonb_array_elements(p_dati->'eventi') e where nullif(e->>'stato','') is null
  or nullif(e->>'at','') is null or (e->>'at')::timestamptz>v_check+interval '5 minutes') then
  raise exception 'Evento GLS incompleto o futuro'; end if;
 if p_attivita_id is not null and nullif(trim(p_operatore),'') is null then raise exception 'Abbinamento manuale senza operatore'; end if;

 -- Lo storico può diventare quello della spedizione: cercare la prova del
 -- RITIRO, non la consegna successiva né la sola creazione della spedizione.
 select max((e->>'at')::timestamptz) into v_ritirato from jsonb_array_elements(p_dati->'eventi') e
 where private.gls_normalizza(e->>'stato')='ritiro effettuato';
 select e into v_latest from jsonb_array_elements(p_dati->'eventi') e
 where private.gls_normalizza(e->>'stato')~'(ritiro|merce non presente|cliente assente)'
 order by (e->>'at')::timestamptz desc,e::text limit 1;
 v_motivo:=v_latest->>'stato'; v_evento:=(v_latest->>'at')::timestamptz;
 if v_ritirato is not null then v_stato:='effettuata';
 elsif private.gls_normalizza(v_motivo)='ritiro annullato' then v_stato:='annullata';
 elsif private.gls_normalizza(v_motivo)~'(merce non presente|cliente assente|ritiro non effettuato)' then
  v_stato:=case when v_data>(v_check at time zone 'Europe/Rome')::date
   and private.gls_normalizza(v_motivo)~'(previsto|riprogramm|giorno lavorativo successivo)'
   then 'prenotata' else 'non_effettuata' end;
 elsif private.gls_normalizza(v_motivo) in ('ritiro inserito','ritiro preso in carico')
  and v_data>=(v_check at time zone 'Europe/Rome')::date then v_stato:='prenotata'; end if;
 v_nome:=private.gls_normalizza(p_dati->>'destinatario');
 v_dest:=case when v_nome~'\malb\M' and v_nome~'meccatronica' then 'ALB Meccatronica'
  when v_nome~'\mjudmax\M' then 'Judmax'
  when v_nome~'monika' and v_nome~'bednarska' then 'Monika Bednarska'
  when v_nome~'(italiana ricambi|italiana abs|italianaabs|italiana electronics)' then 'Italiana Ricambi'
  else 'Destinazione da verificare' end;
 insert into public.esiti_prese_gls(fonte,fonte_id,contratto,riferimento,data_ritiro,mittente,destinatario,destinazione,
  numero_spedizione,eventi,testo,stato,motivo,evento_at,ritirato_at,verificata_at)
 values(p_dati->>'fonte',p_dati->>'fonte_id',p_dati->>'contratto',v_ref,v_data,p_dati->>'mittente',p_dati->>'destinatario',v_dest,
  nullif(p_dati->>'numero_spedizione',''),p_dati->'eventi',p_dati->>'testo',v_stato,v_motivo,v_evento,v_ritirato,v_check)
 on conflict(fonte_id) do nothing;
 select id into v_id from public.esiti_prese_gls where fonte_id=p_dati->>'fonte_id' for update;
 if p_attivita_id is not null and exists(select 1 from public.esiti_prese_gls where id=v_id
  and esito_abbinamento='abbinata' and attivita_id is distinct from p_attivita_id) then
  raise exception 'Esito già abbinato a un altro ritiro'; end if;
 if exists(select 1 from public.esiti_prese_gls e where e.id=v_id and (e.riferimento<>v_ref or e.contratto<>p_dati->>'contratto'
  or e.data_ritiro<>v_data or e.verificata_at<>v_check or e.eventi<>p_dati->'eventi' or e.mittente<>p_dati->>'mittente'
  or e.destinatario<>p_dati->>'destinatario' or e.testo<>p_dati->>'testo')) then raise exception 'Fonte GLS riutilizzata con dati diversi'; end if;
 if exists(select 1 from public.esiti_prese_gls e where e.contratto=p_dati->>'contratto' and e.riferimento=v_ref
  and e.verificata_at>v_check) then v_esito:='controllo_precedente'; end if;
 if v_esito is null then
  select array_agg(x.id order by x.id) into v_ids from public.attivita_operatore x
  join public.pratiche pp on pp.id=x.pratica_id
  where x.tipo like 'ritiro_%'
   and (case when p_attivita_id is null then upper(regexp_replace(coalesce(x.riferimento_ritiro,''),'[^A-Za-z0-9]','','g'))=v_ref
    else x.id=p_attivita_id end)
   and coalesce(pp.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
   and coalesce(pp.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
  if coalesce(cardinality(v_ids),0)<>1 then v_esito:=case when coalesce(cardinality(v_ids),0)=0 then 'da_abbinare' else 'abbinamento_ambiguo' end;
  else
   select * into a from public.attivita_operatore where id=v_ids[1];
   perform 1 from public.pratiche where id=a.pratica_id for update;
   select * into a from public.attivita_operatore where id=v_ids[1] for update;
   select * into p from public.pratiche where id=a.pratica_id;
   v_nome:=private.gls_normalizza(p.nome_cliente);
   if p_attivita_id is null and (length(v_nome)<5 or exists(select 1 from regexp_split_to_table(v_nome,' ') parola
     where length(parola)>2 and parola not in ('srl','snc','sas','srls','della','del','dei')
     and position(parola in private.gls_normalizza(p_dati->>'mittente'))=0)) then v_esito:='mittente_da_verificare';
   elsif v_dest='Destinazione da verificare' and p_attivita_id is null then v_esito:='destinazione_da_verificare';
   elsif v_data<(a.richiesta_at at time zone 'Europe/Rome')::date
     or (v_ritirato is not null and v_ritirato<a.richiesta_at-interval '1 day') then v_esito:='episodio_precedente';
   elsif a.tipo='ritiro_da_classificare' or a.pratica_origine_id is null then v_esito:='ritiro_da_classificare';
   elsif a.stato='annullata' then v_esito:='ritiro_chiuso_operatore';
   elsif a.stato='completata' and v_stato<>'effettuata' then v_esito:='ritiro_chiuso_operatore';
   elsif p_attivita_id is null and a.data_ritiro_prevista is distinct from v_data then v_esito:='data_da_verificare';
   elsif a.metadati#>>'{gls,verificata_at}' is not null and (a.metadati#>>'{gls,verificata_at}')::timestamptz>v_check then v_esito:='controllo_precedente';
   else
    -- Un nuovo codice scelto a mano richiede la conferma di questa precisa
    -- prenotazione; l'automatismo non sceglie in base al solo laboratorio.
    if p_attivita_id is not null and a.stato<>'completata' and
     (upper(regexp_replace(coalesce(a.riferimento_ritiro,''),'[^A-Za-z0-9]','','g')) is distinct from v_ref or a.data_ritiro_prevista is distinct from v_data) then
     v_latest:=public.registra_prenotazione_presa(jsonb_build_object('fonte','messaggio_operatore','fonte_id','gls-abbinamento:'||v_id||':'||a.id,
      'corriere','GLS','riferimento',substring(v_ref,1,2)||' '||substring(v_ref,3),'data_ritiro',v_data,'testo',p_dati->>'testo',
      'confermata',true,'operatore',p_operatore,'pratica_id',a.pratica_id,'attivita_id',a.id));
     if v_latest->>'esito' not in ('presa_prenotata','gia_registrata') then v_esito:='prenotazione_da_verificare'; end if;
     select * into a from public.attivita_operatore where id=a.id;
    end if;
    if v_esito is null then
     v_prima:=to_jsonb(a);
     v_gls:=jsonb_build_object('id',v_id,'contratto',p_dati->>'contratto','stato',v_stato,'motivo',v_motivo,'evento_at',v_evento,'ritirato_at',v_ritirato,
      'verificata_at',v_check,'destinazione',v_dest,'destinatario',p_dati->>'destinatario','numero_spedizione',p_dati->>'numero_spedizione');
     if a.metadati->'gls' is distinct from v_gls then
      update public.attivita_operatore set metadati=metadati||jsonb_build_object('gls',v_gls),
       stato=case when v_stato='effettuata' then 'completata' else stato end,
       completata_at=case when v_stato='effettuata' then coalesce(completata_at,v_ritirato) else completata_at end,updated_at=now() where id=a.id;
      if v_stato='effettuata' and a.stato<>'completata' and a.tipo='ritiro_lavorazione' then
       update public.pratiche set stato_logistica='ritirato',ritirato_at=v_ritirato where id=a.pratica_id;
      end if;
      -- Il ritiro fisico NON prova ricezione o chiusura della garanzia/scambio.
      insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
       values(a.pratica_id,'esito_presa_gls_registrato',v_motivo,v_prima,jsonb_build_object('attivita_id',a.id,'gls',v_gls),coalesce(p_operatore,'Monitoraggio GLS'));
     end if;
     v_esito:='abbinata';
    end if;
   end if;
   update public.esiti_prese_gls set pratica_id=a.pratica_id,attivita_id=a.id where id=v_id;
  end if;
 end if;
 update public.esiti_prese_gls set esito_abbinamento=v_esito,operatore=coalesce(p_operatore,operatore) where id=v_id;
 return jsonb_build_object('ok',true,'id',v_id,'stato',v_stato,'esito',v_esito,'pratica_id',a.pratica_id);
end; $$;
revoke all on function public.registra_esito_presa_gls(jsonb,uuid,text) from public,anon,authenticated;
grant execute on function public.registra_esito_presa_gls(jsonb,uuid,text) to service_role;

create view public.v_esiti_prese_gls_correnti with (security_invoker=true) as
 select distinct on(e.contratto,e.riferimento) e.*,p.numero_pratica,p.targa,p.nome_cliente,a.tipo as tipo_ritiro
 from public.esiti_prese_gls e left join public.pratiche p on p.id=e.pratica_id left join public.attivita_operatore a on a.id=e.attivita_id
 order by e.contratto,e.riferimento,e.verificata_at desc,e.ricevuta_at desc,e.id;
revoke all on public.v_esiti_prese_gls_correnti from public,anon,authenticated;
grant select on public.v_esiti_prese_gls_correnti to service_role;

-- Una nuova prenotazione non eredita l'esito del vecchio codice della presa.
do $$ declare d text; begin
 d:=pg_get_functiondef('public.registra_prenotazione_presa(jsonb)'::regprocedure);
 if position('metadati=(metadati-''prenotazione_rilevata'')' in d)=0 then raise exception 'Funzione prenotazione modificata: verificare prima di applicare'; end if;
 execute replace(d,'metadati=(metadati-''prenotazione_rilevata'')','metadati=(metadati-''prenotazione_rilevata''-''gls'')');
 d:=pg_get_functiondef('public.gestisci_ritiro_assistenza(uuid,uuid,uuid,text,text,text,text,date,text,bigint)'::regprocedure);
 if position('metadati=(metadati-''prenotazione_rilevata'')' in d)=0 then raise exception 'Funzione ritiro modificata: verificare prima di applicare'; end if;
 execute replace(d,'metadati=(metadati-''prenotazione_rilevata'')','metadati=(metadati-''prenotazione_rilevata''-''gls'')');
end $$;
notify pgrst,'reload schema';

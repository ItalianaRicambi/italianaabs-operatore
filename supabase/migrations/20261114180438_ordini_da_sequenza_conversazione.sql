-- Contextual order recovery. Install inert; activation is a separate migration
-- after classifier and transactional integration tests have passed.
create table private.controlli_ordini_contesto (
 pratica_id uuid primary key references public.pratiche(id) on delete cascade,
 richiesta_at timestamptz not null default now(),
 controllata_at timestamptz,
 esito jsonb not null default '{}',
 errore text,
 tentativi integer not null default 0
);
revoke all on private.controlli_ordini_contesto from public, anon, authenticated;

-- Pure classifier: original messages only, chronological ordering, no AI summaries.
-- A fiscal reply is evidence of progression only after an operational request.
create function private.classifica_sequenza_ordine(p_messaggi jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare m jsonb; t text; intenzione jsonb; richiesta jsonb; fiscali jsonb;
 scelta text; scelta_msg text; testo_fiscale text := ''; ids jsonb := '[]';
 stop_msg jsonb; segnale boolean := false; sospetto boolean := false;
begin
 for m in select value from jsonb_array_elements(p_messaggi)
  order by (value->>'data')::timestamptz, value->>'id'
 loop
  t := lower(translate(coalesce(m->>'testo',''),'àèéìòù’','aeeiou'''));
  if coalesce((m->>'revoca')::boolean,false) or coalesce((m->>'modificato')::boolean,false) then
   sospetto := true;
   continue;
  end if;
  if m->>'direzione'='entrata' then
   if t ~ '(annull|non (voglio|intendo|desidero|posso) procedere|non confermo|non accetto|risolto altrove|risolto diversamente|rinuncio|per ora (aspetto|attendo)|prima di (confermare|decidere)|vi faro sapere|vi faccio sapere)' then
    -- Logistics readiness is not a withdrawal of the commercial order.
    if t !~ '(smont|ritir|sped|pacco|imball)' or t ~ '(annull|rinuncio|non confermo|non accetto|non (voglio|intendo|desidero) procedere)' then
     stop_msg := m; intenzione := null; richiesta := null; fiscali := null;
     testo_fiscale := ''; ids := '[]'; scelta := null;
    end if;
   end if;
   if t ~ '(confermo (il |l.)?(preventivo|ordine)|accetto (il |la |l.|vostra |vostro )*(preventivo|offerta|proposta)|vorrei dare seguito alla vostra proposta|desidero procedere|intendo procedere|procediamo con|procedete con)'
    and t !~ '(\mnon\M|\mse\M|qualora|prima di|vorrei sapere|posso|potrei)' then
    intenzione := m; stop_msg := null;
   end if;
   -- Explicit service or customer's own-device choice; uniqueness is checked
   -- against the actual quote by the database wrapper.
   if t !~ '(\mnon\M|\mse\M|qualora|vorrei sapere)' then
    if t ~ '(scelgo|accetto|confermo|procediamo con|procedete con).{0,40}(riparazione elettronica|\mre\M)' then scelta:='RE'; scelta_msg:=m->>'id';
    elsif t ~ '(scelgo|accetto|confermo|procediamo con|procedete con).{0,40}(riparazione idraulica|\mri\M)' then scelta:='RI'; scelta_msg:=m->>'id';
    elsif t ~ '(scelgo|accetto|confermo|procediamo con|procedete con).{0,40}\mpsmi\M' then scelta:='PSMI'; scelta_msg:=m->>'id';
    elsif t ~ '(scelgo|accetto|confermo|procediamo con|procedete con).{0,40}(programma scambio|\mps\M)' then scelta:='PS'; scelta_msg:=m->>'id';
    elsif t ~ '(dovrei inviare il mio dispositivo|riparare il mio|riparazione del mio|riparazione della mia)' then scelta:='ORIGINALE'; scelta_msg:=m->>'id';
    end if;
   end if;
   if t ~ '(codice fiscale|partita iva|fatturazione|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})' then segnale:=true; end if;
   if richiesta is not null and (m->>'data')::timestamptz >= (richiesta->>'data')::timestamptz then
    testo_fiscale := testo_fiscale || E'\n' || t;
    ids := ids || jsonb_build_array(m->>'id');
    if private.dati_fiscali_cliente(testo_fiscale)
      and testo_fiscale ~ '(via |viale |piazza |corso |strada |vicolo |largo |localita )'
      and testo_fiscale ~ '\m[0-9]{5}\M' then
     if fiscali is null then fiscali:=m; end if;
    end if;
   end if;
  elsif m->>'direzione'='uscita'
    and t ~ '(dati fiscali|dati di fatturazione|dati per la fatturazione)'
    and t ~ '(per procedere|apertura della pratica|apertura pratica|conferma.{0,20}ordine)'
    and t !~ '(per (fare|preparare|elaborare|inviare).{0,15}preventivo)' then
   richiesta := m; testo_fiscale := ''; ids := '[]'; fiscali:=null;
  end if;
 end loop;
 if stop_msg is not null then
  return jsonb_build_object('decisione','verifica','motivo','rinvio_o_revoca_commerciale','messaggio',stop_msg->>'id','segnale',segnale);
 end if;
 if fiscali is not null then
  return jsonb_build_object('decisione',case when intenzione is not null and not sospetto then 'conferma' else 'verifica' end,
   'motivo',case when sospetto then 'originali_modificati' when intenzione is null then 'dati_ricevuti_intenzione_da_verificare' else 'accettazione_e_dati_fiscali' end,
   'intenzione_id',intenzione->>'id','richiesta_id',richiesta->>'id','fiscali_id',fiscali->>'id',
   'confermata_at',fiscali->>'data','scelta',scelta,'scelta_id',scelta_msg,'segnale',true);
 end if;
 return jsonb_build_object('decisione',case when segnale then 'verifica' else 'nessuna' end,
  'motivo',case when segnale then 'dati_dopo_offerta_da_verificare' else 'nessuna_sequenza' end,'segnale',segnale);
end $$;

create function private.valuta_ordine_contesto(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare p public.pratiche%rowtype; q public.offerte_versioni%rowtype;
 sid uuid; n integer; msgs jsonb; d jsonb; oid uuid; s public.scelte_cliente%rowtype;
begin
 select * into p from public.pratiche where id=p_id;
 if not found then return jsonb_build_object('decisione','nessuna','motivo','inesistente'); end if;
 if p.tipo_flusso<>'commerciale' or p.stato_fatturazione='fatturato'
  or p.stato_commerciale in ('rifiutato','chiuso')
  or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true'
  or exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
   and c.telefono_normalizzato=regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g')) then
  return jsonb_build_object('decisione','nessuna','motivo','pratica_esclusa');
 end if;
 select * into q from public.offerte_versioni where pratica_id=p_id
  order by inviato_at desc,registrata_at desc,versione desc limit 1;
 if q.id is null then return jsonb_build_object('decisione','nessuna','motivo','nessuna_offerta'); end if;
 select count(distinct sessione),(array_agg(distinct sessione))[1] into n,sid
  from public.keplero_pratiche_conversazioni where pratica_id=p_id;
 if n<>1 then return jsonb_build_object('decisione','verifica','motivo','sessione_non_univoca'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',messaggio_id,'data',data_messaggio,
  'testo',testo,'direzione',direzione,'revoca',revoca,'modificato',modificato)),'[]') into msgs
  from public.keplero_originali where sessione=sid and data_messaggio>=q.inviato_at
  and data_messaggio<=now() and tipo='text';
 d := private.classifica_sequenza_ordine(msgs)||jsonb_build_object('sessione',sid,'offerta_id',q.id);
 if d->>'decisione'='nessuna' then return d; end if;
 if p.stato_commerciale='ordine_acquisito' then
  if d->>'motivo'='rinvio_o_revoca_commerciale' and exists (
   select 1 from public.keplero_originali where sessione=sid and messaggio_id=d->>'messaggio'
   and data_messaggio>p.ordine_acquisito_at) then return d; end if;
  return d||jsonb_build_object('decisione','nessuna','motivo','ordine_gia_acquisito');
 end if;
 if p.blocco_operatore or coalesce(cardinality(p.campi_bloccati_operatore),0)>0 then
  return d||jsonb_build_object('decisione','verifica','motivo','blocco_operatore'); end if;
 if q.stato<>'letta' or q.inviato_at is null then
  return d||jsonb_build_object('decisione','verifica','motivo','offerta_da_leggere'); end if;
 -- Do not reuse a household/garage's fiscal reply for another vehicle.
 if exists(select 1 from public.keplero_pratiche_conversazioni c join public.pratiche x on x.id=c.pratica_id
  where c.sessione=sid and x.id<>p_id and x.tipo_flusso='commerciale'
  and x.stato_commerciale not in ('rifiutato','chiuso') and x.stato_fatturazione<>'fatturato'
  and coalesce(x.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
  and coalesce(x.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
  and exists(select 1 from public.offerte_versioni where pratica_id=x.id)) then
  return d||jsonb_build_object('decisione','verifica','motivo','piu_pratiche_nella_conversazione'); end if;
 select * into s from public.scelte_cliente where pratica_id=p_id;
 if s.pratica_id is not null and (s.protetta_operatore or s.stato in ('revocata','modifica_da_verificare','condizionata')) then
  return d||jsonb_build_object('decisione','verifica','motivo','scelta_operatore_o_condizionata'); end if;
 if d->>'decisione'<>'conferma' then return d; end if;
 select count(*),(array_agg(id))[1] into n,oid from public.offerta_opzioni
  where offerta_id=q.id and (servizio=d->>'scelta' or (d->>'scelta'='ORIGINALE' and servizio in ('RE','RI','RC')));
 if d->>'scelta' is null then
  select count(*),(array_agg(id))[1] into n,oid from public.offerta_opzioni where offerta_id=q.id;
 end if;
 if n<>1 then return d||jsonb_build_object('decisione','verifica','motivo','servizio_da_chiarire'); end if;
 if s.opzione_id is not null and s.opzione_id<>oid then
  return d||jsonb_build_object('decisione','verifica','motivo','scelta_discordante'); end if;
 return d||jsonb_build_object('opzione_id',oid,'prezzo_da_verificare',
  coalesce((d->>'confermata_at')::timestamptz>q.inviato_at+make_interval(days=>q.validita_giorni),false));
end $$;

-- Existing dashboard activity type: no new frontend is necessary to surface an
-- urgent task. Never overwrite an operator's note or close their activity.
create function private.segnala_ordine_contesto(p_id uuid,p_esito jsonb)
returns void language plpgsql set search_path = '' as $$
begin
 insert into public.attivita_operatore(tipo,stato,priorita,pratica_id,evidenza,fonte,metadati)
 values ('richiamata_post_preventivo','da_gestire','urgente',p_id,
  'VERIFICA ORDINE — '||coalesce(p_esito->>'motivo','errore controllo')||
  '. Controllare accettazione e dati ricevuti; non richiederli nuovamente se già presenti.',
  'routine_controllo_k',jsonb_build_object('ordine_contesto',p_esito))
 on conflict (pratica_id,tipo) where stato in ('da_gestire','da_collegare','programmata')
 do update set priorita='urgente',metadati=coalesce(public.attivita_operatore.metadati,'{}')||excluded.metadati,
  evidenza=case when public.attivita_operatore.metadati ? 'ordine_contesto' then excluded.evidenza
   else public.attivita_operatore.evidenza||E'\n'||excluded.evidenza end;
end $$;

create function private.applica_ordine_contesto(p_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare p public.pratiche%rowtype; dopo public.pratiche%rowtype; d jsonb; raw jsonb; precedente text;
begin
 select * into p from public.pratiche where id=p_id for update;
 d:=private.valuta_ordine_contesto(p_id);
 if d->>'decisione'='verifica' then perform private.segnala_ordine_contesto(p_id,d); return d; end if;
 if d->>'decisione'<>'conferma' then return d; end if;
 -- Row lock + current-state revalidation + one transaction for evidence/state.
 insert into public.scelte_cliente(pratica_id,offerta_id,opzione_id,stato,evidenza,richiesta_at,fonte)
 values(p_id,(d->>'offerta_id')::uuid,(d->>'opzione_id')::uuid,'confermata',d::text,
  (d->>'confermata_at')::timestamptz,'originali_contesto')
 on conflict(pratica_id) do update set offerta_id=excluded.offerta_id,opzione_id=excluded.opzione_id,
  stato=excluded.stato,evidenza=excluded.evidenza,richiesta_at=excluded.richiesta_at,fonte=excluded.fonte;
 raw:=coalesce(p.dati_raw,'{}')||jsonb_build_object('conferma_ordine_contesto',d||jsonb_build_object('registrata_at',now()));
 raw:=jsonb_set(raw,'{payload_live}',coalesce(raw->'payload_live','{}')||jsonb_build_object('dati_confermati_cliente',true));
 if (d->>'prezzo_da_verificare')::boolean then
  precedente:=current_setting('app.gestisci_sospensione_fatturazione',true);
  perform set_config('app.gestisci_sospensione_fatturazione','true',true);
  raw:=raw||jsonb_build_object('sospensione_fatturazione_operatore',jsonb_build_object(
   'motivo','Offerta accettata dopo la scadenza: verificare prezzo prima della fattura.',
   'attiva',true,'fonte','ordine_contesto'));
 end if;
 update public.pratiche set stato_commerciale='ordine_acquisito',stato_fatturazione='da_fatturare',
  ordine_acquisito_at=coalesce(ordine_acquisito_at,(d->>'confermata_at')::timestamptz),
  stato_conferma_cliente='confermato',conferma_cliente_at=coalesce(conferma_cliente_at,(d->>'confermata_at')::timestamptz),
  dati_raw=raw where id=p_id returning * into dopo;
 if precedente is not null then perform set_config('app.gestisci_sospensione_fatturazione',precedente,true);
 else perform set_config('app.gestisci_sospensione_fatturazione','false',true); end if;
 if dopo.stato_commerciale<>'ordine_acquisito' or dopo.stato_fatturazione<>'da_fatturare' then
  raise exception 'Transizione ordine non persistita per %',p_id; end if;
 update public.preventivi set stato='accettato',accettato_at=coalesce(accettato_at,dopo.ordine_acquisito_at)
  where id=(select preventivo_id from public.offerte_versioni where id=(d->>'offerta_id')::uuid) and stato='inviato';
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo)
 values(p_id,'ordine_da_contesto','Ordine recuperato da accettazione, richiesta fiscale e risposta originali.',to_jsonb(p),to_jsonb(dopo));
 if (d->>'prezzo_da_verificare')::boolean then
  perform private.segnala_ordine_contesto(p_id,d||jsonb_build_object('motivo','ordine_acquisito_prezzo_scaduto_da_verificare'));
 end if;
 return d||jsonb_build_object('aggiornato',true);
end $$;

create function private.controlla_ordini_contesto(p_limite integer default 50)
returns jsonb language plpgsql set search_path = '' as $$
declare r record; d jsonb; n integer:=0; errori integer:=0;
begin
 if not pg_try_advisory_xact_lock(7114142026) then return '{"occupato":true}'::jsonb; end if;
 -- Independent reconciliation: include old open quotes, no 30-day cutoff.
 insert into private.controlli_ordini_contesto(pratica_id)
 select p.id from public.pratiche p where p.tipo_flusso='commerciale'
  and p.stato_commerciale in ('preventivo_inviato','attesa_cliente') and p.stato_fatturazione<>'fatturato'
  and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
  and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
  and exists(select 1 from public.offerte_versioni where pratica_id=p.id)
 on conflict do nothing;
 for r in select * from private.controlli_ordini_contesto
  where controllata_at is null or richiesta_at>controllata_at or controllata_at<now()-interval '1 day'
  order by coalesce(controllata_at,'-infinity'::timestamptz),richiesta_at
  limit greatest(1,least(p_limite,200)) for update skip locked
 loop
  begin
   d:=private.applica_ordine_contesto(r.pratica_id);
   update private.controlli_ordini_contesto set controllata_at=clock_timestamp(),esito=d,errore=null,tentativi=tentativi+1
    where pratica_id=r.pratica_id;
  exception when others then
   errori:=errori+1;
   update private.controlli_ordini_contesto set controllata_at=clock_timestamp(),errore=SQLSTATE||': '||SQLERRM,
    esito=jsonb_build_object('decisione','errore','motivo','errore_controllo'),tentativi=tentativi+1 where pratica_id=r.pratica_id;
   perform private.segnala_ordine_contesto(r.pratica_id,jsonb_build_object('motivo','errore_controllo','codice',SQLSTATE));
  end;
  n:=n+1;
 end loop;
 return jsonb_build_object('controllate',n,'errori',errori);
end $$;

-- SECURITY DEFINER only for the enqueue operation; no public execution.
create function private.accoda_ordine_contesto()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into private.controlli_ordini_contesto(pratica_id,richiesta_at)
 select distinct pratica_id,clock_timestamp() from public.keplero_pratiche_conversazioni where sessione=new.sessione
 on conflict(pratica_id) do update set richiesta_at=excluded.richiesta_at;
 return new;
end $$;

revoke all on function private.classifica_sequenza_ordine(jsonb),private.valuta_ordine_contesto(uuid),
 private.segnala_ordine_contesto(uuid,jsonb),private.applica_ordine_contesto(uuid),
 private.controlla_ordini_contesto(integer),private.accoda_ordine_contesto() from public,anon,authenticated;

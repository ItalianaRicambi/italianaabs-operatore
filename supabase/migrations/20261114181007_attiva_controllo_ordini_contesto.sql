create or replace function private.classifica_sequenza_ordine(p_messaggi jsonb)
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
   if t ~ '(annull|non (voglio|intendo|desidero|posso) procedere|non confermo|non accetto|risolto altrove|risolto diversamente|rinuncio|per ora (aspetto|attendo)|prima di (confermare|decidere)|vi faro sapere|vi faccio sapere|confermo solo se|accetto solo se|a condizione|se il prezzo|se costa|non ho (deciso|scelto)|non sono (sicuro|convinto)|devo (decidere|valutare)|ci penso|prima di procedere)' then
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

create or replace function private.valuta_ordine_contesto(p_id uuid)
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
 if n=0 then return jsonb_build_object('decisione',case when private.dati_fiscali_cliente(p.dati_raw->>'ultimo_messaggio_cliente') then 'verifica' else 'nessuna' end,'motivo','originali_non_collegati'); end if;
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
 if d->>'motivo'='rinvio_o_revoca_commerciale' and coalesce((d->>'segnale')::boolean,false)=false then
  return d||jsonb_build_object('decisione','nessuna'); end if;
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
 if exists(select 1 from public.pratiche x where x.id<>p_id
  and upper(x.targa)=upper(p.targa) and nullif(regexp_replace(x.telefono,'[^0-9]','','g'),'')=nullif(regexp_replace(p.telefono,'[^0-9]','','g'),'')
  and x.stato_commerciale='ordine_acquisito'
  and coalesce(x.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
  and coalesce(x.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true') then
  return d||jsonb_build_object('decisione','verifica','motivo','ordine_gia_presente_altra_scheda'); end if;
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


-- Enqueue on original messages and newly established conversation links.
create trigger trg_accoda_ordine_contesto
 after insert or update on public.keplero_originali
 for each row execute function private.accoda_ordine_contesto();
create trigger trg_collega_ordine_contesto
 after insert or update on public.keplero_pratiche_conversazioni
 for each row execute function private.accoda_ordine_contesto();

select cron.schedule('controllo-ordini-contesto','* * * * *',
 $job$select private.controlla_ordini_contesto(50);$job$);

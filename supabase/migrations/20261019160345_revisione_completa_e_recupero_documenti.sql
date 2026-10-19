select pg_catalog.pg_advisory_xact_lock(20261019,160035);
-- Revisione completa sul dispositivo originale: categoria distinta da RI, RE e scambio.
alter table public.offerta_opzioni drop constraint offerta_opzioni_servizio_check;
alter table public.offerta_opzioni add constraint offerta_opzioni_servizio_check
 check(servizio in ('RI','RE','RC','PS','PSMI'));

create or replace function private.conferma_invio_operatore_valida(a public.azioni_operatore)
returns boolean language sql stable security invoker set search_path='' as $$
 select coalesce(a.operatore,'') in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4')
 and (a.azione='commerciale_preventivo_inviato' or (
   a.azione='operatore_correzione_stato'
   and a.stato_prima->>'id'=a.pratica_id::text and a.stato_dopo->>'id'=a.pratica_id::text
   and a.stato_prima->>'tipo_flusso'='commerciale' and a.stato_dopo->>'tipo_flusso'='commerciale'
   and a.stato_prima->>'stato_commerciale' in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto','richiesta_verifica')
   and a.stato_dopo->>'stato_commerciale'='preventivo_inviato'
   and a.stato_dopo->>'stato_fatturazione'='non_applicabile'
   and nullif(a.stato_dopo->>'preventivo_inviato_at','') is not null
   and (a.stato_dopo->>'preventivo_inviato_at')::timestamptz between a.created_at-interval '5 minutes' and a.created_at+interval '5 minutes'
 ));
$$;
revoke all on function private.conferma_invio_operatore_valida(public.azioni_operatore) from public,anon,authenticated;
grant execute on function private.conferma_invio_operatore_valida(public.azioni_operatore) to service_role;

CREATE OR REPLACE FUNCTION public.conferma_invio_documento_preventivo(p_documento_id uuid, p_prova jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare d public.documenti_preventivo_auto%rowtype; p public.pratiche%rowtype; a public.azioni_operatore%rowtype;
 r jsonb; invio timestamptz:=(p_prova->>'inviato_at')::timestamptz; fonte_id text:=p_prova->>'fonte_id';
begin
 select * into d from public.documenti_preventivo_auto where id=p_documento_id for update;
 if d.id is null then raise exception 'Documento assente'; end if;
 if coalesce(fonte_id,'')='' or length(fonte_id)>255 or invio is null or invio>now()+interval '5 minutes'
 or invio<d.data_offerta-interval '5 minutes' then raise exception 'Prova invio non valida'; end if;
 if d.stato='inviato' then return jsonb_build_object('ok',true,'esito','gia_registrato','preventivo_id',d.preventivo_id); end if;
 perform private.abbina_documento_preventivo(d.id);
 select * into d from public.documenti_preventivo_auto where id=d.id;
 if d.pratica_id is null then return jsonb_build_object('ok',false,'esito','da_abbinare'); end if;
 select * into p from public.pratiche where id=d.pratica_id;
 if p_prova->>'fonte'='operatore' then
  select * into a from public.azioni_operatore where id=(p_prova->>'azione_id')::bigint
  and pratica_id=p.id and private.conferma_invio_operatore_valida(azioni_operatore) and created_at=invio;
  if a.id is null or fonte_id<>'operatore:'||a.id then raise exception 'Conferma operatore non verificata'; end if;
 elsif p_prova->>'fonte'='keplero_originale_verificato' then
  if p_prova->>'direzione' is distinct from 'uscita' or p_prova->>'esito' is distinct from 'inviato'
   or p_prova->>'impronta_documento' is distinct from d.impronta
   or coalesce(p_prova->>'messaggio_id','')!~'^[A-Za-z0-9_-]{1,100}$'
   or coalesce(p_prova->>'conversazione_id','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   or fonte_id<>'keplero:'||(p_prova->>'conversazione_id')||':'||(p_prova->>'messaggio_id')
   or p.keplero_conversation_id::text is distinct from p_prova->>'conversazione_id'
   or coalesce((p_prova->>'verificata_originale')::boolean,false) is not true
  then raise exception 'Messaggio originale non verificato'; end if;
 else raise exception 'Fonte prova invio non ammessa'; end if;
 -- La prova non sostituisce una correzione umana o riapre ordini già avanzati.
 if p.stato_commerciale in ('ordine_acquisito','chiuso','perso','rifiutato') or p.stato_fatturazione<>'non_applicabile'
 then return jsonb_build_object('ok',false,'esito','stato_avanzato_protetto'); end if;
 update public.documenti_preventivo_auto set prova_invio=p_prova,fonte_invio_id=fonte_id where id=d.id;
 if nullif(d.contenuto->>'errore','') is not null or jsonb_array_length(d.contenuto->'opzioni')=0 then
  update public.documenti_preventivo_auto set stato='da_verificare',motivo='Invio verificato; lettura di soluzioni e prezzi da completare.' where id=d.id;
  return jsonb_build_object('ok',false,'esito','lettura_da_verificare','documento_id',d.id,'pratica_id',p.id);
 end if;
 r:=public.registra_preventivo_con_offerta('drive:'||encode(sha256(convert_to(d.external_id,'UTF8')),'hex')||':'||d.impronta,d.targa||'.pdf',d.targa,d.file_url,d.data_offerta,invio,d.contenuto);
 if r->>'preventivo_id' is null then
  update public.documenti_preventivo_auto set stato='da_verificare',motivo='Invio verificato; aggiornamento protetto: '||coalesce(r->>'esito','da verificare') where id=d.id;
  return r;
 end if;
 if r->>'pratica_id' is distinct from d.pratica_id::text then raise exception 'Abbinamento del preventivo discordante'; end if;
 update public.documenti_preventivo_auto set stato='inviato',motivo='Invio verificato.',
  prova_invio=p_prova,fonte_invio_id=fonte_id,preventivo_id=(r->>'preventivo_id')::uuid where id=d.id;
 return r||jsonb_build_object('ok',true,'documento_id',d.id);
end; $function$;


create or replace function private.collega_documento_a_conferma_operatore(p_pratica_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare doc uuid; a public.azioni_operatore%rowtype; data_doc timestamptz;
begin
 -- Nessuna scelta arbitraria tra più PDF/versioni pendenti.
 select (array_agg(id))[1], min(data_offerta) into doc,data_doc
 from public.documenti_preventivo_auto where pratica_id=p_pratica_id and stato in ('pronto','da_verificare')
 and data_offerta>=now()-interval '30 days' having count(*)=1;
 if doc is null then return '{}'::jsonb; end if;
 select * into a from public.azioni_operatore x where x.pratica_id=p_pratica_id
 and x.created_at between data_doc-interval '5 minutes' and data_doc+interval '30 days'
 and private.conferma_invio_operatore_valida(x) order by x.created_at desc,x.id desc limit 1;
 if a.id is null then return '{}'::jsonb; end if;
 return public.conferma_invio_documento_preventivo(doc,jsonb_build_object('fonte','operatore',
  'fonte_id','operatore:'||a.id,'azione_id',a.id,'inviato_at',a.created_at));
end; $$;
revoke all on function private.collega_documento_a_conferma_operatore(uuid) from public,anon,authenticated;
grant execute on function private.collega_documento_a_conferma_operatore(uuid) to service_role;

CREATE OR REPLACE FUNCTION public.registra_documento_preventivo_auto(p_dati jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare d public.documenti_preventivo_auto%rowtype; c jsonb:=p_dati->'contenuto';
 t text:=upper(regexp_replace(coalesce(p_dati->>'targa',''),'[^A-Za-z0-9]','','g'));
 data_doc timestamptz:=(p_dati->>'data_offerta')::timestamptz;
begin
 if coalesce(p_dati->>'external_id','')='' or length(p_dati->>'external_id')>255
 or coalesce(c->>'impronta','')!~'^[a-f0-9]{64}$'
 or t!~'^[A-Z0-9]{4,12}$' or coalesce(p_dati->>'nome_file','')!~*'\.pdf$'
 or upper(regexp_replace(regexp_replace(regexp_replace(p_dati->>'nome_file','\.pdf$','','i'),'\s*\([0-9]+\)$',''),'[^A-Za-z0-9]','','g'))<>t
 or data_doc is null or data_doc>now()+interval '1 day'
 or jsonb_typeof(c->'opzioni') is distinct from 'array' or jsonb_array_length(c->'opzioni')>8
 then raise exception 'Documento preventivo non valido'; end if;
 if nullif(c->>'errore','') is null and jsonb_array_length(c->'opzioni')=0 then raise exception 'Alternative assenti'; end if;
 if exists(select 1 from jsonb_array_elements(c->'opzioni') o where
 coalesce(o->>'servizio','') not in ('RI','RE','RC','PS','PSMI') or (o->>'importo')::numeric<=0
 or (o->>'importo')::numeric>100000 or (o->>'importo')::numeric is null
 or (o->>'numero')::int not between 1 and 8 or (o->>'numero')::int is null)
 then raise exception 'Alternative non valide'; end if;
 insert into public.documenti_preventivo_auto(external_id,impronta,sha256_pdf,nome_file,targa,file_url,data_offerta,contenuto)
 values(p_dati->>'external_id',c->>'impronta',p_dati->>'sha256_pdf',p_dati->>'nome_file',t,
 nullif(p_dati->>'file_url',''),data_doc,c)
 on conflict(external_id,impronta) do nothing;
 select * into d from public.documenti_preventivo_auto where external_id=p_dati->>'external_id' and impronta=c->>'impronta' for update;
 -- Retry tardivi non cambiano i dati/documenti già collegati.
 if d.targa<>t then raise exception 'Identità documento discordante'; end if;
 -- Solo una lettura fallita può essere migliorata, sullo stesso documento originale.
 -- Non si riscrivono offerte valide, scelte o documenti già inviati.
 if d.stato<>'inviato' and nullif(d.contenuto->>'errore','') is not null
  and nullif(c->>'errore','') is null and jsonb_array_length(c->'opzioni')>0 then
  if coalesce(d.contenuto->>'testo','')='' or d.contenuto->>'testo' is distinct from c->>'testo'
   or d.sha256_pdf is distinct from p_dati->>'sha256_pdf' or d.data_offerta is distinct from data_doc
   or d.file_url is distinct from nullif(p_dati->>'file_url','')
  then raise exception 'Originale documento discordante'; end if;
  update public.documenti_preventivo_auto set contenuto=c where id=d.id;
 end if;
 perform private.abbina_documento_preventivo(d.id);
 select * into d from public.documenti_preventivo_auto where id=d.id;
 if d.stato<>'inviato' and d.pratica_id is not null then
  if d.prova_invio is not null then
   perform public.conferma_invio_documento_preventivo(d.id,d.prova_invio);
  else perform private.collega_documento_a_conferma_operatore(d.pratica_id); end if;
 end if;
 select * into d from public.documenti_preventivo_auto where id=d.id;
 return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito',d.stato,'pratica_id',d.pratica_id);
end; $function$;


create or replace function private.documento_dopo_conferma_operatore()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if private.conferma_invio_operatore_valida(new) then
  perform private.collega_documento_a_conferma_operatore(new.pratica_id);
 end if;
 return new;
end; $$;

CREATE OR REPLACE FUNCTION public.registra_alternative_offerta_operatore(p_pratica_id uuid, p_preventivo_id uuid, p_contenuto jsonb, p_operatore text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare p public.pratiche%rowtype; q public.preventivi%rowtype; r jsonb;
 v_opzioni jsonb:=p_contenuto->'opzioni'; v_creato boolean:=false;
 v_external text:='operatore:alternative:'||p_pratica_id::text;
begin
 if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') or p_operatore is null then
  raise exception 'Operatore non valido';
 end if;
 if jsonb_typeof(v_opzioni) is distinct from 'array' then raise exception 'Alternative non valide'; end if;
 if jsonb_array_length(v_opzioni) not between 1 and 8 or nullif(p_contenuto->>'errore','') is not null then
  raise exception 'Alternative e prezzi da verificare nel documento';
 end if;
 if coalesce(p_contenuto->>'impronta','') !~ '^[0-9a-f]{64}$' then raise exception 'Impronta non valida'; end if;
 if exists(select 1 from jsonb_array_elements(v_opzioni) x where
  coalesce(x->>'servizio','') not in ('RI','RE','RC','PS','PSMI') or
  coalesce(x->>'numero','') !~ '^[1-8]$' or
  coalesce(x->>'importo','') !~ '^[0-9]+([.][0-9]{1,2})?$' or
  coalesce(x->>'valuta','EUR')<>'EUR' or
  coalesce(jsonb_typeof(x->'iva_inclusa'),'null') not in ('boolean','null')) then
  raise exception 'Alternative non valide';
 end if;
 if exists(select 1 from jsonb_array_elements(v_opzioni) x where (x->>'importo')::numeric<=0 or (x->>'importo')::numeric>100000)
  or exists(select 1 from jsonb_array_elements(v_opzioni) x group by x->>'numero' having count(*)>1) then
  raise exception 'Importi o numeri delle alternative non validi';
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_external,0));
 -- Quote prima della pratica, come registra_opzioni_offerta: evita inversioni dei lock.
 if p_preventivo_id is not null then
  select * into q from public.preventivi where id=p_preventivo_id for update;
  if not found or q.pratica_id<>p_pratica_id then raise exception 'Preventivo estraneo alla pratica'; end if;
 else
  select * into q from public.preventivi where external_id=v_external for update;
 end if;
 select * into p from public.pratiche where id=p_pratica_id for update;
 if not found then raise exception 'Pratica non trovata'; end if;
 if p.tipo_flusso<>'commerciale' then raise exception 'Registrazione disponibile per le pratiche commerciali'; end if;
 if q.id is null then
  if exists(select 1 from public.preventivi where pratica_id=p.id) then
   raise exception 'Un preventivo è già presente: ricarica la pratica e selezionalo';
  end if;
  if p.preventivo_inviato_at is null or p.stato_commerciale not in ('preventivo_inviato','attesa_cliente','ordine_acquisito') then
   raise exception 'Registra prima l’invio del preventivo nella sezione commerciale';
  end if;
  insert into public.preventivi(pratica_id,external_id,stato,creato_at,inviato_at,note)
  values(p.id,v_external,'inviato',p.preventivo_inviato_at,p.preventivo_inviato_at,
   'Invio dichiarato dall’operatore; alternative inserite da '||p_operatore||'. PDF non collegato.') returning * into q;
  v_creato:=true;
 end if;
 r:=public.registra_opzioni_offerta(q.id,v_opzioni,p_contenuto->>'impronta',p_contenuto->>'testo',null,
  'operatore:'||p_operatore,(p_contenuto->>'validita_giorni')::integer,null);
 return r||jsonb_build_object('preventivo_id',q.id,'preventivo_creato',v_creato);
end; $function$;


-- Importi citati dal cliente: migliaia italiane e decimali rimangono distinti.
create or replace function private.importo_riferimento_offerta(p_valore text)
returns numeric language sql immutable strict security invoker set search_path='' as $$
 select case when p_valore like '%,%' then replace(replace(p_valore,'.',''),',','.')::numeric
  when p_valore ~ '^[0-9]{1,3}([.][0-9]{3})+$' then replace(p_valore,'.','')::numeric
  else p_valore::numeric end;
$$;
revoke all on function private.importo_riferimento_offerta(text) from public,anon,authenticated;
grant execute on function private.importo_riferimento_offerta(text) to service_role;

CREATE OR REPLACE FUNCTION private.rileva_scelta_cliente_evento(p_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype; q public.offerte_versioni%rowtype;
 s public.scelte_cliente%rowtype; o public.offerta_opzioni%rowtype; t text; v_stato text; v_count integer;
 v_ids uuid[]; v_riferimento text; v_tipi integer; v_tipo text; v_num integer; v_importo numeric; v_ha_riferimento boolean:=false; v_conferma boolean; v_risposta_breve boolean;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id for update;
 if not found or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then return '{}'::jsonb; end if;
 if not exists(select 1 from public.keplero_live_links where pratica_id=p.id and external_key=e.external_key) then return '{}'::jsonb; end if;
 if nullif(e.payload->>'targa','') is not null and upper(regexp_replace(e.payload->>'targa','[^A-Za-z0-9]','','g'))<>upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) then return '{}'::jsonb; end if;
 t:=lower(translate(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),'àèéìòù’','aeeiou'''));
 if t='' then return '{}'::jsonb; end if;
 select * into s from public.scelte_cliente where pratica_id=p.id;
 if s.protetta_operatore or (s.evento_id is not null and s.evento_id>e.id) then return jsonb_build_object('esito','scelta_preservata'); end if;
 if private.revoca_scelta_cliente(t) then
  if s.pratica_id is null then return '{}'::jsonb; end if;
  v_stato:=case when s.stato='confermata' then 'modifica_da_verificare' else 'revocata' end;
  v_ids:=array[s.opzione_id];
  select * into q from public.offerte_versioni where id=s.offerta_id;
 else
  if private.domanda_su_accettazione(t) then return '{}'::jsonb; end if;
  if t~'\mnon\M.{0,20}\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo|scelgo|scegliamo|ho deciso|ha deciso)\M' then return '{}'::jsonb; end if;
  v_risposta_breve:=btrim(t)~'^((la|solo)[[:space:]]+)?(ri|re|rc|ps|psmi|opzione[[:space:]]+[1-8]|programma scambio( made in italy)?)([.! ]*$|[,; ]+\m(se|qualora|altrimenti)\M)';
  if not v_risposta_breve and t!~'(opzione|offerta|proposta|preventivo|ordine|lavorazione|ripar|revision|programma scambio|€|\m(ri|re|rc|ps|psmi|prezzo|importo|euro)\M)'
   and btrim(t)!~'^(?:(?:buongiorno|buonasera|ciao|ok)[,!. ]*)?(accetto|accettiamo|confermo|confermiamo|procedete|procediamo)[.! ]*$' then return '{}'::jsonb; end if;
  if t !~ '\m(preferisco|preferiamo|preferirei|preferiremmo|sceglierei|sceglieremmo|scelgo|scegliamo|accetto|accettiamo|confermo|confermiamo|procedete|procediamo)\M|scelt|deciso per|sta bene|pratica confermata|vorrei revisionare|voglio riparare' and not v_risposta_breve then return '{}'::jsonb; end if;
  select * into q from public.offerte_versioni where pratica_id=p.id and inviato_at<=e.created_at
   order by inviato_at desc,registrata_at desc,versione desc limit 1;
  if q.id is null and not exists(select 1 from public.preventivi where pratica_id=p.id and coalesce(inviato_at,creato_at)<=e.created_at) then return '{}'::jsonb; end if;
  select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id;
  v_riferimento:=(regexp_split_to_array(t,'\m(se|qualora|altrimenti)\M'))[1];
  v_riferimento:=regexp_replace(v_riferimento,'\mnon\M[[:space:]]+(?:(?:voglio|vogliamo|preferisco|il|la)[[:space:]]+)?(?:programma scambio(?: made in italy)?|revisione completa|ri|re|rc|psmi|ps)\M',' ','g');
  v_tipi:=(case when v_riferimento~'\mrc\M|revisione completa' then 1 else 0 end)+(case when v_riferimento~'\mri\M|idraulic' then 1 else 0 end)+(case when v_riferimento~'\mre\M|elettronic' then 1 else 0 end)
   +(case when v_riferimento~'\mpsmi\M|programma scambio made in italy' then 1 else 0 end)
   +(case when regexp_replace(v_riferimento,'programma scambio made in italy','psmi','g')~'\mps\M|programma scambio' then 1 else 0 end);
  if v_riferimento ~ '\mpsmi\M|programma scambio made in italy' then v_tipo:='PSMI';
  elsif v_riferimento ~ '\mps\M|programma scambio' then v_tipo:='PS';
  elsif v_riferimento ~ '\mri\M|idraulic' then v_tipo:='RI';
  elsif v_riferimento ~ '\mre\M|elettronic' then v_tipo:='RE';
  elsif v_riferimento ~ '\mrc\M|revisione completa' then v_tipo:='RC'; end if;
  if v_riferimento ~ '(programma scambio|\mps\M)' and v_riferimento !~ '(made in italy|\mpsmi\M)' and v_riferimento !~ '\mps\M' then
   if exists(select 1 from public.offerta_opzioni where offerta_id=q.id and servizio='PSMI') then v_tipo:='SCAMBIO_GENERICO'; end if;
  end if;
  if v_tipo is not null then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids)
    and (servizio=v_tipo or (v_tipo='SCAMBIO_GENERICO' and servizio in ('PS','PSMI')));
  end if;
  v_num:=(regexp_match(v_riferimento,'(?:opzione|offerta|proposta)\s*(?:n[.]?\s*)?([1-8])\M'))[1]::integer;
  if v_num is null then
   v_num:=case when v_riferimento~'\mprima\M.{0,20}(proposta|offerta|opzione)|\m(prima proposta|prima offerta|prima opzione)\M' then 1
    when v_riferimento~'\mseconda\M.{0,20}(proposta|offerta|opzione)' then 2
    when v_riferimento~'\mterza\M.{0,20}(proposta|offerta|opzione)' then 3 end;
  end if;
  if v_num is not null then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids) and numero=v_num and numero_esplicito;
  end if;
  v_importo:=private.importo_riferimento_offerta((regexp_match(v_riferimento,'(?:€\s*|quella di\s*|quello di\s*|da\s+)([0-9]{1,3}(?:[.][0-9]{3})+(?:,[0-9]{2})?|[0-9]{2,5}(?:[,.][0-9]{2})?)'))[1]);
  if v_importo is null then v_importo:=private.importo_riferimento_offerta((regexp_match(v_riferimento,'([0-9]{1,3}(?:[.][0-9]{3})+(?:,[0-9]{2})?|[0-9]{2,5}(?:[,.][0-9]{2})?)\s*(?:euro|€)'))[1]); end if;
  if v_importo is not null then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids) and importo=v_importo and (v_tipo is not null or v_num is not null or iva_inclusa=true);
  end if;
  if v_tipi>1 or v_riferimento~'(opzione|offerta|proposta)[[:space:]]*[1-8].{0,20}((opzione|offerta|proposta)[[:space:]]*[1-8]|\me\M[[:space:]]*[1-8])' then v_ids:=null; end if;
  v_count:=coalesce(cardinality(v_ids),0);
  -- Più servizi o alternative sono una scelta condizionata/ambigua, mai un ordine incondizionato.
  v_conferma:=not private.preferenza_senza_conferma(t) and not private.rinvio_conferma_per_verifiche(t)
   and t !~ '\m(se|qualora|altrimenti|eventualmente|forse)\M'
   and (private.conferma_letterale_offerta(t) or t ~ '\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo|scelgo|scegliamo)\M|ha deciso per');
  if v_risposta_breve and s.stato='da_chiarire' and s.offerta_id=q.id and p.stato_commerciale::text='ordine_acquisito' and p.ordine_acquisito_at>=q.inviato_at and not private.preferenza_senza_conferma(s.evidenza) then v_conferma:=true; end if;
  v_stato:=case when t~'\m(se|qualora|altrimenti)\M' then 'condizionata'
   when v_conferma and v_count=1 and q.stato='letta' then 'confermata'
   when v_conferma or v_count<>1 then 'da_chiarire' else 'preferenza' end;
  if q.validita_giorni is not null and e.created_at>q.inviato_at+make_interval(days=>q.validita_giorni) then v_stato:='da_chiarire'; end if;
  if s.stato in ('confermata','modifica_da_verificare') then
   if s.offerta_id is distinct from q.id or s.opzione_id is distinct from (v_ids)[1] or v_stato<>'confermata' then
    v_stato:='modifica_da_verificare'; v_ids:=array[s.opzione_id]; select * into q from public.offerte_versioni where id=s.offerta_id;
   else return jsonb_build_object('esito','conferma_preservata'); end if;
  end if;
 end if;
 select * into o from public.offerta_opzioni where id=case when cardinality(v_ids)=1 then v_ids[1] else null end;
 if s.evento_id=e.id and s.offerta_id is not distinct from q.id and s.opzione_id is not distinct from o.id and s.stato=v_stato then return jsonb_build_object('esito','evento_gia_elaborato'); end if;
 insert into public.scelte_cliente(pratica_id,offerta_id,opzione_id,stato,evento_id,evidenza,richiesta_at,fonte)
 values(p.id,q.id,o.id,v_stato,e.id,coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),e.created_at,'keplero_live')
 on conflict(pratica_id) do update set offerta_id=excluded.offerta_id,opzione_id=excluded.opzione_id,
  stato=excluded.stato,evento_id=excluded.evento_id,evidenza=excluded.evidenza,richiesta_at=excluded.richiesta_at,updated_at=now();
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'scelta_cliente_rilevata',v_stato||' - '||coalesce(o.servizio,'soluzione da chiarire'),to_jsonb(s),
  jsonb_build_object('offerta_id',q.id,'opzione_id',o.id,'event_id',e.id,'stato',v_stato,'evidenza',t),'routine_controllo_k');
 if v_stato='confermata' and not p.blocco_operatore then perform public.conferma_ordine_da_keplero(p.id,e.external_key,t); end if;
 return jsonb_build_object('stato',v_stato,'offerta_id',q.id,'opzione_id',o.id,'servizio',o.servizio);
end; $function$;


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
 elsif v_servizio in ('RI','RE','RC') and not exists(select 1 from public.attivita_operatore where pratica_id=p.id and tipo='ritiro_lavorazione' and completata_at<e.created_at) then v_tipo:='ritiro_lavorazione';
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

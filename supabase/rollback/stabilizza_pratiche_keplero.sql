-- Ripristino del motore precedente; registro e prove vengono conservati.
-- Applicare da proprietario della migrazione dopo aver valutato la causa.
begin;
update public.keplero_stato_riconciliazione set attivo=false where id;
select cron.unschedule(jobid) from cron.job where jobname='riconcilia-esiti-commerciali';
drop trigger if exists zz_collega_episodio_conversazione_k on public.keplero_live_links;
drop trigger if exists zz_collega_pratica_legacy_k on public.pratiche;
drop trigger if exists zzzz_conserva_ingresso_k on public.keplero_live_events;
drop trigger if exists zzzz_conserva_ingresso_k on public.keplero_originali;
drop trigger if exists zzzz_conserva_ingresso_k on public.documenti_preventivo_auto;
drop trigger if exists zzzz_ricalcola_lavoro_k on public.pratiche;

CREATE OR REPLACE FUNCTION private.abbina_documento_preventivo(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare d public.documenti_preventivo_auto%rowtype; candidati uuid[];
begin
 select * into d from public.documenti_preventivo_auto where id=p_id for update;
 if d.id is null then raise exception 'Documento assente'; end if;
 if d.stato='inviato' then return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito','inviato','pratica_id',d.pratica_id); end if;
 -- Una targa condivisa da più episodi non permette di scegliere arbitrariamente.
 select array_agg(p.id) into candidati from public.pratiche p
 where upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g'))=d.targa
 and p.tipo_flusso='commerciale' and p.stato_commerciale in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto','preventivo_inviato','attesa_cliente','richiesta_verifica')
 and p.stato_fatturazione='non_applicabile'
 and (p.created_at<=d.data_offerta+interval '5 minutes'
  or (d.ricevuto_at<=p.created_at
   and d.ricevuto_at>=private.inizio_finestra_controllo_keplero(p.created_at,48)
   and d.data_offerta>=private.inizio_finestra_controllo_keplero(d.ricevuto_at,24)))
 and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
 and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
 update public.documenti_preventivo_auto set ultimo_tentativo_at=now(),
 pratica_id=case when cardinality(candidati)=1 then candidati[1] end,
 stato=case when coalesce(cardinality(candidati),0)<>1 then 'da_abbinare'
   when prova_invio is not null or nullif(contenuto->>'errore','') is not null then 'da_verificare' else 'pronto' end,
 motivo=case when coalesce(cardinality(candidati),0)=0 then 'Nessuna pratica compatibile con targa e data del documento.'
   when cardinality(candidati)>1 then 'Più pratiche compatibili: verificare l’abbinamento.'
   when prova_invio is not null then 'Invio rilevato: aggiornamento della pratica da verificare.'
   when nullif(contenuto->>'errore','') is not null then left(contenuto->>'errore',500)
   else 'PDF acquisito. Invio al cliente non ancora verificato.' end
 where id=d.id returning * into d;
 -- Nessuna modifica a classificazione, completezza o stato della pratica.
 return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito',d.stato,'pratica_id',d.pratica_id);
end; $function$;

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

CREATE OR REPLACE FUNCTION public.registra_pdf_originale_k(p_lease uuid, p_sessione uuid, p_messaggio_id text, p_contenuto jsonb, p_url text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare m public.keplero_originali%rowtype; d public.documenti_preventivo_auto%rowtype; r jsonb; ids uuid[];
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now();
 if not found then raise exception 'Lotto scaduto';end if;
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio_id;
 if m.modificato or m.direzione<>'uscita' or m.targa_pdf is null or m.sha256_pdf is null
 or m.testo is distinct from 'attachment:'||p_url then return jsonb_build_object('esito','prova_non_verificata'); end if;
 select array_agg(id) into ids from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf;
 if cardinality(ids)=1 then select * into d from public.documenti_preventivo_auto where id=ids[1];
 elsif coalesce(cardinality(ids),0)=0 then
  r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','keplero:'||p_sessione||':'||p_messaggio_id,
   'contenuto',p_contenuto,'sha256_pdf',m.sha256_pdf,'nome_file',m.targa_pdf||'.pdf','targa',m.targa_pdf,'file_url',p_url,'data_offerta',m.data_messaggio));
  select * into d from public.documenti_preventivo_auto where id=(r->>'documento_id')::uuid;
 else return jsonb_build_object('esito','documento_ambiguo');end if;
 if d.pratica_id is null or nullif(p_contenuto->>'errore','') is not null then return jsonb_build_object('esito','da_verificare');end if;
 if not exists(select 1 from public.pratiche p where p.id=d.pratica_id and p.keplero_conversation_id=p_sessione::text) then return jsonb_build_object('esito','conversazione_da_verificare');end if;
 return public.conferma_invio_documento_preventivo(d.id,jsonb_build_object('fonte','keplero_originale_verificato',
  'fonte_id','keplero:'||p_sessione||':'||p_messaggio_id,'direzione','uscita','esito','inviato','impronta_documento',d.impronta,
  'messaggio_id',p_messaggio_id,'conversazione_id',p_sessione,'verificata_originale',true,'inviato_at',m.data_messaggio));
end; $function$;

CREATE OR REPLACE FUNCTION private.valuta_originale_k(p_sessione uuid, p_messaggio_id text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare m public.keplero_originali%rowtype; f public.keplero_originali%rowtype;
 d public.documenti_preventivo_auto%rowtype; q public.offerte_versioni%rowtype;
 p public.pratiche%rowtype; s public.scelte_cliente%rowtype; o public.offerta_opzioni%rowtype;
 ids uuid[]; opzioni uuid[]; n integer; pid uuid; t text; v_tipo text; motivo text; esito text:='da_verificare'; r jsonb; prima jsonb;
begin
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio_id;
 if not m.candidato or m.data_messaggio<now()-interval '30 days' then return;end if;
 if exists(select 1 from public.keplero_verifiche_originali k where k.sessione=p_sessione and k.messaggio_id=p_messaggio_id and k.esito in ('recuperata','preservata','archiviata')) then return;end if;
 -- Collega l'avviso alla conversazione, mai per nome o telefono soltanto.
 select (array_agg(distinct coalesce(pratica_origine_id,id)))[1] into pid from public.pratiche where keplero_conversation_id=p_sessione::text having count(distinct coalesce(pratica_origine_id,id))=1;
 if pid is not null then select * into p from public.pratiche where id=pid;end if;
 motivo:='Possibile conferma o documento originale da verificare.';
 if m.modificato then motivo:='Il messaggio originale è cambiato: stato e prove precedenti conservati.';
 elsif m.revoca then motivo:='Revoca o modifica del cliente: verificare la scelta e l''ordine, senza annullamenti automatici.';
 elsif m.direzione<>'entrata' or m.tipo<>'text' then motivo:='Documento inviato nella chat: leggere il PDF originale prima di aggiornare la fatturazione.';
 elsif lower(m.testo)~'(bonifico|pagamento eseguito)' then motivo:='Pagamento dichiarato dal cliente: verificare la ricevuta e l''accredito; nessuna quietanza automatica.';
 else
  -- L'ultimo PDF con targa esatta deve avere gli stessi byte del documento già registrato.
  select * into f from public.keplero_originali where sessione=p_sessione and direzione='uscita' and tipo='file'
   and targa_pdf is not null and data_messaggio<=m.data_messaggio order by data_messaggio desc,messaggio_id desc limit 1;
  select array_agg(id) into ids from public.documenti_preventivo_auto where sha256_pdf=f.sha256_pdf and targa=f.targa_pdf and pratica_id is not null and not f.modificato;
  if cardinality(ids)=1 then
   select * into d from public.documenti_preventivo_auto where id=ids[1];
   if exists(select 1 from public.pratiche pc join public.pratiche destinazione on destinazione.id=d.pratica_id
     where pc.keplero_conversation_id=p_sessione::text
     and (pc.id=destinazione.id or pc.pratica_origine_id=destinazione.id
       or (regexp_replace(pc.telefono,'[^0-9]','','g')=regexp_replace(destinazione.telefono,'[^0-9]','','g') and pc.targa=destinazione.targa))) then
    select * into p from public.pratiche where id=d.pratica_id for update;
    select * into q from public.offerte_versioni where pratica_id=p.id and impronta=d.impronta and inviato_at<=m.data_messaggio order by versione desc limit 1;
   end if;
  end if;
  if q.id is null then motivo:='Conferma da verificare: manca un PDF originale inviato, identico a un''offerta registrata e abbinata senza ambiguità.';
  elsif p.stato_fatturazione='fatturato' or p.stato_commerciale in ('rifiutato','chiuso')
    or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  then esito:='preservata';motivo:='Pratica conclusa o fatturata: stati preservati.';
  else
   select * into s from public.scelte_cliente where pratica_id=p.id;
   if s.pratica_id is not null or p.blocco_operatore or p.tipo_flusso<>'commerciale' then
    if s.stato='confermata' and m.data_messaggio<=s.richiesta_at then esito:='preservata';motivo:='Conferma già presente: scelta e correzioni operatore preservate.';
    else motivo:='Scelta o blocco già presente: confrontare il messaggio originale con lo stato attuale.';end if;
   elsif q.stato<>'letta' or (q.validita_giorni is not null and m.data_messaggio>f.data_messaggio+make_interval(days=>q.validita_giorni)) then motivo:='Offerta da leggere o scaduta: verifica operatore richiesta.';
   elsif exists(select 1 from public.offerte_versioni successiva where successiva.pratica_id=p.id and successiva.inviato_at>q.inviato_at)
    or exists(select 1 from public.keplero_originali recente where recente.sessione=p_sessione and recente.data_messaggio>m.data_messaggio and recente.direzione='entrata' and recente.candidato and (recente.revoca or lower(recente.testo)~'(accett|conferm|proced|scelg|ripari|revision)'))
   then motivo:='Esistono messaggi o offerte successivi: verificare la decisione più recente.';
   else
    t:=lower(translate(m.testo,'àèéìòù’','aeeiou'''));
    -- Solo consenso letterale, senza domanda, negazioni, condizioni o futuro.
    if t~'[?]|\m(non|se|qualora|forse|eventualmente|prima|appena|domani|valutare|preferirei|vorrei)\M'
      or private.preferenza_senza_conferma(t) or private.rinvio_conferma_per_verifiche(t)
      or not(t~'\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo|scelgo|scegliamo)\M' or private.scelta_dispositivo_originale(t))
      or not(t~'(ordine|offerta|preventivo|lavorazione|ripar|revision|scambio|rigenerat|opzione|\m(ri|re|rc|ps|psmi)\M)' or btrim(t)~'^(ok[,!. ]*)?(accetto|accettiamo|confermo|confermiamo|procedete|procediamo)[.! ]*$')
    then motivo:='Intenzione, domanda o consenso non conclusivo: verificare con il cliente.';
    else
     select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id;
     if private.scelta_dispositivo_originale(t) then
      select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and servizio in ('RI','RE','RC');
     elsif t~'\mpsmi\M|scambio made in italy' then v_tipo:='PSMI';
     elsif t~'\mps\M' then v_tipo:='PS';
     elsif t~'\mri\M|idraulic' then v_tipo:='RI';
     elsif t~'\mre\M|elettronic' then v_tipo:='RE';
     elsif t~'\mrc\M|revisione completa' then v_tipo:='RC';
     elsif t~'scambio|rigenerat' then
      select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and servizio in ('PS','PSMI');
     end if;
     if v_tipo is not null then select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and servizio=v_tipo;end if;
     n:=(regexp_match(t,'opzione[[:space:]]+([1-8])\M'))[1]::integer;
     if n is not null then select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and id=any(opzioni) and numero=n and numero_esplicito;end if;
     -- Alternative multiple o riferimenti economici restano manuali, evitando selezioni parziali.
     if t~'\m(o|oppure|ma|anche)\M|[€]|[0-9]{2,}|\m(ri|re|rc|ps|psmi)\M.{0,30}\m(ri|re|rc|ps|psmi)\M' then opzioni:=null;end if;
     if (case when t~'\mri\M|idraulic' then 1 else 0 end)+(case when t~'\mre\M|elettronic' then 1 else 0 end)+(case when t~'\mrc\M|revisione completa' then 1 else 0 end)+(case when t~'scambio|rigenerat|\m(ps|psmi)\M' then 1 else 0 end)>1 then opzioni:=null;end if;
     if cardinality(opzioni)=1 and p.stato_commerciale in ('preventivo_inviato','attesa_cliente') then
      select * into o from public.offerta_opzioni where id=opzioni[1];prima:=to_jsonb(p);
      insert into public.scelte_cliente(pratica_id,offerta_id,opzione_id,stato,evidenza,richiesta_at,fonte)
       values(p.id,q.id,o.id,'confermata',m.testo,m.data_messaggio,'keplero_originale');
      r:=public.conferma_ordine_da_keplero(p.id,(select external_key from public.keplero_live_links where pratica_id=p.id),m.testo);
      if coalesce(r->>'aggiornato','false')='true' then
       update public.pratiche set ordine_acquisito_at=m.data_messaggio where id=p.id;
       esito:='recuperata';motivo:='Consenso originale e alternativa unica verificati. Ordine recuperato; i dati fiscali restano soggetti ai controlli amministrativi.';
       insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
        values(p.id,'ordine_recuperato_originale_k','keplero:'||p_sessione||':'||p_messaggio_id||' - '||left(m.testo,1000),prima,(select to_jsonb(pp) from public.pratiche pp where pp.id=p.id),'routine_originali_k');
      else
       delete from public.scelte_cliente where pratica_id=p.id and fonte='keplero_originale' and richiesta_at=m.data_messaggio;
       motivo:='Conferma originale trattenuta dalle protezioni dello stato: '||coalesce(r->>'motivo','verifica richiesta');
      end if;
     else motivo:='Consenso da verificare: più alternative possibili o stato non compatibile. Nessun importo scelto automaticamente.';end if;
    end if;
   end if;
  end if;
 end if;
 insert into public.keplero_verifiche_originali(sessione,messaggio_id,pratica_id,esito,motivo)
 values(p_sessione,p_messaggio_id,p.id,esito,motivo)
 on conflict(sessione,messaggio_id) do update set pratica_id=excluded.pratica_id,esito=excluded.esito,motivo=excluded.motivo,updated_at=now()
 where public.keplero_verifiche_originali.esito='da_verificare';
end; $function$;

CREATE OR REPLACE FUNCTION public.conferma_ordine_da_keplero(p_pratica_id uuid, p_external_key text, p_messaggio_cliente text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_prima public.pratiche%rowtype;
  v_dopo public.pratiche%rowtype;
begin
  if lower(coalesce(p_messaggio_cliente,'')) ~ '\mnon\M.{0,50}\m(scelt[oa]|decis[oa])\M'
    or (lower(coalesce(p_messaggio_cliente,'')) ~ '\m(cliente|proprietario|officina)[[:space:]]+ha[[:space:]]+scelto\M'
       and not private.scelta_conclusa_cliente(p_messaggio_cliente)) then
    return jsonb_build_object('aggiornato',false,'motivo','scelta_riferita_non_conclusa','pratica_id',p_pratica_id);
  end if;

  if private.preferenza_senza_conferma(p_messaggio_cliente) or lower(coalesce(p_messaggio_cliente,'')) ~ '\m(se|qualora)\M.{0,80}(possibil|riparabil|disponib)' then
    return jsonb_build_object('aggiornato',false,'motivo','preferenza_non_confermata');
  end if;
  if p_pratica_id is null then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_non_valida');
  end if;

  select *
  into v_prima
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_non_trovata');
  end if;

  if not exists (
    select 1
    from public.keplero_live_links
    where external_key = p_external_key
      and pratica_id = p_pratica_id
  ) then
    return jsonb_build_object('aggiornato', false, 'motivo', 'collegamento_keplero_non_valido');
  end if;

  if coalesce(v_prima.dati_raw #>> '{archiviazione_test,archiviata}', 'false') = 'true'
     or coalesce(v_prima.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') = 'true' then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_archiviata');
  end if;

  if v_prima.blocco_operatore then
    return jsonb_build_object('aggiornato',false,'motivo','blocco_operatore','pratica_id',p_pratica_id);
  end if;
  if exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
    and c.telefono_normalizzato=regexp_replace(coalesce(v_prima.telefono,''),'[^0-9]','','g')) then
    return jsonb_build_object('aggiornato',false,'motivo','contatto_operativo','pratica_id',p_pratica_id);
  end if;

  if private.domanda_su_accettazione(p_messaggio_cliente)
     or private.domanda_su_accettazione(v_prima.dati_raw->>'ultimo_messaggio_cliente') then
    return jsonb_build_object('aggiornato',false,'motivo','domanda_su_accettazione_non_e_ordine','pratica_id',p_pratica_id);
  end if;

  if private.scelta_dispositivo_originale(p_messaggio_cliente) and not exists(
    select 1 from public.scelte_cliente s join public.offerta_opzioni o on o.id=s.opzione_id
    where s.pratica_id=p_pratica_id and s.stato='confermata' and o.servizio in ('RI','RE','RC')) then
    return jsonb_build_object('aggiornato',false,'motivo','lavorazione_originale_da_chiarire','pratica_id',p_pratica_id);
  end if;

  -- I controlli terminali vengono eseguiti prima dei prerequisiti per
  -- mantenere la funzione idempotente anche per le pratiche avanzate a mano.
  if v_prima.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale then
    update public.preventivi
    set
      stato = 'accettato',
      accettato_at = coalesce(accettato_at, v_prima.ordine_acquisito_at, now())
    where pratica_id = p_pratica_id
      and stato = 'inviato' and (not exists(select 1 from public.scelte_cliente s where s.pratica_id=p_pratica_id and s.stato='confermata' and s.offerta_id is not null) or id=(select q.preventivo_id from public.scelte_cliente s join public.offerte_versioni q on q.id=s.offerta_id where s.pratica_id=p_pratica_id));

    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'ordine_gia_acquisito',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  if v_prima.stato_fatturazione = 'fatturato'::public.stato_fatturazione then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'pratica_gia_fatturata',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  -- Una correzione operatore a "Preventivo inviato" è già una prova
  -- sufficiente dell'invio, anche se non esiste un record in preventivi.
  -- Anche un flag/riepilogo positivo può essere errato. Il rinvio espresso
  -- nel messaggio letterale prevale e vale per trigger e chiamata HTTP diretta.
  if private.rinvio_conferma_per_verifiche(coalesce(
    nullif(btrim(p_messaggio_cliente),''),
    v_prima.dati_raw->>'ultimo_messaggio_cliente','')) then
    return jsonb_build_object('aggiornato',false,
      'motivo','cliente_in_verifica_prima_della_conferma','pratica_id',p_pratica_id);
  end if;

  if not exists (
    select 1
    from public.preventivi pv
    where pv.pratica_id = p_pratica_id
      and pv.stato in ('inviato', 'accettato')
  ) and not (
    v_prima.stato_commerciale in (
      'preventivo_inviato'::public.stato_commerciale,
      'attesa_cliente'::public.stato_commerciale
    )
    and v_prima.preventivo_inviato_at is not null
  ) then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'preventivo_non_registrato',
      'pratica_id', p_pratica_id
    );
  end if;

  if v_prima.stato_commerciale not in (
    'da_preventivare'::public.stato_commerciale,
    'preventivo_pronto'::public.stato_commerciale,
    'preventivo_inviato'::public.stato_commerciale,
    'attesa_cliente'::public.stato_commerciale
  ) then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'stato_non_abilitato',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  if
    v_prima.stato_commerciale = 'da_preventivare'::public.stato_commerciale
    and v_prima.stato_completezza <> 'completa_da_preventivare'::public.stato_completezza
  then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'dati_non_completi',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  update public.pratiche
  set
    tipo_flusso = 'commerciale'::public.tipo_flusso,
    stato_commerciale = 'ordine_acquisito'::public.stato_commerciale,
    stato_fatturazione = 'da_fatturare'::public.stato_fatturazione,
    preventivo_inviato_at = coalesce(preventivo_inviato_at, now()),
    ordine_acquisito_at = coalesce(ordine_acquisito_at, now()),
    data_fattura = null,
    blocco_classificazione_operatore = true
  where id = p_pratica_id
    and stato_commerciale in (
      'da_preventivare'::public.stato_commerciale,
      'preventivo_pronto'::public.stato_commerciale,
      'preventivo_inviato'::public.stato_commerciale,
      'attesa_cliente'::public.stato_commerciale
    )
  returning * into v_dopo;

  if not found then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'stato_modificato_contemporaneamente'
    );
  end if;

  update public.preventivi
  set
    stato = 'accettato',
    accettato_at = coalesce(accettato_at, v_dopo.ordine_acquisito_at, now())
  where pratica_id = p_pratica_id
    and stato = 'inviato' and (not exists(select 1 from public.scelte_cliente s where s.pratica_id=p_pratica_id and s.stato='confermata' and s.offerta_id is not null) or id=(select q.preventivo_id from public.scelte_cliente s join public.offerte_versioni q on q.id=s.offerta_id where s.pratica_id=p_pratica_id));

  insert into public.azioni_operatore (
    pratica_id,
    azione,
    nota,
    stato_prima,
    stato_dopo
  )
  values (
    p_pratica_id,
    'keplero_ordine_acquisito',
    case
      when nullif(trim(coalesce(p_messaggio_cliente, '')), '') is null
        then 'Keplero ha rilevato una conferma esplicita dell''ordine/preventivo da parte del cliente.'
      else 'Conferma esplicita rilevata da Keplero: ' || left(trim(p_messaggio_cliente), 1000)
    end,
    to_jsonb(v_prima),
    to_jsonb(v_dopo)
  );

  return jsonb_build_object(
    'aggiornato', true,
    'motivo', 'conferma_esplicita_cliente',
    'pratica_id', p_pratica_id,
    'stato_precedente', v_prima.stato_commerciale,
    'stato_commerciale', v_dopo.stato_commerciale,
    'stato_fatturazione', v_dopo.stato_fatturazione
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.elabora_evento_keplero(p_event_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_evento public.keplero_live_events%rowtype;
begin
 select * into v_evento from public.keplero_live_events where id=p_event_id;
 if not found then raise exception 'Evento non trovato'; end if;
 declare
  v_decisione jsonb := coalesce(v_evento.payload -> 'decisione_sistema', '{}'::jsonb);
  v_versione text := coalesce(
    nullif(v_decisione ->> 'versione_regole', ''),
    'legacy-non-strutturato'
  );
  v_ordine boolean := coalesce(
    (v_decisione #>> '{ordine,confermato}')::boolean,
    (v_evento.payload ->> 'ordine_confermato_rilevato')::boolean,
    false
  );
  v_contesto_ordine jsonb := '{}'::jsonb;
  v_allegati jsonb := '[]'::jsonb;
  v_esito_ordine jsonb := '{}'::jsonb;
  v_esito_allegati jsonb := '{}'::jsonb;
  v_stato text := 'elaborato';
begin
  if v_evento.pratica_id is null then
    v_stato := 'da_verificare';
  end if;

  if v_evento.pratica_id is not null then
    v_contesto_ordine := private.ordine_da_conferma_letterale(v_evento.id);
    if not v_ordine and coalesce(v_contesto_ordine->>'confermato','false')<>'true' then
      v_contesto_ordine := private.ordine_da_scelta_e_fiscali(v_evento.id);
    end if;
    v_ordine := v_ordine or coalesce((v_contesto_ordine->>'confermato')::boolean,false);
  end if;

  if v_evento.pratica_id is not null and v_ordine then
    if coalesce(v_contesto_ordine->>'confermato','false')='true' then
      v_esito_ordine := private.conferma_ordine_evento_verificato(v_evento.id)->'avanzamento';
    else
    v_esito_ordine := public.conferma_ordine_da_keplero(
      v_evento.pratica_id,
      v_evento.external_key,
      coalesce(
        v_evento.payload ->> 'ultimo_messaggio_cliente',
        v_evento.payload ->> 'messaggio_cliente',
        v_evento.payload ->> 'messaggio'
      )
    );

    end if;

    if coalesce(v_esito_ordine ->> 'motivo', '') in (
      'preventivo_non_registrato',
      'collegamento_keplero_non_valido',
      'stato_non_abilitato',
      'dati_non_completi'
    ) then
      v_stato := 'da_verificare';
    end if;
  end if;

  with sorgenti as (
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'allegati') = 'array'
          then v_evento.payload -> 'allegati'
        when jsonb_typeof(v_evento.payload -> 'allegati') = 'string'
          then jsonb_build_array(v_evento.payload -> 'allegati')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'attachments') = 'array'
          then v_evento.payload -> 'attachments'
        when jsonb_typeof(v_evento.payload -> 'attachments') = 'string'
          then jsonb_build_array(v_evento.payload -> 'attachments')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'attachment_urls') = 'array'
          then v_evento.payload -> 'attachment_urls'
        when jsonb_typeof(v_evento.payload -> 'attachment_urls') = 'string'
          then jsonb_build_array(v_evento.payload -> 'attachment_urls')
        else '[]'::jsonb
      end
    ) elemento
  ), valori as (
    select case
      when jsonb_typeof(elemento) = 'object' then elemento ->> 'url'
      when jsonb_typeof(elemento) = 'string' then elemento #>> '{}'
      else null
    end valore
    from sorgenti
  ), url as (
    select distinct (regexp_match(valore, 'https?://[^[:space:]<>"]+'))[1] valore
    from valori
    where valore ~ 'https?://'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'url', valore,
    'tipo', case when lower(valore) ~ '[.]pdf([?]|$)' then 'PDF' else 'Allegato' end
  )), '[]'::jsonb)
  into v_allegati
  from url
  where valore is not null;

  if v_evento.pratica_id is not null and jsonb_array_length(v_allegati) > 0 then
    v_esito_allegati := public.sincronizza_allegati_keplero(
      v_evento.pratica_id,
      v_allegati
    );
  elsif v_evento.pratica_id is not null and (
    coalesce(v_evento.payload ->> 'stato_lettura_immagini', '') = 'file_non_trasmessi_da_keplero'
    or coalesce(v_evento.payload ->> 'allegati_descritti_ma_non_trasmessi', 'false') = 'true'
  ) then
    v_stato := 'da_verificare';
  end if;

  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore,
    tentativi, elaborato_at, updated_at
  ) values (
    v_evento.id, v_evento.pratica_id, v_versione, v_stato,
    jsonb_build_object(
      'decisione_ricevuta', v_decisione,
      'esito_ordine', v_esito_ordine,
      'contesto_ordine', v_contesto_ordine,
      'esito_allegati', v_esito_allegati,
      'numero_allegati_url', jsonb_array_length(v_allegati)
    ),
    null, 1, now(), now()
  )
  on conflict (event_id) do update set
    pratica_id = excluded.pratica_id,
    versione_regole = excluded.versione_regole,
    stato = excluded.stato,
    decisione = excluded.decisione,
    errore = null,
    tentativi = private.keplero_event_processing.tentativi + 1,
    elaborato_at = now(),
    updated_at = now();

  return;
exception when others then
  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore
  ) values (
    v_evento.id, v_evento.pratica_id, v_versione, 'errore', v_decisione, sqlerrm
  )
  on conflict (event_id) do update set
    stato = 'errore',
    errore = excluded.errore,
    tentativi = private.keplero_event_processing.tentativi + 1,
    updated_at = now();

  return;
end;

end;
$function$;

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
  v_risposta_breve:=v_risposta_breve or private.scelta_dispositivo_originale(t);
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
  if private.scelta_dispositivo_originale(t) then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids) and servizio in ('RI','RE','RC');
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

notify pgrst,'reload schema';
commit;

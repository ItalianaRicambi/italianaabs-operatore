-- Correzione circoscritta all'importazione di un documento verificato.
-- Nessun aggiornamento massivo delle pratiche; nessun bypass dei blocchi.
CREATE OR REPLACE FUNCTION public.registra_documento_amministrativo_verificato(p_pratica_id uuid, p_documento jsonb, p_operatore text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  p public.pratiche%rowtype; d public.documenti_amministrativi%rowtype;
  c jsonb; candidato uuid; totale integer; chiave text; tipo text; numero text;
  data_doc date; importo_doc numeric; iva text; cf text; r jsonb; precedente jsonb;
begin
  if p_operatore is null or p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4','Manutenzione autorizzata')
    or coalesce(p_documento->>'verificata','false')<>'true' then raise exception 'Verifica del documento e operatore richiesti'; end if;
  select * into p from public.pratiche where id=p_pratica_id for update;
  if not found then raise exception 'Pratica non trovata'; end if;
  if p.stato_commerciale<>'ordine_acquisito' or p.tipo_flusso<>'commerciale'
    or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
    or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then
    raise exception 'Il documento richiede un ordine commerciale attivo';
  end if;
  if nullif(regexp_replace(upper(p_documento->>'targa'),'[^A-Z0-9]','','g'),'') is null
    or regexp_replace(upper(p_documento->>'targa'),'[^A-Z0-9]','','g')
      is distinct from regexp_replace(upper(p.targa),'[^A-Z0-9]','','g') then raise exception 'Targa documento diversa dalla pratica'; end if;
  tipo:=p_documento->>'tipo'; numero:=nullif(btrim(p_documento->>'numero'),'');
  data_doc:=(p_documento->>'data')::date; importo_doc:=(p_documento->>'importo')::numeric;
  if tipo is null or tipo not in ('fattura','proforma') or numero is null or length(numero)>80
    or data_doc is null or data_doc>(now() at time zone 'Europe/Rome')::date or importo_doc is null or importo_doc<=0
    or coalesce(p_documento->>'impronta','')!~'^[0-9a-f]{64}$' then raise exception 'Riferimenti documento incompleti o non validi'; end if;
  chiave:=tipo||':'||numero||':'||data_doc::text;
  perform pg_advisory_xact_lock(hashtextextended('documento_amministrativo:'||chiave,0));
  select * into d from public.documenti_amministrativi where provider='documento_verificato' and external_document_id=chiave;
  if found then
    if d.pratica_id<>p.id or d.importo is distinct from importo_doc then raise exception 'Documento già registrato con un collegamento o importo diverso'; end if;
    return jsonb_build_object('esito','gia_registrato','documento_id',d.id,'tipo',d.tipo_documento);
  end if;
  precedente:=to_jsonb(p);
  c:=p_documento->'cliente';
  iva:=upper(regexp_replace(coalesce(c->>'partita_iva',''),'[^A-Za-z0-9]','','g'));
  cf:=upper(regexp_replace(coalesce(c->>'codice_fiscale',''),'[^A-Za-z0-9]','','g'));
  if nullif(btrim(c->>'denominazione'),'') is null or nullif(btrim(c->>'indirizzo_fatturazione'),'') is null
    or nullif(btrim(c->>'cap'),'') is null or nullif(btrim(c->>'comune'),'') is null
    or nullif(btrim(c->>'paese'),'') is null or (iva='' and cf='') then raise exception 'Anagrafica del documento incompleta'; end if;
  if iva<>'' then perform pg_advisory_xact_lock(hashtextextended('cliente_iva:'||iva,0)); end if;
  if cf<>'' then perform pg_advisory_xact_lock(hashtextextended('cliente_cf:'||cf,0)); end if;
  -- Un ordine recuperato può essere acquisito senza aver ancora aperto la
  -- fatturazione. Il documento già validato autorizza questo passaggio, non
  -- una promozione commerciale: anagrafica e documento restano atomici.
  -- I trigger possono collegare/creare un cliente: rileggere prima del match
  -- fiscale evita duplicati e mantiene i controlli sul destinatario.
  if p.stato_fatturazione='non_applicabile' then
    update public.pratiche set stato_fatturazione='da_fatturare' where id=p.id;
    select * into p from public.pratiche where id=p.id;
    if p.stato_fatturazione<>'da_fatturare' then
      raise exception 'Ordine non disponibile per la registrazione del documento';
    end if;
  end if;
  select count(*),min(id::text)::uuid into totale,candidato from public.clienti
    where (iva<>'' and partita_iva_normalizzata=iva) or (cf<>'' and codice_fiscale_normalizzato=cf);
  if totale>1 then raise exception 'Più anagrafiche fiscali compatibili: verifica operatore richiesta'; end if;
  if candidato is not null and exists(select 1 from public.clienti where id=candidato and (
    (iva<>'' and coalesce(partita_iva_normalizzata,'')<>'' and partita_iva_normalizzata<>iva)
    or (cf<>'' and coalesce(codice_fiscale_normalizzato,'')<>'' and codice_fiscale_normalizzato<>cf))) then
    raise exception 'Identificativi fiscali discordanti'; end if;
  if (p.cliente_id is not null and (candidato is null or p.cliente_id<>candidato))
    or (precedente->>'cliente_id' is not null
      and (candidato is null or (precedente->>'cliente_id')::uuid<>candidato)) then
    raise exception 'Il destinatario fiscale non coincide con il cliente già collegato';
  end if;
  if p.stato_fatturazione='fatturato' then
    if candidato is null then raise exception 'Per il documento storico collegare prima il cliente fiscale'; end if;
  elsif candidato is null then
    r:=public.crea_e_collega_cliente_pratica(p.id,c->>'denominazione',c->>'indirizzo_fatturazione',c->>'comune',c->>'cap',
      c->>'provincia',c->>'paese',nullif(iva,''),nullif(cf,''),p.email_cliente,p.telefono,c->>'pec',c->>'codice_sdi');
    candidato:=(r->>'cliente_id')::uuid;
  else
    perform public.collega_cliente_pratica(p.id,candidato);
  end if;
  if private.verifica_dati_cliente_fatturazione(candidato)->>'completi'<>'true' then
    raise exception 'Anagrafica fiscale incompleta o da verificare';
  end if;
  if p.stato_fatturazione<>'fatturato' then
    perform public.gestisci_sospensione_fatturazione(p.id,false,p_operatore);
  end if;
  insert into public.documenti_amministrativi(pratica_id,provider,external_document_id,tipo_documento,numero_documento,
    data_documento,importo,stato,documento_url,dati_raw)
  values(p.id,'documento_verificato',chiave,tipo,numero,data_doc,importo_doc,'emessa',
    nullif(p_documento->>'documento_url',''),
    jsonb_build_object('verificata',true,'operatore',p_operatore,'targa',p_documento->>'targa',
      'impronta',p_documento->>'impronta','fonte_id',p_documento->>'fonte_id',
      'precisione_data','giorno','testo_documento',left(p_documento->>'testo_documento',30000))) returning * into d;
  perform public.prepara_richiesta_dati_amministrativi(p.id);
  select * into p from public.pratiche where id=p.id;
  if tipo='fattura' and p.stato_fatturazione<>'fatturato' then raise exception 'Fattura non allineata: nessuna modifica applicata'; end if;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
    values(p.id,'documento_amministrativo_verificato',tipo||' '||numero||' del '||data_doc::text,
      precedente,to_jsonb(p),p_operatore);
  return jsonb_build_object('esito',case when tipo='fattura' then 'fatturata' else 'proforma_registrata' end,
    'documento_id',d.id,'cliente_id',candidato,'tipo',tipo);
end; $function$
;

revoke all on function public.registra_documento_amministrativo_verificato(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.registra_documento_amministrativo_verificato(uuid,jsonb,text) to service_role;
notify pgrst, 'reload schema';

-- Percorso separato dalla registrazione ordinaria: una fattura originale può
-- attestare un ordine rimasto erroneamente a preventivo. Mai una pro-forma.
-- Nessun backfill automatico, nessun invio e nessuna rimozione dei blocchi.
create function public.riconcilia_fattura_episodio_verificato(
  p_pratica_id uuid, p_documento jsonb, p_verifica jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  p public.pratiche%rowtype; d public.documenti_amministrativi%rowtype;
  prima jsonb; r jsonb; data_doc date; targa_doc text; testo text; iva text; cf text;
begin
  select * into p from public.pratiche where id=p_pratica_id for update;
  if not found then raise exception 'Pratica non trovata'; end if;
  if p_documento->>'tipo' is distinct from 'fattura'
    or p_documento->>'verificata' is distinct from 'true'
    or p_verifica->>'episodio_verificato' is distinct from 'true'
    or nullif(btrim(p_verifica->>'motivazione'),'') is null
    or coalesce(p_documento->>'fonte_id','') not like 'drive:%'
    or coalesce(p_documento->>'documento_url','') not like 'https://drive.google.com/%'
  then raise exception 'Fattura originale e verifica episodio richieste'; end if;
  testo:=btrim(replace(replace(p_documento->>'testo_documento',chr(13),''),chr(160),' '));
  if testo is null or length(testo)<100 or length(testo)>200000
    or p_documento->>'impronta' is distinct from encode(sha256(convert_to(testo,'UTF8')),'hex')
    or testo !~* '^Fattura[[:space:]]+nr[.]'
    or testo !~ 'P[.]IVA:[[:space:]]*02439670031'
  then raise exception 'Testo originale o impronta non validi'; end if;
  data_doc:=(p_documento->>'data')::date;
  targa_doc:=regexp_replace(upper(p_documento->>'targa'),'[^A-Z0-9]','','g');
  if nullif(targa_doc,'') is null or targa_doc is distinct from regexp_replace(upper(p.targa),'[^A-Z0-9]','','g')
    or data_doc is null or data_doc<(p.created_at at time zone 'Europe/Rome')::date
    or data_doc>(now() at time zone 'Europe/Rome')::date then
    raise exception 'Targa o cronologia episodio non compatibili'; end if;
  -- Replay: non creare un secondo documento, né correggere silenziosamente
  -- una revisione o un documento attribuito a un altro episodio/provider.
  perform pg_advisory_xact_lock(hashtextextended('documento_amministrativo:fattura:'||
    (p_documento->>'numero')||':'||data_doc::text,0));
  select * into d from public.documenti_amministrativi
    where tipo_documento='fattura' and numero_documento=p_documento->>'numero' and data_documento=data_doc
    order by created_at limit 1;
  if found then
    if d.pratica_id<>p.id or d.importo is distinct from (p_documento->>'importo')::numeric
      or d.stato is distinct from 'emessa' or p.stato_fatturazione<>'fatturato'
      or (d.dati_raw->>'impronta' is not null and d.dati_raw->>'impronta' is distinct from p_documento->>'impronta')
    then raise exception 'Documento presente con collegamento, revisione o stato da verificare'; end if;
    return jsonb_build_object('esito','gia_registrato','documento_id',d.id,'tipo','fattura');
  end if;
  if p_verifica->>'stato_commerciale_atteso' is distinct from p.stato_commerciale::text
    or p_verifica->>'stato_fatturazione_atteso' is distinct from p.stato_fatturazione::text then
    raise exception 'Pratica cambiata dopo la verifica'; end if;
  if p.tipo_flusso<>'commerciale' or p.stato_commerciale not in ('preventivo_inviato','ordine_acquisito')
    or p.blocco_operatore
    or coalesce(p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}','false')='true'
    or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
    or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true'
    or exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
      and c.telefono_normalizzato=regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g'))
  then raise exception 'Pratica o blocco operatore da verificare'; end if;
  if exists(select 1 from public.pratiche x where x.id<>p.id and x.tipo_flusso='commerciale'
    and regexp_replace(upper(x.targa),'[^A-Z0-9]','','g')=targa_doc
    and (x.created_at at time zone 'Europe/Rome')::date<=data_doc
    and coalesce(x.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
    and coalesce(x.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true') then
    raise exception 'Più episodi per la stessa targa: verifica manuale richiesta'; end if;
  iva:=regexp_replace(upper(regexp_replace(coalesce(p_documento#>>'{cliente,partita_iva}',''),'[^A-Za-z0-9]','','g')),'^IT(?=[0-9]{11}$)','');
  cf:=upper(regexp_replace(coalesce(p_documento#>>'{cliente,codice_fiscale}',''),'[^A-Za-z0-9]','','g'));
  if (nullif(p.dati_raw#>>'{anagrafica_estratta,partita_iva}','') is not null
      and iva is distinct from regexp_replace(upper(regexp_replace(p.dati_raw#>>'{anagrafica_estratta,partita_iva}','[^A-Za-z0-9]','','g')),'^IT(?=[0-9]{11}$)',''))
    or (nullif(p.dati_raw#>>'{anagrafica_estratta,codice_fiscale}','') is not null
      and cf is distinct from upper(regexp_replace(p.dati_raw#>>'{anagrafica_estratta,codice_fiscale}','[^A-Za-z0-9]','','g')))
  then raise exception 'Identificativi fiscali acquisiti discordanti dal documento'; end if;
  prima:=to_jsonb(p);
  if p.stato_commerciale='preventivo_inviato' then
    -- Mantiene classificazione protetta e dati tecnici. La fattura originale,
    -- non il riconoscitore di conferme, è la prova del recupero amministrativo.
    update public.pratiche set stato_commerciale='ordine_acquisito',
      ordine_acquisito_at=coalesce(ordine_acquisito_at,data_doc::timestamp at time zone 'Europe/Rome')
      where id=p.id;
  end if;
  r:=public.registra_documento_amministrativo_verificato(p.id,p_documento,'Manutenzione autorizzata');
  if not exists(select 1 from public.pratiche where id=p.id and stato_fatturazione='fatturato') then
    raise exception 'Riconciliazione non completata'; end if;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
    values(p.id,'fattura_episodio_riconciliata',left(p_verifica->>'motivazione',4000),prima,
      (select to_jsonb(x) from public.pratiche x where id=p.id),'Manutenzione autorizzata');
  return r;
end;
$$;
revoke all on function public.riconcilia_fattura_episodio_verificato(uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.riconcilia_fattura_episodio_verificato(uuid,jsonb,jsonb) to service_role;
notify pgrst,'reload schema';

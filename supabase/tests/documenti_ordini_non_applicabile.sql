-- Fixture sintetiche: nessun documento reale, nessuna scrittura persistente.
begin;
set local role service_role;
do $test$
declare
  p uuid; p2 uuid; p3 uuid; cid uuid; d jsonb; r jsonb; prima jsonb;
  tipo text; n integer; totale integer;
begin
  d:=jsonb_build_object('verificata',true,'tipo','proforma','numero','REGRESSION-NA-P','data',current_date,
    'targa','TNA0001','importo',397,'impronta',repeat('b',64),
    'cliente',jsonb_build_object('denominazione','Test importazione non applicabile',
      'indirizzo_fatturazione','Via Test 10','comune','Roma','cap','00123','paese','IT',
      'codice_fiscale','TSTFSC82A01F952A'));
  select count(*) into totale from public.clienti;
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione,
    blocco_operatore,blocco_classificazione_operatore,campi_bloccati_operatore,ritiro_programmato_at)
    values('TNA0001','Test non applicabile','commerciale','ordine_acquisito','non_applicabile',
      true,true,array['targa','descrizione_guasto'],now()) returning id into p;
  select to_jsonb(x) into prima from public.pratiche x where id=p;
  begin
    perform public.registra_documento_amministrativo_verificato(p,d||'{"targa":"ERRATA"}', 'Operatore 1');
    raise exception 'TEST: targa errata accettata';
  exception when others then
    if sqlerrm<>'Targa documento diversa dalla pratica' then raise;end if;
  end;
  if (select to_jsonb(x) from public.pratiche x where id=p) is distinct from prima then
    raise exception 'TEST: pratica modificata dopo rifiuto';end if;
  r:=public.registra_documento_amministrativo_verificato(p,d,'Operatore 1');
  select cliente_id into cid from public.pratiche where id=p;
  if r->>'esito'<>'proforma_registrata' or not exists(select 1 from public.pratiche where id=p
    and stato_fatturazione='da_fatturare' and data_fattura is null and stato_amministrativo='pronto_fatturazione'
    and blocco_operatore and blocco_classificazione_operatore and campi_bloccati_operatore=array['targa','descrizione_guasto']
    and ritiro_programmato_at=(prima->>'ritiro_programmato_at')::timestamptz)
    or (select count(*) from public.clienti)<>totale+1 then raise exception 'TEST: recupero proforma errato';end if;
  if not exists(select 1 from public.azioni_operatore where pratica_id=p and azione='documento_amministrativo_verificato'
    and stato_prima->>'stato_fatturazione'='non_applicabile' and stato_dopo->>'stato_fatturazione'='da_fatturare') then
    raise exception 'TEST: manca audit stato originale';end if;
  r:=public.registra_documento_amministrativo_verificato(p,d,'Operatore 1');
  if r->>'esito'<>'gia_registrato' or (select count(*) from public.documenti_amministrativi where pratica_id=p)<>1
    or (select count(*) from public.clienti)<>totale+1 then raise exception 'TEST: retry duplicato';end if;

  -- Cliente già esistente: la normalizzazione non deve crearne un altro.
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione)
    values('TNA0002','Test fattura','commerciale','ordine_acquisito','non_applicabile') returning id into p2;
  r:=public.registra_documento_amministrativo_verificato(p2,d||jsonb_build_object('targa','TNA0002',
    'tipo','fattura','numero','REGRESSION-NA-F'), 'Operatore 2');
  if r->>'esito'<>'fatturata' or not exists(select 1 from public.pratiche where id=p2
    and stato_fatturazione='fatturato' and cliente_id=cid and data_fattura is not null)
    or (select count(*) from public.clienti)<>totale+1 then raise exception 'TEST: fattura o riuso cliente errati';end if;

  -- Errore DOPO la normalizzazione: rollback anche di stato, trigger e audit.
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione,cliente_id,fonte_collegamento_cliente)
    values('TNA0003','Test conflitto','commerciale','ordine_acquisito','non_applicabile',cid,'operatore') returning id into p3;
  select to_jsonb(x) into prima from public.pratiche x where id=p3;
  select count(*) into n from public.eventi_pratica where pratica_id=p3;
  begin
    perform public.registra_documento_amministrativo_verificato(p3,d||jsonb_build_object('targa','TNA0003',
      'numero','REGRESSION-NA-CONFLICT','cliente',(d->'cliente')||'{"codice_fiscale":"TSTFSC83A01F952A"}'), 'Operatore 1');
    raise exception 'TEST: destinatario discordante accettato';
  exception when others then
    if sqlerrm<>'Il destinatario fiscale non coincide con il cliente già collegato' then raise;end if;
  end;
  if (select to_jsonb(x) from public.pratiche x where id=p3) is distinct from prima
    or (select count(*) from public.eventi_pratica where pratica_id=p3)<>n
    or exists(select 1 from public.documenti_amministrativi where pratica_id=p3)
    or (select count(*) from public.clienti)<>totale+1 then raise exception 'TEST: rollback incompleto';end if;

  -- Un preventivo non è promosso dall'importazione; fatture storiche non regrediscono.
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione)
    values('TNA0004','Test preventivo','commerciale','preventivo_inviato','non_applicabile') returning id into p3;
  begin
    perform public.registra_documento_amministrativo_verificato(p3,d||jsonb_build_object('targa','TNA0004','numero','REGRESSION-NA-QUOTE'), 'Operatore 1');
    raise exception 'TEST: preventivo promosso';
  exception when others then
    if sqlerrm<>'Il documento richiede un ordine commerciale attivo' then raise;end if;
  end;
  r:=public.registra_documento_amministrativo_verificato(p2,d||jsonb_build_object('targa','TNA0002','numero','REGRESSION-NA-HISTORY'), 'Operatore 1');
  if not exists(select 1 from public.pratiche where id=p2 and stato_fatturazione='fatturato' and data_fattura is not null)
    then raise exception 'TEST: fattura storica regredita';end if;
end;
$test$;
rollback;

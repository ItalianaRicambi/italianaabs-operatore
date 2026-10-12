begin;
set local role service_role;
do $test$
declare p uuid; p2 uuid; p3 uuid; r jsonb; d jsonb; n integer;
begin
  if has_function_privilege('anon','public.registra_documento_amministrativo_verificato(uuid,jsonb,text)','execute')
    or has_function_privilege('authenticated','public.crea_e_conferma_cliente_pratica(uuid,jsonb,text)','execute') then
    raise exception 'RPC amministrative accessibili pubblicamente';
  end if;
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione)
    values('TADM001','Documento test','commerciale','ordine_acquisito','da_fatturare') returning id into p;
  perform public.gestisci_sospensione_fatturazione(p,true,'Operatore 1');
  d:=jsonb_build_object('verificata',true,'tipo','fattura','numero','TEST-ADM-1/2026','data',current_date,
    'targa','TADM001','importo',402.30,'impronta',repeat('a',64),
    'cliente',jsonb_build_object('denominazione','Cliente test','indirizzo_fatturazione','Via Test 10','comune','Roma',
      'cap','00123','paese','IT','codice_fiscale','TSTFSC80A01F952A'));
  begin
    perform public.registra_documento_amministrativo_verificato(p,d||'{"targa":"DIVERSA"}', 'Operatore 1');
    raise exception 'Targa diversa accettata';
  exception when others then if sqlerrm='Targa diversa accettata' then raise; end if; end;
  if exists(select 1 from public.documenti_amministrativi where pratica_id=p)
    or exists(select 1 from public.pratiche where id=p and cliente_id is not null) then raise exception 'Modifica parziale su targa errata'; end if;
  r:=public.registra_documento_amministrativo_verificato(p,d,'Operatore 1');
  if r->>'esito'<>'fatturata' or not exists(select 1 from public.pratiche where id=p and stato_fatturazione='fatturato'
    and stato_amministrativo='completato' and (data_fattura at time zone 'Europe/Rome')::date=current_date
    and dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='false') then raise exception 'Fattura non allineata'; end if;
  if public.registra_documento_amministrativo_verificato(p,d,'Operatore 1')->>'esito'<>'gia_registrato'
    or (select count(*) from public.documenti_amministrativi where pratica_id=p)<>1 then raise exception 'Documento duplicato'; end if;
  update public.pratiche set stato_commerciale='raccolta_dati',stato_fatturazione='non_applicabile' where id=p;
  if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='fatturato') then raise exception 'Fattura regredita'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione)
    values('TADM002','Proforma test','commerciale','ordine_acquisito','da_fatturare') returning id into p2;
  perform public.gestisci_sospensione_fatturazione(p2,true,'Operatore 2');
  r:=public.registra_documento_amministrativo_verificato(p2,d||jsonb_build_object('tipo','proforma','numero','TEST-ADM-2/2026','targa','TADM002'), 'Operatore 2');
  if r->>'esito'<>'proforma_registrata' or not exists(select 1 from public.pratiche where id=p2
    and stato_fatturazione='da_fatturare' and data_fattura is null and stato_amministrativo='pronto_fatturazione'
    and stato_richiesta_amministrativa='completata') then raise exception 'Proforma trattata come fattura o dati ancora mancanti'; end if;
  if (select cliente_id from public.pratiche where id=p) is distinct from (select cliente_id from public.pratiche where id=p2) then raise exception 'Cliente fiscale duplicato'; end if;
  begin
    perform public.registra_documento_amministrativo_verificato(p2,d||jsonb_build_object('targa','TADM002'), 'Operatore 1');
    raise exception 'Stessa fattura su altra pratica accettata';
  exception when others then if sqlerrm='Stessa fattura su altra pratica accettata' then raise; end if; end;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione)
    values('TADM003','Anagrafica test','commerciale','ordine_acquisito','da_fatturare') returning id into p3;
  perform public.gestisci_sospensione_fatturazione(p3,true,'Operatore 3');
  r:=public.crea_e_conferma_cliente_pratica(p3,jsonb_build_object('verificata',true,'denominazione','Altro cliente test',
    'indirizzo_fatturazione','Via Esempio 1','comune','Roma','cap','00123','paese','IT','codice_fiscale','TSTFSC81A01F952A'), 'Operatore 3');
  if r->>'esito'<>'pronto_fatturazione' or not exists(select 1 from public.pratiche where id=p3 and cliente_id is not null
    and stato_amministrativo='pronto_fatturazione' and dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='false') then raise exception 'Conferma dati non ha riabilitato la fatturazione'; end if;
end; $test$;
rollback;

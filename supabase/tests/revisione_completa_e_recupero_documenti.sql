begin;
set local role service_role;
do $test$
declare p uuid; d uuid; p2 uuid; p3 uuid; p4 uuid; r jsonb; c jsonb; v jsonb; dati jsonb;
 prima jsonb; dopo jsonb; a bigint; opt uuid; f uuid;
begin
 c:=jsonb_build_object('impronta',repeat('c',64),'testo','Originale di collaudo, revisione completa ABS FTE, condizioni e limitazioni conservate.',
  'errore','Alternative e prezzi non identificati nel PDF','opzioni','[]'::jsonb,'fonte','pdf','validita_giorni',15);
 v:=c||jsonb_build_object('errore',null,'opzioni',jsonb_build_array(jsonb_build_object('numero',1,'numero_esplicito',false,
  'servizio','RC','descrizione','Revisione completa ABS servoassistito FTE','importo',1247,'iva_inclusa',true,
  'valuta','EUR','condizioni','Dispositivo manomesso: lavorazione NON in garanzia.','reso_vecchio',false)));
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTRC01','Collaudo revisione completa','commerciale','da_preventivare',now()-interval '1 day') returning id into p;
 dati:=jsonb_build_object('external_id','test:rc:originale','nome_file','TSTRC01.pdf','targa','TSTRC01',
  'file_url','https://example.invalid/originale.pdf','data_offerta',now()-interval '1 hour','contenuto',c,'sha256_pdf',repeat('d',64));
 r:=public.registra_documento_preventivo_auto(dati); d:=(r->>'documento_id')::uuid;
 select to_jsonb(x) into prima from public.pratiche x where id=p;
 update public.pratiche set stato_commerciale='preventivo_inviato',preventivo_inviato_at=now(),blocco_classificazione_operatore=true where id=p;
 select to_jsonb(x) into dopo from public.pratiche x where id=p;
 insert into public.azioni_operatore(pratica_id,azione,nota,operatore,stato_prima,stato_dopo)
 values(p,'operatore_correzione_stato','Preventivo inviato','Operatore 1',prima,dopo) returning id into a;
 if exists(select 1 from public.preventivi where pratica_id=p) then raise exception 'Lettura fallita marcata inviata'; end if;
 if not exists(select 1 from public.documenti_preventivo_auto where id=d and stato='da_verificare' and fonte_invio_id='operatore:'||a)
  then raise exception 'Conferma operatore persa durante errore parser'; end if;
 begin
  perform public.registra_documento_preventivo_auto(dati||jsonb_build_object('contenuto',v||'{"testo":"Originale sostituito"}'));
  raise exception 'TEST: originale diverso accettato';
 exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
 begin
  perform public.registra_documento_preventivo_auto(dati||jsonb_build_object('contenuto',v,'sha256_pdf',repeat('e',64)));
  raise exception 'TEST: PDF diverso accettato';
 exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
 r:=public.registra_documento_preventivo_auto(dati||jsonb_build_object('contenuto',v));
 if r->>'esito'<>'inviato' then raise exception 'Documento originale non recuperato: %',r; end if;
 if (select count(*) from public.preventivi where pratica_id=p)<>1 then raise exception 'Preventivo mancante o duplicato'; end if;
 if not exists(select 1 from public.offerte_versioni q join public.offerta_opzioni o on o.offerta_id=q.id
  where q.pratica_id=p and o.servizio='RC' and o.importo=1247 and o.iva_inclusa and not o.reso_vecchio
  and o.condizioni like '%NON in garanzia%') then raise exception 'Offerta FTE persa o classificata RI/RE/PS'; end if;
 if exists(select 1 from public.pratiche where id=p and (stato_commerciale<>'preventivo_inviato' or stato_fatturazione<>'non_applicabile' or not blocco_classificazione_operatore))
  or exists(select 1 from public.scelte_cliente where pratica_id=p) then raise exception 'Offerta trasformata in ordine/scelta o correzione persa'; end if;
 perform public.registra_documento_preventivo_auto(dati||jsonb_build_object('contenuto',jsonb_set(v,'{opzioni,0,importo}','999')));
 if (select count(*) from public.offerte_versioni where pratica_id=p)<>1
  or exists(select 1 from public.offerte_versioni q join public.offerta_opzioni o on o.offerta_id=q.id where q.pratica_id=p and o.importo<>1247)
  then raise exception 'Retry riscrive prezzo o duplica versione'; end if;
 -- Documento arrivato dopo la conferma umana: stesso risultato, senza secondo clic.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at,created_at)
 values('TSTRC02','Collaudo arrivo tardivo','commerciale','preventivo_inviato',now(),now()-interval '1 day') returning id into p2;
 insert into public.azioni_operatore(pratica_id,azione,nota,operatore) values(p2,'commerciale_preventivo_inviato','Collaudo','Operatore 2');
 r:=public.registra_documento_preventivo_auto(dati||jsonb_build_object('external_id','test:rc:tardivo','nome_file','TSTRC02.pdf','targa','TSTRC02','contenuto',v));
 if r->>'esito'<>'inviato' then raise exception 'PDF tardivo richiede secondo clic: %',r; end if;
 -- Il testo della nota, un operatore assente o una correzione di altra fase non provano un invio.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTRC03','Collaudo prova falsa','commerciale','da_preventivare',now()-interval '1 day') returning id into p3;
 insert into public.azioni_operatore(pratica_id,azione,nota,operatore,stato_prima,stato_dopo)
 values(p3,'operatore_correzione_stato','Preventivo inviato','Operatore 1','{}','{}'),
 (p3,'commerciale_preventivo_inviato','Preventivo inviato',null,'{}','{}');
 r:=public.registra_documento_preventivo_auto(dati||jsonb_build_object('external_id','test:rc:nonconfermato','nome_file','TSTRC03.pdf','targa','TSTRC03','contenuto',v));
 if r->>'esito'<>'pronto' or exists(select 1 from public.preventivi where pratica_id=p3) then raise exception 'Drive o nota usati come prova invio'; end if;
 -- Due documenti pendenti: la conferma non sceglie automaticamente un PDF.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTRC04','Collaudo documenti ambigui','commerciale','da_preventivare',now()-interval '1 day') returning id into p4;
 perform public.registra_documento_preventivo_auto(dati||jsonb_build_object('external_id','test:rc:ambiguo1','nome_file','TSTRC04.pdf','targa','TSTRC04','contenuto',v));
 perform public.registra_documento_preventivo_auto(dati||jsonb_build_object('external_id','test:rc:ambiguo2','nome_file','TSTRC04.pdf','targa','TSTRC04','contenuto',v));
 insert into public.azioni_operatore(pratica_id,azione,operatore) values(p4,'commerciale_preventivo_inviato','Operatore 1');
 if exists(select 1 from public.preventivi where pratica_id=p4) then raise exception 'Scelto arbitrariamente un PDF'; end if;
 -- Dopo un consenso esplicito RC, il primo ritiro riguarda la lavorazione originale.
 update public.pratiche set blocco_classificazione_operatore=false where id=p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:rc:scelta',p);
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:rc:scelta',p,'{"targa":"TSTRC01","ultimo_messaggio_cliente":"Preferisco la revisione completa"}',now()+interval '1 second');
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato='preferenza' and servizio='RC') then raise exception 'Preferenza RC persa'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:rc:scelta',p,'{"targa":"TSTRC01","ultimo_messaggio_cliente":"Accetto la revisione completa da € 1.247,00 IVA inclusa"}',now()+interval '2 seconds');
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato='confermata' and servizio='RC' and importo=1247) then raise exception 'Consenso/prezzo RC non riconosciuto'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:rc:scelta',p,'{"targa":"TSTRC01","ultimo_messaggio_cliente":"Il pacco è pronto per il ritiro"}',now()+interval '3 seconds');
 if not exists(select 1 from public.attivita_operatore where pratica_id=p and tipo='ritiro_lavorazione')
  or exists(select 1 from public.attivita_operatore where pratica_id=p and tipo='ritiro_programma_scambio') then raise exception 'Ritiro RC classificato scambio'; end if;
 if private.importo_riferimento_offerta('497.00')<>497 or private.importo_riferimento_offerta('1.247,00')<>1247
  or private.importo_riferimento_offerta('1.247')<>1247 then raise exception 'Conversione importo errata'; end if;
 if has_function_privilege('anon','private.conferma_invio_operatore_valida(public.azioni_operatore)','EXECUTE')
  or has_function_privilege('authenticated','private.collega_documento_a_conferma_operatore(uuid)','EXECUTE') then raise exception 'Funzioni nuove esposte'; end if;
end; $test$;
reset role;
rollback;

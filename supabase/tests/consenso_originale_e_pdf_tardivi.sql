begin;
set local role service_role;
do $test$
declare p uuid; p2 uuid; q uuid; d uuid; c jsonb; r jsonb; frase text; key text:='test:originale:direttiva';
begin
 foreach frase in array array['Ripariamo la nostra','Ok, riparate il nostro ABS.','Revisionate la mia centralina'] loop
  if not private.scelta_dispositivo_originale(frase) or not private.conferma_letterale_offerta(frase) then raise exception 'Direttiva ignorata: %',frase; end if;
 end loop;
 foreach frase in array array['Ripariamo la nostra?','Non ripariamo la nostra','Ripariamo la nostra se possibile','Forse ripariamo la nostra','Ripariamo la nostra, ma prima verifica con il meccanico'] loop
  if private.scelta_dispositivo_originale(frase) or private.conferma_letterale_offerta(frase) then raise exception 'Domanda/condizione confermata: %',frase; end if;
 end loop;
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at,created_at)
 values('TSTOWN1','Test originale con scambio','commerciale','preventivo_inviato',now()-interval '2 hours',now()-interval '1 day') returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values(key,p);
 insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
 values(p,key,'inviato',now()-interval '2 hours',now()-interval '2 hours') returning id into q;
 perform public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","importo":447,"iva_inclusa":true},{"numero":2,"servizio":"PS","importo":547,"iva_inclusa":true},{"numero":3,"servizio":"PSMI","importo":497,"iva_inclusa":true}]','test-originale-direttiva');
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values(key,p,'{"targa":"TSTOWN1","ultimo_messaggio_cliente":"Ripariamo la nostra","ordine_confermato_rilevato":false}');
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and servizio='RI' and stato='confermata' and importo=447)
  or not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare') then raise exception 'Riparazione non selezionata/ordine perso'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload) values(key,p,'{"targa":"TSTOWN1","ultimo_messaggio_cliente":"Il pacco è pronto per il ritiro"}');
 if not exists(select 1 from public.attivita_operatore where pratica_id=p and tipo='ritiro_lavorazione') then raise exception 'Originale classificato scambio'; end if;
 -- Il riferimento al proprio dispositivo non può accettare una sola proposta PS.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TSTOWN2','Test solo scambio','commerciale','preventivo_inviato',now()-interval '1 hour') returning id into p2;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:originale:soloPS',p2);
 insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
 values(p2,'test:originale:soloPS','inviato',now()-interval '1 hour',now()-interval '1 hour') returning id into q;
 perform public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"PS","importo":547}]','test-originale-soloPS');
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:originale:soloPS',p2,'{"targa":"TSTOWN2","ultimo_messaggio_cliente":"Ripariamo la nostra","ordine_confermato_rilevato":true}');
 perform public.conferma_ordine_da_keplero(p2,'test:originale:soloPS','Ripariamo la nostra');
 if exists(select 1 from public.pratiche where id=p2 and stato_commerciale='ordine_acquisito')
  or exists(select 1 from public.v_scelte_cliente where pratica_id=p2 and stato='confermata') then raise exception 'PS accettato come riparazione'; end if;
 -- Più lavorazioni originali richiedono chiarimento: RI e RE non sono intercambiabili.
 perform public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","importo":447},{"numero":2,"servizio":"RE","importo":497}]','test-originale-ambiguo',p_inviato_at=>now());
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:originale:soloPS',p2,'{"targa":"TSTOWN2","ultimo_messaggio_cliente":"Ripariamo la nostra"}');
 if exists(select 1 from public.pratiche where id=p2 and stato_commerciale='ordine_acquisito') then raise exception 'Scelta arbitraria RI/RE'; end if;
 -- PDF recente prima della registrazione della pratica: recupero univoco, senza prova invio.
 c:=jsonb_build_object('opzioni',jsonb_build_array(jsonb_build_object('numero',1,'servizio','RI','importo',447)),
  'testo','Documento di collaudo recente','impronta',repeat('e',64),'errore',null);
 r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','test:pdf:tardivo','nome_file','TSTLATE.pdf','targa','TSTLATE','data_offerta',now()-interval '1 hour','contenuto',c));
 d:=(r->>'documento_id')::uuid;
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
 values('TSTLATE','Test registrazione successiva al PDF','commerciale','da_preventivare') returning id into p2;
 r:=private.abbina_documento_preventivo(d);
 if r->>'esito'<>'pronto' or r->>'pratica_id'<>p2::text or exists(select 1 from public.preventivi where pratica_id=p2) then raise exception 'PDF recente non recuperato o falso invio: %',r; end if;
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
 values('TSTLATE','Test targa ambigua','commerciale','da_preventivare');
 r:=private.abbina_documento_preventivo(d);
 if r->>'pratica_id' is not null then raise exception 'Targa ambigua collegata'; end if;
 -- Un vecchio PDF appena caricato non viene attribuito alla nuova pratica.
 r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','test:pdf:storico','nome_file','TSTOLD.pdf','targa','TSTOLD','data_offerta',now()-interval '90 days','contenuto',c));
 d:=(r->>'documento_id')::uuid;
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
 values('TSTOLD','Test documento vecchio','commerciale','da_preventivare');
 r:=private.abbina_documento_preventivo(d);
 if r->>'pratica_id' is not null then raise exception 'Documento vecchio collegato a nuova vettura'; end if;
 if has_function_privilege('anon','private.scelta_dispositivo_originale(text)','EXECUTE') then raise exception 'Regola privata esposta'; end if;
end $test$;
reset role;
rollback;

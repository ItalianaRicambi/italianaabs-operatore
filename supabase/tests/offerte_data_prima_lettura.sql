begin;
set local role service_role;
do $test$
declare p uuid; q uuid; r jsonb; off uuid; t0 timestamptz:=now()-interval '5 days';
begin
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TSTD001','Test data prima lettura PDF','commerciale','preventivo_inviato',t0) returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:pdf:data-originale',p);
 insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
 values(p,'test:pdf:data-originale','inviato',t0,t0) returning id into q;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:pdf:data-originale',p,'{"targa":"TSTD001","ultimo_messaggio_cliente":"Accetto RI"}',t0+interval '1 hour');
 r:=public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","descrizione":"RI","importo":447,"iva_inclusa":true}]','test-prima-lettura-data',p_inviato_at=>now());
 off:=(r->>'offerta_id')::uuid;
 if not exists(select 1 from public.offerte_versioni where id=off and inviato_at=t0) then raise exception 'Prima lettura ha rinnovato la data storica'; end if;
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato='confermata' and servizio='RI' and offerta_id=off) then raise exception 'Conferma precedente alla lettura PDF non recuperata'; end if;
 r:=public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","descrizione":"RI","importo":447,"iva_inclusa":true}]','test-prima-lettura-data',p_inviato_at=>now());
 if r->>'duplicato'<>'true' or (select count(*) from public.offerte_versioni where preventivo_id=q)<>1 then raise exception 'Retry ha duplicato il PDF'; end if;
 r:=public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","descrizione":"RI","importo":497,"iva_inclusa":true}]','test-revisione-data',p_inviato_at=>now());
 if not exists(select 1 from public.offerte_versioni where id=(r->>'offerta_id')::uuid and inviato_at=now() and versione=2) then raise exception 'Revisione non mantiene la propria data'; end if;
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato='confermata' and offerta_id=off and importo=447 and offerta_successiva) then raise exception 'Revisione ha riscritto il consenso'; end if;
end; $test$;
reset role;
rollback;

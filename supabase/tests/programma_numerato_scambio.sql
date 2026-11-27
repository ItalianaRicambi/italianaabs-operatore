-- Eseguire sul database di collaudo: tutte le scritture vengono annullate.
begin;
set local role service_role;
do $test$
declare p uuid; p_altro uuid; q uuid; r jsonb; op uuid; t0 timestamptz:=now()-interval '2 hours';
 frase text:='BUON POMERIGGIO PER NOI ANDREBBE BENE ANCHE IL PROGRAMMA 2 QUINDI LO SCAMBIO DELLA PARTE';
begin
 if private.programma_numerato_scambio_concluso(frase)<>2
  or not private.conferma_letterale_offerta(frase) then raise exception 'Scelta conclusa non riconosciuta';end if;
 if private.programma_numerato_scambio_concluso(frase||' se disponibile') is not null
  or private.programma_numerato_scambio_concluso('Forse '||frase) is not null
  or private.programma_numerato_scambio_concluso('Per noi andrebbe bene anche il programma 2?') is not null
  then raise exception 'Scelta incerta riconosciuta';end if;
 insert into public.pratiche(nome_cliente,targa,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TEST scambio numerato','TSPS002','commerciale','preventivo_inviato',t0) returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:scambio:numerato',p);
 insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
 values(p,'test:scambio:numerato:offerta','inviato',t0,t0) returning id into q;
 r:=public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","importo":447},{"numero":2,"servizio":"PS","importo":547}]','test:scambio:numerato:impronta');
 select id into op from public.offerta_opzioni where offerta_id=(r->>'offerta_id')::uuid and numero=2;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:scambio:numerato',p,jsonb_build_object('targa','TSPS002','ultimo_messaggio_cliente',frase),t0+interval '10 minutes');
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare')
  or not exists(select 1 from public.scelte_cliente where pratica_id=p and stato='confermata' and opzione_id=op)
  then raise exception 'Scambio numero 2 non collegato e acquisito';end if;

 insert into public.pratiche(nome_cliente,targa,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TEST scambio incoerente','TSPS003','commerciale','preventivo_inviato',t0) returning id into p_altro;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:scambio:incoerente',p_altro);
 insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
 values(p_altro,'test:scambio:incoerente:offerta','inviato',t0,t0) returning id into q;
 perform public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"PS","importo":547},{"numero":2,"servizio":"RI","importo":447}]','test:scambio:incoerente:impronta');
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:scambio:incoerente',p_altro,jsonb_build_object('targa','TSPS003','ultimo_messaggio_cliente',frase),t0+interval '10 minutes');
 if exists(select 1 from public.pratiche where id=p_altro and stato_commerciale='ordine_acquisito')
  or exists(select 1 from public.scelte_cliente where pratica_id=p_altro and stato='confermata')
  then raise exception 'Numero 2 non scambio promosso a ordine';end if;
end $test$;
reset role;
rollback;

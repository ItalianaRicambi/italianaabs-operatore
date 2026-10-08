-- Eseguire come postgres. Tutti i dati di prova vengono annullati.
begin;
set local role service_role;
do $test$
declare
  v_pratica uuid;
  v_result jsonb;
begin
  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:ritenta',
    'TSTQ001.pdf','TSTQ001','https://example.com/quote.pdf',now()-interval '30 minutes',now()-interval '30 minutes');
  if v_result->>'esito'<>'nessuna_pratica_compatibile'
    or not exists(select 1 from public.preventivi_emessi_ricevuti where external_id='test:preventivi:ritenta' and risolto_at is null)
  then raise exception 'PDF senza pratica non persistito'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
  values('TSTQ001','Test rollback','commerciale','raccolta_dati',now())
  returning id into v_pratica;
  update public.preventivi_emessi_ricevuti set ultimo_tentativo_at=now()-interval '5 minutes'
    where external_id='test:preventivi:ritenta';
  perform private.ritenta_preventivi_non_abbinati();
  if not exists(select 1 from public.pratiche where id=v_pratica and stato_commerciale='preventivo_inviato')
    or not exists(select 1 from public.preventivi_emessi_ricevuti where external_id='test:preventivi:ritenta' and risolto_at is not null)
  then raise exception 'Il nuovo tentativo non recupera la pratica arrivata dopo il PDF'; end if;

  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:ritenta',
    'TSTQ001.pdf','TSTQ001','https://example.com/quote.pdf',now(),now());
  if v_result->>'esito'<>'gia_registrato'
    or (select count(*) from public.preventivi where external_id='test:preventivi:ritenta')<>1
  then raise exception 'Idempotenza non rispettata'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
  values('TSTQ002','Test rollback','commerciale','raccolta_dati',now()-interval '1 hour'),
    ('TSTQ002','Test rollback','commerciale','raccolta_dati',now()-interval '1 hour');
  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:ambiguo',
    'TSTQ002.pdf','TSTQ002',null,now(),now());
  if v_result->>'esito'<>'pratica_ambigua'
    or exists(select 1 from public.preventivi where external_id='test:preventivi:ambiguo')
  then raise exception 'Abbinamento ambiguo applicato'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,blocco_classificazione_operatore,created_at)
  values('TSTQ003','Test rollback','commerciale','raccolta_dati',true,now()-interval '1 hour');
  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:bloccato',
    'TSTQ003.pdf','TSTQ003',null,now(),now());
  if v_result->>'esito'<>'blocco_operatore'
    or exists(select 1 from public.preventivi where external_id='test:preventivi:bloccato')
  then raise exception 'Blocco operatore ignorato'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione,created_at)
  values('TSTQ004','Test rollback','commerciale','ordine_acquisito','da_fatturare',now()-interval '1 hour');
  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:ordine',
    'TSTQ004.pdf','TSTQ004',null,now(),now());
  if v_result->>'aggiornato'<>'false'
    or exists(select 1 from public.pratiche where targa='TSTQ004' and stato_commerciale<>'ordine_acquisito')
  then raise exception 'Ordine acquisito modificato'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
  values('TSTQ005','Test rollback','commerciale','da_preventivare',now());
  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:precedente',
    'TSTQ005.pdf','TSTQ005',null,now()-interval '2 days',now()-interval '2 days');
  if v_result->>'aggiornato'<>'false' then raise exception 'Offerta storica assegnata alla nuova pratica'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
  values('TSTQ006','Test rollback','assistenza','raccolta_dati',now()-interval '1 hour');
  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:assistenza',
    'TSTQ006.pdf','TSTQ006',null,now(),now());
  if v_result->>'aggiornato'<>'false' then raise exception 'Assistenza convertita in commerciale'; end if;

  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at,blocco_classificazione_operatore,created_at)
  values('TSTQ007','Test rollback','commerciale','attesa_cliente',now()-interval '30 minutes',true,now()-interval '1 hour');
  v_result:=public.registra_preventivo_emesso_auto('test:preventivi:giaofferta',
    'TSTQ007.pdf','TSTQ007',null,now()-interval '30 minutes',now()-interval '30 minutes');
  if v_result->>'aggiornato'<>'true'
    or exists(select 1 from public.pratiche where targa='TSTQ007' and stato_commerciale<>'attesa_cliente')
  then raise exception 'Il collegamento del documento modifica una fase già confermata'; end if;

  update public.preventivi_emessi_ricevuti set ricevuto_at=now()-interval '15 minutes'
    where external_id='test:preventivi:ambiguo';
end;
$test$;
reset role;
do $test$
begin
  if not exists(select 1 from private.candidati_coerenza_keplero()
    where chiave='pdf_preventivo:test:preventivi:ambiguo')
  then raise exception 'PDF ambiguo non visibile nel controllo'; end if;
end;
$test$;
rollback;

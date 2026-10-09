-- Test sul vero intake e sul cron. Nessun dato di prova viene conservato.
begin;
do $test$
declare v_p uuid; v_event bigint; v_quote timestamptz:=now()-interval '2 hours';
 v_testo text; v_idx integer:=0; v_targa text; v_key text; v_result jsonb;
begin
 foreach v_testo in array array[
  'ok mi sta bene la prima proposta quella di 447',
  'Abbiamo chiarito con l’imperatore gli ultimi dubbi e abbiamo valutato di scegliere l''opzione 1. Nella pratica confermata vorrei applicare il codice sconto coupon. Mi fate sapere quando passerà il corriere a ritirare il pezzo.',
  'Abbiamo scelto l''opzione 2 del preventivo',
  'Ok vorrei revisionare la mia'
 ] loop
  if not private.conferma_letterale_offerta(v_testo) then
   raise exception 'Conferma reale non riconosciuta: %',v_testo; end if;
  v_idx:=v_idx+1; v_targa:='TSTL00'||v_idx; v_key:='test:ordine:letterale:'||v_idx;
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at,created_at)
  values(v_targa,'Test conferma senza anagrafica','commerciale','preventivo_inviato',v_quote,
    v_quote-interval '1 hour')
  returning id into v_p;
  insert into public.keplero_live_links(external_key,pratica_id) values(v_key,v_p);
  insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
  values(v_key,v_p,jsonb_build_object('targa',v_targa,'ultimo_messaggio_cliente',v_testo,
    'decisione_sistema',jsonb_build_object('ordine',jsonb_build_object('confermato',false))),
    now()-interval '20 minutes') returning id into v_event;
  if not exists(select 1 from public.pratiche p where p.id=v_p and stato_commerciale='ordine_acquisito'
    and stato_fatturazione='da_fatturare' and stato_amministrativo<>'pronto_fatturazione'
    and cliente_id is null and ordine_acquisito_at=now()-interval '20 minutes'
    and dati_raw#>>'{conferma_ordine_verificata,event_id}'=v_event::text) then
   raise exception 'Ordine, prova, data o blocco fiscale errati per evento %',v_event; end if;
  perform public.gestisci_sospensione_fatturazione(v_p,true,'Manutenzione autorizzata');
  insert into public.keplero_live_events(external_key,pratica_id,payload)
   values(v_key,v_p,jsonb_build_object('targa',v_targa,
    'ultimo_messaggio_cliente','Mi fate sapere il codice per il ritiro GLS?'));
  v_result:=public.esito_ordine_contestuale_keplero(v_p,v_key);
  if v_result->>'confermato'<>'true' or v_result#>>'{contesto,regola}'<>'conferma_letterale_offerta_v1'
    or public.esito_ordine_contestuale_keplero(v_p,'altra:chat')->>'confermato'<>'false' then
   raise exception 'Messaggio successivo ha perso conferma o esposto altra chat: %',v_result; end if;
  if not exists(select 1 from public.pratiche where id=v_p
    and dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='true'
    and stato_amministrativo<>'pronto_fatturazione') then
   raise exception 'Messaggio successivo ha tolto la sospensione operatore'; end if;
 end loop;

 foreach v_testo in array array['Come accetto l’offerta?','Posso scegliere la prima proposta?',
  'Vorrei sapere se posso scegliere l''opzione 1','Sto valutando l''opzione 1',
  'Preferirei il programma scambio, ma devo chiarire prima alcuni dubbi',
  'Se scegliamo l''opzione 1, quando passate?',
  'Mi sta bene la prima proposta se è possibile riparare il mio pezzo',
  'Non mi sta bene la prima proposta','Non scegliamo l''opzione 1',
  'Vorrei revisionare la mia se è riparabile','Bonifico fatto','Ok grazie',
  'Il cliente ha confermato i codici del dispositivo',
  'Il proprietario ha deciso per la lavorazione ma prima di procedere si confronta con il meccanico'] loop
  if private.conferma_letterale_offerta(v_testo) then
   raise exception 'Domanda, dubbio, dato tecnico o pagamento acquisiti: %',v_testo; end if;
 end loop;

 -- Riproduciamo la perdita storica: evento prima del rilascio, ultimo messaggio GLS.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTL005','Test recupero cron','commerciale','raccolta_dati',v_quote-interval '1 hour') returning id into v_p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:cron-letterale',v_p);
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:ordine:cron-letterale',v_p,'{"targa":"TSTL005","ultimo_messaggio_cliente":"ok mi sta bene la prima proposta quella di 447"}',now()-interval '20 minutes')
 returning id into v_event;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:cron-letterale',v_p,'{"targa":"TSTL005","ultimo_messaggio_cliente":"Codice ritiro GLS?"}');
 update public.pratiche set stato_commerciale='preventivo_inviato',preventivo_inviato_at=v_quote where id=v_p;
 if not exists(select 1 from private.candidati_coerenza_keplero()
   where pratica_id=v_p and regola='scelta_offerta_senza_ordine') then
  raise exception 'Il controllo indipendente non segnala la scelta'; end if;
 perform private.recupera_ordini_contestuali_keplero();
 if not exists(select 1 from public.pratiche where id=v_p and stato_commerciale='ordine_acquisito'
   and ordine_acquisito_at=now()-interval '20 minutes' and stato_amministrativo<>'pronto_fatturazione') then
  raise exception 'Cron non recupera conferma precedente senza dati fiscali'; end if;
 if exists(select 1 from private.candidati_coerenza_keplero()
   where pratica_id=v_p and regola='scelta_offerta_senza_ordine') then
  raise exception 'Segnalazione permane dopo recupero'; end if;

 -- Consenso antecedente all'offerta, targa errata e revoca non confermano.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTL006','Test separazione consenso','commerciale','raccolta_dati',v_quote-interval '1 hour') returning id into v_p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:guardie-letterali',v_p);
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:ordine:guardie-letterali',v_p,'{"targa":"TSTL006","ultimo_messaggio_cliente":"Scelgo la prima proposta"}',now()-interval '20 minutes') returning id into v_event;
 update public.pratiche set stato_commerciale='preventivo_inviato',preventivo_inviato_at=now()-interval '10 minutes' where id=v_p;
 if private.ordine_da_conferma_letterale(v_event)->>'confermato'='true' then
  raise exception 'Consenso anteriore a una nuova offerta acquisito'; end if;
 update public.pratiche set preventivo_inviato_at=v_quote where id=v_p;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:guardie-letterali',v_p,'{"targa":"TSTL999","ultimo_messaggio_cliente":"Scelgo la prima proposta"}') returning id into v_event;
 if private.ordine_da_conferma_letterale(v_event)->>'confermato'='true'
  or exists(select 1 from public.pratiche where id=v_p and stato_commerciale='ordine_acquisito') then
  raise exception 'Targa diversa non protetta'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:guardie-letterali',v_p,'{"targa":"TSTL006","ultimo_messaggio_cliente":"Non procedo"}');
 perform private.recupera_ordini_contestuali_keplero();
 if exists(select 1 from public.pratiche where id=v_p and stato_commerciale='ordine_acquisito') then
  raise exception 'Cron ha ignorato la revoca successiva'; end if;
end;
$test$;

-- Il ruolo usato dalla route esegue l'intake completo, con flag falso o vero.
set local role service_role;
do $test$
declare v_p uuid; v_result jsonb;
begin
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TSTL007','Test intake scelta letterale','commerciale','preventivo_inviato',now()-interval '2 hours') returning id into v_p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:intake-letterale',v_p);
 perform public.upsert_keplero_live(p_external_key=>'test:ordine:intake-letterale',p_targa=>'TSTL007',
  p_nome_cliente=>'Test intake scelta letterale',p_ultimo_messaggio_cliente=>'ok mi sta bene la prima proposta quella di 447',
  p_payload=>'{"targa":"TSTL007","ultimo_messaggio_cliente":"ok mi sta bene la prima proposta quella di 447","ordine_confermato_rilevato":false}');
 v_result:=public.esito_ordine_contestuale_keplero(v_p,'test:ordine:intake-letterale');
 if v_result->>'confermato'<>'true' or v_result#>>'{contesto,regola}'<>'conferma_letterale_offerta_v1' then
  raise exception 'Intake servizio non conferma la scelta: %',v_result; end if;

 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at,blocco_operatore)
 values('TSTL008','Test blocco operatore','commerciale','preventivo_inviato',now()-interval '2 hours',true) returning id into v_p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:blocco-letterale',v_p);
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:blocco-letterale',v_p,'{"targa":"TSTL008","ultimo_messaggio_cliente":"Scelgo la prima proposta","ordine_confermato_rilevato":true}');
 v_result:=public.conferma_ordine_da_keplero(v_p,'test:ordine:blocco-letterale','Scelgo la prima proposta');
 if v_result->>'motivo'<>'blocco_operatore'
  or exists(select 1 from public.pratiche where id=v_p and stato_commerciale='ordine_acquisito') then
  raise exception 'Flag positivo o HTTP hanno aggirato blocco operatore'; end if;
end;
$test$;
reset role;
rollback;

-- Tutte le prove, comprese anagrafiche e code, sono annullate.
begin;
set local role service_role;
do $test$
declare p uuid; q uuid; e bigint; cid uuid; op uuid; r jsonb; a jsonb; testo text;
 t0 timestamptz:=now()-interval '2 hours'; n bigint; prima jsonb;
 fiscali text:='FATTURAZIONE|DENOMINAZIONE:Officina Collaudo Prefissi|INDIRIZZO_FATTURAZIONE:Via Prova 7|CAP:00100|COMUNE:Roma|PIVA:IT 12345678903|CF:IT12345678903|EMAIL:prefissi@example.invalid';
begin
 a:=private.anagrafica_fiscale_intake(jsonb_build_object('dati_fiscali_testo',fiscali,
  'anagrafica_fiscale',jsonb_build_object('partita_iva','12345678903','codice_fiscale','12345678903')));
 if a->>'partita_iva'<>'12345678903' or a->>'codice_fiscale'<>'12345678903'
  or jsonb_array_length(coalesce(a->'_conflitti','[]'))<>0 or a->>'_testo'<>fiscali then raise exception 'Prefisso fiscale o testo originale alterati';end if;
 if private.normalizza_anagrafica_fiscale_intake('{"partita_iva":"DE 12345678903","codice_fiscale":"TSTFSC80A01F952A"}')->>'partita_iva'<>'DE12345678903' then raise exception 'Identificativo estero alterato';end if;
 a:=private.anagrafica_fiscale_intake(jsonb_build_object('dati_fiscali_testo',fiscali,
  'anagrafica_fiscale',jsonb_build_object('partita_iva','22345678903')));
 if not coalesce(a->'_conflitti','[]'::jsonb) ? 'partita_iva' then raise exception 'Discordanza fiscale eliminata';end if;
 foreach testo in array array['Il cliente non ha scelto il programma scambio Made in Italy',
  'Non è vero che il cliente ha scelto il programma scambio',
  'Il cliente ha scelto per il programma scambio se disponibile',
  'Il cliente ha scelto la riparazione qualora fosse possibile',
  'Il cliente ha scelto la riparazione?','Il cliente ha scelto di valutare la riparazione',
  'Il cliente ha scelto per il programma scambio ma prima di procedere verifica con il meccanico',
  'Preferisco il programma scambio','Come confermo il preventivo?'] loop
  if private.scelta_conclusa_cliente(testo) or (private.conferma_letterale_offerta(testo) and not private.preferenza_senza_conferma(testo)) then raise exception 'Falso consenso: %',testo;end if;
 end loop;
 insert into public.pratiche(nome_cliente,targa,tipo_flusso,stato_commerciale,preventivo_inviato_at,dati_raw)
 values('TEST scelta conclusa prefissi','TSCF001','commerciale','preventivo_inviato',t0,
  jsonb_build_object('payload_live',jsonb_build_object('dati_fiscali_testo',fiscali))) returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:scelta:prefissi',p);
 insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
 values(p,'test:scelta:prefissi:offerta','inviato',t0,t0) returning id into q;
 r:=public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","importo":447},{"numero":2,"servizio":"PS","importo":547},{"numero":3,"servizio":"PSMI","importo":497}]','test:scelta:prefissi:impronta');
 select o.id into op from public.offerta_opzioni o where o.offerta_id=(r->>'offerta_id')::uuid and servizio='PSMI';
 -- Anche un flag erroneo non rende incondizionata una scelta ancora dubbia.
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:scelta:prefissi',p,'{"targa":"TSCF001","ultimo_messaggio_cliente":"Il cliente ha scelto per il programma scambio se disponibile","ordine_confermato_rilevato":true}',t0+interval '10 minutes');
 if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Flag AI ha prevalso sulla condizione';end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:scelta:prefissi',p,'{"targa":"TSCF001","ultimo_messaggio_cliente":"Il cliente ha scelto per il programma scambio Made in Italy.","ordine_confermato_rilevato":false}',t0+interval '20 minutes') returning id into e;
 select cliente_id into cid from public.pratiche where id=p;
 if cid is null or not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito'
  and stato_fatturazione='da_fatturare' and stato_amministrativo='pronto_fatturazione' and ordine_acquisito_at=t0+interval '20 minutes')
  or not exists(select 1 from public.scelte_cliente where pratica_id=p and stato='confermata' and opzione_id=op)
  or not exists(select 1 from public.clienti where id=cid and partita_iva='12345678903' and codice_fiscale='12345678903') then raise exception 'Scelta conclusa non pronta per fatturazione';end if;
 select count(*) into n from public.clienti;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 select external_key,pratica_id,payload,created_at from public.keplero_live_events where id=e;
 if (select count(*) from public.clienti)<>n or (select cliente_id from public.pratiche where id=p)<>cid then raise exception 'Replay duplicato o errore';end if;
 update public.pratiche set dati_raw=dati_raw||jsonb_build_object('payload_live',jsonb_build_object('dati_fiscali_testo',replace(fiscali,'IT 12345678903','12345678903'))) where id=p;
 if jsonb_array_length((select dati_raw#>'{anagrafica_estratta,_conflitti}' from public.pratiche where id=p))<>0 then raise exception 'Formato equivalente ha generato un conflitto';end if;
 -- Fatture emesse e correzioni operatore non retrocedono su un replay.
 update public.pratiche set stato_fatturazione='fatturato' where id=p;
 select to_jsonb(x) into prima from public.scelte_cliente x where pratica_id=p;
 perform public.correggi_scelta_cliente(p,op,'confermata','Scelta verificata dal collaudo','Operatore test');
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 select external_key,pratica_id,payload,created_at from public.keplero_live_events where id=e;
 if (select stato_fatturazione from public.pratiche where id=p)<>'fatturato'
  or not exists(select 1 from public.scelte_cliente where pratica_id=p and opzione_id=op and protetta_operatore) then raise exception 'Fattura o scelta operatore modificata';end if;
 if has_function_privilege('anon','private.scelta_conclusa_cliente(text)','execute')
  or has_function_privilege('authenticated','private.normalizza_anagrafica_fiscale_intake(jsonb)','execute') then raise exception 'Helper interni esposti';end if;
end $test$;
reset role;
rollback;
select 'ok: scelta PSMI, coda fatturazione, prefissi, conflitti, condizioni, replay, fatture e blocchi operatore' as verifica;

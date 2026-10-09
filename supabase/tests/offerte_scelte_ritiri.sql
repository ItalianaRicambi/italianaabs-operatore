-- Esecuzione con rollback: verifica intake vero, RPC e protezione delle decisioni.
begin;
set local role service_role;
do $test$
declare p uuid; q uuid; e bigint; off uuid; scelta uuid; a uuid; c uuid; r jsonb;
 t0 timestamptz:=now()-interval '3 hours'; richiesta timestamptz; n integer;
begin
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TSTF001','Test flussi collegati','commerciale','preventivo_inviato',t0) returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:flussi:1',p);
 insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
 values(p,'test:offerta:1','inviato',t0,t0) returning id into q;
 r:=public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","descrizione":"RI","importo":447,"iva_inclusa":true},{"numero":2,"servizio":"PS","descrizione":"PS","importo":547,"iva_inclusa":true},{"numero":3,"servizio":"PSMI","descrizione":"PSMI","importo":497,"iva_inclusa":true}]','test-impronta-originale');
 off:=(r->>'offerta_id')::uuid;
 if public.registra_opzioni_offerta(q,'[]','test-impronta-originale',null,'lettura già presente')->>'duplicato'<>'true' then raise exception 'Retry ha duplicato la versione'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"Preferisco RI","ordine_confermato_rilevato":true}',t0+interval '5 minutes');
 if not exists(select 1 from public.scelte_cliente where pratica_id=p and stato='preferenza')
  or exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Preferenza acquisita come ordine'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"Scelgo il programma scambio"}',t0+interval '10 minutes');
 if not exists(select 1 from public.scelte_cliente where pratica_id=p and stato='da_chiarire' and opzione_id is null) then raise exception 'Scambio ambiguo non protetto'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"ok mi sta bene la prima proposta quella di 447"}',t0+interval '15 minutes') returning id into e;
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato='confermata' and servizio='RI' and importo=447 and offerta_id=off)
  or not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Ordinale/importo non collegati a RI'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"Il pacco è pronto per il ritiro"}',t0+interval '20 minutes');
 select id,richiesta_at into a,richiesta from public.attivita_operatore where pratica_id=p and tipo='ritiro_lavorazione';
 if a is null then raise exception 'Primo ritiro RI classificato come scambio'; end if;
 perform public.gestisci_ritiro_assistenza(p,a,null,'prendi_in_carico',p_operatore=>'Operatore test');
 begin
  perform public.gestisci_ritiro_assistenza(p,a,null,'programma',p_operatore=>'Operatore test');
  raise exception 'Prenotazione senza riferimento permessa';
 exception when others then if sqlerrm='Prenotazione senza riferimento permessa' then raise; end if; end;
 perform public.gestisci_ritiro_assistenza(p,a,null,'programma',p_riferimento=>'GLS-TEST-1',p_data_ritiro=>current_date,p_operatore=>'Operatore test');
 perform public.gestisci_ritiro_assistenza(p,a,null,'completa',p_nota=>'Ritiro verificato dal tracking',p_operatore=>'Operatore test');
 update public.attivita_operatore set completata_at=t0+interval '25 minutes' where id=a;
 perform public.crea_e_collega_cliente_pratica(p,'Test fiscale flussi','Via Test 1','Novara','28100',p_codice_fiscale=>'TSTFSC80A01F952A',p_email=>'flussi@test.invalid');
 update public.pratiche set stato_fatturazione='fatturato' where id=p;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"Dopo il montaggio non abbiamo risolto, il pacco è pronto per il ritiro","tipo_assistenza":"post_riparazione"}');
 select id into c from public.assistenze_rientri where pratica_id=p and chiusa_at is null;
 select id,richiesta_at into a,richiesta from public.attivita_operatore where pratica_id=p and tipo='ritiro_verifica_garanzia' and stato='da_gestire';
 if c is null or a is null then raise exception 'Rientro post lavorazione non urgente'; end if;
 if not exists(select 1 from public.pratiche where id=p and stato_fatturazione='fatturato' and tipo_flusso='commerciale') then raise exception 'Assistenza ha riscritto la pratica commerciale'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"Quando passa il corriere? Il pacco è pronto"}');
 if (select count(*) from public.attivita_operatore where pratica_id=p and tipo like 'ritiro_%' and stato in ('da_gestire','da_collegare','programmata'))<>1
  or not exists(select 1 from public.attivita_operatore where id=a and richiesta_at=richiesta and priorita='urgente') then raise exception 'Secondo messaggio duplica o resetta il ritiro'; end if;
 perform public.gestisci_ritiro_assistenza(p,a,c,'prendi_in_carico',p_operatore=>'Operatore test');
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"Il pacco lo avete già fatto ritirare martedì"}') returning id into e;
 begin
  perform public.gestisci_ritiro_assistenza(p,a,c,'programma',p_riferimento=>'GLS-DUPLICATO',p_data_ritiro=>current_date,p_operatore=>'Operatore test');
  raise exception 'Ritiro già effettuato prenotato senza verifica';
 exception when others then if sqlerrm='Ritiro già effettuato prenotato senza verifica' then raise; end if; end;
 perform public.gestisci_ritiro_assistenza(p,a,c,'verifica_prenotazione',p_nota=>'Tracking verificato: segnalazione relativa a spedizione precedente',p_operatore=>'Operatore test');
 perform private.rileva_rientro_evento(e);
 if exists(select 1 from public.attivita_operatore where id=a and metadati->>'ritiro_gia_effettuato_segnalato'='true') then raise exception 'Retry annulla verifica operatore'; end if;
 perform public.gestisci_ritiro_assistenza(p,a,c,'programma',p_riferimento=>'GLS-TEST-2',p_data_ritiro=>current_date,p_operatore=>'Operatore test');
 perform public.gestisci_ritiro_assistenza(p,a,c,'completa',p_nota=>'Presa del corriere verificata',p_operatore=>'Operatore test');
 if not exists(select 1 from public.assistenze_rientri where id=c and chiusa_at is null) then raise exception 'Ritiro ha chiuso assistenza'; end if;
 begin
  perform public.gestisci_ritiro_assistenza(p,null,c,'chiudi',p_nota=>'chiusura senza esito',p_operatore=>'Operatore test');
  raise exception 'Chiusura senza esito tecnico permessa';
 exception when others then if sqlerrm='Chiusura senza esito tecnico permessa' then raise; end if; end;
 perform public.gestisci_ritiro_assistenza(p,null,c,'ricevuto',p_operatore=>'Operatore test');
 perform public.gestisci_ritiro_assistenza(p,null,c,'in_lavorazione',p_operatore=>'Operatore test');
 perform public.gestisci_ritiro_assistenza(p,null,c,'esito_comunicato',p_nota=>'Verifica tecnica conclusa e comunicata al cliente',p_operatore=>'Operatore test');
 perform public.gestisci_ritiro_assistenza(p,null,c,'chiudi',p_nota=>'Chiusura verificata dal tecnico',p_operatore=>'Operatore test');
 if not exists(select 1 from public.assistenze_rientri where id=c and chiusa_at is not null) then raise exception 'Chiusura finale mancante'; end if;
 -- Una nuova versione non rimappa il consenso al nuovo prezzo/numero.
 r:=public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"PS","descrizione":"PS","importo":647},{"numero":2,"servizio":"RI","descrizione":"RI","importo":447}]','test-impronta-nuova',p_inviato_at=>now());
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and servizio='RI' and offerta_id=off and offerta_successiva) then raise exception 'Nuova versione ha riscritto il consenso'; end if;
 select id into scelta from public.offerta_opzioni where offerta_id=off and servizio='PSMI';
 perform public.correggi_scelta_cliente(p,scelta,'preferenza','Correzione operatore verificata','Operatore test');
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:flussi:1',p,'{"targa":"TSTF001","ultimo_messaggio_cliente":"Accetto opzione 1"}');
 if not exists(select 1 from public.scelte_cliente where pratica_id=p and opzione_id=scelta and protetta_operatore) then raise exception 'K ha sovrascritto correzione operatore'; end if;
 -- Controllo oltre le 48h: il timer resta lavorativo, non riparte sui messaggi.
 insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evidenza,aperta_at)
 values(p,null,'Problema post lavorazione ancora aperto',now()-interval '10 days') returning id into c;
 select numero_pratica into n from public.pratiche where id=p;
 perform public.gestisci_ritiro_assistenza(p,null,c,'collega_origine',p_nota=>'Ordine originale verificato',p_operatore=>'Operatore test',p_origine_numero=>n);
 if not exists(select 1 from public.assistenze_rientri where id=c and pratica_origine_id=p) then raise exception 'Assistenza senza ritiro non collegabile all’ordine originale'; end if;
 if not exists(select 1 from private.candidati_flussi_offerta_rientro() where chiave='assistenza_non_assegnata:'||c) then raise exception 'Controllo ignora assistenze oltre 48h'; end if;
 if public.minuti_lavorativi_trascorsi('2026-10-10 00:00:00+02','2026-10-12 08:59:00+02')<>0 then raise exception 'Conteggio weekend attivo'; end if;
end; $test$;
reset role;
do $test$
begin
 if exists(select 1 from private.keplero_event_processing ep join public.keplero_live_events e on e.id=ep.event_id
  join public.pratiche p on p.id=e.pratica_id where p.nome_cliente='Test flussi collegati' and ep.stato='errore') then
  raise exception 'Trigger ha nascosto errori'; end if;
end; $test$;
rollback;

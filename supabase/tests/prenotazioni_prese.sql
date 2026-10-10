-- Rollback: dati sintetici, passaggi di stato e protezione degli episodi.
begin;
do $test$
declare p uuid; q uuid; a uuid; a2 uuid; c uuid; e bigint; r jsonb; base jsonb; v_tipo text; d date:=current_date+2;
begin
 if has_function_privilege('anon','public.registra_prenotazione_presa(jsonb)','execute')
  or has_function_privilege('authenticated','public.registra_prenotazione_presa(jsonb)','execute')
  or not has_function_privilege('service_role','public.registra_prenotazione_presa(jsonb)','execute') then raise exception 'RPC accessibile senza servizio'; end if;
 foreach v_tipo in array array['ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_programma_scambio'] loop
  insert into public.pratiche(targa,nome_cliente,stato_commerciale,stato_logistica,stato_fatturazione)
  values('TSTP001','Test prenotazioni '||v_tipo,'ordine_acquisito','ritirato','da_fatturare') returning id into p;
  perform public.crea_e_collega_cliente_pratica(p,'Test fiscale prese','Via Test 1','Novara','28100',p_codice_fiscale=>case when v_tipo='ritiro_lavorazione' then 'TSTFSC80A01F952A' when v_tipo='ritiro_verifica_garanzia' then 'TSTFSC80A01F952B' else 'TSTFSC80A01F952C' end,p_email=>'prese@test.invalid');
  update public.pratiche set stato_fatturazione='fatturato' where id=p;
  c:=null;
  if v_tipo='ritiro_verifica_garanzia' then
   insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evidenza,aperta_at)
   values(p,p,'Test garanzia',now()-interval '2 hours') returning id into c;
  end if;
  insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza,assistenza_rientro_id,richiesta_at)
  values(p,p,v_tipo,'Test presa',c,now()-interval '2 hours') returning id into a;
  base:=jsonb_build_object('fonte','email_gls','fonte_id','test:'||a,'corriere','GLS','data_ritiro',d,
   'riferimento','P3 9260993058','testo','Conferma prenotazione presa GLS','pratica_id',p,'confermata',true,
   'ricevuta_at',now()-interval '1 hour','verifica_email',jsonb_build_object('dominio','gls-italy.com','autenticata',true));
  begin
   perform public.registra_prenotazione_presa(base-'verifica_email');
   raise exception 'Email non autenticata applicata';
  exception when others then if sqlerrm='Email non autenticata applicata' then raise; end if; end;
  r:=public.registra_prenotazione_presa(base||jsonb_build_object('fonte','cliente','fonte_id','cliente:'||a));
  if r->>'esito'<>'da_confermare' or not exists(select 1 from public.attivita_operatore where id=a and stato='da_gestire' and riferimento_ritiro is null and metadati#>>'{prenotazione_rilevata,riferimento}'='P3 9260993058') then raise exception 'Cliente confermato automaticamente'; end if;
  r:=public.registra_prenotazione_presa(base);
  if r->>'esito'<>'presa_prenotata' or not exists(select 1 from public.attivita_operatore where id=a and attivita_operatore.tipo=v_tipo and stato='programmata' and data_ritiro_prevista=d and riferimento_ritiro='P3 9260993058' and completata_at is null and operatore is null and presa_in_carico_at is null) then raise exception 'Prenotazione automatica incompleta: %',r; end if;
  if not exists(select 1 from public.pratiche where id=p and stato_fatturazione='fatturato' and stato_commerciale='ordine_acquisito' and stato_logistica=case when v_tipo='ritiro_lavorazione' then 'ritiro_programmato'::public.stato_logistica else 'ritirato'::public.stato_logistica end) then raise exception 'Prenotazione ha alterato fatture o ritiro storico'; end if;
  if c is not null and not exists(select 1 from public.assistenze_rientri where id=c and stato='ritiro_prenotato' and chiusa_at is null) then raise exception 'Assistenza chiusa dalla presa'; end if;
  r:=public.registra_prenotazione_presa(base);
  if r->>'duplicato'<>'true' or (select count(*) from public.azioni_operatore where pratica_id=p and azione='prenotazione_presa_registrata')<>1 then raise exception 'Retry ha duplicato la presa'; end if;
  r:=public.registra_prenotazione_presa(base||jsonb_build_object('fonte_id','nuova:'||a,'riferimento','P3 9260993059','data_ritiro',d+1,'ricevuta_at',now()-interval '30 minutes'));
  if r->>'esito'<>'presa_prenotata' then raise exception 'Revisione recente non applicata'; end if;
  r:=public.registra_prenotazione_presa(base||jsonb_build_object('fonte_id','vecchia:'||a));
  if r->>'esito'<>'messaggio_precedente' or (select riferimento_ritiro from public.attivita_operatore where id=a)<>'P3 9260993059' then raise exception 'Email vecchia sovrascrive nuova'; end if;
  r:=public.registra_prenotazione_presa(base||jsonb_build_object('fonte','messaggio_operatore','fonte_id','operatore:'||a,'operatore','Operatore test','riferimento','P3 9260993060','ricevuta_at',now()-interval '10 minutes'));
  if r->>'esito'<>'presa_prenotata' then raise exception 'Correzione manuale non applicata'; end if;
  r:=public.registra_prenotazione_presa(base||jsonb_build_object('fonte_id','conflitto:'||a,'ricevuta_at',now()));
  if r->>'esito'<>'modifica_da_verificare' then raise exception 'Email modifica correzione operatore'; end if;
  -- Anche il percorso manuale preesistente resta protetto.
  perform public.gestisci_ritiro_assistenza(p,a,c,'programma',p_riferimento=>'P3 9260993061',p_data_ritiro=>d,p_operatore=>'Operatore test');
  if not exists(select 1 from public.attivita_operatore where id=a and metadati->>'prenotazione_protetta_operatore'='true') then raise exception 'Prenotazione manuale non protetta'; end if;
  update public.attivita_operatore set stato='completata',completata_at=now() where id=a;
  r:=public.registra_prenotazione_presa(base);
  if r->>'duplicato'<>'true' then raise exception 'Retry riapre presa chiusa'; end if;
 end loop;
 -- Ambiguità: stessa targa su due ritiri, nessuno viene scelto arbitrariamente.
 insert into public.pratiche(targa,nome_cliente,stato_commerciale) values('TSTAMB1','Test presa ambigua 1','ordine_acquisito') returning id into p;
 insert into public.pratiche(targa,nome_cliente,stato_commerciale) values('TSTAMB1','Test presa ambigua 2','ordine_acquisito') returning id into q;
 insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza,richiesta_at) values(p,p,'ritiro_lavorazione','Ambigua 1',now()-interval '1 hour') returning id into a;
 insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza,richiesta_at) values(q,q,'ritiro_lavorazione','Ambigua 2',now()-interval '1 hour') returning id into a2;
 base:=jsonb_build_object('fonte','email_gls','fonte_id','test:ambigua','corriere','GLS','data_ritiro',d,'riferimento','P3 9260993070','testo','Conferma prenotazione GLS','targa','TSTAMB1','confermata',true,'verifica_email',jsonb_build_object('dominio','gls-italy.com','autenticata',true));
 r:=public.registra_prenotazione_presa(base);
 if r->>'esito'<>'abbinamento_ambiguo' or exists(select 1 from public.attivita_operatore where id in(a,a2) and stato='programmata') then raise exception 'Ambiguità non trattenuta'; end if;
 select id into c from public.prenotazioni_prese_ricevute where fonte_id='test:ambigua';
 r:=public.conferma_abbinamento_presa(c,a,'Operatore test');
 if r->>'esito'<>'presa_prenotata' or not exists(select 1 from public.prenotazioni_prese_ricevute where id=c and applicata_at is not null and esito='verificata_operatore') then raise exception 'Verifica abbinamento non applicata'; end if;
 -- Conferma ricevuta prima dell'attività: riabbinamento senza perdere i criteri.
 base:=base||jsonb_build_object('fonte_id','test:anticipata','targa','TSTNEW1');
 if public.registra_prenotazione_presa(base)->>'esito'<>'da_abbinare' then raise exception 'Email anticipata persa'; end if;
 insert into public.pratiche(targa,nome_cliente,stato_commerciale) values('TSTNEW1','Test presa anticipata','ordine_acquisito') returning id into p;
 insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza) values(p,p,'ritiro_lavorazione','Anticipata') returning id into a;
 perform private.riprova_prenotazioni_prese();
 if not exists(select 1 from public.attivita_operatore where id=a and stato='programmata') then raise exception 'Riprova perde targa originale'; end if;
 -- Un nuovo episodio non viene prenotato da un messaggio precedente.
 update public.attivita_operatore set stato='completata',completata_at=now()-interval '1 hour' where id=a;
 insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza,richiesta_at) values(p,p,'ritiro_programma_scambio','Nuovo episodio',now()) returning id into a;
 r:=public.registra_prenotazione_presa(base||jsonb_build_object('fonte_id','test:altro-episodio','ricevuta_at',now()-interval '2 days','data_ritiro',current_date-2));
 if r->>'esito'<>'messaggio_precedente' or (select stato from public.attivita_operatore where id=a)<>'da_gestire' then raise exception 'Vecchio episodio prenota nuovo ritiro'; end if;
 -- Il trigger legge il testo reale del cliente e non segna il ritiro effettuato.
 insert into public.keplero_live_links(external_key,pratica_id) values('test:presa:cliente',p);
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:presa:cliente',p,jsonb_build_object('targa','TSTNEW1','ultimo_messaggio_cliente','Il pacco è pronto per il corriere. GLS per la giornata del '||to_char(d,'DD/MM/YYYY')||', codice (da riportare sulla scatola) P3 9260993080.')) returning id into e;
 if not exists(select 1 from public.attivita_operatore where id=a and stato='da_gestire' and metadati#>>'{prenotazione_rilevata,riferimento}'='P3 9260993080' and coalesce(metadati->>'ritiro_gia_effettuato_segnalato','false')='false') then raise exception 'Trigger cliente non precompila correttamente'; end if;
 base:=base-'targa';
 r:=public.registra_prenotazione_presa(base||jsonb_build_object('fonte_id','test:codice-unico','riferimento','P3 9260993080'));
 if r->>'esito'<>'presa_prenotata' then raise exception 'Conferma email non abbina codice già rilevato'; end if;
 if exists(select 1 from private.keplero_event_processing where event_id=e and stato='errore') then raise exception 'Errore nascosto nel trigger'; end if;
end; $test$;
rollback;

-- Tutti i dati di prova sono annullati. Verifica il vero trigger dell'intake,
-- il recupero cron, il controllo indipendente e la separazione fra le pratiche.
begin;
do $test$
declare
 v_p uuid; v_altro uuid; v_event bigint; v_quote timestamptz:=now()-interval '2 hours';
 v_testo text:='Cliente Test; BRNFNC01P22I234X; Via Test 59, 20138 Milano; cliente@test.invalid';
 v_riepilogo text:='Il cliente ha ricevuto l''offerta e intende procedere. Dati fiscali forniti.';
 v_payload jsonb; v_result jsonb;
begin
 if private.codice_fiscale_letterale(v_testo)<>'BRNFNC01P22I234X' then
   raise exception 'CF senza etichetta non estratto'; end if;
 if private.codice_fiscale_letterale('Esempio BRNFNC01P22I234X') is not null
   or private.codice_fiscale_letterale('BRNFNC01P22I234X FLPFRZ71M24D612G') is not null then
   raise exception 'CF fittizio o ambiguo estratto'; end if;
 if not private.intenzione_offerta_con_fiscali(v_testo,v_riepilogo) then
   raise exception 'Combinazione positiva non riconosciuta'; end if;
 if not private.scelta_lavorazione_cliente('Il proprietario ha deciso per la prima opzione, la lavorazione sull''originale. Come dobbiamo procedere?')
   or private.scelta_lavorazione_cliente('Il proprietario ha deciso di valutare la lavorazione')
   or private.scelta_lavorazione_cliente('Il proprietario ha deciso per la lavorazione ma prima di procedere si confronta con il meccanico') then
   raise exception 'Scelta del proprietario o rinvio non riconosciuti'; end if;
 if private.intenzione_offerta_con_fiscali('Via Test 59; cliente@test.invalid',v_riepilogo)
   or private.intenzione_offerta_con_fiscali(v_testo,'Il cliente richiede un preventivo e intende procedere.')
   or private.intenzione_offerta_con_fiscali(v_testo,'Il cliente ha ricevuto l''offerta e intende procedere dopo un confronto con il meccanico.')
   or private.intenzione_offerta_con_fiscali(v_testo,'Il cliente ha ricevuto l''offerta e forse intende procedere.')
   or private.intenzione_offerta_con_fiscali(v_testo||'; non procedo',v_riepilogo) then
   raise exception 'Intenzione ambigua, fiscali mancanti o rinvio hanno confermato'; end if;

 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,
   preventivo_inviato_at,created_at)
 values('TSTI001','Test rollback ordine','commerciale','preventivo_inviato',v_quote,
   v_quote-interval '1 hour') returning id into v_p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:fiscali',v_p);
 v_payload:=jsonb_build_object('targa','TSTI001','tipo_flusso','commerciale',
   'ultimo_messaggio_cliente',v_testo,'descrizione_guasto',v_riepilogo,
   'decisione_sistema',jsonb_build_object('ordine',jsonb_build_object('confermato',false)));
 insert into public.keplero_live_events(external_key,pratica_id,payload)
   values('test:ordine:fiscali',v_p,v_payload) returning id into v_event;
 if not exists(select 1 from public.pratiche where id=v_p
   and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare') then
   raise exception 'Trigger non ha avanzato la pratica quotata'; end if;
 v_result:=public.esito_ordine_contestuale_keplero(v_p,'test:ordine:fiscali');
 if v_result->>'confermato'<>'true' or v_result#>>'{contesto,regola}'<>'intenzione_offerta_e_dati_fiscali_v1' then
   raise exception 'Esito HTTP incoerente: %',v_result; end if;
 if public.esito_ordine_contestuale_keplero(v_p,'altra:chat')->>'confermato'<>'false' then
   raise exception 'Esito di un''altra conversazione esposto'; end if;

 -- Senza offerta registrata restano soltanto dati fiscali e intenzione.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
   values('TSTI002','Test senza preventivo','commerciale','raccolta_dati') returning id into v_altro;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:senza-quote',v_altro);
 insert into public.keplero_live_events(external_key,pratica_id,payload)
   values('test:ordine:senza-quote',v_altro,v_payload||'{"targa":"TSTI002"}'::jsonb);
 if exists(select 1 from public.pratiche where id=v_altro and stato_fatturazione='da_fatturare') then
   raise exception 'Ordine acquisito senza offerta'; end if;

 -- Il controllo segnala una formulazione non riconosciuta dal classificatore.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,
   preventivo_inviato_at,created_at)
 values('TSTI003','Test controllo indipendente','commerciale','preventivo_inviato',v_quote,
   v_quote-interval '1 hour') returning id into v_altro;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:controllo',v_altro);
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:ordine:controllo',v_altro,v_payload||jsonb_build_object('targa','TSTI003',
   'descrizione_guasto','Invio dei dati per la gestione della proposta.'),now()-interval '20 minutes');
 if not exists(select 1 from private.candidati_coerenza_keplero()
   where pratica_id=v_altro and regola='dati_fiscali_senza_ordine') then
   raise exception 'Controllo indipendente non segnala il caso'; end if;

 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:ordine:controllo',v_altro,jsonb_build_object('targa','TSTI003',
   'ultimo_messaggio_cliente','Documento allegato',
   'allegati',jsonb_build_array('https://example.invalid/Fattura-test.pdf')),now()-interval '15 minutes');
 if not exists(select 1 from private.candidati_coerenza_keplero()
   where pratica_id=v_altro and regola='fattura_documento_non_allineato')
   or exists(select 1 from public.pratiche where id=v_altro and stato_fatturazione='fatturato') then
   raise exception 'Nome PDF non segnalato o erroneamente sufficiente a fatturare'; end if;

 -- Targa diversa e blocco esplicito non possono acquisire l'ordine.
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:controllo',v_altro,v_payload||'{"targa":"TSTI999"}'::jsonb) returning id into v_event;
 if private.ordine_da_scelta_e_fiscali(v_event)->>'confermato'='true' then
   raise exception 'Ordine acquisito su targa differente'; end if;
 update public.pratiche set blocco_operatore=true where id=v_altro;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:controllo',v_altro,v_payload||'{"targa":"TSTI003"}'::jsonb);
 if exists(select 1 from public.pratiche where id=v_altro and stato_fatturazione='da_fatturare') then
   raise exception 'Blocco operatore ignorato'; end if;

 -- Riproduciamo un evento precedente alla correzione e poi la revoca.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTI004','Test recupero revoca','commerciale','raccolta_dati',v_quote-interval '1 hour') returning id into v_altro;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:revoca',v_altro);
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('test:ordine:revoca',v_altro,v_payload||'{"targa":"TSTI004"}'::jsonb,now()-interval '20 minutes') returning id into v_event;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:revoca',v_altro,'{"targa":"TSTI004","ultimo_messaggio_cliente":"Non procedo"}'::jsonb);
 update public.pratiche set stato_commerciale='preventivo_inviato',preventivo_inviato_at=v_quote where id=v_altro;
 if private.ordine_da_scelta_e_fiscali(v_event)->>'confermato'='true' then
   raise exception 'Recupero ha ignorato revoca successiva'; end if;
 perform private.recupera_ordini_contestuali_keplero();
 if exists(select 1 from public.pratiche where id=v_altro and stato_fatturazione='da_fatturare') then
   raise exception 'Cron ha acquisito una scelta revocata'; end if;
end;
$test$;

-- Percorso HTTP effettivo: il ruolo di servizio chiama l'intake completo.
set local role service_role;
do $test$
declare v_id uuid; v_esito jsonb;
 v_testo text:='Cliente Test; BRNFNC01P22I234X; Via Test 59; cliente@test.invalid';
 v_riepilogo text:='Il cliente ha ricevuto l''offerta e intende procedere.';
begin
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TSTI005','Test intake servizio','commerciale','preventivo_inviato',now()-interval '2 hours') returning id into v_id;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:intake',v_id);
 perform public.upsert_keplero_live(p_external_key=>'test:ordine:intake',p_targa=>'TSTI005',
   p_nome_cliente=>'Cliente Test',p_ultimo_messaggio_cliente=>v_testo,
   p_descrizione_guasto=>v_riepilogo,p_payload=>jsonb_build_object('targa','TSTI005',
   'ultimo_messaggio_cliente',v_testo,'descrizione_guasto',v_riepilogo));
 if not exists(select 1 from public.pratiche where id=v_id and stato_fatturazione='da_fatturare'
   and dati_raw#>>'{anagrafica_estratta,codice_fiscale}'='BRNFNC01P22I234X') then
   raise exception 'Intake servizio non ha acquisito ordine/CF'; end if;
 v_esito:=public.esito_ordine_contestuale_keplero(v_id,'test:ordine:intake');
 if v_esito->>'confermato'<>'true' then raise exception 'Servizio non legge esito: %',v_esito; end if;

 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TSTI006','Test scelta proprietario','commerciale','preventivo_inviato',now()-interval '2 hours') returning id into v_id;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:ordine:proprietario',v_id);
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:proprietario',v_id,jsonb_build_object('targa','TSTI006',
   'ultimo_messaggio_cliente','Il proprietario ha deciso per la prima opzione, la lavorazione sull''originale. Come dobbiamo procedere?'));
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:ordine:proprietario',v_id,jsonb_build_object('targa','TSTI006',
   'ultimo_messaggio_cliente',v_testo));
 if not exists(select 1 from public.pratiche where id=v_id and stato_fatturazione='da_fatturare') then
   raise exception 'Scelta del proprietario seguita da dati fiscali non acquisita'; end if;
end;
$test$;
reset role;
rollback;

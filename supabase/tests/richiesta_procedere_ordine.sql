-- Dati sintetici e nessun invio esterno. Eseguire dopo stabilizza_pratiche_keplero.
begin;
create temporary table risultati_affidabilita(caso text primary key);
grant all on risultati_affidabilita to service_role;
create function pg_temp.caso_k(t text,s uuid default gen_random_uuid(),secondario boolean default false,storico boolean default false,alternative integer default 1)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p uuid; d uuid; impronta text:=encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex');
 sha text:=encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex'); dt timestamptz; contenuto jsonb;
begin
 dt:=case when storico then now()-interval '35 days' else now()-interval '1 hour' end;
 insert into public.pratiche(keplero_conversation_id,targa,telefono,nome_cliente,tipo_flusso,stato_commerciale,stato_completezza,descrizione_guasto,dati_raw)
 values(case when secondario then null else s::text end,t,'390000000000','Collaudo sintetico rollback','commerciale','raccolta_dati','dati_mancanti','Guasto descritto da verificare',
  jsonb_build_object('origine','test_affidabilita','codici_identificativi_estratti',jsonb_build_array(jsonb_build_object('codice','TEST-ABS')),
   'payload_live',jsonb_build_object('decisione_sistema',jsonb_build_object('completezza',jsonb_build_object('datiMancanti',jsonb_build_array('dtc_con_spie_accese')))))) returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values('conversation:'||s||case when secondario then ':veicolo:'||lower(t) else '' end,p);
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,targa_pdf,sha256_pdf)
 values(s,'pdf-'||t,dt,dt::text,'uscita','file','attachment:https://v2.api.keplero.ai/v2/session-attachments/test-'||t||'.pdf',repeat('a',64),true,false,t,sha);
 contenuto:=jsonb_build_object('impronta',impronta,'testo','Preventivo sintetico '||t,'opzioni',jsonb_build_array(jsonb_build_object('numero',1,'numero_esplicito',true,'servizio','RI','importo',447,'valuta','EUR')));
 if alternative=2 then contenuto:=jsonb_set(contenuto,'{opzioni}',(contenuto->'opzioni')||jsonb_build_array(jsonb_build_object('numero',2,'numero_esplicito',true,'servizio','PS','importo',597,'valuta','EUR')));end if;
 insert into public.documenti_preventivo_auto(external_id,impronta,sha256_pdf,nome_file,targa,file_url,data_offerta,contenuto,stato)
 values('test-affidabilita:'||s||':'||t,impronta,sha,t||'.pdf',''||t,'https://v2.api.keplero.ai/v2/session-attachments/test-'||t||'.pdf',dt,contenuto,'da_abbinare') returning id into d;
 return jsonb_build_object('pratica',p,'documento',d,'sessione',s,'messaggio','pdf-'||t,'data',dt,'impronta',impronta,'sha',sha);
end; $$;

create function pg_temp.messaggio_k(s uuid,id text,testo text,candidato boolean default true,revoca boolean default false)
returns void language plpgsql security invoker set search_path='' as $$
begin
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca)
 values(s,id,now()-interval '10 minutes',(now()-interval '10 minutes')::text,'entrata','text',testo,encode(sha256(convert_to(testo,'UTF8')),'hex'),candidato,revoca);
end; $$;


set local role service_role;
do $test$
declare x jsonb; p uuid; s uuid; e bigint; msg text; i int:=0; n int; r jsonb;
begin
 if has_function_privilege('anon','private.richiesta_procedere_ordine(text)','execute')
  or has_function_privilege('authenticated','private.richiesta_procedere_ordine(text)','execute') then raise exception 'Permessi troppo ampi';end if;
 foreach msg in array array['Possiamo procedere per fare l’ordine','Buongiorno, possiamo procedere con PS. Grazie','Possiamo procedere con l''opzione 2'] loop
  if not private.richiesta_procedere_ordine(msg) or not private.conferma_letterale_offerta(msg) then raise exception 'Consenso perso: %',msg;end if;
 end loop;
 foreach msg in array array['Possiamo procedere per fare l’ordine?','Possiamo procedere con PS se disponibile','Non possiamo procedere con PS','Possiamo procedere con PS domani','Possiamo procedere con il pagamento','Possiamo procedere con il ritiro','Come possiamo procedere con l’ordine','Possiamo procedere con PS oppure RI','Possiamo procedere con PS a 300 euro','Possiamo procedere con PS, ma prima sento il cliente'] loop
  if private.richiesta_procedere_ordine(msg) then raise exception 'Falso consenso: %',msg;end if;
  i:=i+1;x:=pg_temp.caso_k('YY'||(100+i)::text||'AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
  perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
  perform pg_temp.messaggio_k(s,'negativo',msg);perform private.valuta_originale_k(s,'negativo');
  insert into public.keplero_live_events(external_key,pratica_id,payload)
   values('conversation:'||s,p,jsonb_build_object('targa','YY'||(100+i)::text||'AA','ultimo_messaggio_cliente',msg));
  if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Ordine spurio: %',msg;end if;
 end loop;
 insert into risultati_affidabilita values('Domande, negazioni, condizioni, logistica e importi non acquisiti');

 -- Percorso originale: unica alternativa, scelta multipla, scelta esplicita.
 for i in 1..3 loop
  x:=pg_temp.caso_k('YY'||(120+i)::text||'AA',gen_random_uuid(),false,false,case when i=1 then 1 else 2 end);p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
  perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
  msg:=case when i=3 then 'Possiamo procedere con PS' else 'Possiamo procedere per fare l’ordine' end;
  perform pg_temp.messaggio_k(s,'ordine',msg);perform private.valuta_originale_k(s,'ordine');
  if i=2 then
   if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Alternativa arbitraria';end if;
   perform private.valuta_fonte_commerciale_k('originale',s||':ordine');
   if not exists(select 1 from public.keplero_esiti_fonti where chiave=s||':ordine' and stato='da_verificare') then raise exception 'Consenso ambiguo non segnalato';end if;
  else
   if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare' and stato_amministrativo='dati_mancanti') then raise exception 'Ordine originale perso: %',i;end if;
   perform private.valuta_originale_k(s,'ordine');
   if (select count(*) from public.scelte_cliente where pratica_id=p)<>1 then raise exception 'Replay duplica scelta';end if;
  end if;
 end loop;
 insert into risultati_affidabilita values('Originali: alternativa unica o esplicita acquisita; ambiguità segnalata; replay e dati fiscali preservati');

 -- Percorso live: consenso generico visibile, risposta breve completa la scelta.
 x:=pg_temp.caso_k('YY130AA',gen_random_uuid(),false,false,2);p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('conversation:'||s,p,jsonb_build_object('targa','YY130AA','ultimo_messaggio_cliente','Possiamo procedere per fare l’ordine')) returning id into e;
 if not exists(select 1 from public.scelte_cliente where pratica_id=p and stato='da_chiarire' and opzione_id is null)
  or exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Consenso ambiguo live perso o acquisito';end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('conversation:'||s,p,jsonb_build_object('targa','YY130AA','ultimo_messaggio_cliente','PS'));
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare' and stato_amministrativo='dati_mancanti')
  or not exists(select 1 from public.scelte_cliente sc join public.offerta_opzioni o on o.id=sc.opzione_id where sc.pratica_id=p and sc.stato='confermata' and o.servizio='PS') then raise exception 'Scelta successiva non acquisita';end if;
 insert into risultati_affidabilita values('Live: scelta da chiarire visibile e successivo PS acquisito senza dati fiscali inventati');

 x:=pg_temp.caso_k('YY131AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('conversation:'||s,p,jsonb_build_object('targa','YY131AA','ultimo_messaggio_cliente','Possiamo procedere per fare l’ordine'));
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Live alternativa unica persa';end if;
 insert into risultati_affidabilita values('Live: alternativa unica acquisita anche senza flag AI');
end $test$;
select * from risultati_affidabilita order by caso;
rollback;

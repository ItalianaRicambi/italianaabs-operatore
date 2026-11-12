-- Fixture isolata. L'orologio sostituito e tutti i dati vengono annullati.
begin;
select set_config('followup_test.clock', '2026-11-09T10:00:00Z', true);
do $$
declare f regprocedure;
begin
 foreach f in array array[
  'private.followup_dati_risposte_verificate(public.followup_dati_richieste,timestamptz,jsonb)'::regprocedure,
  'private.followup_dati_stato_valido(uuid,timestamptz,timestamptz,jsonb)'::regprocedure,
  'public.claim_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb)'::regprocedure,
  'public.inizia_invio_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb,jsonb)'::regprocedure,
  'public.segnala_followup_dati(uuid,text,timestamptz,timestamptz,jsonb)'::regprocedure
 ] loop
  execute replace(pg_get_functiondef(f), 'clock_timestamp()', 'current_setting(''followup_test.clock'')::timestamptz');
 end loop;
end; $$;
set local role service_role;
do $test$
declare
 p uuid; s uuid:=gen_random_uuid(); r uuid; token uuid; first_token uuid; v timestamptz;
 initial_time timestamptz:='2026-11-09T10:00:00Z'; due timestamptz:='2026-11-16T10:00:00Z';
 h text:=repeat('b',64); proof jsonb; attempt jsonb;
begin
 if has_function_privilege('anon','public.claim_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb)','execute')
 or has_function_privilege('authenticated','public.rilascia_claim_followup_dati(uuid)','execute') then
  raise exception 'RPC esposta';
 end if;
 insert into public.pratiche(keplero_conversation_id,stato_commerciale) values(s::text,'ordine_acquisito') returning id,updated_at into p,v;
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,direzione,tipo,testo,impronta,revoca,originale)
 values(s,'request',initial_time-interval '25 hours','uscita','text','Ci invia i dati di fatturazione?',repeat('a',64),false,
 '{"sender":"assistant","whatsapp_message":{"status":"delivered"}}');
 update public.followup_dati_config set enabled=true,transport_verified=true,accept_requests_after=initial_time-interval '4 days' where id;
 r:=public.registra_richiesta_followup_dati(p,'fatturazione',s,'request',array['sdi_o_pec']);
 first_token:=public.claim_followup_dati(r,v,initial_time,h,array['sdi_o_pec']);
 if first_token is null then raise exception 'Prenotazione iniziale assente';end if;

 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,direzione,tipo,testo,impronta,revoca,originale)
 values(s,'reply',initial_time,'entrata','text','Vi mando i dati di fatturazione tra una settimana',repeat('c',64),false,'{}');
 update public.pratiche set ultimo_messaggio_cliente_at=initial_time where id=p;
 insert into public.keplero_verifiche_originali(sessione,messaggio_id,esito) values(s,'reply','da_verificare');
 proof:=jsonb_build_object('notBefore','2026-11-16T10:00:00.000Z','conversationFingerprint',h,
  'messages',jsonb_build_array(jsonb_build_object('id','reply','fingerprint',repeat('c',64))));
 attempt:=jsonb_build_object('session',s,'phase','fatturazione','to','+390000000000','startedAt',initial_time,
  'beforeIds',jsonb_build_array('request','reply'),'variables',jsonb_build_array('ABS-999999','SDI'),'expectedText','Pratica ABS-999999: SDI');
 if public.inizia_invio_followup_dati(first_token,v,initial_time,h,array['sdi_o_pec'],attempt,proof) then
  raise exception 'Tentativo autorizzato prima della scadenza';
 end if;
 if not public.rilascia_claim_followup_dati(first_token) then raise exception 'Impossibile rinviare la prenotazione';end if;
 if public.claim_followup_dati(r,v,initial_time,h,array['sdi_o_pec'],proof) is not null then raise exception 'Claim prima della scadenza';end if;

 perform set_config('followup_test.clock', due::text, true);
 attempt:=jsonb_set(attempt,'{startedAt}',to_jsonb(due));
 if public.claim_followup_dati(r,v,due,h,array['sdi_o_pec']) is not null
  or public.claim_followup_dati(r,v,due,repeat('d',64),array['sdi_o_pec'],proof) is not null then
  raise exception 'Claim senza prova live associata';
 end if;
 token:=public.claim_followup_dati(r,v,due,h,array['sdi_o_pec'],proof);
 if token is null or token=first_token then raise exception 'Rinvio non riacquisito alla scadenza';end if;
 if public.inizia_invio_followup_dati(first_token,v,due,h,array['sdi_o_pec'],attempt,proof) then raise exception 'Claim precedente riutilizzato';end if;

 update public.keplero_originali set impronta=repeat('d',64),modificato=true where sessione=s and messaggio_id='reply';
 if public.inizia_invio_followup_dati(token,v,due,h,array['sdi_o_pec'],attempt,proof) then raise exception 'Originale modificato accettato';end if;
 update public.keplero_originali set impronta=repeat('c',64),modificato=false where sessione=s and messaggio_id='reply';
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,direzione,tipo,testo,impronta,revoca,originale)
 values(s,'attachment',due,'entrata','file','Dati fiscali',repeat('e',64),false,'{}');
 if public.inizia_invio_followup_dati(token,v,due,h,array['sdi_o_pec'],attempt,proof) then raise exception 'Allegato nuovo ignorato';end if;
 delete from public.keplero_originali where sessione=s and messaggio_id='attachment';
 if not public.inizia_invio_followup_dati(token,v,due,h,array['sdi_o_pec'],attempt,proof) then raise exception 'Tentativo dovuto respinto';end if;
 if public.rilascia_claim_followup_dati(token) then raise exception 'Tentativo già iniziato riapribile';end if;
 if public.inizia_invio_followup_dati(token,v,due,h,array['sdi_o_pec'],attempt,proof) then raise exception 'Secondo tentativo autorizzato';end if;

 update public.followup_dati_invii set stato='sent',provider_message_id='synthetic-rinvio',inviata_at=due,conferma='{}' where claim=token;
 if public.segnala_followup_dati(p,'fatturazione',v,due,proof) then raise exception 'Attività interna anticipata';end if;
 perform set_config('followup_test.clock', (due+interval '48 hours')::text, true);
 if not public.segnala_followup_dati(p,'fatturazione',v,due+interval '48 hours',proof) then raise exception 'Attività interna mancante dopo 48h';end if;
end; $test$;
rollback;
select 'ok: rinvio, scadenza, originali, riacquisizione senza duplicati e attività 48h' as verifica;

-- Collaudo dati sintetici, nessun DDL o invio; rollback obbligatorio.
begin;
set local role service_role;
do $test$
declare p uuid; s uuid:=gen_random_uuid(); r uuid; token uuid; v timestamptz; attempt jsonb; n integer; activity uuid;
 t timestamptz:=clock_timestamp(); aperto boolean;
begin
 aperto:=extract(isodow from t at time zone 'Europe/Rome') between 1 and 4 and ((t at time zone 'Europe/Rome')::time between time '09:00' and time '12:29:59' or (t at time zone 'Europe/Rome')::time between time '14:00' and time '18:29:59') or extract(isodow from t at time zone 'Europe/Rome')=5 and (t at time zone 'Europe/Rome')::time between time '09:00' and time '13:29:59';
 if (select enabled from public.followup_dati_config where id) then raise exception 'Non testare con invii abilitati';end if;
 if has_function_privilege('anon','public.inizia_invio_followup_dati(uuid,timestamptz,timestamptz,text,text[],jsonb)','execute')
 or has_function_privilege('authenticated','public.segnala_followup_dati(uuid,text,timestamptz,timestamptz)','execute') then raise exception 'RPC esposta';end if;
 insert into public.pratiche(keplero_conversation_id,targa,telefono,nome_cliente,tipo_flusso,stato_commerciale,stato_completezza)
 values(s::text,'ZZ999ZZ','390000000000','Test trasporto rollback','commerciale','raccolta_dati','dati_mancanti') returning id into p;
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale)
 values(s,'synthetic-request',t-interval '25 hours',(t-interval '25 hours')::text,'uscita','text','Ci invia foto?',repeat('a',64),false,false,
 '{"sender":"assistant","whatsapp_message":{"status":"delivered"}}');
 update public.followup_dati_config set enabled=true,transport_verified=true,accept_requests_after=t-interval '4 days',calendar_confirmed_through=current_date+1 where id;
 r:=public.registra_richiesta_followup_dati(p,'preventivo',s,'synthetic-request',array['foto']);
 select updated_at into v from public.pratiche where id=p;
 token:=public.claim_followup_dati(r,v,t,repeat('b',64),array['foto']);
 if aperto and token is null then raise exception 'Claim fallito';end if;
 if not aperto then
  if token is not null then raise exception 'Claim fuori fascia';end if;
  insert into public.followup_dati_invii(pratica_id,fase,richiesta_id,verificata_at,impronta_verifica,campi) values(p,'preventivo',r,t,repeat('b',64),array['foto']) returning claim into token;
 end if;
 attempt:=jsonb_build_object('session',s,'phase','preventivo','to','+390000000000','startedAt',t,
 'beforeIds',jsonb_build_array('synthetic-request'),'variables',jsonb_build_array('ABS-999999','foto'),'expectedText','Pratica ABS-999999: foto');
 if public.inizia_invio_followup_dati(token,v,t-interval '16 seconds',repeat('b',64),array['foto'],attempt) then raise exception 'Snapshot scaduto accettato';end if;
 if public.inizia_invio_followup_dati(token,v,t,repeat('b',64),array['targa'],attempt) then raise exception 'Campi diversi accettati';end if;
 -- Risposta entrata dopo il claim: nessun POST autorizzato.
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale)
 values(s,'synthetic-reply',t,t::text,'entrata','text','Ecco le foto',repeat('c',64),false,false,'{}');
 if public.inizia_invio_followup_dati(token,v,t,repeat('b',64),array['foto'],attempt) then raise exception 'Risposta non ha fermato invio';end if;
 delete from public.keplero_originali where sessione=s and messaggio_id='synthetic-reply';
 if public.inizia_invio_followup_dati(token,v,t,repeat('b',64),array['foto'],attempt) is distinct from aperto then raise exception 'Finestra invio non rispettata';end if;
 if public.inizia_invio_followup_dati(token,v,t,repeat('b',64),array['foto'],attempt) then raise exception 'Secondo POST autorizzato';end if;
 if aperto and (select tentativo from public.followup_dati_invii where claim=token) is distinct from attempt then raise exception 'Prova tentativo persa';end if;
 if not public.esito_followup_dati(token,'ambiguous') then raise exception 'Ambiguità non registrata';end if;
 if public.inizia_invio_followup_dati(token,v,t,repeat('b',64),array['foto'],attempt) then raise exception 'Retry ambiguo';end if;
 -- Fixture invio passato: non una conferma reale, nessun trasporto chiamato.
 update public.followup_dati_richieste set inviata_at=t-interval '80 hours' where id=r;
 update public.followup_dati_invii set stato='sent',provider_message_id='synthetic-rollback',inviata_at=t-interval '49 hours',conferma='{"source":"synthetic"}' where claim=token;
 if not public.segnala_followup_dati(p,'preventivo',v,t) then raise exception 'Segnalazione 48h assente';end if;
 select attivita_id into activity from public.followup_dati_invii where claim=token;
 if activity is null then raise exception 'Attivita non collegata';end if;
 if public.segnala_followup_dati(p,'preventivo',v,t) then raise exception 'Segnalazione duplicata';end if;
 update public.attivita_operatore set stato='completata' where id=activity;
 if public.segnala_followup_dati(p,'preventivo',v,t) then raise exception 'Attivita completata riaperta';end if;
 select count(*) into n from public.attivita_operatore where pratica_id=p and tipo='followup_dati_preventivo';
 if n<>1 then raise exception 'Numero attività errato';end if;
end; $test$;
rollback;
select 'ok: guardie nella fascia corrente (CAS positivo solo in orario aperto), ambiguità, attività 48h unica, permessi; nessun invio' as verifica;


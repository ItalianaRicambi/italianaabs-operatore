-- Dati sintetici solo in transazione: nessun messaggio o modifica cliente viene confermato.
begin;
set local role service_role;
do $test$
declare p uuid; s uuid:=gen_random_uuid(); r uuid; r2 uuid; token uuid; claim_time timestamptz; n integer;
begin
 if has_table_privilege('anon','public.followup_dati_invii','select')
 or has_table_privilege('authenticated','public.followup_dati_richieste','insert')
 or has_function_privilege('anon','public.claim_followup_dati(uuid,timestamptz,timestamptz,text,text[])','execute') then raise exception 'Registro esposto';end if;
 if (select enabled from public.followup_dati_config where id) then raise exception 'Non testare con invii abilitati';end if;
 if public.claim_followup_dati(gen_random_uuid(),now(),now(),repeat('a',64),array['foto']) is not null then raise exception 'Claim abilitato per errore';end if;
 insert into public.pratiche(keplero_conversation_id,targa,telefono,nome_cliente,tipo_flusso,stato_commerciale,stato_completezza)
 values(s::text,'ZZ999ZZ','390000000000','Test follow-up rollback','commerciale','raccolta_dati','dati_mancanti') returning id into p;
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale)
 values(s,'test-followup-1',now()-interval '25 hours',(now()-interval '25 hours')::text,'uscita','text','Ci invia foto e targa?',repeat('a',64),false,false,
 '{"sender":"assistant","whatsapp_message":{"status":"delivered"}}');
 if public.registra_richiesta_followup_dati(p,'preventivo',s,'test-followup-1',array['foto','targa']) is not null then raise exception 'Cutover assente ignorato';end if;
 update public.followup_dati_config set accept_requests_after=now()-interval '48 hours' where id;
 r:=public.registra_richiesta_followup_dati(p,'preventivo',s,'test-followup-1',array['foto','targa']);
 if r is null then raise exception 'Prova invio verificata non registrata';end if;
 if public.registra_richiesta_followup_dati(p,'preventivo',s,'test-followup-1',array['targa','foto'])<>r then raise exception 'Registrazione duplicata';end if;
 if (select inviata_at from public.followup_dati_richieste where id=r)<>(select data_messaggio from public.keplero_originali where sessione=s and messaggio_id='test-followup-1') then raise exception 'Data invio alterata';end if;
 begin
  perform public.registra_richiesta_followup_dati(p,'preventivo',s,'test-followup-1',array['foto']);
  raise exception using errcode='XX000',message='Campi mutati sullo stesso messaggio';
 exception when sqlstate 'P0001' then null;end;
 update public.keplero_originali set originale='{"sender":"assistant","whatsapp_message":{"status":"pending"}}' where sessione=s;
 if public.registra_richiesta_followup_dati(p,'preventivo',s,'test-followup-1',array['foto','targa']) is not null then raise exception 'Invio non confermato accettato';end if;
 update public.keplero_originali set originale='{"sender":"assistant","whatsapp_message":{"status":"delivered"}}' where sessione=s;
 update public.followup_dati_config set accept_requests_after=now()-interval '1 hour' where id;
 if public.registra_richiesta_followup_dati(p,'preventivo',s,'test-followup-1',array['foto','targa']) is not null then raise exception 'Richiesta storica recuperata';end if;
 update public.followup_dati_config set accept_requests_after=now()-interval '48 hours' where id;
 -- Verifica vincolo permanente e transizioni; la concorrenza multi-connessione del worker resta da collaudare.
 insert into public.followup_dati_invii(pratica_id,fase,richiesta_id,verificata_at,impronta_verifica,campi)
 values(p,'preventivo',r,clock_timestamp(),repeat('b',64),array['foto']) returning claim,claimed_at into token,claim_time;
 insert into public.followup_dati_invii(pratica_id,fase,richiesta_id,verificata_at,impronta_verifica,campi)
 values(p,'preventivo',r,clock_timestamp(),repeat('b',64),array['foto']) on conflict(pratica_id,fase) do nothing;
 select count(*) into n from public.followup_dati_invii where pratica_id=p;
 if n<>1 then raise exception 'Duplicato pratica/fase';end if;
 if public.esito_followup_dati(token,'sent') then raise exception 'Invio senza ID confermato';end if;
 if not public.esito_followup_dati(token,'ambiguous') then raise exception 'Esito ambiguo perso';end if;
 if public.esito_followup_dati(token,'cancelled') then raise exception 'Ambiguo resettato';end if;
 if not public.esito_followup_dati(token,'sent','synthetic-rollback-provider-id',clock_timestamp(),'{"status":"confirmed","source":"synthetic-test"}') then raise exception 'Conferma successiva non registrata';end if;
 if public.esito_followup_dati(token,'ambiguous') then raise exception 'Conferma sovrascritta';end if;
 if public.esito_followup_dati(token,'sent','other-id',clock_timestamp(),'{"status":"confirmed"}') then raise exception 'ID messaggio sovrascritto';end if;
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale)
 values(s,'test-followup-2',now()-interval '1 hour',(now()-interval '1 hour')::text,'uscita','text','Ci invia solo le foto?',repeat('c',64),false,false,
 '{"sender":"assistant","whatsapp_message":{"status":"delivered"}}');
 r2:=public.registra_richiesta_followup_dati(p,'preventivo',s,'test-followup-2',array['foto']);
 if r2 is null or r2=r then raise exception 'Nuova richiesta mirata persa';end if;
 insert into public.followup_dati_invii(pratica_id,fase,richiesta_id,verificata_at,impronta_verifica,campi)
 values(p,'preventivo',r2,clock_timestamp(),repeat('c',64),array['foto']) on conflict(pratica_id,fase) do nothing;
 if (select count(*) from public.followup_dati_invii where pratica_id=p)<>1 then raise exception 'Nuova richiesta ha duplicato reminder';end if;
end; $test$;
rollback;
select 'ok: cutoff, prove invio, data originale, replay, unicità fase/pratica, esito ambiguo, conferma e permessi; nessun invio eseguito' as verifica;

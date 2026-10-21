-- Eseguire dopo la migrazione; nessun dato sintetico viene mantenuto.
begin;
set local role service_role;
do $test$
declare s uuid:=gen_random_uuid(); altra uuid:=gen_random_uuid(); n integer;
begin
 if has_table_privilege('anon','public.keplero_risposte_in_attesa','select') or has_function_privilege('authenticated','public.controllo_risposte_k()','execute') then raise exception 'Dati chat esposti';end if;
 insert into public.keplero_sessioni_originali(sessione,assistente,attivita_at,ultimo_successo_at)
 values(s,'2aef20d3-5ef8-4c81-8f21-bd450f22960c',now()-interval '1 hour',now()),(altra,'2aef20d3-5ef8-4c81-8f21-bd450f22960c',now()-interval '1 hour',now());
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale,consegna)
 values(s,'1',now()-interval '1 hour',now()::text,'entrata','text','Potete aiutarmi?',repeat('a',64),false,false,'{}','{}'),
 (altra,'2',now()-interval '30 minutes',now()::text,'uscita','text','Risposta in altra chat',repeat('b',64),false,false,'{}','{"whatsapp_message":{"status":"delivered"}}');
 if not exists(select 1 from public.keplero_risposte_in_attesa where sessione=s) then raise exception 'Attesa persa o risposta di altra chat usata';end if;
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale,consegna)
 values(s,'3',now()-interval '30 minutes',now()::text,'uscita','text','Risposta',repeat('c',64),false,false,'{}','{"whatsapp_message":{"status":"failed"}}');
 if not exists(select 1 from public.keplero_risposte_in_attesa where sessione=s and motivo like 'Invio fallito%') then raise exception 'Invio fallito ha chiuso attesa';end if;
 update public.keplero_originali set consegna='{"whatsapp_message":{"status":"sent"}}' where sessione=s and messaggio_id='3';
 if not exists(select 1 from public.keplero_risposte_in_attesa where sessione=s) then raise exception 'Invio non consegnato ha chiuso attesa';end if;
 update public.keplero_originali set consegna='{"whatsapp_message":{"status":"delivered"}}' where sessione=s and messaggio_id='3';
 if exists(select 1 from public.keplero_risposte_in_attesa where sessione=s) then raise exception 'Consegna non riconosciuta';end if;
 update public.keplero_originali set consegna='{"metadata":{"origin":"whatsapp_coexistence"}}' where sessione=s and messaggio_id='3';
 if exists(select 1 from public.keplero_risposte_in_attesa where sessione=s) then raise exception 'Risposta manuale non riconosciuta';end if;
 update public.keplero_originali set consegna='{}' where sessione=s and messaggio_id='3';
 perform public.verifica_risposta_k(s,'1','Verifica sintetica','Operatore 1');
 if exists(select 1 from public.keplero_risposte_in_attesa where sessione=s) then raise exception 'Verifica non registrata';end if;
 update public.keplero_originali set modificato=true,revisione=jsonb_build_object('impronta',repeat('d',64),'testo','Nuova richiesta urgente') where sessione=s and messaggio_id='1';
 if not exists(select 1 from public.keplero_risposte_in_attesa where sessione=s and testo='Nuova richiesta urgente') then raise exception 'Revisione non riaperta';end if;
 perform public.verifica_risposta_k(s,'1','Revisione verificata','Operatore 1');
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale)
 values(s,'4',now()-interval '20 minutes',now()::text,'entrata','text','Un altro problema',repeat('e',64),false,false,'{}');
 if not exists(select 1 from public.keplero_risposte_in_attesa where sessione=s and messaggio_id='4') then raise exception 'Nuovo messaggio non riaperto';end if;
end; $test$;
rollback;
select 'ok: attesa, isolamento chat, invio fallito, consegna, coesistenza, verifica e riapertura' as verifica;

begin;
do $test$
declare p uuid; p2 uuid; p3 uuid; e bigint; e2 bigint; n integer; r jsonb; d text;
begin
 if not private.richiesta_richiamata_esplicita('Potete farmi contattare dal vostro tecnico il prima possibile?')
  or private.richiesta_richiamata_esplicita('Non potete farmi contattare')
  or private.richiesta_richiamata_esplicita('Vi richiamo io domani') then raise exception 'Riconoscimento richiamata errato'; end if;
 if has_function_privilege('anon','private.riprocessa_evento_keplero(bigint)','execute')
  or has_function_privilege('authenticated','private.esegui_manutenzione_keplero()','execute') then raise exception 'Funzioni interne esposte'; end if;

 insert into public.pratiche(nome_cliente,targa,tipo_flusso,tipo_assistenza,stato_assistenza,
  assistenza_chiusa_at,blocco_classificazione_operatore,fonte_classificazione)
 values('TEST assistenza chiusa','TREQ001','assistenza','montaggio_codifica','risolta',now()-interval '1 hour',true,'operatore') returning id into p;
 insert into public.keplero_live_events(pratica_id,external_key,payload,created_at)
 values(p,'test-richieste',jsonb_build_object('targa','TREQ001','ultimo_messaggio_cliente','Potete farmi contattare dal vostro tecnico il prima possibile?'),now()-interval '2 hours');
 if exists(select 1 from public.assistenze_rientri where pratica_id=p) or exists(select 1 from public.attivita_operatore where pratica_id=p) then raise exception 'Vecchio episodio riaperto'; end if;
 insert into public.keplero_live_events(pratica_id,external_key,payload,created_at)
 values(p,'test-richieste',jsonb_build_object('targa','TREQ001','ultimo_messaggio_cliente','Potete farmi contattare dal vostro tecnico il prima possibile?'),now()-interval '30 minutes') returning id into e;
 if (select count(*) from public.assistenze_rientri where pratica_id=p)<>1
  or (select count(*) from public.attivita_operatore where pratica_id=p and tipo='richiamata_post_vendita')<>1
  or (select stato_assistenza from public.pratiche where id=p)<>'risolta' then raise exception 'Nuova richiesta invisibile o chiusura operatore sovrascritta'; end if;
 r:=private.riprocessa_evento_keplero(e);
 if r->>'esito'='errore' or (select count(*) from public.assistenze_rientri where pratica_id=p)<>1
  or (select count(*) from public.attivita_operatore where pratica_id=p)<>1 then raise exception 'Replay duplicato o errore %',r; end if;

 insert into public.pratiche(nome_cliente,tipo_flusso,tipo_assistenza,stato_assistenza)
 values('TEST Venanzi senza identificativi','assistenza','montaggio_codifica','da_verificare') returning id into p2;
 insert into public.keplero_live_events(pratica_id,external_key,payload)
 values(p2,'test-senza-targa','{"ultimo_messaggio_cliente":"Ho acquistato una pompa ABS seguendo il programma scambio, sto avendo problemi con la codifica, non riescono a configurarla"}') returning id into e2;
 if not exists(select 1 from public.assistenze_rientri where pratica_id=p2 and pratica_origine_id is null)
  then raise exception 'Assistenza senza targa bloccata o origine inventata'; end if;
 update private.keplero_event_processing set stato='errore',errore='deadlock detected' where event_id=e2;
 r:=private.riprocessa_evento_keplero(e2);
 if r->>'esito'='errore' or (select errore from private.keplero_event_processing where event_id=e2) is not null then raise exception 'Errore non recuperato %',r; end if;

 -- Una fase successiva fallita non deve risultare recuperata solo perché
 -- l'elaborazione principale è riuscita. Il tentativo seguente la riprende.
 d:=pg_get_functiondef('private.precompila_presa_evento(bigint)'::regprocedure);
 execute $stub$create or replace function private.precompila_presa_evento(p_event_id bigint)
 returns void language plpgsql set search_path='' as $body$
 begin raise exception 'TEST errore fase successiva'; end; $body$$stub$;
 r:=private.riprocessa_evento_keplero(e2);
 if r->>'esito'<>'errore' or (select errore from private.keplero_event_processing where event_id=e2)<>'TEST errore fase successiva' then raise exception 'Errore secondario nascosto'; end if;
 execute d;
 r:=private.riprocessa_evento_keplero(e2);
 if r->>'esito'='errore' then raise exception 'Ripresa dopo errore non riuscita'; end if;

 insert into public.pratiche(nome_cliente,targa,tipo_flusso,stato_commerciale,stato_fatturazione)
 values('TEST preventivo garanzia','TREQ003','commerciale','raccolta_dati','non_applicabile') returning id into p3;
 insert into public.keplero_live_events(pratica_id,external_key,payload)
 values(p3,'test-preventivo','{"ultimo_messaggio_cliente":"Vorrei richiedere un preventivo per il mio ABS perfettamente funzionante, per mantenere la codifica. Quale garanzia?"}');
 if exists(select 1 from public.assistenze_rientri where pratica_id=p3) then raise exception 'Preventivo scambiato per post vendita'; end if;
 if (select count(*) from cron.job where jobname in ('ritenta-preventivi-non-abbinati','recupera-offerte-ritiri-assistenza') and active and command='select private.esegui_manutenzione_keplero();')<>2 then raise exception 'Job non coordinati o disattivati'; end if;
end;
$test$;

-- Il percorso reale usa service_role; i trigger mantengono i loro privilegi.
set local role service_role;
do $test$
declare r jsonb; p uuid;
begin
 r:=public.upsert_keplero_live(p_external_key:='test-service-tecnica',p_nome_cliente:='TEST service',
  p_telefono:='390000000001',p_tipo_flusso:='assistenza',p_tipo_assistenza:='montaggio_codifica',
  p_ultimo_messaggio_cliente:='Ho acquistato una pompa ABS e ho problemi con la codifica',
  p_payload:='{"ultimo_messaggio_cliente":"Ho acquistato una pompa ABS e ho problemi con la codifica"}');
 p:=(r->>'pratica_id')::uuid;
 if p is null or not exists(select 1 from public.assistenze_rientri where pratica_id=p)
  then raise exception 'Intake service_role non registra assistenza'; end if;
end;
$test$;
reset role;
rollback;

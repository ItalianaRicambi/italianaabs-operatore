-- Collaudo in rollback delle richieste di rientro e dei falsi positivi diagnostici.
begin;
select pg_advisory_xact_lock(20261015,94749);
set local role service_role;
do $test$
declare caso record; p uuid; e bigint; n integer; prima integer;
begin
 for caso in select * from (values
  ('Il guasto non è rientrato. Potrebbe essere il modulo ABS?',false),
  ('Il guasto può rientrare nel difetto del modulo ABS?',false),
  ('Il problema rientra nelle anomalie della centralina',false),
  ('Rientro della pompa ABS per verifica',true),
  ('Devo far rientrare il mio modulo ABS',true),
  ('Rientro in garanzia della centralina',true),
  ('Devo restituire la pompa ABS',true),
  ('Il pacco è pronto per il ritiro',true),
  ('Potete organizzare il ritiro?',true),
  ('Il guasto non è rientrato. Potete organizzare il ritiro?',true),
  ('Il pacco non è pronto per il ritiro',false),
  ('Non prenotare il ritiro del pacco',false),
  ('Il rientro della pompa è solo ipotetico',false)
 ) as x(testo,atteso)
 loop
  insert into public.pratiche(nome_cliente,targa,tipo_flusso,stato_commerciale)
   values('Collaudo rientro fisico','TSTRIE1','commerciale','raccolta_dati') returning id into p;
  insert into public.keplero_live_events(external_key,pratica_id,payload)
   values('collaudo-rientro:'||p,p,jsonb_build_object('targa','TSTRIE1','ultimo_messaggio_cliente',caso.testo))
   returning id into e;
  perform private.rileva_attivita_operativa_evento(e);
  select count(*) into n from public.attivita_operatore where pratica_id=p and tipo like 'ritiro_%';
  if (n=1) is distinct from caso.atteso or n>1 then
   raise exception 'Rilevamento errato: %; attività %, atteso %',caso.testo,n,caso.atteso;
  end if;
  perform private.rileva_rientro_evento(e);
  if n<>(select count(*) from public.attivita_operatore where pratica_id=p and tipo like 'ritiro_%')
   then raise exception 'Replay non idempotente'; end if;
 end loop;
 if private.richiesta_rientro_dispositivo(null) then raise exception 'Null non escluso'; end if;
end;
$test$;
reset role;
do $test$
begin
 if has_function_privilege('anon','private.richiesta_rientro_dispositivo(text)','execute')
 or has_function_privilege('authenticated','private.richiesta_rientro_dispositivo(text)','execute')
 or not has_function_privilege('service_role','private.richiesta_rientro_dispositivo(text)','execute')
 then raise exception 'Permessi helper errati'; end if;
end;
$test$;
rollback;

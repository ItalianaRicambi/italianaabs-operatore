begin;
set local role service_role;
do $test$
declare p uuid; q uuid; e bigint; r jsonb; idx integer:=0; caso record; key text;
begin
 for caso in select * from (values
  ('Preferisco RI','preferenza','RI'),
  ('RI, se non è possibile allora PS','condizionata','RI'),
  ('Scelgo opzione 1 e opzione 2','da_chiarire',null),
  ('Scelgo quella da 597 euro','da_chiarire',null),
  ('Accetto opzione 1 quella da 597 euro','da_chiarire',null),
  ('Scelgo RI e PS','da_chiarire',null),
  ('Scelgo RI, non PS','confermata','RI'),
  ('Preferisco RI, confermo il preventivo, procedete','confermata','RI'),
  ('Il proprietario ha deciso per la prima opzione, la lavorazione sull’originale','confermata','RI'),
  ('Accetto il preventivo','da_chiarire',null)
 ) x(testo,stato,servizio) loop
  idx:=idx+1; key:='test:guardie:offerta:'||idx;
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
   values('TSTG00'||idx,'Test guardie scelta','commerciale','preventivo_inviato',now()-interval '2 hours') returning id into p;
  insert into public.keplero_live_links(external_key,pratica_id) values(key,p);
  insert into public.preventivi(pratica_id,stato,inviato_at,creato_at) values(p,'inviato',now()-interval '2 hours',now()-interval '2 hours') returning id into q;
  perform public.registra_opzioni_offerta(q,'[{"numero":1,"servizio":"RI","descrizione":"RI","importo":447,"iva_inclusa":true},{"numero":2,"servizio":"PS","descrizione":"PS","importo":597,"iva_inclusa":true},{"numero":3,"servizio":"PSMI","descrizione":"PSMI","importo":597,"iva_inclusa":true}]','test-impronta-guardie');
  insert into public.keplero_live_events(external_key,pratica_id,payload)
  values(key,p,jsonb_build_object('targa','TSTG00'||idx,'ultimo_messaggio_cliente',caso.testo,'ordine_confermato_rilevato',true)) returning id into e;
  if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato=caso.stato and servizio is not distinct from caso.servizio) then
   raise exception 'Scelta errata per %: %',caso.testo,(select to_jsonb(s) from public.v_scelte_cliente s where pratica_id=p); end if;
  if caso.stato in ('preferenza','condizionata') and exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Preferenza/condizione trasformata in ordine: %',caso.testo; end if;
  if caso.testo='Accetto il preventivo' then
   insert into public.keplero_live_events(external_key,pratica_id,payload)
   values(key,p,jsonb_build_object('targa','TSTG00'||idx,'ultimo_messaggio_cliente','RI'));
   if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato='confermata' and servizio='RI') then raise exception 'Risposta breve non chiarisce scelta dopo accettazione'; end if;
  end if;
 end loop;
 -- Confermata RI, il cambio successivo richiede verifica e conserva RI anche al retry.
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values(key,p,jsonb_build_object('targa','TSTG00'||idx,'ultimo_messaggio_cliente','Cambio idea, scelgo PSMI')) returning id into e;
 perform private.rileva_scelta_cliente_evento(e);
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and stato='modifica_da_verificare' and servizio='RI') then raise exception 'Retry ha sostituito la scelta confermata'; end if;
 -- Una sola alternativa consente accettazione breve, ma il solo preventivo non acquisisce ordine.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('TSTG010','Test singola PSMI','commerciale','preventivo_inviato',now()-interval '1 hour') returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:singola:psmi',p);
 insert into public.preventivi(pratica_id,stato,inviato_at,creato_at) values(p,'inviato',now()-interval '1 hour',now()-interval '1 hour') returning id into q;
 perform public.registra_opzioni_offerta(q,'[{"numero":1,"numero_esplicito":false,"servizio":"PSMI","descrizione":"PSMI","importo":497,"iva_inclusa":true}]','test-impronta-singola');
 if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'La sola offerta ha acquisito ordine'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:singola:psmi',p,'{"targa":"TSTG010","ultimo_messaggio_cliente":"Non accetto PSMI"}');
 if exists(select 1 from public.scelte_cliente where pratica_id=p) then raise exception 'Rifiuto registrato come scelta positiva'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:singola:psmi',p,'{"targa":"TSTG010","ultimo_messaggio_cliente":"Confermo ricezione"}'),
 ('test:singola:psmi',p,'{"targa":"TSTG010","ultimo_messaggio_cliente":"Confermo il codice della pompa e le spie accese"}');
 if exists(select 1 from public.scelte_cliente where pratica_id=p) then raise exception 'Conferma diagnostica registrata come scelta commerciale'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:singola:psmi',p,'{"targa":"TSTG010","ultimo_messaggio_cliente":"Accetto"}');
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and servizio='PSMI' and stato='confermata') then raise exception 'Singola opzione non riconosciuta'; end if;
 -- Origine targa diversa: la scelta non si applica a un'altra vettura della stessa chat.
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:singola:psmi',p,'{"targa":"XY999ZZ","ultimo_messaggio_cliente":"Scelgo RI"}');
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and servizio='PSMI' and stato='confermata') then raise exception 'Targa diversa ha cambiato la scelta'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:singola:psmi',p,'{"targa":"TSTG010","ultimo_messaggio_cliente":"Ho appena effettuato il bonifico di 397,00 euro"}');
 if not exists(select 1 from public.v_scelte_cliente where pratica_id=p and servizio='PSMI' and importo=497 and prezzo_da_verificare) then raise exception 'Pagamento diverso cambia il prezzo o non genera verifica'; end if;
end; $test$;
reset role;
rollback;

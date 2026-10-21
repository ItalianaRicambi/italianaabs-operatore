-- Da eseguire dopo la migrazione. Dati sintetici interamente annullati.
begin;
set local role service_role;
do $test$
declare p uuid; v_sessione uuid; preventivo uuid; offerta uuid; doc uuid;
 l uuid; messaggi jsonb; r jsonb; frase text; i integer; n integer;
 casi text[]:=array['Confermo RI','Ripariamo la nostra','Confermo lo scambio','Confermo RI se disponibile','Non confermo RI','Confermo il mio indirizzo','Confermo idraulica e programma scambio'];
begin
 if has_function_privilege('anon','public.registra_originali_k(uuid,uuid,jsonb)','execute')
  or has_table_privilege('authenticated','public.keplero_originali','select') then raise exception 'Originali esposti';end if;
 if public.autorizza_worker_originali_k('inesistente') then raise exception 'Ticket invalido accettato';end if;
 for i in 1..cardinality(casi) loop
  v_sessione:=gen_random_uuid();l:=gen_random_uuid();frase:=casi[i];
  insert into public.pratiche(keplero_conversation_id,targa,telefono,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at,created_at)
  values(v_sessione::text,'ZZ'||lpad(i::text,3,'0')||'AA','390000000'||i,'Test originali rollback','commerciale','preventivo_inviato',now()-interval '1 hour',now()-interval '2 hours') returning id into p;
  insert into public.keplero_live_links(external_key,pratica_id) values('test:originali:'||v_sessione,p);
  insert into public.preventivi(pratica_id,external_id,stato,inviato_at,creato_at)
  values(p,'test:originali:'||v_sessione,'inviato',now()-interval '1 hour',now()-interval '1 hour') returning id into preventivo;
  r:=public.registra_opzioni_offerta(preventivo,'[{"numero":1,"servizio":"RI","importo":447},{"numero":2,"servizio":"PS","importo":597},{"numero":3,"servizio":"PSMI","importo":547}]'::jsonb,encode(sha256(convert_to(v_sessione::text,'UTF8')),'hex'));
  offerta:=(r->>'offerta_id')::uuid;
  insert into public.documenti_preventivo_auto(external_id,impronta,sha256_pdf,nome_file,targa,data_offerta,contenuto,pratica_id,stato)
  select 'test:originali:'||v_sessione,q.impronta,encode(sha256(convert_to('pdf:'||v_sessione,'UTF8')),'hex'),q.targa||'.pdf',q.targa,now()-interval '1 hour','{}',p,'pronto' from public.offerte_versioni q where id=offerta returning id into doc;
  update public.keplero_recupero_originali set lease=l,scade_at=now()+interval '90 seconds' where id;
  insert into public.keplero_sessioni_originali(sessione,lease,ultimo_tentativo_at) values(v_sessione,l,now());
  messaggi:=jsonb_build_array(
   jsonb_build_object('id','1','data',now()-interval '50 minutes','data_originale',(now()-interval '50 minutes')::text,'direzione','uscita','tipo','file','testo','attachment:originale-verificato','impronta',repeat('a',64),'candidato',false,'revoca',false,'targa_pdf','ZZ'||lpad(i::text,3,'0')||'AA','sha256_pdf',encode(sha256(convert_to('pdf:'||v_sessione,'UTF8')),'hex')),
   jsonb_build_object('id','2','data',now()-interval '40 minutes','data_originale',(now()-interval '40 minutes')::text,'direzione','entrata','tipo','text','testo',frase,'impronta',repeat('b',64),'candidato',true,'revoca',i=5));
  perform public.registra_originali_k(l,v_sessione,messaggi);
  perform private.valuta_originale_k(v_sessione,'2');
  if i in (1,2) then
   if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare')
     or not exists(select 1 from public.keplero_verifiche_originali where sessione=v_sessione and messaggio_id='2' and pratica_id=p and esito='recuperata') then raise exception 'Consenso univoco non recuperato: %',frase;end if;
  else
   if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Caso ambiguo ha acquisito ordine: %',frase;end if;
  end if;
  select count(*) into n from public.keplero_verifiche_originali where pratica_id=p;
  update public.keplero_sessioni_originali set lease=l where keplero_sessioni_originali.sessione=v_sessione;
  perform public.registra_originali_k(l,v_sessione,messaggi);
  if (select count(*) from public.keplero_verifiche_originali where pratica_id=p)<>n then raise exception 'Replay duplicato';end if;
  -- Una revisione non annulla né sostituisce il primo consenso.
  update public.keplero_sessioni_originali set lease=l where keplero_sessioni_originali.sessione=v_sessione;
  messaggi:=jsonb_set(jsonb_set(messaggi,'{1,testo}','"Non confermo più"'),'{1,impronta}',to_jsonb(repeat('c',64)));
  perform public.registra_originali_k(l,v_sessione,messaggi);
  if not exists(select 1 from public.keplero_originali k where k.sessione=v_sessione and messaggio_id='2' and modificato and testo=frase)
    or not exists(select 1 from public.keplero_verifiche_originali k where k.sessione=v_sessione and messaggio_id='2' and esito='da_verificare') then raise exception 'Revisione non conservata';end if;
 end loop;
end; $test$;
rollback;
select 'ok: consensi originali, ambiguità, revoche, revisioni, replay e permessi' verifica;

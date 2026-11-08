begin;
set local role service_role;
do $test$
declare p uuid; q uuid; sess uuid:=gen_random_uuid(); cid uuid; imp uuid; d jsonb; f jsonb; r jsonb; n bigint; errore boolean;
begin
 if has_function_privilege('anon','public.fic_registra_fattura_chat(uuid,text,jsonb,jsonb)','execute')
  or has_function_privilege('authenticated','public.fic_registra_controllo_cliente(uuid,jsonb,text)','execute') then raise exception 'RPC esposte';end if;
 insert into public.pratiche(nome_cliente,targa,keplero_conversation_id,tipo_flusso,stato_commerciale,stato_fatturazione,created_at,dati_raw)
 values('TEST avvisi fattura','TFIC001',sess::text,'commerciale','ordine_acquisito','da_fatturare',now()-interval '1 day','{"anagrafica_estratta":{"codice_fiscale":"TSTFSC80A01F952A"},"payload_live":{"anagrafica_fiscale":{"codice_fiscale":"TSTFSC80A01F952A"}}}') returning id into p;
 if public.contesto_cliente_keplero(p)->>'richiedere_anagrafica_completa'<>'false' then raise exception 'Richiesta dati duplicata';end if;
 r:=public.fic_registra_controllo_cliente(p,'[{"id":999999999999,"name":"Cliente test automazione","tax_code":"TSTFSC80A01F952A","address_street":"Via Test 1","address_city":"Roma","address_postal_code":"00100","country":"Italia"}]','riconosciuto');
 select cliente_id into cid from public.pratiche where id=p;
 if cid is null or r->>'esito'<>'riconosciuto' or (select stato_amministrativo from public.pratiche where id=p)<>'pronto_fatturazione' then raise exception 'Anagrafica FIC non riusata';end if;
 select count(*) into n from public.clienti;
 perform public.fic_registra_controllo_cliente(p,'[{"id":999999999999,"name":"Cliente test automazione","tax_code":"TSTFSC80A01F952A","address_street":"Via Test 1","address_city":"Roma","address_postal_code":"00100","country":"Italia"}]','riconosciuto');
 if (select count(*) from public.clienti)<>n then raise exception 'Anagrafica duplicata';end if;
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,originale)
 values(sess,'test-fattura',now(),now()::text,'uscita','file','attachment:https://v2.api.keplero.ai/v2/session-attachments/test/fattura.pdf',repeat('a',64),false,false,'{"sender_type":"user","metadata":{"origin":"whatsapp_coexistence"}}');
 d:=jsonb_build_object('tipo','fattura','numero','TEST-FIC-AUTO/2026','data',current_date,'targa','TFIC001','importo',497,'sha256_pdf',repeat('b',64),'cliente',jsonb_build_object('codice_fiscale','TSTFSC80A01F952A'));
 f:=jsonb_build_object('id',999999999999,'tipo','invoice','numero','TEST-FIC-AUTO/2026','data',current_date,'importo',497,'valuta','EUR','codiceFiscale','TSTFSC80A01F952A','partitaIva','');
 -- Ogni caso negativo deve lasciare la pratica da fatturare.
 for n in 1..7 loop
  errore:=false;
  begin
   if n=1 then update public.keplero_originali set direzione='entrata' where sessione=sess;
   elsif n=2 then update public.keplero_originali set originale='{}' where sessione=sess;
   elsif n=3 then update public.pratiche set blocco_operatore=true where id=p;
   elsif n=4 then perform public.gestisci_sospensione_fatturazione(p,true,'Operatore 1');
   end if;
   perform public.fic_registra_fattura_chat(sess,'test-fattura',case when n=5 then d||'{"tipo":"proforma"}' when n=6 then d||'{"targa":"DIVERSA"}' else d end,case when n=7 then f||'{"codiceFiscale":"TSTFSC81A01F952A"}' else f end);
  exception when others then errore:=true;end;
  if not errore then raise exception 'Caso negativo % accettato',n;end if;
 end loop;
 if exists(select 1 from public.documenti_amministrativi where pratica_id=p) then raise exception 'Scritture parziali';end if;
 r:=public.fic_registra_fattura_chat(sess,'test-fattura',d,f);
 if r->>'esito'<>'fatturata' or (select stato_fatturazione from public.pratiche where id=p)<>'fatturato' then raise exception 'Fattura non aggiornata';end if;
 if (select stato_logistica from public.pratiche where id=p)<>'non_applicabile' then raise exception 'Logistica modificata';end if;
 r:=public.fic_registra_fattura_chat(sess,'test-fattura',d,f);
 if r->>'esito'<>'gia_registrata' or (select count(*) from public.documenti_amministrativi where pratica_id=p)<>1 then raise exception 'Replay duplicato';end if;
 perform public.fic_segnala_fattura_chat(sess,'test-fattura');
end $test$;
rollback;
select 'OK: anagrafica riusata, avviso, guardie WhatsApp e fiscali, fatturazione, replay, logistica e permessi' as verifica;

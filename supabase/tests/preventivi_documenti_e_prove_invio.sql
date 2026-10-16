begin;
set local role service_role;
do $test$
declare p uuid; p2 uuid; d uuid; d2 uuid; r jsonb; c jsonb; prova jsonb; msg text;
begin
 c:=jsonb_build_object('opzioni',jsonb_build_array(jsonb_build_object('numero',1,'numero_esplicito',true,'servizio','RI','descrizione','Riparazione idraulica','importo',447,'iva_inclusa',true)),
 'impronta',repeat('a',64),'testo','Documento di collaudo','errore',null,'fonte','pdf','validita_giorni',15);
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,keplero_conversation_id,created_at)
 values('TSTD26','Test PDF automatico','commerciale','da_preventivare','11111111-1111-4111-8111-111111111111',now()-interval '1 day') returning id into p;
 r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','test:documento:26','nome_file','TSTD26 (1).pdf','targa','TSTD26','data_offerta',now()-interval '1 hour','contenuto',c));
 d:=(r->>'documento_id')::uuid;
 if r->>'esito'<>'pronto' or r->>'pratica_id'<>p::text then raise exception 'Documento non collegato'; end if;
 if (select stato_commerciale from public.pratiche where id=p)<>'da_preventivare' or exists(select 1 from public.preventivi where pratica_id=p) then raise exception 'Drive trattato come invio'; end if;
 r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','test:documento:26','nome_file','TSTD26 (1).pdf','targa','TSTD26','data_offerta',now()-interval '1 hour','contenuto',c));
 if (select count(*) from public.documenti_preventivo_auto where external_id='test:documento:26')<>1 then raise exception 'Retry duplicato'; end if;
 prova:=jsonb_build_object('fonte','keplero_originale_verificato','fonte_id','keplero:11111111-1111-4111-8111-111111111111:26','conversazione_id','11111111-1111-4111-8111-111111111111','messaggio_id','26','direzione','entrata','esito','inviato','verificata_originale',true,'impronta_documento',repeat('a',64),'inviato_at',now()-interval '30 minutes');
 begin
  perform public.conferma_invio_documento_preventivo(d,prova);
  raise exception 'TEST: file cliente promosso';
 exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
 begin
  perform public.conferma_invio_documento_preventivo(d,prova||'{"direzione":"uscita","conversazione_id":"22222222-2222-4222-8222-222222222222"}');
  raise exception 'TEST: conversazione diversa accettata';
 exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
 begin
  perform public.conferma_invio_documento_preventivo(d,prova||jsonb_build_object('direzione','uscita','impronta_documento',repeat('b',64)));
  raise exception 'TEST: file omonimo con contenuto diverso accettato';
 exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
 begin
  perform public.conferma_invio_documento_preventivo(d,(prova-'conversazione_id')||'{"direzione":"uscita"}');
  raise exception 'TEST: riferimento conversazione assente accettato';
 exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
 update public.pratiche set blocco_operatore=true where id=p;
 r:=public.conferma_invio_documento_preventivo(d,prova||'{"direzione":"uscita"}');
 if exists(select 1 from public.preventivi where pratica_id=p) or (select stato_commerciale from public.pratiche where id=p)<>'da_preventivare' then raise exception 'Correzione operatore superata'; end if;
 if (select prova_invio from public.documenti_preventivo_auto where id=d) is null then raise exception 'Prova persa durante blocco'; end if;
 update public.pratiche set blocco_operatore=false where id=p;
 r:=public.conferma_invio_documento_preventivo(d,prova||'{"direzione":"uscita"}');
 if not coalesce((r->>'ok')::boolean,false) or (select stato_commerciale from public.pratiche where id=p)<>'preventivo_inviato' then raise exception 'Invio originale non applicato: %',r; end if;
 if not exists(select 1 from public.offerte_versioni o join public.offerta_opzioni x on x.offerta_id=o.id where o.pratica_id=p and x.importo=447 and x.servizio='RI') then raise exception 'Prezzi non registrati'; end if;
 r:=public.conferma_invio_documento_preventivo(d,prova||'{"direzione":"uscita"}');
 if (select count(*) from public.preventivi where pratica_id=p)<>1 then raise exception 'Prova ripetuta duplica preventivo'; end if;
 -- Nuovo documento: acquisizione metadati consentita, avanzamento esistente protetto.
 update public.pratiche set stato_commerciale='ordine_acquisito' where id=p;
 r:=public.conferma_invio_documento_preventivo(d,prova||'{"direzione":"uscita"}');
 if (select stato_commerciale from public.pratiche where id=p)<>'ordine_acquisito' then raise exception 'Regressione ordine'; end if;
 -- Più pratiche per stessa targa: nessuna scelta arbitraria.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTAMB26','Test ambiguità','commerciale','da_preventivare',now()-interval '1 day'),
 ('TSTAMB26','Test ambiguità 2','commerciale','da_preventivare',now()-interval '1 day');
 r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','test:ambiguo:26','nome_file','TSTAMB26.pdf','targa','TSTAMB26','data_offerta',now(),'contenuto',c));
 if r->>'esito'<>'da_abbinare' or r->>'pratica_id' is not null then raise exception 'Ambiguo collegato'; end if;
 -- Il clic manuale collega le proposte già acquisite, non è necessario ricaricarle.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
 values('TSTMAN26','Test conferma operatore','commerciale','da_preventivare',now()-interval '1 day') returning id into p2;
 r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','test:manuale:26','nome_file','TSTMAN26.pdf','targa','TSTMAN26','data_offerta',now()-interval '1 hour','contenuto',c));
 update public.pratiche set stato_commerciale='preventivo_inviato',preventivo_inviato_at=now() where id=p2;
 insert into public.azioni_operatore(pratica_id,azione,nota,operatore) values(p2,'commerciale_preventivo_inviato','Collaudo','Operatore 1');
 if not exists(select 1 from public.documenti_preventivo_auto where pratica_id=p2 and stato='inviato' and prova_invio->>'fonte'='operatore') then raise exception 'Conferma manuale non collega documento'; end if;
 if has_function_privilege('anon','public.registra_documento_preventivo_auto(jsonb)','EXECUTE') or has_table_privilege('authenticated','public.documenti_preventivo_auto','SELECT') then raise exception 'ACL esposte'; end if;
end; $test$;
reset role;
rollback;

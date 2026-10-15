begin;
set local role service_role;
do $test$
declare p uuid;p2 uuid;q uuid;r jsonb;r2 jsonb;stato_prima jsonb;
 t timestamptz:=now()-interval '2 hours';
 c jsonb:='{"opzioni":[{"numero":1,"servizio":"RI","importo":447,"iva_inclusa":true},{"numero":2,"servizio":"PS","importo":597,"iva_inclusa":true}],"impronta":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","testo":"alternative trascritte dall’operatore"}';
begin
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at,blocco_classificazione_operatore)
 values('TSTOF001','Test alternative senza PDF','commerciale','preventivo_inviato',t,true) returning id into p;
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
 values('TSTOF002','Test preventivo estraneo','commerciale','da_preventivare') returning id into p2;
 select jsonb_build_object('commerciale',stato_commerciale,'fatturazione',stato_fatturazione,'data',preventivo_inviato_at,'blocco',blocco_classificazione_operatore) into stato_prima from public.pratiche where id=p;
 r:=public.registra_alternative_offerta_operatore(p,null,c,'Operatore 1');
 q:=(r->>'preventivo_id')::uuid;
 if r->>'ok'<>'true' or r->>'preventivo_creato'<>'true' then raise exception 'Preventivo mancante non creato'; end if;
 if not exists(select 1 from public.preventivi where id=q and pratica_id=p and file_url is null and inviato_at=t)
  or (select count(*) from public.offerta_opzioni where offerta_id=(r->>'offerta_id')::uuid)<>2 then raise exception 'Alternative o data non conservate'; end if;
 if (select jsonb_build_object('commerciale',stato_commerciale,'fatturazione',stato_fatturazione,'data',preventivo_inviato_at,'blocco',blocco_classificazione_operatore) from public.pratiche where id=p) is distinct from stato_prima then raise exception 'Registrazione ha modificato la pratica'; end if;
 r2:=public.registra_alternative_offerta_operatore(p,null,c,'Operatore 1');
 if r2->>'duplicato'<>'true' or (select count(*) from public.preventivi where pratica_id=p)<>1
  or (select count(*) from public.offerte_versioni where pratica_id=p)<>1 then raise exception 'Retry duplicato'; end if;
 begin
  perform public.registra_alternative_offerta_operatore(p2,q,c,'Operatore 1');
  raise exception 'Accettato preventivo estraneo';
 exception when others then
  if sqlerrm<>'Preventivo estraneo alla pratica' then raise; end if;
 end;
 begin
  perform public.registra_alternative_offerta_operatore(p2,null,c,'Operatore 1');
  raise exception 'Inventata data di invio';
 exception when others then
  if sqlerrm<>'Registra prima l’invio del preventivo nella sezione commerciale' then raise; end if;
 end;
 if exists(select 1 from public.preventivi where pratica_id=p2) then raise exception 'Errore ha lasciato un preventivo orfano'; end if;
 begin
  perform public.registra_alternative_offerta_operatore(p,null,jsonb_set(c,'{opzioni,0,importo}','-1'),'Operatore 1');
  raise exception 'Accettato prezzo negativo';
 exception when others then
  if sqlerrm not in ('Alternative non valide','Importi o numeri delle alternative non validi') then raise; end if;
 end;
 if has_function_privilege('anon','public.registra_alternative_offerta_operatore(uuid,uuid,jsonb,text)','execute')
  or has_function_privilege('authenticated','public.registra_alternative_offerta_operatore(uuid,uuid,jsonb,text)','execute') then raise exception 'Funzione accessibile pubblicamente'; end if;
end; $test$;
reset role;
rollback;

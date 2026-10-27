-- Collaudo in rollback: nessuna pratica o modifica di test resta salvata.
begin;
set local role service_role;
do $test$
declare p uuid; assistenza uuid; storico jsonb;
begin
 if exists (
  select 1 from private.candidati_flussi_offerta_rientro() c join public.pratiche p on p.id=c.pratica_id
  where p.dati_raw#>>'{archiviazione_test,archiviata}'='true'
   or p.dati_raw#>>'{pratica_duplicata,archiviata}'='true'
 ) then raise exception 'Avvisi operativi su pratiche archiviate'; end if;
 -- Tutte e tre le categorie cessano sulle vendite concluse, anche reali.
 if exists (
   select 1 from private.candidati_flussi_offerta_rientro() c
   join public.pratiche p on p.id=c.pratica_id
   where c.regola in ('scelta_cliente_da_chiarire','scelta_versione_precedente','prezzo_scelta_da_verificare')
    and (p.stato_fatturazione='fatturato' or p.stato_commerciale in ('chiuso','rifiutato') or p.tipo_flusso<>'commerciale')
 ) then raise exception 'Avvisi di scelta presenti su vendite concluse'; end if;

 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
 values('TSTCF14','Collaudo coerenza scelte fatturate','commerciale','preventivo_inviato') returning id into p;
 insert into public.scelte_cliente(pratica_id,stato,evidenza,richiesta_at,fonte)
 values(p,'da_chiarire','Scelta ambigua di collaudo',now(),'test');
 if not exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p and regola='scelta_cliente_da_chiarire')
 then raise exception 'Scelta ambigua aperta nascosta'; end if;
 select to_jsonb(s) into storico from public.scelte_cliente s where pratica_id=p;

 update public.pratiche set stato_commerciale='ordine_acquisito',stato_fatturazione='da_fatturare',ordine_acquisito_at=now() where id=p;
 perform public.crea_e_collega_cliente_pratica(p,'Collaudo coerenza fiscale','Via Test 1','Novara','28100',
  p_codice_fiscale=>'TSTFSC80A01F952A',p_email=>'coerenza@test.invalid');
 update public.pratiche set stato_fatturazione='fatturato' where id=p;
 if exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p and regola='scelta_cliente_da_chiarire')
 then raise exception 'La fatturazione non chiude gli avvisi commerciali'; end if;
 if storico is distinct from (select to_jsonb(s) from public.scelte_cliente s where pratica_id=p)
 then raise exception 'Lo storico della scelta è stato modificato'; end if;
 update public.scelte_cliente set stato='modifica_da_verificare' where pratica_id=p;
 if exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p and regola='scelta_cliente_da_chiarire')
 then raise exception 'Un aggiornamento successivo ha riaperto una vendita fatturata'; end if;

 -- Una fattura non deve nascondere un vero rientro in assistenza.
 insert into public.assistenze_rientri(pratica_id,evidenza,aperta_at)
 values(p,'Rientro tecnico di collaudo',now()-interval '10 days') returning id into assistenza;
 if not exists(select 1 from private.candidati_flussi_offerta_rientro() where chiave='assistenza_non_assegnata:'||assistenza)
 then raise exception 'Assistenza urgente della pratica fatturata nascosta'; end if;

 -- Archiviazione esplicita: spariscono gli avvisi, non lo storico sottostante.
 update public.pratiche set dati_raw=jsonb_set(coalesce(dati_raw,'{}'),'{archiviazione_test}',
  '{"archiviata":true}') where id=p;
 if exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p)
 then raise exception 'Pratica di test archiviata ancora segnalata'; end if;
 update public.pratiche set dati_raw=(dati_raw-'archiviazione_test') ||
  '{"pratica_duplicata":{"archiviata":true}}'::jsonb where id=p;
 if exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p)
 then raise exception 'Duplicato archiviato ancora segnalato'; end if;
 update public.pratiche set dati_raw=dati_raw-'pratica_duplicata' where id=p;
 -- I trigger di archiviazione possono chiudere l'episodio; non lo riapriamo.
 if not exists(select 1 from public.assistenze_rientri where id=assistenza)
 then raise exception 'Storico assistenza eliminato'; end if;

 update public.pratiche set stato_fatturazione='non_applicabile',stato_commerciale='chiuso' where id=p;
 if exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p and regola='scelta_cliente_da_chiarire')
 then raise exception 'Vendita chiusa ancora segnalata'; end if;
 update public.pratiche set stato_commerciale='rifiutato' where id=p;
 if exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p and regola='scelta_cliente_da_chiarire')
 then raise exception 'Vendita rifiutata ancora segnalata'; end if;
 update public.pratiche set tipo_flusso='assistenza',stato_commerciale='preventivo_inviato' where id=p;
 if exists(select 1 from private.candidati_flussi_offerta_rientro() where pratica_id=p and regola='scelta_cliente_da_chiarire')
 then raise exception 'Flusso assistenza nella coda commerciale'; end if;
end;
$test$;
reset role;
do $test$
begin
 if has_function_privilege('anon','private.candidati_flussi_offerta_rientro()','execute')
 or has_function_privilege('authenticated','private.candidati_flussi_offerta_rientro()','execute')
 or not has_function_privilege('service_role','private.candidati_flussi_offerta_rientro()','execute')
 then raise exception 'Permessi della funzione alterati'; end if;
end;
$test$;
rollback;

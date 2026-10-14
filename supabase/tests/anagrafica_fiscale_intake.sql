begin;

do $test$
declare id1 uuid; id2 uuid; id3 uuid; c1 uuid; totale bigint; esito jsonb;
 dati text:='FATTURAZIONE|DENOMINAZIONE:Officina Collaudo|INDIRIZZO_FATTURAZIONE:Via Prova 7|CAP:00100|COMUNE:Roma|PIVA:12345678901|EMAIL:collaudo@example.invalid';
begin
 if private.anagrafica_fiscale_intake(jsonb_build_object('dati_fiscali_testo','RITIRO|INDIRIZZO:Via Ritiro 99|CAP:20100|COMUNE:Milano'))<>'{}'::jsonb
 then raise exception 'Indirizzo ritiro scambiato per fiscale';end if;
 insert into public.pratiche(nome_cliente,telefono,stato_commerciale,stato_fatturazione,dati_raw)
 values('Collaudo fiscale',null,'ordine_acquisito','da_fatturare',
  jsonb_build_object('payload_live',jsonb_build_object('dati_fiscali_testo',dati)))
 returning id into id1;
 select cliente_id into c1 from public.pratiche where id=id1;
 if c1 is null or (select stato_amministrativo from public.pratiche where id=id1)<>'pronto_fatturazione'
 then raise exception 'Anagrafica completa non acquisita';end if;
 select count(*) into totale from public.clienti where partita_iva_normalizzata='12345678901';
 update public.pratiche set dati_raw=dati_raw||jsonb_build_object('payload_live','{}'::jsonb) where id=id1;
 if (select cliente_id from public.pratiche where id=id1)<>c1
 or (select count(*) from public.clienti where partita_iva_normalizzata='12345678901')<>totale
 then raise exception 'Replay duplicato o perdita anagrafica';end if;
 insert into public.pratiche(nome_cliente,stato_commerciale,stato_fatturazione,dati_raw)
 values('Collaudo seconda pratica','ordine_acquisito','da_fatturare',
 jsonb_build_object('payload_live',jsonb_build_object('dati_fiscali_testo',dati))) returning id into id2;
 if (select cliente_id from public.pratiche where id=id2)<>c1
 then raise exception 'Non riusato il cliente con identificativo esatto';end if;
 insert into public.pratiche(nome_cliente,stato_commerciale,stato_fatturazione,dati_raw)
 values('Collaudo dati incompleti','ordine_acquisito','da_fatturare',
 jsonb_build_object('payload_live',jsonb_build_object('dati_fiscali_testo','FATTURAZIONE|DENOMINAZIONE:Officina Senza Indirizzo|PIVA:22345678901|EMAIL:incompleto@example.invalid'))) returning id into id3;
 if (select cliente_id from public.pratiche where id=id3) is not null
 then raise exception 'Cliente creato con indirizzo incompleto';end if;
 perform public.gestisci_sospensione_fatturazione(id3,true,'Manutenzione autorizzata');
 update public.pratiche set dati_raw=dati_raw||jsonb_build_object('payload_live',
 jsonb_build_object('dati_fiscali_testo',replace(replace(dati,'12345678901','22345678901'),'collaudo@example.invalid','incompleto@example.invalid'))) where id=id3;
 if (select cliente_id from public.pratiche where id=id3) is not null
 then raise exception 'Sospensione operatore aggirata';end if;
 update public.pratiche set dati_raw=dati_raw||jsonb_build_object('payload_live',
 jsonb_build_object('dati_fiscali_testo',replace(dati,'Via Prova 7','Via Diversa 12'))) where id=id1;
 if (select stato_amministrativo from public.pratiche where id=id1)<>'corrispondenza_ambigua'
 or (select indirizzo_fatturazione from public.clienti where id=c1)<>'Via Prova 7'
 then raise exception 'Conflitto non segnalato o anagrafica originale sovrascritta';end if;
 if has_function_privilege('anon','private.crea_cliente_fiscale_intake(uuid)','execute')
 then raise exception 'Nuova funzione esposta';end if;
end $test$;

rollback;

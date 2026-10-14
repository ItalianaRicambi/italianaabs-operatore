
begin;
do $test$
declare pid uuid;
begin
 insert into public.pratiche(nome_cliente,stato_commerciale,stato_fatturazione,dati_raw)
 values('Collaudo dati distribuiti','ordine_acquisito','da_fatturare',
 jsonb_build_object('payload_live',jsonb_build_object('dati_fiscali_testo',
 'FATTURAZIONE|DENOMINAZIONE:Cliente Distribuito|PIVA:32345678901'))) returning id into pid;
 update public.pratiche set dati_raw=dati_raw||jsonb_build_object('payload_live',
 jsonb_build_object('dati_fiscali_testo','FATTURAZIONE|INDIRIZZO_FATTURAZIONE:Via Origine 8|CAP:00100|COMUNE:Roma')) where id=pid;
 if (select cliente_id from public.pratiche where id=pid) is not null then raise exception 'Email mancante ignorata';end if;
 update public.pratiche set dati_raw=dati_raw||jsonb_build_object('payload_live',
 jsonb_build_object('dati_fiscali_testo','FATTURAZIONE|EMAIL:distribuito@example.invalid')) where id=pid;
 if (select stato_amministrativo from public.pratiche where id=pid)<>'pronto_fatturazione'
 or (select dati_raw#>>'{anagrafica_estratta,indirizzo_fatturazione}' from public.pratiche where id=pid)<>'Via Origine 8'
 then raise exception 'Dati distribuiti persi';end if;
end $test$;
rollback;
select 'dati_su_messaggi_successivi_superato' as esito;

-- Ingresso atomico del documento e lettura differita, con rollback.
begin;
set local role service_role;
do $test$
declare p uuid; r jsonb; c jsonb; n integer;
begin
 c:='{"opzioni":[{"numero":1,"servizio":"RI","descrizione":"Lavorazione idraulica","importo":447,"iva_inclusa":true}],"impronta":"test-impronta-ingresso","testo":"Offerta di prova","fonte":"pdf","validita_giorni":15}';
 r:=public.registra_preventivo_con_offerta('test:offerte:ingresso','TSTN001.pdf','TSTN001',null,now()-interval '30 minutes',now()-interval '30 minutes',c);
 if not exists(select 1 from public.preventivi_emessi_ricevuti where external_id='test:offerte:ingresso' and contenuto_offerta->>'impronta'='test-impronta-ingresso') then raise exception 'Lettura del PDF prima della pratica persa'; end if;
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
 values('TSTN001','Test ingresso documento','commerciale','raccolta_dati') returning id into p;
 update public.preventivi_emessi_ricevuti set ultimo_tentativo_at=now()-interval '5 minutes' where external_id='test:offerte:ingresso';
 perform private.ritenta_preventivi_non_abbinati();
 perform private.ritenta_letture_offerte();
 if not exists(select 1 from public.offerte_versioni where pratica_id=p and stato='letta' and impronta='test-impronta-ingresso') then raise exception 'Lettura differita non collegata'; end if;
 n:=private.ritenta_letture_offerte();
 if n<>0 then raise exception 'Retry letture duplica le versioni'; end if;
 r:=public.registra_preventivo_con_offerta('test:offerte:ingresso','TSTN001.pdf','TSTN001',null,now(),now(),c);
 if (select count(*) from public.offerte_versioni where pratica_id=p)<>1 then raise exception 'Documento identico duplicato'; end if;
 c:='{"opzioni":[],"impronta":"test-impronta-errore","testo":null,"errore":"Documento non leggibile","fonte":"pdf"}';
 r:=public.registra_preventivo_con_offerta('test:offerte:illeggibile','TSTN001.pdf','TSTN001',null,now(),now(),c);
 if not exists(select 1 from public.preventivi where pratica_id=p and external_id='test:offerte:illeggibile') or not exists(select 1 from public.offerte_versioni where pratica_id=p and stato='da_verificare') then raise exception 'Errore lettura nasconde preventivo emesso'; end if;
end; $test$;
reset role;
rollback;

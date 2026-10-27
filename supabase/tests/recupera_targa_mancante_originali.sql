begin;
do $test$
declare l uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); x jsonb; snapshot jsonb;
begin
perform 1 from public.keplero_recupero_originali where id for update;
update public.keplero_recupero_originali set lease=l,scade_at=now()+interval '4 minutes' where id;
insert into public.keplero_sessioni_originali(sessione,lease) values(s,l);
x:=jsonb_build_object('id','collaudo-pdf-estero','data',now()-interval '1 hour','data_originale',(now()-interval '1 hour')::text,'direzione','uscita','tipo','file','testo','attachment:collaudo.pdf','impronta',repeat('a',64),'candidato',false,'revoca',false,'targa_pdf',null,'sha256_pdf',null,'originale','{}'::jsonb);
perform public.registra_originali_k(l,s,jsonb_build_array(x));
select originale into snapshot from public.keplero_originali where sessione=s and messaggio_id='collaudo-pdf-estero';
x:=x||jsonb_build_object('targa_pdf','LU71264','sha256_pdf',repeat('c',64));
perform public.registra_originali_k(l,s,jsonb_build_array(x));
if not exists(select 1 from public.keplero_originali where sessione=s and targa_pdf='LU71264' and sha256_pdf=repeat('c',64) and originale=snapshot and not modificato) then raise exception 'Metadata mancanti non recuperati';end if;
x:=x||jsonb_build_object('targa_pdf','LU99999');
perform public.registra_originali_k(l,s,jsonb_build_array(x));
if not exists(select 1 from public.keplero_originali where sessione=s and targa_pdf='LU71264') then raise exception 'Targa esistente sovrascritta';end if;
x:=x||jsonb_build_object('impronta',repeat('b',64));
perform public.registra_originali_k(l,s,jsonb_build_array(x));
if not exists(select 1 from public.keplero_originali where sessione=s and targa_pdf='LU71264' and originale=snapshot and modificato) then raise exception 'Originale modificato sovrascritto';end if;
end;$test$;
rollback;

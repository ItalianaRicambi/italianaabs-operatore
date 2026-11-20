-- Eseguire dopo la migrazione; tutte le fixture vengono annullate.
begin;
set local lock_timeout = '2s';
set local statement_timeout = '20s';
do $test$
declare
 lotto uuid := gen_random_uuid();
 sana uuid := gen_random_uuid();
 nuova uuid := gen_random_uuid();
 recente uuid := gen_random_uuid();
 errori uuid[] := '{}';
 risultato jsonb;
 sid uuid;
 i integer;
begin
 if has_function_privilege('anon','public.seleziona_sessioni_originali_k(uuid)','execute')
 or has_function_privilege('authenticated','public.seleziona_sessioni_originali_k(uuid)','execute')
 or not has_function_privilege('service_role','public.seleziona_sessioni_originali_k(uuid)','execute') then
  raise exception 'Permessi del worker non corretti';
 end if;
 update public.keplero_recupero_originali set lease=lotto,scade_at=now()+interval '1 minute' where id;
 -- Una chat già letta con nuova attività attende da più tempo dei retry falliti.
 insert into public.keplero_sessioni_originali(sessione,ultimo_successo_at,ultimo_tentativo_at,attivita_at)
 values(sana,'1900-01-01','1901-01-01','1903-01-01'),
       (nuova,null,null,'1903-01-01'),
       (recente,null,now(),'1903-01-01');
 for i in 1..8 loop
  sid:=gen_random_uuid();errori:=array_append(errori,sid);
  insert into public.keplero_sessioni_originali(sessione,ultimo_tentativo_at,attivita_at,errore)
  values(sid,'1902-01-01','1903-01-01','non_disponibile');
 end loop;
 risultato:=public.seleziona_sessioni_originali_k(lotto);
 if jsonb_array_length(risultato)<>8 or not risultato ? sana::text or not risultato ? nuova::text then
  raise exception 'Le chat mai lette in errore bloccano ancora le altre';
 end if;
 if risultato ? recente::text then raise exception 'Cooldown di cinque minuti ignorato';end if;
 if exists(select 1 from jsonb_array_elements_text(risultato) x
  join public.keplero_sessioni_originali s on s.sessione=x.value::uuid
  where s.lease is distinct from lotto or s.ultimo_tentativo_at is distinct from now()) then
  raise exception 'Lotto o data tentativo non assegnati';
 end if;
 risultato:=public.seleziona_sessioni_originali_k(lotto);
 if risultato ? sana::text or risultato ? nuova::text then
  raise exception 'Chat appena lavorate selezionate nuovamente';
 end if;
 if (select count(*) from unnest(errori) x where risultato ? x::text)<>2 then
  raise exception 'I retry falliti devono continuare a ricevere un turno';
 end if;
 update public.keplero_recupero_originali set scade_at=now()-interval '1 second' where id;
 begin
  perform public.seleziona_sessioni_originali_k(lotto);
  raise exception 'Lease scaduto accettato';
 exception when raise_exception then
  if sqlerrm<>'Lotto scaduto' then raise;end if;
 end;
end;
$test$;
rollback;

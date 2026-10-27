begin;
do $test$
declare l uuid:=gen_random_uuid(); old1 uuid:=gen_random_uuid(); old2 uuid:=gen_random_uuid(); retry uuid:=gen_random_uuid(); ids jsonb; ids2 jsonb;
begin
-- La prova occupa il lease solo nella transazione, poi ripristina tutti i dati.
perform 1 from public.keplero_recupero_originali where id for update;
update public.keplero_recupero_originali set lease=l,scade_at=now()+interval '4 minutes' where id;
insert into public.keplero_sessioni_originali(sessione,attivita_at)
select keplero_conversation_id::uuid,max(updated_at) from public.pratiche where keplero_conversation_id~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' and updated_at>now()-interval '30 days' group by keplero_conversation_id on conflict do nothing;
update public.keplero_sessioni_originali set ultimo_tentativo_at=now();
insert into public.keplero_sessioni_originali(sessione,attivita_at,ultimo_tentativo_at)
values(old1,now()-interval '30 days',now()-interval '20 days'),(old2,now()-interval '20 days',now()-interval '10 days');
insert into public.keplero_sessioni_originali(sessione,attivita_at,ultimo_tentativo_at,ultimo_successo_at,errore)
values(retry,now(),now()-interval '9 days',now()-interval '1 day','collaudo');
insert into public.keplero_sessioni_originali(sessione,attivita_at,ultimo_tentativo_at,ultimo_successo_at,errore)
select gen_random_uuid(),now()-n*interval '1 minute',now()-n*interval '1 day',now()-interval '1 day','collaudo' from generate_series(1,8) n;
ids:=public.seleziona_sessioni_originali_k(l);
if jsonb_array_length(ids)<>8 or not(ids ? old1::text) or not(ids ? old2::text) or not(ids ? retry::text) then raise exception 'Letture storiche o tentativo più vecchio lasciati indietro';end if;
ids2:=public.seleziona_sessioni_originali_k(l);
if jsonb_array_length(ids2)<>3 then raise exception 'Limite o intervallo tentativi alterato';end if;
if exists(select 1 from jsonb_array_elements_text(ids) a join jsonb_array_elements_text(ids2) b on a.value=b.value) then raise exception 'Conversazione ripetuta prima di cinque minuti';end if;
end;$test$;
rollback;

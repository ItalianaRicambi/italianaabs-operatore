CREATE OR REPLACE FUNCTION public.seleziona_sessioni_originali_k(p_lease uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare ids uuid[];
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now() for update;
 if not found then raise exception 'Lotto scaduto';end if;
 insert into public.keplero_sessioni_originali(sessione,attivita_at)
 select keplero_conversation_id::uuid,max(updated_at) from public.pratiche
 where keplero_conversation_id~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' and updated_at>now()-interval '30 days'
 group by keplero_conversation_id on conflict do nothing;
 select array_agg(sessione) into ids from (
 select s.sessione from public.keplero_sessioni_originali s
 where (s.ultimo_successo_at is null or s.ultimo_successo_at<s.attivita_at or s.errore is not null or exists(select 1 from public.keplero_risposte_in_attesa a where a.sessione=s.sessione))
 and (s.ultimo_tentativo_at is null or s.ultimo_tentativo_at<now()-interval '5 minutes')
 order by (s.ultimo_successo_at is null) desc,s.ultimo_tentativo_at nulls first,s.attivita_at desc nulls last,s.sessione limit 8) x;
 update public.keplero_sessioni_originali set lease=p_lease,ultimo_tentativo_at=now() where sessione=any(ids);
 return coalesce(to_jsonb(ids),'[]');
end; $function$
;

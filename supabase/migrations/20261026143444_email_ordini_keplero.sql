-- Estende il registro; le email ordini non attestano ordini o pagamenti.
alter table public.richieste_email drop constraint richieste_email_mailbox_check;
alter table public.richieste_email add constraint richieste_email_mailbox_check
 check (mailbox in ('info@italianaabs.com','ordini@italianaabs.com'));

create or replace function public.registra_richiesta_email(p_dati jsonb) returns jsonb
language plpgsql security invoker set search_path=public,pg_temp as $$
declare r public.richieste_email; acquisita boolean:=false;
begin
 if coalesce(p_dati->>'mailbox','') not in ('info@italianaabs.com','ordini@italianaabs.com')
   or coalesce(p_dati->>'sender','') !~ '^[^[:space:]<>@]+@[^[:space:]<>@]+[.][^[:space:]<>@]+$'
   or length(coalesce(p_dati->>'content',''))>250000
   or length(coalesce(p_dati->>'subject',''))>2000 then raise exception 'Dati email non validi'; end if;
 insert into public.richieste_email(fingerprint,mailbox,sender,subject,content,conversation_id,token,lease_at)
 values(p_dati->>'fingerprint',p_dati->>'mailbox',p_dati->>'sender',p_dati->>'subject',p_dati->>'content',(p_dati->>'conversation_id')::uuid,gen_random_uuid(),now())
 on conflict(fingerprint) do update set consegne=richieste_email.consegne+1,updated_at=now()
 returning * into r;
 if r.consegne=1 then acquisita:=true;
 elsif r.stato='errore' or (r.stato='in_elaborazione' and r.lease_at<now()-interval '2 minutes') then
  update public.richieste_email set stato='in_elaborazione',token=gen_random_uuid(),lease_at=now(),updated_at=now() where id=r.id returning * into r;
  acquisita:=true;
 end if;
 return to_jsonb(r)-'token'||jsonb_build_object('token',case when acquisita then r.token else null end);
end $$;

revoke execute on function public.registra_richiesta_email(jsonb) from public,anon,authenticated;
grant execute on function public.registra_richiesta_email(jsonb) to service_role;

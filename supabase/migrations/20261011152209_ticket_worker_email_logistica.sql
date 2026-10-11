-- Le ACL di pg_net sono gestite da supabase_admin. Gli header HTTP non
-- devono quindi contenere il segreto permanente del worker: ticket monouso.
create table private.ticket_worker_email_logistica (
 impronta text primary key,
 scade_at timestamptz not null
);
revoke all on private.ticket_worker_email_logistica from public,anon,authenticated,service_role;

create or replace function public.autorizza_worker_email_logistica(p_token text)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if p_token is null or length(p_token) not between 64 and 100 then return false; end if;
 delete from private.ticket_worker_email_logistica
 where impronta=encode(sha256(convert_to(p_token,'UTF8')),'hex') and scade_at>now();
 return found;
end; $$;
revoke all on function public.autorizza_worker_email_logistica(text) from public,anon,authenticated;
grant execute on function public.autorizza_worker_email_logistica(text) to service_role;

create or replace function private.avvia_worker_email_logistica()
returns void language plpgsql security definer set search_path='' as $$
declare t text;
begin
 if not exists(select 1 from private.config_email_logistica where abilitata) then return; end if;
 delete from private.ticket_worker_email_logistica where scade_at<=now();
 t:=gen_random_uuid()::text||gen_random_uuid()::text;
 insert into private.ticket_worker_email_logistica(impronta,scade_at)
 values(encode(sha256(convert_to(t,'UTF8')),'hex'),now()+interval '2 minutes');
 perform net.http_post(url:='https://italianaabs-operatore.vercel.app/api/logistica/email',
  headers:=jsonb_build_object('Authorization','Bearer '||t,'Content-Type','application/json'),body:='{}'::jsonb,timeout_milliseconds:=55000);
end; $$;
revoke all on function private.avvia_worker_email_logistica() from public,anon,authenticated,service_role;
notify pgrst,'reload schema';

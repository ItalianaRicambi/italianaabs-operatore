create function private.avvia_worker_mbe()
returns void language plpgsql security invoker set search_path='' as $$
declare t text;
begin
 if not exists(select 1 from public.mbe_collegamento where automatico) then return;end if;
 delete from public.mbe_ticket_worker where scade_at<=now();
 t:=gen_random_uuid()::text||gen_random_uuid()::text;
 insert into public.mbe_ticket_worker values(encode(sha256(convert_to(t,'UTF8')),'hex'),now()+interval '2 minutes');
 perform net.http_post(url:='https://italianaabs-operatore.vercel.app/api/mbe/sincronizza',headers:=jsonb_build_object('Authorization','Bearer '||t,'Content-Type','application/json'),body:='{}',timeout_milliseconds:=55000);
end; $$;
revoke all on function private.avvia_worker_mbe() from public,anon,authenticated,service_role;
select cron.schedule('sincronizza-mbe','*/15 * * * *','select private.avvia_worker_mbe();');
notify pgrst,'reload schema';

create table public.fic_worker_controlli (
 id boolean primary key default true check(id), lease uuid, scade_at timestamptz,
 ultimo_avvio_at timestamptz, ultimo_termine_at timestamptz, automatico boolean not null default false
);
alter table public.fic_worker_controlli enable row level security;
revoke all on public.fic_worker_controlli from public,anon,authenticated;
grant select,update on public.fic_worker_controlli to service_role;
insert into public.fic_worker_controlli(id) values(true);
create function public.fic_inizia_controlli() returns uuid language plpgsql set search_path='' as $$
declare l uuid;
begin
 perform 1 from public.fic_worker_controlli where id for update;
 if exists(select 1 from public.fic_worker_controlli where scade_at>now()) then return null;end if;
 l:=gen_random_uuid();
 update public.fic_worker_controlli set lease=l,scade_at=now()+interval '4 minutes',ultimo_avvio_at=now() where id;
 return l;
end;$$;
create function public.fic_termina_controlli(p_lease uuid) returns void language sql set search_path='' as $$
 update public.fic_worker_controlli set lease=null,scade_at=null,ultimo_termine_at=now() where lease=p_lease;
$$;
create function private.avvia_controlli_fic() returns bigint language plpgsql set search_path='' as $$
declare t text; richiesta bigint;
begin
 if not exists(select 1 from public.fic_worker_controlli where automatico and (scade_at is null or scade_at<=now())) then return null;end if;
 delete from public.keplero_ticket_originali where scade_at<=now();
 t:=gen_random_uuid()::text||gen_random_uuid()::text;
 insert into public.keplero_ticket_originali values(encode(sha256(convert_to(t,'UTF8')),'hex'),now()+interval '2 minutes');
 select net.http_post(url:='https://italianaabs-operatore-git-codex-fatture-466f32-italiana-ricambi.vercel.app/api/fatture-in-cloud/controlli',
 headers:=jsonb_build_object('Authorization','Bearer '||t,'Content-Type','application/json'),body:='{}',timeout_milliseconds:=240000) into richiesta;
 return richiesta;
end;$$;
revoke all on function public.fic_inizia_controlli(),public.fic_termina_controlli(uuid),private.avvia_controlli_fic() from public,anon,authenticated;
grant execute on function public.fic_inizia_controlli(),public.fic_termina_controlli(uuid) to service_role;
revoke all on function private.avvia_controlli_fic() from service_role;
-- Attivato soltanto dopo il collaudo del worker nel deployment FIC già autorizzato.
select cron.schedule('controlli-anagrafiche-fatture-chat','2-59/5 * * * *','select private.avvia_controlli_fic();');
notify pgrst,'reload schema';

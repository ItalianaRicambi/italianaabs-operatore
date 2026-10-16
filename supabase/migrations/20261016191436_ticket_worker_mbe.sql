-- Ticket monouso: nessun segreto permanente negli header di pg_net.
create table public.mbe_ticket_worker(impronta text primary key,scade_at timestamptz not null);
alter table public.mbe_ticket_worker enable row level security;
revoke all on public.mbe_ticket_worker from public,anon,authenticated;
grant select,delete on public.mbe_ticket_worker to service_role;
create function public.autorizza_worker_mbe(p_token text)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if p_token is null or length(p_token) not between 64 and 100 then return false;end if;
 delete from public.mbe_ticket_worker where impronta=encode(sha256(convert_to(p_token,'UTF8')),'hex') and scade_at>now();
 return found;
end; $$;
revoke all on function public.inizia_sincronizzazione_mbe(),public.termina_sincronizzazione_mbe(uuid,jsonb,jsonb,text),public.configura_automatico_mbe(boolean),public.classifica_spedizione_mbe(text,text,text),public.autorizza_worker_mbe(text) from public,anon,authenticated;
grant execute on function public.inizia_sincronizzazione_mbe(),public.termina_sincronizzazione_mbe(uuid,jsonb,jsonb,text),public.configura_automatico_mbe(boolean),public.classifica_spedizione_mbe(text,text,text),public.autorizza_worker_mbe(text) to service_role;
notify pgrst,'reload schema';

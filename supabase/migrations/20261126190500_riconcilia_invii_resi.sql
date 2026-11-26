-- Riutilizza la transizione principale per audit, permessi, lock e revisione.
alter function public.evento_reso_scambio(uuid,integer,text,text,text,jsonb) rename to registra_evento_reso_base;
create function public.evento_reso_scambio(p_id uuid,p_revisione integer,p_tipo text,
 p_chiave text,p_autore text,p_dati jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare
 r public.resi_scambio; eid uuid; oggi date:=(now() at time zone 'Europe/Rome')::date;
 effettiva date; tentativo date;
begin
 if p_tipo='ricontatto' then
  select * into strict r from public.resi_scambio where id=p_id for update;
  select id into eid from public.resi_scambio_eventi where reso_id=p_id and chiave=p_chiave;
  if found then return eid; end if;
  if r.stato<>'accordo' or r.prossima is null or r.prossima>oggi or r.spedizione is null
    or oggi >= (r.spedizione+interval '6 months')::date or nullif(trim(p_chiave),'') is null
    or p_autore is distinct from 'Routine resi' or nullif(trim(p_dati->>'nota'),'') is null
    or r.revisione is distinct from p_revisione then raise exception 'Ricontatto non ammissibile'; end if;
  update public.resi_scambio set stato='montaggio',revisione=revisione+1 where id=p_id;
  insert into public.resi_scambio_eventi(reso_id,chiave,tipo,autore,dettagli)
  values(p_id,p_chiave,p_tipo,p_autore,p_dati) returning id into eid;
  return eid;
 end if;
 if p_tipo='inviato' then
  select * into strict r from public.resi_scambio where id=p_id for update;
  select id into eid from public.resi_scambio_eventi where reso_id=p_id and chiave=p_chiave;
  if found then return eid; end if;
  select (data_evento at time zone 'Europe/Rome')::date into tentativo from public.resi_scambio_eventi
   where id=r.unico_tentativo and reso_id=p_id and tipo='tentativo';
  effettiva:=coalesce((p_dati->>'data')::date,tentativo);
  if effettiva is null or effettiva<tentativo or effettiva>oggi then raise exception 'Verificare data della ricevuta'; end if;
 end if;
 eid:=public.registra_evento_reso_base(p_id,p_revisione,p_tipo,p_chiave,p_autore,p_dati);
 if p_tipo='inviato' and effettiva<oggi then
  update public.resi_scambio set ultimo_invio=effettiva,
   prossima=case when stato='attesa' then public.resi_aggiungi_lavorativi(effettiva,15) else prossima end where id=p_id;
 end if;
 return eid;
end $$;
revoke all on function public.registra_evento_reso_base(uuid,int,text,text,text,jsonb) from service_role,public,anon,authenticated;
revoke all on function public.evento_reso_scambio(uuid,int,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.evento_reso_scambio(uuid,int,text,text,text,jsonb) to service_role;

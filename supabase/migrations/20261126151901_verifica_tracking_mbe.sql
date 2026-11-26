alter table public.mbe_spedizioni
  add column tracking_rifiutato_at timestamptz,
  add column cliente_segnalato text;

create function public.registra_ciclo_tracking_mbe(
  p_lease uuid, p_spedizioni jsonb, p_tracking jsonb, p_rifiutati text[]
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare risultato jsonb; numero integer;
begin
  if p_rifiutati is null or cardinality(p_rifiutati)>1000 or exists (
    select 1 from unnest(p_rifiutati) id where id is null or id !~ '^[A-Za-z0-9-]{1,20}$'
      or exists (select 1 from jsonb_array_elements(p_tracking) t where t->>'tracking_mbe'=id)
  ) then raise exception 'Elenco tracking rifiutati non valido'; end if;

  -- The existing lease check, shipment import and confirmed observations
  -- share this transaction with the retry flags.
  risultato:=public.termina_sincronizzazione_mbe(p_lease,p_spedizioni,p_tracking,null);
  update public.mbe_spedizioni set tracking_rifiutato_at=now() where tracking_mbe=any(p_rifiutati);
  get diagnostics numero=row_count;
  if numero<>cardinality(p_rifiutati) then raise exception 'Tracking rifiutato assente o duplicato'; end if;
  update public.mbe_spedizioni m set tracking_rifiutato_at=null
    where m.tracking_rifiutato_at is not null and exists (
      select 1 from jsonb_array_elements(p_tracking) t where t->>'tracking_mbe'=m.tracking_mbe
    );
  return risultato || jsonb_build_object('da_verificare',numero);
end; $$;
revoke all on function public.registra_ciclo_tracking_mbe(uuid,jsonb,jsonb,text[]) from public,anon,authenticated;
grant execute on function public.registra_ciclo_tracking_mbe(uuid,jsonb,jsonb,text[]) to service_role;

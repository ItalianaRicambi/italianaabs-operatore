-- Contratto della lettura usata dalla scheda pratica, eseguito con il ruolo
-- della dashboard. Include i campi che causavano HTTP 400 e l'apertura fallita.
begin;
do $$
begin
  if has_table_privilege('anon', 'public.v_attivita_operatore_aperte', 'select')
    or has_table_privilege('authenticated', 'public.v_attivita_operatore_aperte', 'select') then
    raise exception 'La vista attività non deve essere accessibile ai ruoli pubblici';
  end if;
  if not exists (select 1 from pg_class
    where oid='public.v_attivita_operatore_aperte'::regclass
      and reloptions @> array['security_invoker=true']) then
    raise exception 'La vista attività deve rispettare i permessi del chiamante';
  end if;
end;
$$;
set local role service_role;
do $$
declare
  v_rows bigint;
begin
  -- Stessa selezione della pagina: deve funzionare anche quando non ci sono attività.
  perform id,tipo,stato,priorita,pratica_origine_id,codice_pratica_origine,
    evidenza,richiesta_at,programmata_at,operatore,presa_in_carico_at,
    riferimento_ritiro,data_ritiro_prevista,metadati
  from public.v_attivita_operatore_aperte order by richiesta_at asc;

  if exists (
    select 1 from public.v_attivita_operatore_aperte v
    join public.attivita_operatore a on a.id=v.id
    where v.assistenza_rientro_id is distinct from a.assistenza_rientro_id
      or v.presa_in_carico_at is distinct from a.presa_in_carico_at
      or v.blocco_classificazione is distinct from a.blocco_classificazione
      or v.riferimento_ritiro is distinct from a.riferimento_ritiro
      or v.data_ritiro_prevista is distinct from a.data_ritiro_prevista
      or a.stato not in ('da_gestire','da_collegare','programmata')
  ) then
    raise exception 'Dati di presa in carico o prenotazione non allineati';
  end if;

  select count(*) into v_rows from public.attivita_operatore a
    join public.pratiche p on p.id=a.pratica_id
    where a.stato in ('da_gestire','da_collegare','programmata');
  if v_rows <> (select count(*) from public.v_attivita_operatore_aperte) then
    raise exception 'La vista ha perso o duplicato attività aperte';
  end if;
end;
$$;
rollback;

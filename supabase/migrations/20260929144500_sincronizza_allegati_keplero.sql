create unique index if not exists allegati_pratica_url_uidx
  on public.allegati (pratica_id, url)
  where url is not null;

create or replace function public.sincronizza_allegati_keplero(
  p_pratica_id uuid,
  p_allegati jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_righe integer := 0;
begin
  if p_pratica_id is null
     or not exists (select 1 from public.pratiche where id = p_pratica_id) then
    return jsonb_build_object(
      'ok', false,
      'motivo', 'pratica_non_valida',
      'allegati_sincronizzati', 0
    );
  end if;

  if p_allegati is null or jsonb_typeof(p_allegati) <> 'array' then
    return jsonb_build_object(
      'ok', false,
      'motivo', 'allegati_non_validi',
      'allegati_sincronizzati', 0
    );
  end if;

  insert into public.allegati (
    pratica_id,
    tipo,
    url,
    leggibile,
    verificato_operatore,
    fonte
  )
  select distinct on (nullif(trim(elemento ->> 'url'), ''))
    p_pratica_id,
    coalesce(nullif(trim(elemento ->> 'tipo'), ''), 'Allegato'),
    nullif(trim(elemento ->> 'url'), ''),
    null,
    false,
    'keplero'::public.fonte_dato
  from jsonb_array_elements(p_allegati) as elemento
  where nullif(trim(elemento ->> 'url'), '') ~ '^https?://'
  order by nullif(trim(elemento ->> 'url'), '')
  on conflict (pratica_id, url) where url is not null
  do update set
    tipo = coalesce(nullif(excluded.tipo, ''), public.allegati.tipo);

  get diagnostics v_righe = row_count;

  return jsonb_build_object(
    'ok', true,
    'pratica_id', p_pratica_id,
    'allegati_sincronizzati', v_righe
  );
end;
$$;

revoke all on function public.sincronizza_allegati_keplero(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.sincronizza_allegati_keplero(uuid, jsonb)
  to service_role;

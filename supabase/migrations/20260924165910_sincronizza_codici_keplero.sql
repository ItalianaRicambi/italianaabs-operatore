create or replace function public.sincronizza_codici_keplero(
  p_pratica_id uuid,
  p_codici jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_inseriti integer := 0;
begin
  if p_pratica_id is null then
    raise exception 'pratica_id mancante';
  end if;

  if jsonb_typeof(coalesce(p_codici, '[]'::jsonb)) <> 'array' then
    raise exception 'p_codici deve essere un array JSON';
  end if;

  insert into public.codici_identificativi (
    pratica_id,
    tipo_codice,
    codice,
    completo,
    verificato_operatore,
    fonte,
    note
  )
  select distinct
    p_pratica_id,
    null,
    trim(item ->> 'codice'),
    false,
    false,
    'keplero'::public.fonte_dato,
    'Acquisito automaticamente dal collegamento Keplero'
  from jsonb_array_elements(coalesce(p_codici, '[]'::jsonb)) item
  where nullif(trim(item ->> 'codice'), '') is not null
  on conflict (pratica_id, codice) do nothing;

  get diagnostics v_inseriti = row_count;

  return jsonb_build_object(
    'ok', true,
    'pratica_id', p_pratica_id,
    'codici_inseriti', v_inseriti
  );
end;
$$;

revoke all on function public.sincronizza_codici_keplero(uuid, jsonb)
from public, anon, authenticated;

grant execute on function public.sincronizza_codici_keplero(uuid, jsonb)
to service_role;

comment on function public.sincronizza_codici_keplero(uuid, jsonb) is
  'Salva in modo idempotente i codici identificativi ricevuti dal webhook Keplero, senza modificare quelli già verificati dall''operatore.';

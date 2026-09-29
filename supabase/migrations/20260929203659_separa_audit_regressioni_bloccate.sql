create table if not exists private.regressioni_stato_bloccate (
  id bigint generated always as identity primary key,
  pratica_id uuid not null references public.pratiche(id) on delete cascade,
  stato_prima jsonb not null,
  modifica_richiesta jsonb not null,
  stato_applicato jsonb not null,
  fonte text not null default 'motore_stati',
  created_at timestamptz not null default now()
);

create index if not exists idx_regressioni_stato_bloccate_pratica_created
  on private.regressioni_stato_bloccate(pratica_id, created_at desc);

revoke all on private.regressioni_stato_bloccate
  from public, anon, authenticated;

create or replace function private.proteggi_stati_avanzati()
returns trigger
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  v_regressione boolean := false;
  v_richiesto jsonb;
begin
  if coalesce(current_setting('app.autorizza_regressione', true), 'false') = 'true' then
    return new;
  end if;

  v_richiesto := jsonb_build_object(
    'stato_commerciale', new.stato_commerciale,
    'stato_fatturazione', new.stato_fatturazione,
    'preventivo_inviato_at', new.preventivo_inviato_at,
    'ordine_acquisito_at', new.ordine_acquisito_at,
    'data_fattura', new.data_fattura
  );

  if old.stato_fatturazione = 'fatturato'::public.stato_fatturazione then
    if new.stato_fatturazione is distinct from old.stato_fatturazione
       or new.data_fattura is distinct from old.data_fattura then
      v_regressione := true;
      new.stato_fatturazione := old.stato_fatturazione;
      new.data_fattura := old.data_fattura;
    end if;
  elsif old.stato_fatturazione = 'da_fatturare'::public.stato_fatturazione
        and new.stato_fatturazione = 'non_applicabile'::public.stato_fatturazione then
    v_regressione := true;
    new.stato_fatturazione := old.stato_fatturazione;
  end if;

  if old.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale
     and new.stato_commerciale in (
       'nuova'::public.stato_commerciale,
       'raccolta_dati'::public.stato_commerciale,
       'da_preventivare'::public.stato_commerciale,
       'preventivo_pronto'::public.stato_commerciale,
       'preventivo_inviato'::public.stato_commerciale,
       'attesa_cliente'::public.stato_commerciale
     ) then
    v_regressione := true;
    new.stato_commerciale := old.stato_commerciale;
    new.ordine_acquisito_at := old.ordine_acquisito_at;
  elsif old.stato_commerciale in (
          'preventivo_inviato'::public.stato_commerciale,
          'attesa_cliente'::public.stato_commerciale
        )
        and new.stato_commerciale in (
          'nuova'::public.stato_commerciale,
          'raccolta_dati'::public.stato_commerciale,
          'da_preventivare'::public.stato_commerciale,
          'preventivo_pronto'::public.stato_commerciale
        ) then
    v_regressione := true;
    new.stato_commerciale := old.stato_commerciale;
    new.preventivo_inviato_at := old.preventivo_inviato_at;
  end if;

  if v_regressione then
    insert into private.regressioni_stato_bloccate (
      pratica_id, stato_prima, modifica_richiesta, stato_applicato
    ) values (
      old.id,
      jsonb_build_object(
        'stato_commerciale', old.stato_commerciale,
        'stato_fatturazione', old.stato_fatturazione,
        'preventivo_inviato_at', old.preventivo_inviato_at,
        'ordine_acquisito_at', old.ordine_acquisito_at,
        'data_fattura', old.data_fattura
      ),
      v_richiesto,
      jsonb_build_object(
        'stato_commerciale', new.stato_commerciale,
        'stato_fatturazione', new.stato_fatturazione,
        'preventivo_inviato_at', new.preventivo_inviato_at,
        'ordine_acquisito_at', new.ordine_acquisito_at,
        'data_fattura', new.data_fattura
      )
    );
  end if;

  return new;
end;
$$;

revoke all on function private.proteggi_stati_avanzati()
  from public, anon, authenticated;

comment on table private.regressioni_stato_bloccate is
  'Audit tecnico dei tentativi di regressione neutralizzati dal motore degli stati.';

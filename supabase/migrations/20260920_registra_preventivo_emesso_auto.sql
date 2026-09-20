create unique index if not exists preventivi_external_id_unique
  on public.preventivi (external_id)
  where external_id is not null;

create index if not exists idx_pratiche_targa_preventivabile
  on public.pratiche (
    upper(regexp_replace(coalesce(targa, ''), '[^A-Za-z0-9]', '', 'g')),
    created_at desc
  )
  where tipo_flusso = 'commerciale'
    and stato_commerciale in ('da_preventivare', 'preventivo_pronto');

create or replace function public.registra_preventivo_emesso_auto(
  p_external_id text,
  p_nome_file text,
  p_targa text,
  p_file_url text,
  p_data_offerta timestamptz,
  p_inviato_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_external_id text := nullif(btrim(p_external_id), '');
  v_nome_file text := btrim(coalesce(p_nome_file, ''));
  v_targa text := upper(regexp_replace(coalesce(p_targa, ''), '[^A-Za-z0-9]', '', 'g'));
  v_targa_file text := upper(regexp_replace(regexp_replace(v_nome_file, '\.pdf$', '', 'i'), '[^A-Za-z0-9]', '', 'g'));
  v_data_offerta timestamptz := coalesce(p_data_offerta, p_inviato_at, now());
  v_inviato_at timestamptz := coalesce(p_inviato_at, now());
  v_pratica_id uuid;
  v_preventivo_id uuid;
  v_numero_pratica bigint;
  v_candidati integer;
  v_stato_prima public.stato_commerciale;
begin
  if v_external_id is null then
    raise exception 'external_id obbligatorio';
  end if;

  if v_nome_file !~* '\.pdf$' or v_targa = '' or v_targa <> v_targa_file then
    return jsonb_build_object(
      'aggiornato', false,
      'esito', 'nome_file_non_valido',
      'targa', v_targa
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_external_id, 0));

  select id, pratica_id
    into v_preventivo_id, v_pratica_id
  from public.preventivi
  where external_id = v_external_id
  limit 1;

  if v_preventivo_id is not null then
    return jsonb_build_object(
      'aggiornato', false,
      'esito', 'gia_registrato',
      'preventivo_id', v_preventivo_id,
      'pratica_id', v_pratica_id,
      'targa', v_targa
    );
  end if;

  if v_data_offerta < now() - interval '30 days'
     or v_data_offerta > now() + interval '1 day' then
    return jsonb_build_object(
      'aggiornato', false,
      'esito', 'fuori_finestra_30_giorni',
      'targa', v_targa,
      'data_offerta', v_data_offerta
    );
  end if;

  select
    count(*),
    (array_agg(id order by created_at desc))[1],
    (array_agg(numero_pratica order by created_at desc))[1]
    into v_candidati, v_pratica_id, v_numero_pratica
  from public.pratiche
  where tipo_flusso = 'commerciale'
    and stato_commerciale in ('da_preventivare', 'preventivo_pronto')
    and created_at >= now() - interval '30 days'
    and created_at <= v_data_offerta + interval '1 day'
    and upper(regexp_replace(coalesce(targa, ''), '[^A-Za-z0-9]', '', 'g')) = v_targa;

  if v_candidati = 0 then
    return jsonb_build_object(
      'aggiornato', false,
      'esito', 'nessuna_pratica_compatibile',
      'targa', v_targa
    );
  end if;

  if v_candidati > 1 then
    return jsonb_build_object(
      'aggiornato', false,
      'esito', 'pratica_ambigua',
      'targa', v_targa,
      'candidati', v_candidati
    );
  end if;

  select stato_commerciale
    into v_stato_prima
  from public.pratiche
  where id = v_pratica_id
  for update;

  if v_stato_prima not in ('da_preventivare', 'preventivo_pronto') then
    return jsonb_build_object(
      'aggiornato', false,
      'esito', 'pratica_gia_avanzata',
      'pratica_id', v_pratica_id,
      'numero_pratica', v_numero_pratica,
      'targa', v_targa
    );
  end if;

  insert into public.preventivi (
    pratica_id,
    external_id,
    stato,
    file_url,
    creato_at,
    inviato_at,
    note
  ) values (
    v_pratica_id,
    v_external_id,
    'inviato',
    nullif(btrim(p_file_url), ''),
    v_data_offerta,
    v_inviato_at,
    'Riconosciuto automaticamente dal PDF in Preventivi emessi: ' || v_nome_file
  )
  returning id into v_preventivo_id;

  insert into public.azioni_operatore (
    pratica_id,
    azione,
    nota,
    stato_prima,
    stato_dopo,
    operatore
  ) values (
    v_pratica_id,
    'preventivo_emesso_automatico',
    'PDF riconosciuto automaticamente in Preventivi emessi: ' || v_nome_file,
    jsonb_build_object('stato_commerciale', v_stato_prima),
    jsonb_build_object(
      'stato_commerciale', 'preventivo_inviato',
      'preventivo_id', v_preventivo_id,
      'external_id', v_external_id
    ),
    null
  );

  return jsonb_build_object(
    'aggiornato', true,
    'esito', 'preventivo_inviato',
    'preventivo_id', v_preventivo_id,
    'pratica_id', v_pratica_id,
    'numero_pratica', v_numero_pratica,
    'targa', v_targa
  );
end;
$$;

revoke all on function public.registra_preventivo_emesso_auto(
  text, text, text, text, timestamptz, timestamptz
) from public, anon, authenticated;

grant execute on function public.registra_preventivo_emesso_auto(
  text, text, text, text, timestamptz, timestamptz
) to service_role;

create or replace function public.sync_preventivo_pratica()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.stato = 'inviato' then
    update public.pratiche
    set
      stato_commerciale = 'preventivo_inviato',
      preventivo_inviato_at = coalesce(new.inviato_at, now()),
      stato_followup = 'bloccato_meta',
      followup_previsto_at = coalesce(new.inviato_at, now()) + interval '10 days'
    where id = new.pratica_id
      and stato_commerciale in ('da_preventivare', 'preventivo_pronto', 'preventivo_inviato');
  end if;

  if new.stato = 'accettato' then
    update public.pratiche
    set
      stato_commerciale = 'ordine_acquisito',
      ordine_acquisito_at = coalesce(new.accettato_at, now()),
      stato_fatturazione = 'da_fatturare',
      stato_followup = 'annullato',
      followup_previsto_at = null
    where id = new.pratica_id
      and stato_commerciale in ('preventivo_inviato', 'attesa_cliente', 'ordine_acquisito');
  end if;

  return new;
end;
$$;

revoke all on function public.sync_preventivo_pratica()
  from public, anon, authenticated;

grant execute on function public.sync_preventivo_pratica()
  to service_role;

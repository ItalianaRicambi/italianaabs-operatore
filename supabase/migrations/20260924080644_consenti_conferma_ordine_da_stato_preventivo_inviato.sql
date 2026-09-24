create or replace function public.conferma_ordine_da_keplero(
  p_pratica_id uuid,
  p_external_key text,
  p_messaggio_cliente text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_prima public.pratiche%rowtype;
  v_dopo public.pratiche%rowtype;
begin
  if p_pratica_id is null then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_non_valida');
  end if;

  select *
  into v_prima
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_non_trovata');
  end if;

  if not exists (
    select 1
    from public.keplero_live_links
    where external_key = p_external_key
      and pratica_id = p_pratica_id
  ) then
    return jsonb_build_object('aggiornato', false, 'motivo', 'collegamento_keplero_non_valido');
  end if;

  if coalesce(v_prima.dati_raw #>> '{archiviazione_test,archiviata}', 'false') = 'true'
     or coalesce(v_prima.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') = 'true' then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_archiviata');
  end if;

  -- I controlli terminali vengono eseguiti prima dei prerequisiti per
  -- mantenere la funzione idempotente anche per le pratiche avanzate a mano.
  if v_prima.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale then
    update public.preventivi
    set
      stato = 'accettato',
      accettato_at = coalesce(accettato_at, v_prima.ordine_acquisito_at, now())
    where pratica_id = p_pratica_id
      and stato = 'inviato';

    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'ordine_gia_acquisito',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  if v_prima.stato_fatturazione = 'fatturato'::public.stato_fatturazione then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'pratica_gia_fatturata',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  -- Una correzione operatore a "Preventivo inviato" è già una prova
  -- sufficiente dell'invio, anche se non esiste un record in preventivi.
  if not exists (
    select 1
    from public.preventivi pv
    where pv.pratica_id = p_pratica_id
      and pv.stato in ('inviato', 'accettato')
  ) and not (
    v_prima.stato_commerciale in (
      'preventivo_inviato'::public.stato_commerciale,
      'attesa_cliente'::public.stato_commerciale
    )
    and v_prima.preventivo_inviato_at is not null
  ) then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'preventivo_non_registrato',
      'pratica_id', p_pratica_id
    );
  end if;

  if v_prima.stato_commerciale not in (
    'da_preventivare'::public.stato_commerciale,
    'preventivo_pronto'::public.stato_commerciale,
    'preventivo_inviato'::public.stato_commerciale,
    'attesa_cliente'::public.stato_commerciale
  ) then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'stato_non_abilitato',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  if
    v_prima.stato_commerciale = 'da_preventivare'::public.stato_commerciale
    and v_prima.stato_completezza <> 'completa_da_preventivare'::public.stato_completezza
  then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'dati_non_completi',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  update public.pratiche
  set
    tipo_flusso = 'commerciale'::public.tipo_flusso,
    stato_commerciale = 'ordine_acquisito'::public.stato_commerciale,
    stato_fatturazione = 'da_fatturare'::public.stato_fatturazione,
    preventivo_inviato_at = coalesce(preventivo_inviato_at, now()),
    ordine_acquisito_at = coalesce(ordine_acquisito_at, now()),
    data_fattura = null,
    blocco_classificazione_operatore = true
  where id = p_pratica_id
    and stato_commerciale in (
      'da_preventivare'::public.stato_commerciale,
      'preventivo_pronto'::public.stato_commerciale,
      'preventivo_inviato'::public.stato_commerciale,
      'attesa_cliente'::public.stato_commerciale
    )
  returning * into v_dopo;

  if not found then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'stato_modificato_contemporaneamente'
    );
  end if;

  update public.preventivi
  set
    stato = 'accettato',
    accettato_at = coalesce(accettato_at, v_dopo.ordine_acquisito_at, now())
  where pratica_id = p_pratica_id
    and stato = 'inviato';

  insert into public.azioni_operatore (
    pratica_id,
    azione,
    nota,
    stato_prima,
    stato_dopo
  )
  values (
    p_pratica_id,
    'keplero_ordine_acquisito',
    case
      when nullif(trim(coalesce(p_messaggio_cliente, '')), '') is null
        then 'Keplero ha rilevato una conferma esplicita dell''ordine/preventivo da parte del cliente.'
      else 'Conferma esplicita rilevata da Keplero: ' || left(trim(p_messaggio_cliente), 1000)
    end,
    to_jsonb(v_prima),
    to_jsonb(v_dopo)
  );

  return jsonb_build_object(
    'aggiornato', true,
    'motivo', 'conferma_esplicita_cliente',
    'pratica_id', p_pratica_id,
    'stato_precedente', v_prima.stato_commerciale,
    'stato_commerciale', v_dopo.stato_commerciale,
    'stato_fatturazione', v_dopo.stato_fatturazione
  );
end;
$function$;

revoke all on function public.conferma_ordine_da_keplero(uuid, text, text)
from public, anon, authenticated;

grant execute on function public.conferma_ordine_da_keplero(uuid, text, text)
to service_role;

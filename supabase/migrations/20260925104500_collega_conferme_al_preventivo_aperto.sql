create or replace function public.prepara_instradamento_keplero(
  p_external_key text,
  p_conversation_id text default null,
  p_telefono text default null,
  p_targa text default null,
  p_marca_veicolo text default null,
  p_modello_veicolo text default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_pratica public.pratiche%rowtype;
  v_conversation_uuid uuid;
  v_targa text;
  v_targa_attuale text;
  v_telefono text;
  v_marca text;
  v_marca_attuale text;
  v_modello text;
  v_modello_attuale text;
  v_nuova_pratica_esplicita boolean := false;
  v_ordine_confermato boolean := false;
  v_identita_diversa boolean := false;
  v_external_key_effettiva text;
  v_candidato_id uuid;
  v_numero_candidati integer := 0;
begin
  if nullif(btrim(coalesce(p_external_key, '')), '') is null then
    raise exception 'external_key mancante';
  end if;

  v_targa := nullif(
    upper(regexp_replace(btrim(coalesce(p_targa, '')), '[^A-Za-z0-9]', '', 'g')),
    ''
  );
  v_telefono := nullif(regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g'), '');
  v_marca := nullif(lower(regexp_replace(btrim(coalesce(p_marca_veicolo, '')), '\s+', ' ', 'g')), '');
  v_modello := nullif(lower(regexp_replace(btrim(coalesce(p_modello_veicolo, '')), '\s+', ' ', 'g')), '');
  v_nuova_pratica_esplicita := lower(
    coalesce(p_payload ->> 'nuova_pratica_richiesta', 'false')
  ) in ('1', 'true', 'vero', 'si', 'sì', 'yes');
  v_ordine_confermato := lower(
    coalesce(p_payload ->> 'ordine_confermato_rilevato', 'false')
  ) in ('1', 'true', 'vero', 'si', 'sì', 'yes');

  select p.*
    into v_pratica
  from public.keplero_live_links l
  join public.pratiche p on p.id = l.pratica_id
  where l.external_key = p_external_key
  limit 1;

  if v_pratica.id is null then
    begin
      if nullif(btrim(coalesce(p_conversation_id, '')), '') is not null then
        v_conversation_uuid := btrim(p_conversation_id)::uuid;
      end if;
    exception when others then
      v_conversation_uuid := null;
    end;

    if v_conversation_uuid is not null then
      select p.*
        into v_pratica
      from public.pratiche p
      where p.keplero_conversation_id = v_conversation_uuid::text
      order by p.updated_at desc, p.created_at desc
      limit 1;
    end if;
  end if;

  -- Una conferma esplicita deve raggiungere il preventivo commerciale aperto,
  -- anche se Keplero la etichetta come assistenza o corregge un carattere
  -- della targa letto in precedenza. Prima si cerca la corrispondenza esatta;
  -- in sua assenza si procede solo se esiste un unico preventivo aperto per
  -- quel numero WhatsApp.
  if v_pratica.id is null
     and v_ordine_confermato
     and length(coalesce(v_telefono, '')) >= 8
  then
    if v_targa is not null then
      select count(*), min(c.id::text)::uuid
        into v_numero_candidati, v_candidato_id
      from (
        select p.id
        from public.pratiche p
        where p.tipo_flusso = 'commerciale'::public.tipo_flusso
          and p.stato_commerciale in (
            'preventivo_inviato'::public.stato_commerciale,
            'attesa_cliente'::public.stato_commerciale
          )
          and regexp_replace(coalesce(p.telefono, ''), '[^0-9]', '', 'g') = v_telefono
          and upper(regexp_replace(coalesce(p.targa, ''), '[^A-Za-z0-9]', '', 'g')) = v_targa
          and p.created_at >= now() - interval '90 days'
          and (
            p.preventivo_inviato_at is not null
            or exists (
              select 1
              from public.preventivi pv
              where pv.pratica_id = p.id
                and pv.stato in ('inviato', 'accettato')
            )
          )
          and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
          and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
        limit 2
      ) c;
    end if;

    if v_numero_candidati <> 1 then
      v_candidato_id := null;

      select count(*), min(c.id::text)::uuid
        into v_numero_candidati, v_candidato_id
      from (
        select p.id
        from public.pratiche p
        where p.tipo_flusso = 'commerciale'::public.tipo_flusso
          and p.stato_commerciale in (
            'preventivo_inviato'::public.stato_commerciale,
            'attesa_cliente'::public.stato_commerciale
          )
          and regexp_replace(coalesce(p.telefono, ''), '[^0-9]', '', 'g') = v_telefono
          and p.created_at >= now() - interval '90 days'
          and (
            p.preventivo_inviato_at is not null
            or exists (
              select 1
              from public.preventivi pv
              where pv.pratica_id = p.id
                and pv.stato in ('inviato', 'accettato')
            )
          )
          and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
          and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
        limit 2
      ) c;
    end if;

    if v_numero_candidati = 1 and v_candidato_id is not null then
      select * into v_pratica
      from public.pratiche
      where id = v_candidato_id;

      delete from public.keplero_live_links
      where pratica_id = v_pratica.id
        and external_key <> p_external_key;

      insert into public.keplero_live_links (
        external_key, pratica_id, created_at, updated_at
      )
      values (p_external_key, v_pratica.id, now(), now())
      on conflict (external_key)
      do update set
        pratica_id = excluded.pratica_id,
        updated_at = now();
    end if;
  end if;

  if v_pratica.id is null then
    return jsonb_build_object(
      'ok', true,
      'external_key', p_external_key,
      'nuova_pratica', false,
      'richiedi_targa', false,
      'usa_conversation_id', true,
      'motivo', 'prima_pratica_conversazione'
    );
  end if;

  v_targa_attuale := nullif(
    upper(regexp_replace(btrim(coalesce(v_pratica.targa, '')), '[^A-Za-z0-9]', '', 'g')),
    ''
  );
  v_marca_attuale := nullif(lower(regexp_replace(btrim(coalesce(v_pratica.marca_veicolo, '')), '\s+', ' ', 'g')), '');
  v_modello_attuale := nullif(lower(regexp_replace(btrim(coalesce(v_pratica.modello_veicolo, '')), '\s+', ' ', 'g')), '');

  v_identita_diversa :=
    (v_marca is not null and v_marca_attuale is not null and v_marca <> v_marca_attuale)
    or
    (v_modello is not null and v_modello_attuale is not null and v_modello <> v_modello_attuale);

  if not v_ordine_confermato
     and v_targa is null
     and (v_nuova_pratica_esplicita or v_identita_diversa)
  then
    return jsonb_build_object(
      'ok', true,
      'external_key', p_external_key,
      'nuova_pratica', false,
      'richiedi_targa', true,
      'usa_conversation_id', false,
      'pratica_precedente_id', v_pratica.id,
      'pratica_precedente_targa', v_targa_attuale,
      'motivo', case
        when v_nuova_pratica_esplicita then 'nuovo_veicolo_senza_targa'
        else 'identita_veicolo_diversa_senza_targa'
      end
    );
  end if;

  if not v_ordine_confermato
     and v_targa is not null
     and (
       (v_targa_attuale is not null and v_targa <> v_targa_attuale)
       or
       (v_targa_attuale is null and (v_nuova_pratica_esplicita or v_identita_diversa))
     )
  then
    v_external_key_effettiva := concat(
      p_external_key,
      ':veicolo:',
      lower(v_targa)
    );

    return jsonb_build_object(
      'ok', true,
      'external_key', v_external_key_effettiva,
      'external_key_conversazione', p_external_key,
      'nuova_pratica', true,
      'richiedi_targa', false,
      'usa_conversation_id', false,
      'pratica_precedente_id', v_pratica.id,
      'pratica_precedente_targa', v_targa_attuale,
      'nuova_targa', v_targa,
      'motivo', 'targa_diversa'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'external_key', p_external_key,
    'nuova_pratica', false,
    'richiedi_targa', false,
    'usa_conversation_id', false,
    'pratica_id', v_pratica.id,
    'motivo', case
      when v_ordine_confermato then 'conferma_ordine_collegata_al_preventivo'
      else 'continua_pratica_attiva'
    end
  );
end;
$$;

revoke all on function public.prepara_instradamento_keplero(
  text, text, text, text, text, text, jsonb
) from public, anon, authenticated;

grant execute on function public.prepara_instradamento_keplero(
  text, text, text, text, text, text, jsonb
) to service_role;

comment on function public.prepara_instradamento_keplero(
  text, text, text, text, text, text, jsonb
) is
  'Instrada le nuove vetture e collega le conferme esplicite al preventivo commerciale aperto univoco dello stesso numero WhatsApp.';

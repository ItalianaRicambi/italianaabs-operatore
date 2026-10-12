CREATE OR REPLACE FUNCTION public.prepara_instradamento_keplero(p_external_key text, p_conversation_id text DEFAULT NULL::text, p_telefono text DEFAULT NULL::text, p_targa text DEFAULT NULL::text, p_marca_veicolo text DEFAULT NULL::text, p_modello_veicolo text DEFAULT NULL::text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_targhe_allegati integer := 0;
  v_event_id bigint;
begin
  if nullif(btrim(coalesce(p_external_key, '')), '') is null then
    raise exception 'external_key mancante';
  end if;

  v_targa := nullif(upper(regexp_replace(btrim(coalesce(p_targa, '')), '[^A-Za-z0-9]', '', 'g')), '');
  v_telefono := nullif(regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g'), '');
  v_marca := nullif(lower(regexp_replace(btrim(coalesce(p_marca_veicolo, '')), '\s+', ' ', 'g')), '');
  v_modello := nullif(lower(regexp_replace(btrim(coalesce(p_modello_veicolo, '')), '\s+', ' ', 'g')), '');
  v_nuova_pratica_esplicita := lower(coalesce(p_payload ->> 'nuova_pratica_richiesta', 'false'))
    in ('1','true','vero','si','sì','yes');
  v_ordine_confermato := lower(coalesce(p_payload ->> 'ordine_confermato_rilevato', 'false'))
    in ('1','true','vero','si','sì','yes');

  -- Recupera la pratica del preventivo anche quando K non marca la conferma.
  -- Conserva i blocchi e non sposta una conversazione già in gestione avanzata.
  v_candidato_id:=private.preventivo_univoco_per_payload(p_telefono,p_targa,p_marca_veicolo,p_payload);
  if v_candidato_id is not null and not v_nuova_pratica_esplicita
    and not exists(select 1 from public.keplero_live_links l join public.pratiche a on a.id=l.pratica_id
      where l.external_key=p_external_key and a.id<>v_candidato_id
      and (a.blocco_operatore or a.tipo_flusso<>'commerciale'
        or a.stato_commerciale::text in ('ordine_acquisito','rifiutato','chiuso')
        or a.stato_fatturazione<>'non_applicabile'))
  then
    -- La tabella mantiene una sola chiave canonica per pratica.
    -- Riutilizzarla evita violazioni unique e conserva i link storici.
    select external_key into v_external_key_effettiva from public.keplero_live_links where pratica_id=v_candidato_id;
    if v_external_key_effettiva is null then
      -- Se la chiave ricevuta è già assegnata, lascia gestire il caso al flusso esistente.
      if exists(select 1 from public.keplero_live_links where external_key=p_external_key) then
        v_candidato_id:=null;
      else
        insert into public.keplero_live_links(external_key,pratica_id) values(p_external_key,v_candidato_id);
        v_external_key_effettiva:=p_external_key;
      end if;
    end if;
    if v_candidato_id is not null then
      return jsonb_build_object('ok',true,'external_key',v_external_key_effettiva,
        'nuova_pratica',false,'richiedi_targa',false,'usa_conversation_id',false,
        'pratica_id',v_candidato_id,'motivo','continuita_preventivo_univoco');
    end if;
  end if;

  select p.* into v_pratica
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
      select p.* into v_pratica
      from public.pratiche p
      where p.keplero_conversation_id = v_conversation_uuid::text
      order by p.updated_at desc, p.created_at desc
      limit 1;
    end if;
  end if;

  -- Se la targa non è strutturata, prova a ricavarla solo da un PDF il cui
  -- nome coincide esattamente con una targa già presente. Nessuna OCR o
  -- interpretazione libera: occorre una sola corrispondenza univoca.
  if v_ordine_confermato and v_targa is null then
    with allegati as (
      select upper(regexp_replace(regexp_replace(x, '^.*[/\\]', ''), '\.pdf$', '', 'i')) as nome
      from jsonb_array_elements_text(coalesce(p_payload -> 'allegati', '[]'::jsonb)) x
      where x ~* '\.pdf$'
    ), corrispondenze as (
      select distinct upper(regexp_replace(coalesce(p.targa, ''), '[^A-Za-z0-9]', '', 'g')) as targa
      from allegati a
      join public.pratiche p
        on upper(regexp_replace(a.nome, '[^A-Za-z0-9]', '', 'g'))
         = upper(regexp_replace(coalesce(p.targa, ''), '[^A-Za-z0-9]', '', 'g'))
      where coalesce(p.targa, '') <> ''
    )
    select count(*), min(targa)
    into v_targhe_allegati, v_targa
    from corrispondenze;

    if v_targhe_allegati <> 1 then
      v_targa := null;
    end if;
  end if;

  -- Una conferma esplicita può provenire da un numero diverso dell'officina.
  -- Prima usa la targa esatta (anche ricavata dal nome PDF), poi il telefono.
  -- Il collegamento avviene solo se esiste un unico preventivo aperto.
  if v_ordine_confermato then
    if v_targa is not null then
      select count(*), min(c.id::text)::uuid
      into v_numero_candidati, v_candidato_id
      from (
        select p.id
        from public.pratiche p
        where upper(regexp_replace(coalesce(p.targa, ''), '[^A-Za-z0-9]', '', 'g')) = v_targa
          and p.stato_commerciale in ('preventivo_inviato','attesa_cliente','ordine_acquisito')
          and p.stato_fatturazione <> 'fatturato'
          and (
            p.preventivo_inviato_at is not null
            or exists (
              select 1 from public.preventivi pv
              where pv.pratica_id = p.id and pv.stato in ('inviato','accettato')
            )
          )
          and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
          and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
        limit 2
      ) c;
    end if;

    if v_numero_candidati <> 1 and length(coalesce(v_telefono, '')) >= 8 then
      v_candidato_id := null;
      select count(*), min(c.id::text)::uuid
      into v_numero_candidati, v_candidato_id
      from (
        select p.id
        from public.pratiche p
        where p.tipo_flusso = 'commerciale'::public.tipo_flusso
          and p.stato_commerciale in ('preventivo_inviato','attesa_cliente','ordine_acquisito')
          and p.stato_fatturazione <> 'fatturato'
          and regexp_replace(coalesce(p.telefono, ''), '[^0-9]', '', 'g') = v_telefono
          and (
            p.preventivo_inviato_at is not null
            or exists (
              select 1 from public.preventivi pv
              where pv.pratica_id = p.id and pv.stato in ('inviato','accettato')
            )
          )
          and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
          and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
        limit 2
      ) c;
    end if;

    if v_numero_candidati = 1 and v_candidato_id is not null
       and (
         v_pratica.id is null
         or v_pratica.id = v_candidato_id
         or (
           v_pratica.stato_commerciale not in ('preventivo_inviato','attesa_cliente','ordine_acquisito')
           and v_pratica.stato_fatturazione <> 'fatturato'
         )
       ) then
      select * into v_pratica from public.pratiche where id = v_candidato_id;

      insert into public.keplero_live_links(external_key, pratica_id, created_at, updated_at)
      values (p_external_key, v_pratica.id, now(), now())
      on conflict (external_key) do update
      set pratica_id = excluded.pratica_id, updated_at = now();
    end if;
  end if;

  if v_pratica.id is null then
    return jsonb_build_object('ok', true, 'external_key', p_external_key,
      'nuova_pratica', false, 'richiedi_targa', false, 'usa_conversation_id', true,
      'motivo', 'prima_pratica_conversazione');
  end if;

  v_targa_attuale := nullif(upper(regexp_replace(btrim(coalesce(v_pratica.targa, '')), '[^A-Za-z0-9]', '', 'g')), '');
  v_marca_attuale := nullif(lower(regexp_replace(btrim(coalesce(v_pratica.marca_veicolo, '')), '\s+', ' ', 'g')), '');
  v_modello_attuale := nullif(lower(regexp_replace(btrim(coalesce(v_pratica.modello_veicolo, '')), '\s+', ' ', 'g')), '');

  v_identita_diversa :=
    (v_marca is not null and v_marca_attuale is not null and v_marca <> v_marca_attuale)
    or (v_modello is not null and v_modello_attuale is not null and v_modello <> v_modello_attuale);

  if not v_ordine_confermato and v_targa is null
     and (v_nuova_pratica_esplicita or v_identita_diversa) then
    -- Conserva la ricezione senza attribuire il nuovo veicolo alla vecchia pratica.
    insert into public.keplero_live_events(external_key, pratica_id, payload)
    values (p_external_key, null, coalesce(p_payload, '{}'::jsonb) ||
      jsonb_build_object('instradamento_sospeso', true,
        'motivo_sospensione', 'nuovo_veicolo_senza_targa',
        'pratica_precedente_id', v_pratica.id,
        'marca_veicolo', p_marca_veicolo, 'modello_veicolo', p_modello_veicolo))
    returning id into v_event_id;
    return jsonb_build_object('ok', true, 'external_key', p_external_key,
      'nuova_pratica', false, 'richiedi_targa', true, 'usa_conversation_id', false,
      'evento_ricevuto_id', v_event_id, 'ricezione_registrata', true,
      'pratica_precedente_id', v_pratica.id, 'pratica_precedente_targa', v_targa_attuale,
      'motivo', case when v_nuova_pratica_esplicita then 'nuovo_veicolo_senza_targa'
                     else 'identita_veicolo_diversa_senza_targa' end);
  end if;

  if not v_ordine_confermato and v_targa is not null
     and ((v_targa_attuale is not null and v_targa <> v_targa_attuale)
       or (v_targa_attuale is null and (v_nuova_pratica_esplicita or v_identita_diversa))) then
    v_external_key_effettiva := concat(p_external_key, ':veicolo:', lower(v_targa));
    return jsonb_build_object('ok', true, 'external_key', v_external_key_effettiva,
      'external_key_conversazione', p_external_key, 'nuova_pratica', true,
      'richiedi_targa', false, 'usa_conversation_id', false,
      'pratica_precedente_id', v_pratica.id, 'pratica_precedente_targa', v_targa_attuale,
      'nuova_targa', v_targa, 'motivo', 'targa_diversa');
  end if;

  return jsonb_build_object('ok', true, 'external_key', p_external_key,
    'nuova_pratica', false, 'richiedi_targa', false, 'usa_conversation_id', false,
    'pratica_id', v_pratica.id,
    'motivo', case when v_ordine_confermato then 'conferma_ordine_collegata_al_preventivo'
                   else 'continua_pratica_attiva' end);
end;
$function$;

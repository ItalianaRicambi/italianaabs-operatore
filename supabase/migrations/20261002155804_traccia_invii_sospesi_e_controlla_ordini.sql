-- Registra invii sospesi e rende il controllo coerente con le nuove regole ordine.
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
$function$
;
CREATE OR REPLACE FUNCTION private.candidati_coerenza_keplero()
 RETURNS TABLE(chiave text, pratica_id uuid, event_id bigint, regola text, descrizione text, evidenza text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
with eventi as (
  select e.*, lower(trim(coalesce(e.payload->>'ultimo_messaggio_cliente', e.payload->>'messaggio_cliente', e.payload->>'messaggio', ''))) as testo
  from public.keplero_live_events e
  where e.created_at >= private.inizio_finestra_controllo_keplero(now(),48)
    and e.created_at < now() - interval '10 minutes'
), ultime as (
  select distinct on (e.pratica_id) e.* from eventi e
  where e.pratica_id is not null order by e.pratica_id, e.id desc
), pratiche as (
  select p.*, q.inviato_at as ultimo_preventivo_at
  from public.pratiche p
  left join lateral (
    select max(coalesce(pv.inviato_at,pv.creato_at)) inviato_at
    from public.preventivi pv where pv.pratica_id=p.id and pv.stato in ('inviato','accettato')
  ) q on true
  where coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
    and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
    and p.stato_commerciale::text not in ('rifiutato','chiuso')
    and not exists (
      select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
      and c.telefono_normalizzato = regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g')
    )
), conferme as (
  select distinct on (p.id) p.id pratica_id,e.id event_id,e.testo
  from pratiche p join eventi e on e.pratica_id=p.id
  where p.tipo_flusso::text='commerciale'
    and p.stato_commerciale::text <> 'ordine_acquisito'
    and p.stato_fatturazione::text not in ('fatturato','da_fatturare')
    and coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at) is not null
    and e.created_at >= coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at)
    and private.evidenza_accettazione_controllo(e.testo)
    and not private.rinvio_conferma_per_verifiche(e.testo)
    -- Una revoca successiva sospende la segnalazione della vecchia accettazione.
    and not exists (select 1 from eventi r where r.pratica_id=p.id and r.id>e.id
      and private.revoca_scelta_cliente(r.testo))
  order by p.id,e.id desc
), contestuali as (
  select distinct on (p.id) p.id pratica_id,e.id event_id,e.testo
  from pratiche p join eventi e on e.pratica_id=p.id
  where p.tipo_flusso::text='commerciale'
    and p.stato_commerciale::text in ('preventivo_inviato','attesa_cliente')
    and p.stato_fatturazione::text not in ('fatturato','da_fatturare')
    and coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at) is not null
    and e.created_at >= coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at)
    and e.testo ~ '^programma scambio[.! ]*$'
    and exists (select 1 from eventi a where a.pratica_id=p.id and a.id<=e.id
      and a.created_at>=coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at)
      and a.created_at >= private.inizio_finestra_controllo_keplero(e.created_at,24)
      and a.testo ~ '\m(compro|acquisto|compriamo|acquistiamo)\M'
      and a.testo !~ '(non[[:space:]]+((lo|la)[[:space:]]+)?(compr|acquist)|\mse\M|forse|valutare)')
    and not exists (select 1 from eventi r where r.pratica_id=p.id and r.id>e.id and r.testo ~ '(rifiut|annull|non.{0,25}(accett|compr|acquist))')
  order by p.id,e.id desc
)
select 'ordine:'||c.pratica_id,c.pratica_id,c.event_id,'ordine_non_acquisito',
  'Accettazione letterale dopo il preventivo, ma ordine non acquisito. Verificare offerta e pratica prima di confermare.', left(c.testo,600) from conferme c
union all
select 'contesto:'||c.pratica_id,c.pratica_id,c.event_id,'acquisto_da_verificare',
  'Intenzione di acquisto e scelta Programma Scambio nella stessa pratica. Accettazione da verificare nel contesto.',left(c.testo,600) from contestuali c
union all
select 'completezza:'||p.id,p.id,e.id,'richiesta_completa_non_in_coda',
  'Dati tecnici presenti, ma pratica ancora fuori dalla coda Da preventivare. Verificare eventuali blocchi operatore.',left(e.testo,600)
from pratiche p join ultime e on e.pratica_id=p.id
where p.tipo_flusso::text='commerciale' and p.stato_commerciale::text in ('nuova','raccolta_dati')
  and nullif(trim(p.targa),'') is not null and nullif(trim(p.descrizione_guasto),'') is not null
  and (exists(select 1 from public.codici_identificativi c where c.pratica_id=p.id and nullif(trim(c.codice),'') is not null)
       or exists(select 1 from public.allegati a where a.pratica_id=p.id and nullif(a.url,'') is not null))
  and (p.spie_accese=false or (p.spie_accese=true and exists(select 1 from public.dtc d where d.pratica_id=p.id)))
  and p.ultimo_preventivo_at is null and p.preventivo_inviato_at is null
union all
select 'preventivo:'||p.id,p.id,e.id,'preventivo_non_allineato',
  'Preventivo registrato come inviato, ma pratica ancora in una fase precedente.',left(e.testo,600)
from pratiche p join ultime e on e.pratica_id=p.id
where p.ultimo_preventivo_at is not null and p.stato_commerciale::text in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto')
  and p.stato_fatturazione::text not in ('fatturato','da_fatturare')
union all
select 'allegati:'||p.id,p.id,e.id,'allegati_non_disponibili',
  'K dichiara documenti o immagini senza trasmettere i file. Verificare la conversazione originale.',left(e.testo,600)
from pratiche p join ultime e on e.pratica_id=p.id
where (e.payload->>'allegati_descritti_ma_non_trasmessi'='true' or e.payload->>'stato_lettura_immagini'='file_non_trasmessi_da_keplero')
  and not exists(select 1 from public.allegati a where a.pratica_id=p.id and a.created_at>=e.created_at)
union all
select 'evento:'||e.id,e.pratica_id,e.id,'evento_senza_pratica',
  'Evento ricevuto senza collegamento a una pratica.',left(e.testo,600)
from eventi e where e.pratica_id is null
  and coalesce(e.payload->>'instradamento_sospeso','false') <> 'true'
union all
select 'errore:'||e.id,e.pratica_id,e.id,'errore_elaborazione',
  'Errore nel motore eventi: '||left(coalesce(ep.errore,''),250),left(e.testo,600)
from eventi e join private.keplero_event_processing ep on ep.event_id=e.id where ep.stato='errore'
union all
select 'sospeso:'||e.external_key||':'||md5(coalesce(e.payload->>'marca_veicolo','')||':'||coalesce(e.payload->>'modello_veicolo','')),
  null::uuid,e.id,'nuovo_veicolo_senza_targa',
  'Invio ricevuto ma nuova pratica sospesa: manca la targa. Verificare la conversazione.',left(e.testo,600)
from (select distinct on (external_key,payload->>'marca_veicolo',payload->>'modello_veicolo') *
  from eventi where pratica_id is null and payload->>'instradamento_sospeso'='true'
  order by external_key,payload->>'marca_veicolo',payload->>'modello_veicolo',id desc) e
union all
select distinct on (e.pratica_id) 'scelta_fiscali:'||e.pratica_id,e.pratica_id,e.id,
  'ordine_contestuale_non_acquisito',
  'Scelta di lavorazione seguita da dati fiscali dopo il preventivo, ma ordine non acquisito.',left(e.testo,600)
from eventi e join pratiche p on p.id=e.pratica_id
where private.ordine_da_scelta_e_fiscali(e.id)->>'confermato'='true'
  and not exists (select 1 from eventi r where r.pratica_id=e.pratica_id and r.id>e.id
    and private.revoca_scelta_cliente(r.testo))
;
$function$
;

-- La scelta espressa al condizionale non basta da sola: occorre il successivo
-- invio letterale di dati fiscali sulla stessa pratica e dopo il preventivo.
create or replace function private.scelta_lavorazione_cliente(p_testo text)
returns boolean language sql immutable set search_path = '' as $fn$
select coalesce(
 lower(trim(p_testo)) ~ '^(sarei interessat[oa] a (fare )?(revisionare|riparare)|vorrei procedere con|procediamo con|scelgo|ho scelto|preferisco)[[:space:]]'
 and lower(p_testo) ~ '\m(revision|ripar|lavoraz|programma scambio)'
 and lower(p_testo) !~ '(non.{0,30}(revision|ripar|proced|scel)|ci penso|forse|valut|quanto|se.{0,30}(riparabile|possibile|costa))',
 false);
$fn$;

create or replace function private.dati_fiscali_cliente(p_testo text)
returns boolean language sql immutable set search_path = '' as $fn$
select coalesce(
 p_testo ~* '[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}'
 and (p_testo ~* '\m[A-Z]{6}[0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z]\M'
      or p_testo ~* '(partita[[:space:]]*iva|p[.]?[[:space:]]*iva)[[:space:]:.]*(IT)?[0-9]{11}\M')
 and lower(p_testo) !~ '(esempio|fac.?simile|annull|non.{0,25}(accett|conferm|proced))',
 false);
$fn$;

create or replace function private.revoca_scelta_cliente(p_testo text)
returns boolean language sql immutable set search_path = '' as $fn$
select coalesce(lower(p_testo) ~ '(non.{0,30}(accett|conferm|proced|revision|ripar)|annull|rifiut|ci penso|ho cambiato idea|aspetta|attenda)',false);
$fn$;

create or replace function private.ordine_da_scelta_e_fiscali(p_event_id bigint)
returns jsonb language plpgsql stable set search_path = '' as $fn$
declare
 v_evento public.keplero_live_events%rowtype;
 v_pratica public.pratiche%rowtype;
 v_scelta public.keplero_live_events%rowtype;
 v_preventivo_at timestamptz;
 v_testo text;
begin
 select * into v_evento from public.keplero_live_events where id=p_event_id;
 if not found or v_evento.pratica_id is null then return '{}'::jsonb; end if;
 select * into v_pratica from public.pratiche where id=v_evento.pratica_id;
 if not found or v_pratica.tipo_flusso::text <> 'commerciale'
    or v_pratica.stato_commerciale::text not in ('preventivo_inviato','attesa_cliente')
    or v_pratica.stato_fatturazione::text in ('da_fatturare','fatturato')
    or v_pratica.blocco_operatore
    or coalesce(v_pratica.dati_raw #>> '{archiviazione_test,archiviata}','false')='true'
    or coalesce(v_pratica.dati_raw #>> '{pratica_duplicata,archiviata}','false')='true'
 then return '{}'::jsonb; end if;
 if exists (select 1 from public.contatti_operativi c where c.attivo
    and c.blocca_automazioni_commerciali and c.telefono_normalizzato=
      regexp_replace(coalesce(v_pratica.telefono,''),'[^0-9]','','g'))
 then return '{}'::jsonb; end if;

 -- Preferire l'ultimo preventivo: una scelta precedente a una nuova offerta
 -- non autorizza automaticamente l'accettazione della nuova proposta.
 select greatest(v_pratica.preventivo_inviato_at,max(pv.inviato_at))
 into v_preventivo_at from public.preventivi pv
 where pv.pratica_id=v_pratica.id and pv.stato in ('inviato','accettato');
 if v_preventivo_at is null or v_evento.created_at < v_preventivo_at
 then return '{}'::jsonb; end if;
 v_testo := coalesce(v_evento.payload->>'ultimo_messaggio_cliente',
                    v_evento.payload->>'messaggio_cliente',v_evento.payload->>'messaggio','');
 if not private.dati_fiscali_cliente(v_testo)
    or nullif(v_pratica.targa,'') is null
    or upper(regexp_replace(coalesce(v_evento.payload->>'targa',''),'[^A-Za-z0-9]','','g')) <>
       upper(regexp_replace(v_pratica.targa,'[^A-Za-z0-9]','','g'))
 then return '{}'::jsonb; end if;

 select e.* into v_scelta from public.keplero_live_events e
 where e.pratica_id=v_pratica.id and e.external_key=v_evento.external_key
   and e.id<v_evento.id and e.created_at<=v_evento.created_at
   and e.created_at>=v_preventivo_at
   and e.created_at>=private.inizio_finestra_controllo_keplero(v_evento.created_at,48)
   and upper(regexp_replace(coalesce(e.payload->>'targa',''),'[^A-Za-z0-9]','','g')) =
       upper(regexp_replace(v_pratica.targa,'[^A-Za-z0-9]','','g'))
   and private.scelta_lavorazione_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
         e.payload->>'messaggio_cliente',e.payload->>'messaggio',''))
 order by e.created_at desc,e.id desc limit 1;
 if not found then return '{}'::jsonb; end if;
 if exists (select 1 from public.keplero_live_events e
   where e.pratica_id=v_pratica.id and e.id>v_scelta.id
     and e.created_at>=v_scelta.created_at
     and e.created_at<=v_evento.created_at and e.id<=v_evento.id
     and private.revoca_scelta_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
       e.payload->>'messaggio_cliente',e.payload->>'messaggio','')))
 then return '{}'::jsonb; end if;
 return jsonb_build_object('confermato',true,'regola','scelta_lavorazione_e_dati_fiscali_v1',
   'evento_scelta',v_scelta.id,'evento_dati_fiscali',v_evento.id);
end;
$fn$;

revoke all on function private.scelta_lavorazione_cliente(text),
 private.dati_fiscali_cliente(text),private.revoca_scelta_cliente(text),
 private.ordine_da_scelta_e_fiscali(bigint) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.processa_evento_keplero()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_decisione jsonb := coalesce(new.payload -> 'decisione_sistema', '{}'::jsonb);
  v_versione text := coalesce(
    nullif(v_decisione ->> 'versione_regole', ''),
    'legacy-non-strutturato'
  );
  v_ordine boolean := coalesce(
    (v_decisione #>> '{ordine,confermato}')::boolean,
    (new.payload ->> 'ordine_confermato_rilevato')::boolean,
    false
  );
  v_contesto_ordine jsonb := '{}'::jsonb;
  v_allegati jsonb := '[]'::jsonb;
  v_esito_ordine jsonb := '{}'::jsonb;
  v_esito_allegati jsonb := '{}'::jsonb;
  v_stato text := 'elaborato';
begin
  if new.pratica_id is null then
    v_stato := 'da_verificare';
  end if;

  if new.pratica_id is not null and not v_ordine then
    v_contesto_ordine := private.ordine_da_scelta_e_fiscali(new.id);
    v_ordine := coalesce((v_contesto_ordine->>'confermato')::boolean,false);
  end if;

  if new.pratica_id is not null and v_ordine then
    v_esito_ordine := public.conferma_ordine_da_keplero(
      new.pratica_id,
      new.external_key,
      coalesce(
        new.payload ->> 'ultimo_messaggio_cliente',
        new.payload ->> 'messaggio_cliente',
        new.payload ->> 'messaggio'
      )
    );

    if coalesce(v_esito_ordine ->> 'motivo', '') in (
      'preventivo_non_registrato',
      'collegamento_keplero_non_valido',
      'stato_non_abilitato',
      'dati_non_completi'
    ) then
      v_stato := 'da_verificare';
    end if;
  end if;

  with sorgenti as (
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(new.payload -> 'allegati') = 'array'
          then new.payload -> 'allegati'
        when jsonb_typeof(new.payload -> 'allegati') = 'string'
          then jsonb_build_array(new.payload -> 'allegati')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(new.payload -> 'attachments') = 'array'
          then new.payload -> 'attachments'
        when jsonb_typeof(new.payload -> 'attachments') = 'string'
          then jsonb_build_array(new.payload -> 'attachments')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(new.payload -> 'attachment_urls') = 'array'
          then new.payload -> 'attachment_urls'
        when jsonb_typeof(new.payload -> 'attachment_urls') = 'string'
          then jsonb_build_array(new.payload -> 'attachment_urls')
        else '[]'::jsonb
      end
    ) elemento
  ), valori as (
    select case
      when jsonb_typeof(elemento) = 'object' then elemento ->> 'url'
      when jsonb_typeof(elemento) = 'string' then elemento #>> '{}'
      else null
    end valore
    from sorgenti
  ), url as (
    select distinct (regexp_match(valore, 'https?://[^[:space:]<>"]+'))[1] valore
    from valori
    where valore ~ 'https?://'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'url', valore,
    'tipo', case when lower(valore) ~ '[.]pdf([?]|$)' then 'PDF' else 'Allegato' end
  )), '[]'::jsonb)
  into v_allegati
  from url
  where valore is not null;

  if new.pratica_id is not null and jsonb_array_length(v_allegati) > 0 then
    v_esito_allegati := public.sincronizza_allegati_keplero(
      new.pratica_id,
      v_allegati
    );
  elsif new.pratica_id is not null and (
    coalesce(new.payload ->> 'stato_lettura_immagini', '') = 'file_non_trasmessi_da_keplero'
    or coalesce(new.payload ->> 'allegati_descritti_ma_non_trasmessi', 'false') = 'true'
  ) then
    v_stato := 'da_verificare';
  end if;

  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore,
    tentativi, elaborato_at, updated_at
  ) values (
    new.id, new.pratica_id, v_versione, v_stato,
    jsonb_build_object(
      'decisione_ricevuta', v_decisione,
      'esito_ordine', v_esito_ordine,
      'contesto_ordine', v_contesto_ordine,
      'esito_allegati', v_esito_allegati,
      'numero_allegati_url', jsonb_array_length(v_allegati)
    ),
    null, 1, now(), now()
  )
  on conflict (event_id) do update set
    pratica_id = excluded.pratica_id,
    versione_regole = excluded.versione_regole,
    stato = excluded.stato,
    decisione = excluded.decisione,
    errore = null,
    tentativi = private.keplero_event_processing.tentativi + 1,
    elaborato_at = now(),
    updated_at = now();

  return new;
exception when others then
  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore
  ) values (
    new.id, new.pratica_id, v_versione, 'errore', v_decisione, sqlerrm
  )
  on conflict (event_id) do update set
    stato = 'errore',
    errore = excluded.errore,
    tentativi = private.keplero_event_processing.tentativi + 1,
    updated_at = now();

  return new;
end;
$function$;

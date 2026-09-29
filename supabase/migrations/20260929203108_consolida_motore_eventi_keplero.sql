-- Consolida l'elaborazione degli eventi Keplero in un unico punto e rende
-- osservabili gli esiti. I payload restano immutabili in keplero_live_events.

create table if not exists private.keplero_event_processing (
  event_id bigint primary key
    references public.keplero_live_events(id) on delete cascade,
  pratica_id uuid null references public.pratiche(id) on delete set null,
  versione_regole text not null,
  stato text not null check (stato in ('elaborato', 'da_verificare', 'errore')),
  decisione jsonb not null default '{}'::jsonb,
  errore text null,
  tentativi integer not null default 1 check (tentativi > 0),
  elaborato_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_keplero_event_processing_stato_updated
  on private.keplero_event_processing(stato, updated_at desc);

revoke all on private.keplero_event_processing from public, anon, authenticated;

create or replace function private.processa_evento_keplero()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
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
  v_allegati jsonb := '[]'::jsonb;
  v_esito_ordine jsonb := '{}'::jsonb;
  v_esito_allegati jsonb := '{}'::jsonb;
  v_stato text := 'elaborato';
begin
  if new.pratica_id is null then
    v_stato := 'da_verificare';
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

  -- Normalizza soltanto URL letterali presenti nel payload. Il download e la
  -- persistenza del file restano responsabilita del livello applicativo.
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
    select distinct (regexp_match(valore, 'https?://[^[:space:]<>\"]+'))[1] valore
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
    event_id,
    pratica_id,
    versione_regole,
    stato,
    decisione,
    errore,
    tentativi,
    elaborato_at,
    updated_at
  ) values (
    new.id,
    new.pratica_id,
    v_versione,
    v_stato,
    jsonb_build_object(
      'decisione_ricevuta', v_decisione,
      'esito_ordine', v_esito_ordine,
      'esito_allegati', v_esito_allegati,
      'numero_allegati_url', jsonb_array_length(v_allegati)
    ),
    null,
    1,
    now(),
    now()
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

  -- L'evento originale non viene perso anche se una regola secondaria fallisce.
  return new;
end;
$$;

revoke all on function private.processa_evento_keplero()
  from public, anon, authenticated;

drop trigger if exists trg_recupera_conferma_ordine_evento_keplero
  on public.keplero_live_events;
drop trigger if exists trg_riconcilia_ordine_keplero_live_event
  on public.keplero_live_events;
drop trigger if exists trg_sincronizza_allegati_evento_keplero
  on public.keplero_live_events;

drop trigger if exists trg_processa_evento_keplero
  on public.keplero_live_events;
create trigger trg_processa_evento_keplero
after insert on public.keplero_live_events
for each row
execute function private.processa_evento_keplero();

-- Protezione finale: un aggiornamento generico non puo riportare indietro
-- preventivi inviati, ordini acquisiti o fatture. Le correzioni eccezionali
-- richiedono una transazione esplicita che imposti app.autorizza_regressione.
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
    insert into public.azioni_operatore (
      pratica_id, azione, nota, stato_prima, stato_dopo, operatore
    ) values (
      old.id,
      'regressione_bloccata',
      'Il motore centrale ha bloccato una regressione di stato non autorizzata.',
      jsonb_build_object(
        'stato_commerciale', old.stato_commerciale,
        'stato_fatturazione', old.stato_fatturazione,
        'preventivo_inviato_at', old.preventivo_inviato_at,
        'ordine_acquisito_at', old.ordine_acquisito_at,
        'data_fattura', old.data_fattura
      ),
      jsonb_build_object(
        'richiesto', v_richiesto,
        'applicato', jsonb_build_object(
          'stato_commerciale', new.stato_commerciale,
          'stato_fatturazione', new.stato_fatturazione,
          'preventivo_inviato_at', new.preventivo_inviato_at,
          'ordine_acquisito_at', new.ordine_acquisito_at,
          'data_fattura', new.data_fattura
        )
      ),
      'motore_stati'
    );
  end if;

  return new;
end;
$$;

revoke all on function private.proteggi_stati_avanzati()
  from public, anon, authenticated;

drop trigger if exists trg_00_proteggi_stati_avanzati on public.pratiche;
create trigger trg_00_proteggi_stati_avanzati
before update of stato_commerciale, stato_fatturazione,
  preventivo_inviato_at, ordine_acquisito_at, data_fattura
on public.pratiche
for each row
execute function private.proteggi_stati_avanzati();

comment on table private.keplero_event_processing is
  'Esito osservabile e idempotente dell''unico elaboratore centrale degli eventi Keplero.';
comment on function private.proteggi_stati_avanzati() is
  'Impedisce regressioni accidentali di preventivi, ordini e fatture; registra ogni tentativo bloccato.';

create or replace function private.sincronizza_allegati_evento_keplero()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_allegati jsonb := '[]'::jsonb;
begin
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
    ) as elemento
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
    ) as elemento
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
    ) as elemento
  ), valori as (
    select case
      when jsonb_typeof(elemento) = 'object' then elemento ->> 'url'
      when jsonb_typeof(elemento) = 'string' then elemento #>> '{}'
      else null
    end as valore
    from sorgenti
  ), url as (
    select distinct (regexp_match(valore, 'https?://[^[:space:]<>"]+'))[1] as valore
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

  perform public.sincronizza_allegati_keplero(
    new.pratica_id,
    v_allegati
  );

  return new;
end;
$$;

revoke all on function private.sincronizza_allegati_evento_keplero()
  from public, anon, authenticated;

drop trigger if exists trg_sincronizza_allegati_evento_keplero
  on public.keplero_live_events;
create trigger trg_sincronizza_allegati_evento_keplero
after insert on public.keplero_live_events
for each row
execute function private.sincronizza_allegati_evento_keplero();

create or replace function private.recupera_conferma_ordine_evento_keplero()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_messaggio text := lower(trim(coalesce(
    new.payload ->> 'ultimo_messaggio_cliente',
    new.payload ->> 'messaggio_cliente',
    new.payload ->> 'messaggio',
    ''
  )));
  v_riepilogo text := lower(trim(coalesce(
    new.payload ->> 'riepilogo_operativo',
    new.payload ->> 'descrizione_guasto',
    new.payload ->> 'richiesta',
    ''
  )));
  v_conferma boolean := false;
begin
  if v_messaggio ~ '(non.{0,25}(accett|conferm|approv|proced)|rifiut|troppo caro|ci penso|devo valutare|dobbiamo valutare|vi faccio sapere|se (accetto|confermo|procedo)|non vorrei procedere)' then
    return new;
  end if;

  v_conferma :=
    v_messaggio ~ '(accetto|confermo|approvo).{0,45}(preventivo|offerta|ordine)'
    or v_messaggio ~ '(preventivo|offerta|ordine).{0,45}(accettat|confermat|approvat)'
    or v_messaggio ~ '(potete procedere|procedete pure|date pure corso|vorrei dare seguito|vorrei proseguire)'
    or v_messaggio ~ '^lavorazione (elettronica )?(del|dello|sul) dispositivo[.! ]*$'
    or v_messaggio ~ 'ordine.{0,80}(modificar|procedere|ritiro)'
    or v_messaggio ~ '(pagamento effettuato|pagamento eseguito|ho effettuato il pagamento|ho eseguito il pagamento)'
    or v_riepilogo ~ '(accettat|confermat|approvat).{0,55}(lavorazione|riparazione|preventivo|offerta|ordine)'
    or v_riepilogo ~ '(lavorazione|riparazione|preventivo|offerta|ordine).{0,55}(accettat|confermat|approvat)'
    or v_riepilogo ~ 'scelt[oa].{0,55}(lavorazione|riparazione|programma scambio)'
    or v_riepilogo ~ '(dare seguito|procedere|proseguire).{0,55}(preventivo|offerta|lavorazione|riparazione|programma scambio)'
    or v_riepilogo ~ 'modifica.{0,30}ordine.{0,80}(procedere|ritiro)';

  if v_conferma then
    perform public.conferma_ordine_da_keplero(
      new.pratica_id,
      new.external_key,
      coalesce(nullif(v_messaggio, ''), nullif(v_riepilogo, ''))
    );
  end if;

  return new;
end;
$$;

revoke all on function private.recupera_conferma_ordine_evento_keplero()
  from public, anon, authenticated;

drop trigger if exists trg_recupera_conferma_ordine_evento_keplero
  on public.keplero_live_events;
create trigger trg_recupera_conferma_ordine_evento_keplero
after insert on public.keplero_live_events
for each row
execute function private.recupera_conferma_ordine_evento_keplero();

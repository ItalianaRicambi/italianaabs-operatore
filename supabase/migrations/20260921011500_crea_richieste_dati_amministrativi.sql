alter table public.pratiche
  add column if not exists stato_richiesta_amministrativa text
    not null default 'non_necessaria'
    check (stato_richiesta_amministrativa in (
      'non_necessaria',
      'da_inviare',
      'inviata',
      'completata',
      'annullata'
    )),
  add column if not exists campi_richiesta_amministrativa text[]
    not null default '{}'::text[],
  add column if not exists messaggio_richiesta_amministrativa text,
  add column if not exists richiesta_amministrativa_preparata_at timestamptz,
  add column if not exists richiesta_amministrativa_inviata_at timestamptz,
  add column if not exists richiesta_amministrativa_completata_at timestamptz;

create index if not exists idx_pratiche_richieste_amministrative_attive
  on public.pratiche (stato_richiesta_amministrativa, ordine_acquisito_at)
  where stato_richiesta_amministrativa in ('da_inviare', 'inviata');

create or replace function public.prepara_richiesta_dati_amministrativi(
  p_pratica_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pratica public.pratiche%rowtype;
  v_campi text[] := '{}'::text[];
  v_elenco text;
  v_messaggio text;
  v_stato text;
begin
  select *
  into v_pratica
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    raise exception 'Pratica non trovata';
  end if;

  if v_pratica.stato_fatturazione = 'fatturato'
     or v_pratica.stato_amministrativo in ('pronto_fatturazione', 'completato') then
    update public.pratiche
    set
      stato_richiesta_amministrativa = 'completata',
      campi_richiesta_amministrativa = '{}'::text[],
      messaggio_richiesta_amministrativa = null,
      richiesta_amministrativa_completata_at = coalesce(
        richiesta_amministrativa_completata_at,
        now()
      )
    where id = p_pratica_id;

    return jsonb_build_object(
      'necessaria', false,
      'stato', 'completata',
      'campi', '[]'::jsonb,
      'messaggio', null,
      'pratica_id', p_pratica_id
    );
  end if;

  if v_pratica.stato_fatturazione <> 'da_fatturare'
     or v_pratica.stato_amministrativo = 'corrispondenza_ambigua' then
    v_stato := case
      when v_pratica.stato_richiesta_amministrativa in ('da_inviare', 'inviata')
        then 'annullata'
      else 'non_necessaria'
    end;

    update public.pratiche
    set
      stato_richiesta_amministrativa = v_stato,
      campi_richiesta_amministrativa = '{}'::text[],
      messaggio_richiesta_amministrativa = null
    where id = p_pratica_id;

    return jsonb_build_object(
      'necessaria', false,
      'stato', v_stato,
      'campi', '[]'::jsonb,
      'messaggio', null,
      'pratica_id', p_pratica_id,
      'motivo', case
        when v_pratica.stato_amministrativo = 'corrispondenza_ambigua'
          then 'corrispondenza_cliente_da_risolvere'
        else 'ordine_non_da_fatturare'
      end
    );
  end if;

  if v_pratica.cliente_id is not null then
    select coalesce(campi_amministrativi_mancanti, '{}'::text[])
    into v_campi
    from public.clienti
    where id = v_pratica.cliente_id;
  end if;

  if coalesce(cardinality(v_campi), 0) = 0 then
    v_campi := array[
      'indirizzo_fatturazione',
      'cap',
      'comune',
      'partita_iva_o_codice_fiscale'
    ];
  end if;

  select string_agg(
    case campo
      when 'denominazione' then 'denominazione o ragione sociale'
      when 'indirizzo_fatturazione' then 'indirizzo di fatturazione'
      when 'cap' then 'CAP'
      when 'comune' then 'comune'
      when 'provincia' then 'provincia'
      when 'paese' then 'paese'
      when 'partita_iva' then 'partita IVA'
      when 'codice_fiscale' then 'codice fiscale'
      when 'partita_iva_o_codice_fiscale' then 'partita IVA o codice fiscale'
      when 'pec' then 'PEC'
      when 'codice_sdi' then 'codice SDI'
      else replace(campo, '_', ' ')
    end,
    ', '
  )
  into v_elenco
  from unnest(v_campi) as campo;

  v_messaggio := 'Grazie, abbiamo registrato l''accettazione del preventivo. '
    || 'Per preparare la fattura ci servono ancora: '
    || v_elenco
    || '. Può inviarceli qui?';

  v_stato := case
    when v_pratica.stato_richiesta_amministrativa = 'inviata'
      and v_pratica.campi_richiesta_amministrativa = v_campi
      then 'inviata'
    else 'da_inviare'
  end;

  update public.pratiche
  set
    stato_richiesta_amministrativa = v_stato,
    campi_richiesta_amministrativa = v_campi,
    messaggio_richiesta_amministrativa = v_messaggio,
    richiesta_amministrativa_preparata_at = case
      when campi_richiesta_amministrativa is distinct from v_campi
        or messaggio_richiesta_amministrativa is distinct from v_messaggio
        or richiesta_amministrativa_preparata_at is null
        then now()
      else richiesta_amministrativa_preparata_at
    end,
    richiesta_amministrativa_inviata_at = case
      when v_stato = 'inviata' then richiesta_amministrativa_inviata_at
      else null
    end,
    richiesta_amministrativa_completata_at = null
  where id = p_pratica_id;

  return jsonb_build_object(
    'necessaria', true,
    'stato', v_stato,
    'campi', to_jsonb(v_campi),
    'messaggio', v_messaggio,
    'pratica_id', p_pratica_id
  );
end;
$$;

create or replace function public.segna_richiesta_dati_amministrativi_inviata(
  p_pratica_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pratica public.pratiche%rowtype;
begin
  select *
  into v_pratica
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    raise exception 'Pratica non trovata';
  end if;

  if v_pratica.stato_richiesta_amministrativa not in ('da_inviare', 'inviata')
     or nullif(btrim(coalesce(v_pratica.messaggio_richiesta_amministrativa, '')), '') is null then
    raise exception 'Non esiste una richiesta amministrativa pronta da segnare come inviata';
  end if;

  update public.pratiche
  set
    stato_richiesta_amministrativa = 'inviata',
    richiesta_amministrativa_inviata_at = coalesce(
      richiesta_amministrativa_inviata_at,
      now()
    )
  where id = p_pratica_id;

  return jsonb_build_object(
    'pratica_id', p_pratica_id,
    'stato', 'inviata',
    'campi', to_jsonb(v_pratica.campi_richiesta_amministrativa),
    'messaggio', v_pratica.messaggio_richiesta_amministrativa
  );
end;
$$;

create or replace function public.trigger_prepara_richiesta_dati_amministrativi()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform public.prepara_richiesta_dati_amministrativi(new.id);
  return new;
end;
$$;

drop trigger if exists trg_prepara_richiesta_dati_amministrativi on public.pratiche;

create trigger trg_prepara_richiesta_dati_amministrativi
after insert or update of stato_fatturazione, stato_amministrativo, cliente_id
on public.pratiche
for each row
execute function public.trigger_prepara_richiesta_dati_amministrativi();

revoke all on function public.prepara_richiesta_dati_amministrativi(uuid) from public;
revoke all on function public.segna_richiesta_dati_amministrativi_inviata(uuid) from public;
revoke all on function public.trigger_prepara_richiesta_dati_amministrativi() from public;

grant execute on function public.prepara_richiesta_dati_amministrativi(uuid) to service_role;
grant execute on function public.segna_richiesta_dati_amministrativi_inviata(uuid) to service_role;
grant execute on function public.trigger_prepara_richiesta_dati_amministrativi() to service_role;

comment on column public.pratiche.stato_richiesta_amministrativa is
  'Stato della richiesta dei soli dati fiscali mancanti, separato dal flusso commerciale.';
comment on column public.pratiche.messaggio_richiesta_amministrativa is
  'Testo pronto da inviare al cliente, generato esclusivamente dai campi amministrativi mancanti.';
comment on function public.prepara_richiesta_dati_amministrativi(uuid) is
  'Prepara o completa la richiesta dati amministrativi dopo l''acquisizione dell''ordine, senza segnare automaticamente l''invio.';

select public.prepara_richiesta_dati_amministrativi(id)
from public.pratiche
where stato_fatturazione in ('da_fatturare', 'fatturato');

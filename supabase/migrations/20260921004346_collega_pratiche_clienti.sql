alter table public.pratiche
  add column if not exists fonte_collegamento_cliente text
    not null default 'nessuna'
    check (fonte_collegamento_cliente in ('nessuna', 'automatico', 'operatore')),
  add column if not exists cliente_collegato_at timestamptz;

create table if not exists public.pratiche_clienti_candidati (
  pratica_id uuid not null
    references public.pratiche(id) on delete cascade,
  cliente_id uuid not null
    references public.clienti(id) on delete restrict,
  punteggio smallint not null check (punteggio > 0),
  segnali text[] not null default '{}'::text[],
  created_at timestamptz not null default now(),
  primary key (pratica_id, cliente_id)
);

create index if not exists idx_pratiche_clienti_candidati_cliente
  on public.pratiche_clienti_candidati (cliente_id, pratica_id);

alter table public.pratiche_clienti_candidati enable row level security;

revoke all on table public.pratiche_clienti_candidati
  from public, anon, authenticated;
grant select, insert, update, delete
  on table public.pratiche_clienti_candidati
  to service_role;

create or replace function public.normalizza_email_cliente(valore text)
returns text
language sql
immutable
strict
set search_path = ''
as $$
  select lower(btrim(valore));
$$;

create or replace function public.normalizza_telefono_cliente(valore text)
returns text
language sql
immutable
strict
set search_path = ''
as $$
  with base as (
    select regexp_replace(valore, '[^0-9]', '', 'g') as cifre
  )
  select case
    when cifre like '0039%' and length(cifre) between 13 and 15
      then substring(cifre from 5)
    when cifre like '39%' and length(cifre) between 11 and 13
      then substring(cifre from 3)
    else cifre
  end
  from base;
$$;

create index if not exists idx_clienti_email_match
  on public.clienti (public.normalizza_email_cliente(email))
  where email is not null and btrim(email) <> '';

create index if not exists idx_clienti_telefono_match
  on public.clienti (public.normalizza_telefono_cliente(telefono))
  where telefono is not null
    and length(public.normalizza_telefono_cliente(telefono)) >= 8;

create or replace function public.valuta_collegamento_cliente(
  p_pratica_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pratica public.pratiche%rowtype;
  v_candidati integer := 0;
  v_cliente_id uuid;
  v_cliente_completo boolean := false;
  v_cliente_da_verificare boolean := false;
  v_campi_mancanti text[] := '{}'::text[];
  v_segnali text[] := '{}'::text[];
begin
  select *
  into v_pratica
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    raise exception 'Pratica non trovata';
  end if;

  if v_pratica.stato_fatturazione <> 'da_fatturare' then
    return jsonb_build_object(
      'esito', 'non_applicabile',
      'pratica_id', p_pratica_id
    );
  end if;

  if v_pratica.cliente_id is not null
     and v_pratica.fonte_collegamento_cliente = 'operatore' then
    select
      dati_fiscali_completi,
      campi_amministrativi_mancanti
    into
      v_cliente_completo,
      v_campi_mancanti
    from public.clienti
    where id = v_pratica.cliente_id;

    update public.pratiche
    set
      stato_amministrativo = case
        when v_cliente_completo then 'pronto_fatturazione'::public.stato_amministrativo
        else 'cliente_riconosciuto'::public.stato_amministrativo
      end,
      stato_amministrativo_at = now(),
      nota_amministrativa = case
        when v_cliente_completo
          then 'Cliente confermato dall''operatore: dati completi per la fatturazione.'
        else 'Cliente confermato dall''operatore. Dati mancanti: '
          || array_to_string(v_campi_mancanti, ', ')
      end
    where id = p_pratica_id;

    return jsonb_build_object(
      'esito', case when v_cliente_completo then 'pronto_fatturazione' else 'cliente_riconosciuto' end,
      'pratica_id', p_pratica_id,
      'cliente_id', v_pratica.cliente_id,
      'fonte', 'operatore'
    );
  end if;

  delete from public.pratiche_clienti_candidati
  where pratica_id = p_pratica_id;

  insert into public.pratiche_clienti_candidati (
    pratica_id,
    cliente_id,
    punteggio,
    segnali
  )
  select
    p_pratica_id,
    c.id,
    (
      case when email_match then 100 else 0 end
      + case when telefono_match then 80 else 0 end
    )::smallint,
    array_remove(array[
      case when email_match then 'email' end,
      case when telefono_match then 'telefono' end
    ], null)
  from public.clienti c
  cross join lateral (
    select
      public.normalizza_email_cliente(coalesce(v_pratica.email_cliente, '')) <> ''
        and public.normalizza_email_cliente(coalesce(c.email, ''))
          = public.normalizza_email_cliente(coalesce(v_pratica.email_cliente, ''))
        as email_match,
      length(public.normalizza_telefono_cliente(coalesce(v_pratica.telefono, ''))) >= 8
        and public.normalizza_telefono_cliente(coalesce(c.telefono, ''))
          = public.normalizza_telefono_cliente(coalesce(v_pratica.telefono, ''))
        as telefono_match
  ) confronto
  where email_match or telefono_match
  on conflict (pratica_id, cliente_id) do update
  set
    punteggio = excluded.punteggio,
    segnali = excluded.segnali,
    created_at = now();

  select count(*)
  into v_candidati
  from public.pratiche_clienti_candidati
  where pratica_id = p_pratica_id;

  if v_candidati = 1 then
    select
      pc.cliente_id,
      pc.segnali,
      c.dati_fiscali_completi,
      c.da_verificare or c.possibile_duplicato,
      c.campi_amministrativi_mancanti
    into
      v_cliente_id,
      v_segnali,
      v_cliente_completo,
      v_cliente_da_verificare,
      v_campi_mancanti
    from public.pratiche_clienti_candidati pc
    join public.clienti c on c.id = pc.cliente_id
    where pc.pratica_id = p_pratica_id;

    if v_cliente_da_verificare then
      update public.pratiche
      set
        cliente_id = null,
        fonte_collegamento_cliente = 'nessuna',
        cliente_collegato_at = null,
        stato_amministrativo = 'corrispondenza_ambigua',
        stato_amministrativo_at = now(),
        nota_amministrativa = 'Trovato un cliente compatibile, ma l''anagrafica è segnalata per verifica o possibile duplicato.'
      where id = p_pratica_id;

      return jsonb_build_object(
        'esito', 'corrispondenza_ambigua',
        'pratica_id', p_pratica_id,
        'candidati', 1
      );
    end if;

    update public.pratiche
    set
      cliente_id = v_cliente_id,
      fonte_collegamento_cliente = 'automatico',
      cliente_collegato_at = now(),
      stato_amministrativo = case
        when v_cliente_completo then 'pronto_fatturazione'::public.stato_amministrativo
        else 'cliente_riconosciuto'::public.stato_amministrativo
      end,
      stato_amministrativo_at = now(),
      nota_amministrativa = case
        when v_cliente_completo
          then 'Cliente riconosciuto automaticamente tramite '
            || array_to_string(v_segnali, ' e ')
            || ': dati completi per la fatturazione.'
        else 'Cliente riconosciuto automaticamente tramite '
          || array_to_string(v_segnali, ' e ')
          || '. Dati mancanti: '
          || array_to_string(v_campi_mancanti, ', ')
      end
    where id = p_pratica_id;

    return jsonb_build_object(
      'esito', case when v_cliente_completo then 'pronto_fatturazione' else 'cliente_riconosciuto' end,
      'pratica_id', p_pratica_id,
      'cliente_id', v_cliente_id,
      'segnali', to_jsonb(v_segnali),
      'fonte', 'automatico'
    );
  end if;

  if v_candidati > 1 then
    update public.pratiche
    set
      cliente_id = null,
      fonte_collegamento_cliente = 'nessuna',
      cliente_collegato_at = null,
      stato_amministrativo = 'corrispondenza_ambigua',
      stato_amministrativo_at = now(),
      nota_amministrativa = format(
        'Trovati %s clienti compatibili tramite telefono o e-mail: selezionare l''anagrafica corretta.',
        v_candidati
      )
    where id = p_pratica_id;

    return jsonb_build_object(
      'esito', 'corrispondenza_ambigua',
      'pratica_id', p_pratica_id,
      'candidati', v_candidati
    );
  end if;

  update public.pratiche
  set
    cliente_id = null,
    fonte_collegamento_cliente = 'nessuna',
    cliente_collegato_at = null,
    stato_amministrativo = 'dati_mancanti',
    stato_amministrativo_at = now(),
    nota_amministrativa = 'Nessun cliente trovato tramite telefono o e-mail. Per la nuova anagrafica richiedere: indirizzo di fatturazione, CAP, comune e partita IVA o codice fiscale.'
  where id = p_pratica_id;

  return jsonb_build_object(
    'esito', 'dati_mancanti',
    'pratica_id', p_pratica_id,
    'candidati', 0
  );
end;
$$;

create or replace function public.collega_cliente_pratica(
  p_pratica_id uuid,
  p_cliente_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_stato_fatturazione public.stato_fatturazione;
  v_cliente public.clienti%rowtype;
begin
  select stato_fatturazione
  into v_stato_fatturazione
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    raise exception 'Pratica non trovata';
  end if;

  if v_stato_fatturazione <> 'da_fatturare' then
    raise exception 'Il cliente fiscale può essere collegato solo a un ordine da fatturare';
  end if;

  select *
  into v_cliente
  from public.clienti
  where id = p_cliente_id;

  if not found then
    raise exception 'Cliente non trovato';
  end if;

  update public.pratiche
  set
    cliente_id = p_cliente_id,
    fonte_collegamento_cliente = 'operatore',
    cliente_collegato_at = now(),
    stato_amministrativo = case
      when v_cliente.dati_fiscali_completi
        then 'pronto_fatturazione'::public.stato_amministrativo
      else 'cliente_riconosciuto'::public.stato_amministrativo
    end,
    stato_amministrativo_at = now(),
    nota_amministrativa = case
      when v_cliente.dati_fiscali_completi
        then 'Cliente collegato e confermato dall''operatore: dati completi per la fatturazione.'
      else 'Cliente collegato e confermato dall''operatore. Dati mancanti: '
        || array_to_string(v_cliente.campi_amministrativi_mancanti, ', ')
    end
  where id = p_pratica_id;

  return jsonb_build_object(
    'esito', case
      when v_cliente.dati_fiscali_completi then 'pronto_fatturazione'
      else 'cliente_riconosciuto'
    end,
    'pratica_id', p_pratica_id,
    'cliente_id', p_cliente_id,
    'fonte', 'operatore'
  );
end;
$$;

create or replace function public.crea_e_collega_cliente_pratica(
  p_pratica_id uuid,
  p_denominazione text,
  p_indirizzo_fatturazione text,
  p_comune text,
  p_cap text,
  p_provincia text default null,
  p_paese text default 'IT',
  p_partita_iva text default null,
  p_codice_fiscale text default null,
  p_email text default null,
  p_telefono text default null,
  p_pec text default null,
  p_codice_sdi text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pratica public.pratiche%rowtype;
  v_cliente_id uuid := gen_random_uuid();
  v_importazione_id uuid := gen_random_uuid();
  v_partita_iva_norm text;
  v_codice_fiscale_norm text;
  v_email text;
  v_telefono text;
  v_email_norm text;
  v_telefono_norm text;
  v_sha text;
begin
  select *
  into v_pratica
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    raise exception 'Pratica non trovata';
  end if;

  if v_pratica.stato_fatturazione <> 'da_fatturare' then
    raise exception 'La nuova anagrafica può essere creata solo per un ordine da fatturare';
  end if;

  if btrim(coalesce(p_denominazione, '')) = ''
     or btrim(coalesce(p_indirizzo_fatturazione, '')) = ''
     or btrim(coalesce(p_comune, '')) = ''
     or btrim(coalesce(p_cap, '')) = '' then
    raise exception 'Denominazione, indirizzo, CAP e comune sono obbligatori';
  end if;

  v_partita_iva_norm := upper(regexp_replace(coalesce(p_partita_iva, ''), '[^A-Za-z0-9]', '', 'g'));
  v_codice_fiscale_norm := upper(regexp_replace(coalesce(p_codice_fiscale, ''), '[^A-Za-z0-9]', '', 'g'));

  if v_partita_iva_norm = '' and v_codice_fiscale_norm = '' then
    raise exception 'Inserire almeno la partita IVA o il codice fiscale';
  end if;

  if exists (
    select 1
    from public.clienti
    where (v_partita_iva_norm <> '' and partita_iva_normalizzata = v_partita_iva_norm)
       or (v_codice_fiscale_norm <> '' and codice_fiscale_normalizzato = v_codice_fiscale_norm)
  ) then
    raise exception 'Esiste già un cliente con la stessa partita IVA o lo stesso codice fiscale: cercarlo e collegarlo senza creare duplicati';
  end if;

  v_email := nullif(btrim(coalesce(p_email, v_pratica.email_cliente, '')), '');
  v_telefono := nullif(btrim(coalesce(p_telefono, v_pratica.telefono, '')), '');
  v_email_norm := coalesce(public.normalizza_email_cliente(v_email), '');
  v_telefono_norm := coalesce(public.normalizza_telefono_cliente(v_telefono), '');
  v_sha := replace(v_importazione_id::text, '-', '')
    || replace(v_cliente_id::text, '-', '');

  insert into public.clienti_importazioni (
    id,
    fonte,
    nome_file,
    file_sha256,
    righe_origine,
    righe_inserite,
    stato,
    riepilogo,
    completed_at
  ) values (
    v_importazione_id,
    'manuale',
    'Dashboard Operatore',
    v_sha,
    1,
    1,
    'completata',
    jsonb_build_object('pratica_id', p_pratica_id, 'tipo', 'inserimento_manuale'),
    now()
  );

  insert into public.clienti (
    id,
    fonte,
    source_record_key,
    denominazione,
    indirizzo_fatturazione,
    comune,
    cap,
    provincia,
    paese,
    email,
    telefono,
    partita_iva,
    codice_fiscale,
    pec,
    codice_sdi,
    partita_iva_normalizzata,
    codice_fiscale_normalizzato,
    email_normalizzata,
    telefono_normalizzato,
    dati_fiscali_completi,
    campi_amministrativi_mancanti,
    da_verificare,
    motivi_verifica,
    possibile_duplicato,
    chiavi_duplicate,
    source_fingerprint,
    source_row_number,
    importazione_id
  ) values (
    v_cliente_id,
    'manuale',
    'dashboard:' || v_cliente_id::text,
    btrim(p_denominazione),
    btrim(p_indirizzo_fatturazione),
    btrim(p_comune),
    btrim(p_cap),
    nullif(btrim(coalesce(p_provincia, '')), ''),
    coalesce(nullif(upper(btrim(coalesce(p_paese, ''))), ''), 'IT'),
    v_email,
    v_telefono,
    nullif(btrim(coalesce(p_partita_iva, '')), ''),
    nullif(btrim(coalesce(p_codice_fiscale, '')), ''),
    nullif(btrim(coalesce(p_pec, '')), ''),
    nullif(btrim(coalesce(p_codice_sdi, '')), ''),
    v_partita_iva_norm,
    v_codice_fiscale_norm,
    v_email_norm,
    v_telefono_norm,
    true,
    '{}'::text[],
    false,
    '{}'::text[],
    false,
    '{}'::text[],
    v_sha,
    2,
    v_importazione_id
  );

  update public.pratiche
  set
    cliente_id = v_cliente_id,
    fonte_collegamento_cliente = 'operatore',
    cliente_collegato_at = now(),
    stato_amministrativo = 'pronto_fatturazione',
    stato_amministrativo_at = now(),
    nota_amministrativa = 'Nuova anagrafica fiscale creata e collegata dall''operatore: dati completi per la fatturazione.'
  where id = p_pratica_id;

  return jsonb_build_object(
    'esito', 'pronto_fatturazione',
    'pratica_id', p_pratica_id,
    'cliente_id', v_cliente_id,
    'creato', true,
    'fonte', 'operatore'
  );
end;
$$;

create or replace function public.cerca_clienti_amministrativi(
  p_query text
)
returns table (
  id uuid,
  denominazione text,
  email text,
  telefono text,
  partita_iva text,
  codice_fiscale text,
  comune text,
  provincia text,
  dati_fiscali_completi boolean,
  campi_amministrativi_mancanti text[],
  da_verificare boolean,
  possibile_duplicato boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    c.id,
    c.denominazione,
    c.email,
    c.telefono,
    c.partita_iva,
    c.codice_fiscale,
    c.comune,
    c.provincia,
    c.dati_fiscali_completi,
    c.campi_amministrativi_mancanti,
    c.da_verificare,
    c.possibile_duplicato
  from public.clienti c
  where length(btrim(coalesce(p_query, ''))) >= 3
    and (
      c.denominazione ilike '%' || btrim(p_query) || '%'
      or (
        position('@' in p_query) > 1
        and public.normalizza_email_cliente(coalesce(c.email, ''))
          = public.normalizza_email_cliente(coalesce(p_query, ''))
      )
      or (
        length(public.normalizza_telefono_cliente(coalesce(p_query, ''))) >= 8
        and public.normalizza_telefono_cliente(coalesce(c.telefono, ''))
          = public.normalizza_telefono_cliente(coalesce(p_query, ''))
      )
      or c.partita_iva_normalizzata
        = upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g'))
      or c.codice_fiscale_normalizzato
        = upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g'))
    )
  order by
    case
      when c.partita_iva_normalizzata
        = upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g'))
        then 0
      when c.codice_fiscale_normalizzato
        = upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g'))
        then 0
      when position('@' in p_query) > 1
        and public.normalizza_email_cliente(coalesce(c.email, ''))
          = public.normalizza_email_cliente(coalesce(p_query, ''))
        then 1
      when length(public.normalizza_telefono_cliente(coalesce(p_query, ''))) >= 8
        and public.normalizza_telefono_cliente(coalesce(c.telefono, ''))
          = public.normalizza_telefono_cliente(coalesce(p_query, ''))
        then 1
      else 2
    end,
    c.denominazione,
    c.id
  limit 20;
$$;

create or replace function public.trigger_valuta_collegamento_cliente()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.stato_fatturazione = 'da_fatturare' then
    perform public.valuta_collegamento_cliente(new.id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_valuta_collegamento_cliente on public.pratiche;

create trigger trg_valuta_collegamento_cliente
after insert or update of stato_fatturazione, telefono, email_cliente
on public.pratiche
for each row
when (new.stato_fatturazione = 'da_fatturare')
execute function public.trigger_valuta_collegamento_cliente();

revoke all on function public.normalizza_email_cliente(text) from public;
revoke all on function public.normalizza_telefono_cliente(text) from public;
revoke all on function public.valuta_collegamento_cliente(uuid) from public;
revoke all on function public.collega_cliente_pratica(uuid, uuid) from public;
revoke all on function public.crea_e_collega_cliente_pratica(
  uuid, text, text, text, text, text, text, text, text, text, text, text, text
) from public;
revoke all on function public.cerca_clienti_amministrativi(text) from public;
revoke all on function public.trigger_valuta_collegamento_cliente() from public;

grant execute on function public.normalizza_email_cliente(text) to service_role;
grant execute on function public.normalizza_telefono_cliente(text) to service_role;
grant execute on function public.valuta_collegamento_cliente(uuid) to service_role;
grant execute on function public.collega_cliente_pratica(uuid, uuid) to service_role;
grant execute on function public.crea_e_collega_cliente_pratica(
  uuid, text, text, text, text, text, text, text, text, text, text, text, text
) to service_role;
grant execute on function public.cerca_clienti_amministrativi(text) to service_role;
grant execute on function public.trigger_valuta_collegamento_cliente() to service_role;

comment on table public.pratiche_clienti_candidati is
  'Candidati di abbinamento pratica-cliente calcolati con chiavi forti; nessun record cliente viene mai fuso automaticamente.';
comment on column public.pratiche.fonte_collegamento_cliente is
  'Origine del collegamento fiscale: nessuna, automatico oppure operatore.';
comment on function public.valuta_collegamento_cliente(uuid) is
  'Ricalcola i candidati, collega solo una corrispondenza univoca non segnalata e mantiene ambiguità e duplicati alla revisione operatore.';

select public.valuta_collegamento_cliente(id)
from public.pratiche
where stato_fatturazione = 'da_fatturare';

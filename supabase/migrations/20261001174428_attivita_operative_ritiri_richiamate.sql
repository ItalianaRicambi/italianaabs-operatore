-- Registro operativo stabile per richieste di ritiro e richiamata.
-- Le attivita sono indipendenti dagli stati commerciali/fiscali: una richiesta
-- telefonica non puo trasformare una pratica in ordine o da fatturare.

alter table public.pratiche
  add column if not exists pratica_origine_id uuid null
    references public.pratiche(id) on delete set null,
  add column if not exists fonte_collegamento_origine text not null default 'nessuna',
  add column if not exists pratica_origine_collegata_at timestamptz null;

alter table public.pratiche
  drop constraint if exists pratiche_fonte_collegamento_origine_check;
alter table public.pratiche
  add constraint pratiche_fonte_collegamento_origine_check
  check (fonte_collegamento_origine in ('nessuna', 'automatico', 'operatore'));

create index if not exists idx_pratiche_pratica_origine
  on public.pratiche(pratica_origine_id)
  where pratica_origine_id is not null;

create table if not exists public.attivita_operatore (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in (
    'ritiro_programma_scambio',
    'richiamata_post_preventivo',
    'richiamata_post_vendita',
    'richiamata_da_classificare'
  )),
  stato text not null default 'da_gestire' check (stato in (
    'da_gestire', 'da_collegare', 'programmata', 'completata', 'annullata'
  )),
  priorita text not null default 'normale' check (priorita in (
    'normale', 'alta', 'urgente'
  )),
  pratica_id uuid not null references public.pratiche(id) on delete cascade,
  pratica_origine_id uuid null references public.pratiche(id) on delete set null,
  preventivo_id uuid null references public.preventivi(id) on delete set null,
  evento_keplero_id bigint null references public.keplero_live_events(id) on delete set null,
  external_key text null,
  evidenza text not null,
  fonte text not null default 'keplero_live' check (fonte in (
    'keplero_live', 'operatore', 'routine_controllo_k'
  )),
  nota text null,
  metadati jsonb not null default '{}'::jsonb,
  richiesta_at timestamptz not null default now(),
  programmata_at timestamptz null,
  completata_at timestamptz null,
  annullata_at timestamptz null,
  operatore text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_attivita_evento_tipo
  on public.attivita_operatore(evento_keplero_id, tipo)
  where evento_keplero_id is not null;

create unique index if not exists uq_attivita_attiva_pratica_tipo
  on public.attivita_operatore(pratica_id, tipo)
  where stato in ('da_gestire', 'da_collegare', 'programmata');

create index if not exists idx_attivita_operatore_coda
  on public.attivita_operatore(stato, tipo, priorita, richiesta_at);
create index if not exists idx_attivita_operatore_origine
  on public.attivita_operatore(pratica_origine_id)
  where pratica_origine_id is not null;
create index if not exists idx_attivita_operatore_preventivo
  on public.attivita_operatore(preventivo_id)
  where preventivo_id is not null;

alter table public.attivita_operatore enable row level security;
revoke all on public.attivita_operatore from public, anon, authenticated;
grant select, insert, update, delete on public.attivita_operatore to service_role;

create or replace view public.v_attivita_operatore_aperte
with (security_invoker = true)
as
select
  a.*,
  'ABS-' || lpad(p.numero_pratica::text, 6, '0') as codice_pratica,
  p.nome_cliente,
  p.telefono,
  p.targa,
  p.marca_veicolo,
  p.modello_veicolo,
  p.tipo_flusso,
  p.stato_commerciale,
  p.stato_fatturazione,
  p.stato_assistenza,
  case
    when po.id is null then null
    else 'ABS-' || lpad(po.numero_pratica::text, 6, '0')
  end as codice_pratica_origine,
  po.stato_logistica as stato_logistica_origine
from public.attivita_operatore a
join public.pratiche p on p.id = a.pratica_id
left join public.pratiche po on po.id = a.pratica_origine_id
where a.stato in ('da_gestire', 'da_collegare', 'programmata');

revoke all on public.v_attivita_operatore_aperte from public, anon, authenticated;
grant select on public.v_attivita_operatore_aperte to service_role;

create or replace function private.rileva_attivita_operativa_evento(
  p_evento_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_evento public.keplero_live_events%rowtype;
  v_pratica public.pratiche%rowtype;
  v_messaggio text;
  v_testo text;
  v_callback boolean := false;
  v_ritiro boolean := false;
  v_ritiro_forte boolean := false;
  v_tipo_attivita text;
  v_stato_attivita text := 'da_gestire';
  v_preventivo_id uuid;
  v_origine_id uuid;
  v_numero_origini integer := 0;
  v_attivita_id uuid;
  v_inserita boolean := false;
  v_risultati jsonb := '[]'::jsonb;
  v_prima jsonb;
  v_dopo jsonb;
begin
  select * into v_evento
  from public.keplero_live_events
  where id = p_evento_id;

  if not found or v_evento.pratica_id is null then
    return jsonb_build_object('ok', true, 'esito', 'evento_senza_pratica');
  end if;

  select * into v_pratica
  from public.pratiche
  where id = v_evento.pratica_id;

  if not found then
    return jsonb_build_object('ok', true, 'esito', 'pratica_non_trovata');
  end if;

  v_messaggio := trim(coalesce(
    v_evento.payload ->> 'ultimo_messaggio_cliente',
    v_evento.payload ->> 'messaggio_cliente',
    v_evento.payload ->> 'messaggio',
    ''
  ));
  v_testo := lower(v_messaggio);

  if v_testo = '' then
    return jsonb_build_object('ok', true, 'esito', 'messaggio_assente');
  end if;

  -- Richiesta esplicita del cliente. I boilerplate Voice e le intenzioni del
  -- cliente di richiamare lui stesso non sono richieste di ricontatto.
  v_callback := v_testo ~ (
    '(richiamatemi|mi (potete|puo|può) richiamare|essere (ricontattat|contattat)|' ||
    '(potrei|posso|e possibile|è possibile) parlare con|possiamo sentirci|' ||
    'riusciamo a sentirci|sentirci telefonicamente|parlare telefonicamente|' ||
    'parlare con (qualcuno|un operatore)|a voce|verr[oò] contattat|' ||
    '(aspetto|attendo) (una )?(chiamata|telefonata))'
  );

  if v_testo ~ '(domani|piu tardi|più tardi)?[[:space:]]*(vi|la|le)[[:space:]]+richiam'
     and v_testo !~ '(richiamatemi|mi (potete|puo|può) richiamare|essere (ricontattat|contattat))'
  then
    v_callback := false;
  end if;

  -- Rientro fisico: richiede una formulazione operativa, non la sola parola
  -- "ritiro" usata mentre si conferma un ordine.
  v_ritiro_forte := v_testo ~ (
    '(pacc(o|hetto).*(pront|ritir)|pront[ioa].*(ritir|restitu|rientr)|' ||
    '(restitu|rientr).*(pompa|abs|centralina|prodotto|pezzo)|' ||
    'ritirare.*(pompa|abs|centralina|prodotto|pezzo).*(usat|vecchi)|' ||
    '(non (e|è) ancora passat|quando passa|quando passera|quando passerà).*corriere)'
  );
  v_ritiro := v_ritiro_forte
    or (
      v_pratica.tipo_flusso = 'assistenza'::public.tipo_flusso
      and v_testo ~ '(programmar|prenotar|organizzar).*(ritiro|corriere)'
    );

  if v_callback then
    select a.id into v_attivita_id
    from public.attivita_operatore a
    where a.evento_keplero_id = v_evento.id
      and a.tipo in (
        'richiamata_post_preventivo',
        'richiamata_post_vendita',
        'richiamata_da_classificare'
      )
    limit 1;

    if v_attivita_id is not null then
      v_risultati := v_risultati || jsonb_build_array(jsonb_build_object(
        'tipo', 'richiamata_gia_elaborata', 'attivita_id', v_attivita_id
      ));
    else
    select pr.id into v_preventivo_id
    from public.preventivi pr
    where pr.pratica_id = v_pratica.id
      and pr.stato in ('inviato', 'accettato')
      and pr.inviato_at is not null
    order by pr.inviato_at desc
    limit 1;

    if v_pratica.stato_fatturazione = 'fatturato'::public.stato_fatturazione
       or v_pratica.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale
       or v_pratica.tipo_flusso = 'assistenza'::public.tipo_flusso
    then
      v_tipo_attivita := 'richiamata_post_vendita';
    elsif v_preventivo_id is not null
          and v_pratica.stato_commerciale in (
            'preventivo_inviato'::public.stato_commerciale,
            'attesa_cliente'::public.stato_commerciale
          )
    then
      v_tipo_attivita := 'richiamata_post_preventivo';
    else
      v_tipo_attivita := 'richiamata_da_classificare';
      v_stato_attivita := 'da_collegare';
    end if;

    insert into public.attivita_operatore (
      tipo, stato, priorita, pratica_id, preventivo_id, evento_keplero_id,
      external_key, evidenza, fonte, metadati, richiesta_at
    ) values (
      v_tipo_attivita, v_stato_attivita, 'alta', v_pratica.id,
      v_preventivo_id, v_evento.id, v_evento.external_key, v_messaggio,
      'keplero_live', jsonb_build_object('regola', 'richiamata_esplicita_v1'),
      v_evento.created_at
    )
    on conflict (pratica_id, tipo)
      where stato in ('da_gestire', 'da_collegare', 'programmata')
    do update set
      evidenza = excluded.evidenza,
      evento_keplero_id = excluded.evento_keplero_id,
      external_key = excluded.external_key,
      richiesta_at = greatest(public.attivita_operatore.richiesta_at, excluded.richiesta_at),
      updated_at = now()
    returning id, (created_at = updated_at) into v_attivita_id, v_inserita;

    if v_inserita then
      insert into public.azioni_operatore (
        pratica_id, azione, nota, stato_prima, stato_dopo, operatore
      ) values (
        v_pratica.id,
        'routine_controllo_k_attivita_richiamata',
        'Richiesta di contatto telefonico rilevata dal testo letterale del cliente.',
        '{}'::jsonb,
        jsonb_build_object(
          'attivita_id', v_attivita_id,
          'tipo', v_tipo_attivita,
          'stato', v_stato_attivita,
          'evento_keplero_id', v_evento.id,
          'evidenza', v_messaggio
        ),
        'routine_controllo_k'
      );
    end if;

    v_risultati := v_risultati || jsonb_build_array(jsonb_build_object(
      'tipo', v_tipo_attivita, 'attivita_id', v_attivita_id
    ));
    end if;
  end if;

  if v_ritiro then
    select a.id into v_attivita_id
    from public.attivita_operatore a
    where a.evento_keplero_id = v_evento.id
      and a.tipo = 'ritiro_programma_scambio'
    limit 1;

    if v_attivita_id is not null then
      v_risultati := v_risultati || jsonb_build_array(jsonb_build_object(
        'tipo', 'ritiro_gia_elaborato', 'attivita_id', v_attivita_id
      ));
    else
    if v_pratica.stato_fatturazione = 'fatturato'::public.stato_fatturazione
       or v_pratica.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale
    then
      v_origine_id := v_pratica.id;
      v_numero_origini := 1;
    elsif nullif(upper(regexp_replace(coalesce(v_pratica.targa, ''), '[^A-Z0-9]', '', 'g')), '') is not null then
      select count(*), min(candidato.id::text)::uuid
      into v_numero_origini, v_origine_id
      from (
        select p.id
        from public.pratiche p
        where p.id <> v_pratica.id
          and upper(regexp_replace(coalesce(p.targa, ''), '[^A-Z0-9]', '', 'g')) =
              upper(regexp_replace(coalesce(v_pratica.targa, ''), '[^A-Z0-9]', '', 'g'))
          and (
            p.stato_fatturazione = 'fatturato'::public.stato_fatturazione
            or p.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale
          )
          and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
          and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
      ) candidato;
    end if;

    if v_numero_origini <> 1 or v_origine_id is null then
      v_origine_id := null;
      v_stato_attivita := 'da_collegare';
    else
      v_stato_attivita := 'da_gestire';
    end if;

    insert into public.attivita_operatore (
      tipo, stato, priorita, pratica_id, pratica_origine_id,
      evento_keplero_id, external_key, evidenza, fonte, metadati, richiesta_at
    ) values (
      'ritiro_programma_scambio', v_stato_attivita, 'alta', v_pratica.id,
      v_origine_id, v_evento.id, v_evento.external_key, v_messaggio,
      'keplero_live', jsonb_build_object(
        'regola', 'rientro_prodotto_v1',
        'prova_forte', v_ritiro_forte,
        'numero_origini_candidate', v_numero_origini
      ), v_evento.created_at
    )
    on conflict (pratica_id, tipo)
      where stato in ('da_gestire', 'da_collegare', 'programmata')
    do update set
      pratica_origine_id = coalesce(excluded.pratica_origine_id, public.attivita_operatore.pratica_origine_id),
      stato = case
        when public.attivita_operatore.stato = 'da_collegare'
             and excluded.pratica_origine_id is not null then 'da_gestire'
        else public.attivita_operatore.stato
      end,
      evidenza = excluded.evidenza,
      evento_keplero_id = excluded.evento_keplero_id,
      external_key = excluded.external_key,
      richiesta_at = greatest(public.attivita_operatore.richiesta_at, excluded.richiesta_at),
      metadati = public.attivita_operatore.metadati || excluded.metadati,
      updated_at = now()
    returning id, (created_at = updated_at) into v_attivita_id, v_inserita;

    if v_origine_id is not null then
      select to_jsonb(p) into v_prima
      from public.pratiche p where p.id = v_origine_id;

      update public.pratiche
      set
        stato_logistica = case
          when stato_logistica = 'non_applicabile'::public.stato_logistica
            then 'ritiro_richiesto'::public.stato_logistica
          else stato_logistica
        end,
        ritiro_richiesto_at = coalesce(ritiro_richiesto_at, v_evento.created_at)
      where id = v_origine_id;

      if v_pratica.tipo_flusso = 'assistenza'::public.tipo_flusso
         and (v_pratica.pratica_origine_id is null or v_pratica.pratica_origine_id = v_origine_id)
      then
        update public.pratiche
        set
          pratica_origine_id = v_origine_id,
          fonte_collegamento_origine = 'automatico',
          pratica_origine_collegata_at = coalesce(pratica_origine_collegata_at, now())
        where id = v_pratica.id;
      end if;

      select to_jsonb(p) into v_dopo
      from public.pratiche p where p.id = v_origine_id;
    else
      v_prima := '{}'::jsonb;
      v_dopo := '{}'::jsonb;
    end if;

    if v_inserita then
      insert into public.azioni_operatore (
        pratica_id, azione, nota, stato_prima, stato_dopo, operatore
      ) values (
        v_pratica.id,
        'routine_controllo_k_attivita_ritiro',
        case when v_origine_id is null
          then 'Ritiro rilevato, ma pratica/ordine di origine non univoco: richiesta verifica manuale.'
          else 'Ritiro/rientro prodotto rilevato e collegato alla pratica di origine.'
        end,
        coalesce(v_prima, '{}'::jsonb),
        coalesce(v_dopo, '{}'::jsonb) || jsonb_build_object(
          'attivita_id', v_attivita_id,
          'pratica_origine_id', v_origine_id,
          'evento_keplero_id', v_evento.id,
          'evidenza', v_messaggio
        ),
        'routine_controllo_k'
      );
    end if;

    v_risultati := v_risultati || jsonb_build_array(jsonb_build_object(
      'tipo', 'ritiro_programma_scambio',
      'attivita_id', v_attivita_id,
      'pratica_origine_id', v_origine_id,
      'stato', v_stato_attivita
    ));
    end if;
  end if;

  return jsonb_build_object('ok', true, 'attivita', v_risultati);
end;
$$;

revoke all on function private.rileva_attivita_operativa_evento(bigint)
  from public, anon, authenticated;
grant execute on function private.rileva_attivita_operativa_evento(bigint)
  to service_role;

create or replace function private.trg_rileva_attivita_operativa_evento()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rileva_attivita_operativa_evento(new.id);
  return new;
exception when others then
  -- La coda operativa non deve mai interrompere l'acquisizione dell'evento.
  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore,
    tentativi, elaborato_at, updated_at
  ) values (
    new.id, new.pratica_id, 'attivita-operative-v1', 'errore', '{}'::jsonb,
    'attivita_operativa: ' || sqlerrm, 1, now(), now()
  )
  on conflict (event_id) do update set
    stato = 'errore',
    errore = coalesce(private.keplero_event_processing.errore || ' | ', '') || excluded.errore,
    tentativi = private.keplero_event_processing.tentativi + 1,
    updated_at = now();
  return new;
end;
$$;

revoke all on function private.trg_rileva_attivita_operativa_evento()
  from public, anon, authenticated;

drop trigger if exists trg_zz_rileva_attivita_operativa
  on public.keplero_live_events;
create trigger trg_zz_rileva_attivita_operativa
after insert on public.keplero_live_events
for each row execute function private.trg_rileva_attivita_operativa_evento();

create or replace function public.applica_azione_attivita_operatore(
  p_attivita_id uuid,
  p_azione text,
  p_nota text default null,
  p_operatore text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prima public.attivita_operatore%rowtype;
  v_dopo public.attivita_operatore%rowtype;
  v_pratica_logistica_id uuid;
begin
  select * into v_prima
  from public.attivita_operatore
  where id = p_attivita_id
  for update;

  if not found then
    raise exception 'Attivita non trovata';
  end if;

  if v_prima.stato in ('completata', 'annullata') then
    raise exception 'Attivita gia chiusa';
  end if;

  if p_azione = 'programma' then
    if v_prima.tipo <> 'ritiro_programma_scambio' then
      raise exception 'Solo un ritiro puo essere programmato';
    end if;
    if v_prima.pratica_origine_id is null then
      raise exception 'Collegare prima la pratica/ordine di origine';
    end if;
    update public.attivita_operatore
    set stato = 'programmata', programmata_at = now(), nota = nullif(trim(coalesce(p_nota, '')), ''),
        operatore = nullif(trim(coalesce(p_operatore, '')), ''), updated_at = now()
    where id = p_attivita_id;
  elsif p_azione = 'completa' then
    update public.attivita_operatore
    set stato = 'completata', completata_at = now(), nota = nullif(trim(coalesce(p_nota, '')), ''),
        operatore = nullif(trim(coalesce(p_operatore, '')), ''), updated_at = now()
    where id = p_attivita_id;
  elsif p_azione = 'annulla' then
    update public.attivita_operatore
    set stato = 'annullata', annullata_at = now(), nota = nullif(trim(coalesce(p_nota, '')), ''),
        operatore = nullif(trim(coalesce(p_operatore, '')), ''), updated_at = now()
    where id = p_attivita_id;
  else
    raise exception 'Azione attivita non riconosciuta: %', p_azione;
  end if;

  select * into v_dopo
  from public.attivita_operatore where id = p_attivita_id;

  v_pratica_logistica_id := coalesce(v_prima.pratica_origine_id, v_prima.pratica_id);
  if v_prima.tipo = 'ritiro_programma_scambio' and p_azione = 'programma' then
    update public.pratiche
    set stato_logistica = 'ritiro_programmato'::public.stato_logistica,
        ritiro_richiesto_at = coalesce(ritiro_richiesto_at, v_prima.richiesta_at),
        ritiro_programmato_at = now()
    where id = v_pratica_logistica_id;
  elsif v_prima.tipo = 'ritiro_programma_scambio' and p_azione = 'completa' then
    update public.pratiche
    set stato_logistica = 'ritirato'::public.stato_logistica,
        ritiro_richiesto_at = coalesce(ritiro_richiesto_at, v_prima.richiesta_at),
        ritirato_at = now()
    where id = v_pratica_logistica_id;
  end if;

  insert into public.azioni_operatore (
    pratica_id, azione, nota, stato_prima, stato_dopo, operatore
  ) values (
    v_prima.pratica_id,
    'attivita_operatore_' || p_azione,
    nullif(trim(coalesce(p_nota, '')), ''),
    to_jsonb(v_prima),
    to_jsonb(v_dopo),
    nullif(trim(coalesce(p_operatore, '')), '')
  );

  return jsonb_build_object(
    'ok', true, 'attivita_id', p_attivita_id, 'azione', p_azione,
    'tipo', v_dopo.tipo, 'stato', v_dopo.stato
  );
end;
$$;

revoke all on function public.applica_azione_attivita_operatore(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.applica_azione_attivita_operatore(uuid, text, text, text)
  to service_role;

comment on table public.attivita_operatore is
  'Coda operativa indipendente dagli stati commerciali e fiscali per ritiri e richieste di ricontatto.';
comment on function private.rileva_attivita_operativa_evento(bigint) is
  'Classifica in modo conservativo un evento Keplero in attivita operative idempotenti.';

-- Il recupero storico viene eseguito dopo la migrazione in lotti piccoli.
-- Tenerlo fuori dal DDL evita che una grande cronologia prolunghi il lock.

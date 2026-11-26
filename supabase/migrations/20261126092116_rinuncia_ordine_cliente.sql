alter table public.pratiche
  add column ordine_annullato_cliente_at timestamptz,
  add constraint ordine_annullato_cliente_chiuso check (
    ordine_annullato_cliente_at is null or (
      tipo_flusso = 'commerciale' and stato_commerciale = 'chiuso'
      and stato_fatturazione = 'non_applicabile' and ordine_acquisito_at is null
      and stato_followup = 'annullato' and followup_previsto_at is null
    )
  );

create function public.gestisci_rinuncia_ordine_cliente(
  p_pratica_id uuid, p_azione text, p_riferimento timestamptz, p_operatore text, p_nota text default null
) returns boolean
language plpgsql security invoker set search_path = ''
as $$
declare
  prima public.pratiche%rowtype;
  dopo public.pratiche%rowtype;
  scelta public.scelte_cliente%rowtype;
  nota text;
  autore text;
  autorizzazione_precedente text := coalesce(current_setting('app.autorizza_regressione', true), '');
begin
  if p_operatore is null or p_operatore not in (
    'Operatore 1', 'Operatore 2', 'Operatore 3', 'Operatore 4', 'Manutenzione autorizzata'
  ) or p_azione is null or p_azione not in ('annulla', 'riapri') then
    raise exception 'Comando o operatore non valido';
  end if;

  select * into strict prima from public.pratiche where id = p_pratica_id for update;
  if prima.tipo_flusso <> 'commerciale' or prima.stato_fatturazione = 'fatturato'
     or prima.data_fattura is not null or exists (
       select 1 from public.documenti_amministrativi
       where pratica_id = p_pratica_id and tipo_documento = 'fattura'
     ) then
    raise exception 'Operazione disponibile solo per una pratica commerciale senza fattura';
  end if;

  autore := nullif(p_operatore, 'Manutenzione autorizzata');
  if p_azione = 'annulla' then
    if prima.ordine_annullato_cliente_at is not null then return false; end if;
    if prima.stato_commerciale <> 'ordine_acquisito'
       or prima.ordine_acquisito_at is distinct from p_riferimento then
      raise exception 'Lo stato dell’ordine è cambiato. Ricarica la pratica';
    end if;
    perform set_config('app.autorizza_regressione', 'true', true);
    nota := 'Il cliente ha annullato l’ordine.';
    update public.pratiche set
      ordine_annullato_cliente_at = now(), stato_commerciale = 'chiuso',
      ordine_acquisito_at = null, stato_fatturazione = 'non_applicabile',
      stato_amministrativo = 'non_applicabile', stato_amministrativo_at = now(),
      nota_amministrativa = nota, stato_followup = 'annullato', followup_previsto_at = null,
      fonte_classificazione = 'operatore', blocco_classificazione_operatore = true,
      ultima_azione_operatore_at = now()
    where id = p_pratica_id returning * into dopo;

    perform set_config('app.autorizza_regressione', autorizzazione_precedente, true);

    select * into scelta from public.scelte_cliente where pratica_id = p_pratica_id for update;
    if found then
      update public.scelte_cliente set
        stato = 'revocata', evidenza = nota, richiesta_at = now(), evento_id = null,
        fonte = 'operatore', protetta_operatore = true, operatore = p_operatore, updated_at = now()
      where pratica_id = p_pratica_id;
    end if;
    update public.verifiche_acquisizione_ordini
    set risolta_at = now(), nota = 'Ordine annullato dal cliente.', operatore = p_operatore
    where pratica_id = p_pratica_id and risolta_at is null and evento_at <= now();
  else
    if prima.ordine_annullato_cliente_at is null then return false; end if;
    if prima.ordine_annullato_cliente_at is distinct from p_riferimento then
      raise exception 'Lo stato dell’ordine è cambiato. Ricarica la pratica';
    end if;
    nota := 'Pratica riaperta dopo la rinuncia, in attesa di una nuova conferma del cliente.';
    update public.pratiche set
      ordine_annullato_cliente_at = null,
      stato_commerciale = case when preventivo_inviato_at is null
        then 'da_preventivare'::public.stato_commerciale
        else 'preventivo_inviato'::public.stato_commerciale end,
      nota_amministrativa = null, ultima_azione_operatore_at = now()
    where id = p_pratica_id returning * into dopo;
  end if;

  if nullif(btrim(p_nota), '') is not null then
    nota := nota || ' ' || left(btrim(p_nota), 2000);
  end if;
  if autore is null then nota := nota || ' (' || p_operatore || ')'; end if;
  insert into public.azioni_operatore(pratica_id, azione, nota, stato_prima, stato_dopo, operatore)
  values (p_pratica_id, case when p_azione = 'annulla' then 'ordine_annullato_cliente'
                             else 'riapertura_dopo_rinuncia_cliente' end, nota,
          jsonb_build_object('stato_commerciale', prima.stato_commerciale,
                             'stato_fatturazione', prima.stato_fatturazione,
                             'ordine_acquisito_at', prima.ordine_acquisito_at,
                             'ordine_annullato_cliente_at', prima.ordine_annullato_cliente_at,
                             'scelta_cliente', to_jsonb(scelta)),
          jsonb_build_object('stato_commerciale', dopo.stato_commerciale,
                             'stato_fatturazione', dopo.stato_fatturazione,
                             'ordine_annullato_cliente_at', dopo.ordine_annullato_cliente_at),
          autore);
  return true;
end;
$$;

revoke all on function public.gestisci_rinuncia_ordine_cliente(uuid,text,timestamptz,text,text) from public, anon, authenticated;
grant execute on function public.gestisci_rinuncia_ordine_cliente(uuid,text,timestamptz,text,text) to service_role;

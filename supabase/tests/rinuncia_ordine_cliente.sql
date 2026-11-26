-- Transizioni reali con il ruolo della dashboard. Tutte le modifiche sono transazionali.
begin;
set local role service_role;

do $test$
declare
  pratica_id_test uuid;
  acquisito_at timestamptz := now() - interval '1 day';
  preventivo_at timestamptz := now() - interval '2 days';
  annullato_at timestamptz;
begin
  insert into public.pratiche(numero_pratica, nome_cliente, tipo_flusso, stato_commerciale,
                              stato_fatturazione, ordine_acquisito_at, preventivo_inviato_at)
  overriding system value
  values (-81002, 'Prova rinuncia', 'commerciale', 'ordine_acquisito', 'da_fatturare', acquisito_at, preventivo_at)
  returning id into pratica_id_test;
  insert into public.scelte_cliente(pratica_id, stato, evidenza, fonte, richiesta_at)
  values (pratica_id_test, 'da_chiarire', 'Prova', 'operatore', preventivo_at);

  if not public.gestisci_rinuncia_ordine_cliente(pratica_id_test, 'annulla', acquisito_at, 'Operatore 1') then
    raise exception 'Annullamento non registrato';
  end if;
  select ordine_annullato_cliente_at into strict annullato_at from public.pratiche where id = pratica_id_test
    and stato_commerciale = 'chiuso' and stato_fatturazione = 'non_applicabile'
    and stato_followup = 'annullato' and preventivo_inviato_at = preventivo_at;
  if annullato_at is null or exists (select 1 from public.v_evasioni_pratiche where pratica_id = pratica_id_test)
     or not exists (select 1 from public.scelte_cliente where pratica_id = pratica_id_test and stato = 'revocata' and protetta_operatore) then
    raise exception 'Ordine ancora aperto dopo la rinuncia';
  end if;

  if public.gestisci_rinuncia_ordine_cliente(pratica_id_test, 'annulla', acquisito_at, 'Operatore 1') then
    raise exception 'Annullamento duplicato';
  end if;
  if (select count(*) from public.azioni_operatore where pratica_id = pratica_id_test and azione = 'ordine_annullato_cliente') <> 1 then
    raise exception 'Storico incoerente';
  end if;
  begin
    update public.pratiche set stato_commerciale = 'ordine_acquisito', stato_fatturazione = 'da_fatturare'
    where id = pratica_id_test;
    raise exception 'Riattivazione automatica permessa';
  exception when check_violation then null;
  end;
  begin
    perform public.gestisci_rinuncia_ordine_cliente(pratica_id_test, 'riapri', acquisito_at, 'Operatore 1');
    raise exception 'Scheda obsoleta accettata';
  exception when raise_exception then
    if sqlerrm <> 'Lo stato dell’ordine è cambiato. Ricarica la pratica' then raise; end if;
  end;

  if not public.gestisci_rinuncia_ordine_cliente(pratica_id_test, 'riapri', annullato_at, 'Operatore 1') then
    raise exception 'Riapertura non registrata';
  end if;
  if not exists (select 1 from public.pratiche where id = pratica_id_test and ordine_annullato_cliente_at is null
                 and stato_commerciale = 'preventivo_inviato' and stato_fatturazione = 'non_applicabile'
                 and preventivo_inviato_at = preventivo_at and ordine_acquisito_at is null) then
    raise exception 'Riapertura fuori dalla fase di preventivo';
  end if;
  if has_function_privilege('authenticated', 'public.gestisci_rinuncia_ordine_cliente(uuid,text,timestamptz,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.gestisci_rinuncia_ordine_cliente(uuid,text,timestamptz,text,text)', 'EXECUTE') then
    raise exception 'Funzione esposta a un ruolo non operativo';
  end if;
end;
$test$;
rollback;

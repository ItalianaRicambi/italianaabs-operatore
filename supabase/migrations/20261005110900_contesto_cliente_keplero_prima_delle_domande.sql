-- Consultazione prima delle domande, anche senza un ordine già acquisito.
-- Non crea clienti, non collega pratiche e non comunica valori fiscali riservati.
create or replace function public.contesto_cliente_keplero(p_pratica_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_pratica public.pratiche%rowtype;
  v_cliente public.clienti%rowtype;
  v_ids uuid[];
  v_telefono text;
  v_email text;
  v_piva text;
  v_campi text[];
begin
  select * into v_pratica from public.pratiche where id = p_pratica_id;
  if not found then
    raise exception 'Pratica non trovata';
  end if;

  v_telefono := public.normalizza_telefono_cliente(coalesce(v_pratica.telefono, ''));
  v_email := public.normalizza_email_cliente(coalesce(v_pratica.email_cliente, ''));
  v_piva := upper(regexp_replace(coalesce(
    v_pratica.dati_raw #>> '{anagrafica_estratta,partita_iva}',
    v_pratica.dati_raw #>> '{payload_live,partita_iva}', ''
  ), '[^A-Za-z0-9]', '', 'g'));

  if v_pratica.cliente_id is not null and v_pratica.fonte_collegamento_cliente = 'operatore' then
    v_ids := array[v_pratica.cliente_id];
  else
    select array_agg(c.id) into v_ids
    from public.clienti c
    where c.id = v_pratica.cliente_id
      or (v_email <> '' and c.email_normalizzata = v_email)
      or (v_piva <> '' and c.partita_iva_normalizzata = v_piva)
      or (length(v_telefono) >= 8 and exists (
        select 1
        from regexp_split_to_table(coalesce(c.telefono, ''), '[/;,|\n\r]+') as numeri(numero)
        where public.normalizza_telefono_cliente(numeri.numero) = v_telefono
      ));
  end if;

  if coalesce(cardinality(v_ids), 0) = 0 then
    return jsonb_build_object(
      'stato', 'non_trovato', 'cliente_riconosciuto', false,
      'richiedere_anagrafica_completa', false,
      'nome_attivita_acquisito', nullif(coalesce(
        v_pratica.dati_raw #>> '{anagrafica_estratta,ragione_sociale}',
        v_pratica.dati_raw #>> '{payload_live,nome_attivita}', ''
      ), ''),
      'istruzione', 'Nessuna corrispondenza certa in anagrafica: conserva tutti i dati già ricevuti nel testo e nelle immagini e chiedi solo quelli realmente mancanti.'
    );
  end if;

  if cardinality(v_ids) > 1 then
    return jsonb_build_object(
      'stato', 'ambiguo', 'cliente_riconosciuto', false,
      'richiedere_anagrafica_completa', false,
      'istruzione', 'Più anagrafiche compatibili: inoltra la verifica all’operatore, senza ricominciare la raccolta di dati già forniti e senza scegliere un cliente arbitrariamente.'
    );
  end if;

  select * into v_cliente from public.clienti where id = v_ids[1];
  if v_cliente.da_verificare or v_cliente.possibile_duplicato then
    return jsonb_build_object(
      'stato', 'da_verificare', 'cliente_riconosciuto', false,
      'richiedere_anagrafica_completa', false,
      'istruzione', 'L’anagrafica trovata richiede verifica dell’operatore: non chiedere nuovamente tutti i dati al cliente.'
    );
  end if;

  v_campi := coalesce(v_cliente.campi_amministrativi_mancanti, '{}'::text[]);
  if nullif(btrim(v_cliente.email), '') is null
     and nullif(btrim(v_pratica.email_cliente), '') is null
     and not ('email' = any(v_campi)) then
    v_campi := array_append(v_campi, 'email');
  end if;

  return jsonb_build_object(
    'stato', 'riconosciuto', 'cliente_riconosciuto', true,
    'denominazione', v_cliente.denominazione,
    'dati_fiscali_completi', v_cliente.dati_fiscali_completi and cardinality(v_campi) = 0,
    'campi_mancanti', to_jsonb(v_campi),
    'richiedere_anagrafica_completa', false,
    'istruzione', case
      when v_cliente.dati_fiscali_completi and cardinality(v_campi) = 0
        then 'Cliente già riconosciuto e dati fiscali completi: NON chiedere nome, ragione sociale, partita IVA, codice fiscale, indirizzo o email. Chiedi solo eventuali variazioni o un diverso luogo di ritiro/spedizione quando necessario.'
      else 'Cliente già riconosciuto: NON richiedere nome o tutti i dati fiscali. Dopo una reale accettazione chiedi soltanto i campi mancanti indicati, sottraendo quelli già ricevuti nella conversazione o nelle immagini.'
    end
  );
end;
$$;

revoke all on function public.contesto_cliente_keplero(uuid) from public, anon, authenticated;
grant execute on function public.contesto_cliente_keplero(uuid) to service_role;

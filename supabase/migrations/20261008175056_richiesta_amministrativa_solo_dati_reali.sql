CREATE OR REPLACE FUNCTION public.prepara_richiesta_dati_amministrativi(p_pratica_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pratica public.pratiche%rowtype;
  v_campi text[] := '{}'::text[];
  v_cliente_completo boolean := false;
  v_elenco text;
  v_messaggio text;
  v_stato text;
begin
  select * into v_pratica
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    raise exception 'Pratica non trovata';
  end if;

  if v_pratica.stato_fatturazione = 'fatturato' then
    update public.pratiche
    set stato_amministrativo = 'completato',
        stato_amministrativo_at = coalesce(stato_amministrativo_at, now()),
        stato_richiesta_amministrativa = 'completata',
        campi_richiesta_amministrativa = '{}'::text[],
        messaggio_richiesta_amministrativa = null,
        richiesta_amministrativa_completata_at = coalesce(richiesta_amministrativa_completata_at, now())
    where id = p_pratica_id;

    return jsonb_build_object('necessaria', false, 'stato', 'completata',
      'campi', '[]'::jsonb, 'messaggio', null, 'pratica_id', p_pratica_id);
  end if;

  if v_pratica.stato_fatturazione <> 'da_fatturare'
     or v_pratica.stato_amministrativo = 'corrispondenza_ambigua' then
    v_stato := case
      when v_pratica.stato_richiesta_amministrativa in ('da_inviare', 'inviata') then 'annullata'
      else 'non_necessaria'
    end;

    update public.pratiche
    set stato_richiesta_amministrativa = v_stato,
        campi_richiesta_amministrativa = '{}'::text[],
        messaggio_richiesta_amministrativa = null
    where id = p_pratica_id;

    return jsonb_build_object('necessaria', false, 'stato', v_stato,
      'campi', '[]'::jsonb, 'messaggio', null, 'pratica_id', p_pratica_id,
      'motivo', case when v_pratica.stato_amministrativo = 'corrispondenza_ambigua'
        then 'corrispondenza_cliente_da_risolvere' else 'ordine_non_da_fatturare' end);
  end if;

  if v_pratica.cliente_id is not null then
    select (private.verifica_dati_cliente_fatturazione(id)->>'completi')::boolean,
           array(select jsonb_array_elements_text(private.verifica_dati_cliente_fatturazione(id)->'campi'))
    into v_cliente_completo, v_campi
    from public.clienti
    where id = v_pratica.cliente_id;

    if coalesce(v_cliente_completo,false)
       and coalesce(v_pratica.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}','false')='true' then
      update public.pratiche set stato_richiesta_amministrativa='non_necessaria',
        campi_richiesta_amministrativa='{}'::text[],messaggio_richiesta_amministrativa=null
        where id=p_pratica_id;
      return jsonb_build_object('necessaria',false,'stato','non_necessaria','campi','[]'::jsonb,
        'motivo','sospensione_operatore_da_confermare','pratica_id',p_pratica_id);
    end if;

    if coalesce(v_cliente_completo, false) then
      update public.pratiche
      set stato_amministrativo = 'pronto_fatturazione',
          stato_amministrativo_at = now(),
          stato_richiesta_amministrativa = 'completata',
          campi_richiesta_amministrativa = '{}'::text[],
          messaggio_richiesta_amministrativa = null,
          richiesta_amministrativa_completata_at = coalesce(richiesta_amministrativa_completata_at, now()),
          nota_amministrativa = coalesce(nota_amministrativa,
            'Cliente già presente in anagrafica con dati fiscali completi.')
      where id = p_pratica_id;

      return jsonb_build_object('necessaria', false, 'stato', 'completata',
        'campi', '[]'::jsonb, 'messaggio', null, 'pratica_id', p_pratica_id,
        'motivo', 'cliente_in_anagrafica_completo');
    end if;
  elsif v_pratica.stato_amministrativo <> 'dati_mancanti' then
    update public.pratiche
    set stato_richiesta_amministrativa = 'non_necessaria',
        campi_richiesta_amministrativa = '{}'::text[],
        messaggio_richiesta_amministrativa = null
    where id = p_pratica_id;

    return jsonb_build_object('necessaria', false, 'stato', 'non_necessaria',
      'campi', '[]'::jsonb, 'messaggio', null, 'pratica_id', p_pratica_id,
      'motivo', 'in_attesa_riconoscimento_cliente');
  end if;

  if coalesce(cardinality(v_campi), 0) = 0 then
    v_campi := array['indirizzo_fatturazione','cap','comune','partita_iva_o_codice_fiscale'];
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
    end, ', '
  ) into v_elenco
  from unnest(v_campi) as campo;

  v_messaggio := 'Grazie, abbiamo registrato l''accettazione del preventivo. '
    || 'Per preparare la fattura ci servono ancora: ' || v_elenco || '. Può inviarceli qui?';

  v_stato := case
    when v_pratica.stato_richiesta_amministrativa = 'inviata'
      and v_pratica.campi_richiesta_amministrativa = v_campi then 'inviata'
    else 'da_inviare'
  end;

  update public.pratiche
  set stato_richiesta_amministrativa = v_stato,
      campi_richiesta_amministrativa = v_campi,
      messaggio_richiesta_amministrativa = v_messaggio,
      richiesta_amministrativa_preparata_at = case
        when campi_richiesta_amministrativa is distinct from v_campi
          or messaggio_richiesta_amministrativa is distinct from v_messaggio
          or richiesta_amministrativa_preparata_at is null then now()
        else richiesta_amministrativa_preparata_at end,
      richiesta_amministrativa_inviata_at = case
        when v_stato = 'inviata' then richiesta_amministrativa_inviata_at else null end,
      richiesta_amministrativa_completata_at = null
  where id = p_pratica_id;

  return jsonb_build_object('necessaria', true, 'stato', v_stato,
    'campi', to_jsonb(v_campi), 'messaggio', v_messaggio, 'pratica_id', p_pratica_id);
end;
$function$
;

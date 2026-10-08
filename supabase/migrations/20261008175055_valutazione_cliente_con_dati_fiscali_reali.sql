CREATE OR REPLACE FUNCTION public.valuta_collegamento_cliente(p_pratica_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pratica public.pratiche%rowtype;
  v_candidati integer := 0;
  v_sospesa boolean;
  v_cliente_id uuid;
  v_cliente_completo boolean := false;
  v_cliente_da_verificare boolean := false;
  v_campi_mancanti text[] := '{}'::text[];
  v_segnali text[] := '{}'::text[];
  v_partita_iva text;
  v_codice_fiscale text;
begin
  select *
  into v_pratica
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    raise exception 'Pratica non trovata';
  end if;

  v_sospesa := coalesce(v_pratica.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}','false')='true';

  v_partita_iva := regexp_replace(
    coalesce(v_pratica.dati_raw #>> '{anagrafica_estratta,partita_iva}', ''),
    '[^0-9]', '', 'g'
  );
  v_codice_fiscale := upper(regexp_replace(
    coalesce(v_pratica.dati_raw #>> '{anagrafica_estratta,codice_fiscale}', ''),
    '[^A-Z0-9]', '', 'g'
  ));

  if v_pratica.stato_fatturazione <> 'da_fatturare' then
    return jsonb_build_object(
      'esito', 'non_applicabile',
      'pratica_id', p_pratica_id
    );
  end if;

  if v_pratica.cliente_id is not null
     and v_pratica.fonte_collegamento_cliente = 'operatore' then
    select
      (private.verifica_dati_cliente_fatturazione(id)->>'completi')::boolean and not v_sospesa,
      array(select jsonb_array_elements_text(private.verifica_dati_cliente_fatturazione(id)->'campi'))
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
      case when partita_iva_match then 140 else 0 end
      + case when codice_fiscale_match then 140 else 0 end
      + case when email_match then 100 else 0 end
      + case when telefono_match then 80 else 0 end
    )::smallint,
    array_remove(array[
      case when partita_iva_match then 'partita_iva' end,
      case when codice_fiscale_match then 'codice_fiscale' end,
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
        and (
          public.normalizza_telefono_cliente(coalesce(c.telefono, ''))
            = public.normalizza_telefono_cliente(coalesce(v_pratica.telefono, ''))
          or (
            length(public.normalizza_telefono_cliente(coalesce(v_pratica.telefono, ''))) >= 9
            and position(
              public.normalizza_telefono_cliente(coalesce(v_pratica.telefono, ''))
              in regexp_replace(coalesce(c.telefono, ''), '[^0-9]', '', 'g')
            ) > 0
          )
        )
        as telefono_match,
      length(v_partita_iva) = 11
        and regexp_replace(coalesce(c.partita_iva, ''), '[^0-9]', '', 'g') = v_partita_iva
        as partita_iva_match,
      length(v_codice_fiscale) = 16
        and upper(regexp_replace(coalesce(c.codice_fiscale, ''), '[^A-Z0-9]', '', 'g'))
          = v_codice_fiscale
        as codice_fiscale_match
  ) confronto
  where email_match or telefono_match or partita_iva_match or codice_fiscale_match
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
      (private.verifica_dati_cliente_fatturazione(c.id)->>'completi')::boolean and not v_sospesa,
      c.da_verificare or c.possibile_duplicato,
      array(select jsonb_array_elements_text(private.verifica_dati_cliente_fatturazione(c.id)->'campi'))
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
$function$
;

-- Il rientro del guasto è diagnostico; il rientro di un dispositivo è logistico.
create or replace function private.richiesta_rientro_dispositivo(p_testo text)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(lower(p_testo) ~ (
  'restitu.{0,70}(pompa|abs|centralina|prodotto|pezzo|dispositivo)|' ||
  '\mrientr(o|are)\M[[:space:]]+((del|della|dello|di|il|la|lo|un|una|nostro|nostra|vostro|vostra|mio|mia|gruppo|modulo|in garanzia)[[:space:]]+){0,4}(pompa|abs|centralina|prodotto|pezzo|dispositivo)'
 ),false)
$$;
revoke all on function private.richiesta_rientro_dispositivo(text) from public,anon,authenticated;
grant execute on function private.richiesta_rientro_dispositivo(text) to service_role;

CREATE OR REPLACE FUNCTION private.rileva_rientro_evento(p_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype; a public.attivita_operatore%rowtype;
 c public.assistenze_rientri%rowtype; t text; v_origine uuid; v_num integer; v_problema boolean; v_ritiro boolean;
 v_tipo text; v_servizio text; v_nuova boolean:=false; v_gia_ritirato boolean; v_prenotato_segnalato boolean;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id for update;
 if not found or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then return '{}'::jsonb; end if;
 if nullif(e.payload->>'targa','') is not null and upper(regexp_replace(e.payload->>'targa','[^A-Za-z0-9]','','g'))<>upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) then return '{}'::jsonb; end if;
 t:=lower(translate(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),'àèéìòù’','aeeiou'''));
 if t='' then return '{}'::jsonb; end if;
 v_origine:=p.pratica_origine_id;
 if v_origine is null and (p.stato_commerciale::text='ordine_acquisito' or p.stato_fatturazione::text='fatturato') then v_origine:=p.id; end if;
 if v_origine is null and nullif(p.targa,'') is not null then
  select count(*),min(x.id::text)::uuid into v_num,v_origine from public.pratiche x
  where x.id<>p.id and upper(regexp_replace(coalesce(x.targa,''),'[^A-Za-z0-9]','','g'))=upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))
   and (x.stato_commerciale::text='ordine_acquisito' or x.stato_fatturazione::text='fatturato')
   and (x.cliente_id=p.cliente_id or (nullif(p.telefono,'') is not null and regexp_replace(x.telefono,'[^0-9]','','g')=regexp_replace(p.telefono,'[^0-9]','','g')))
   and coalesce(x.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
   and coalesce(x.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
  if v_num<>1 then v_origine:=null; end if;
 end if;
 select * into c from public.assistenze_rientri where pratica_id=p.id and chiusa_at is null for update;
 -- Il problema deve riguardare un intervento/prodotto precedente, oppure essere una richiesta esplicita di garanzia.
 v_problema:= t~'(in garanzia|rientro.{0,25}garanzia|dopo.{0,35}(vostra riparazione|vostro intervento)|(?:ricambio|pezzo|dispositivo|centralina|modulo).{0,40}(ricevuto da voi|fornito da voi|fornito).{0,70}(difett|non funzion|errato))'
  or (((p.stato_fatturazione::text='fatturato' and coalesce(p.data_fattura,p.ordine_acquisito_at,p.created_at)<=e.created_at) or p.tipo_assistenza::text in ('post_riparazione','garanzia') or e.payload->>'tipo_assistenza' in ('post_riparazione','post_scambio','post_installazione'))
   and t~'(non.{0,30}(risolto|funziona)|stess[oa].{0,20}(difetto|problema)|problema.{0,30}(persiste|rimane)|dopo.{0,25}(montaggio|riparazione|sostituzione)|(?:pezzo|modulo|pompa).{0,25}(difettoso|sbagliato)|(?:ricevuto|montato|installato).{0,100}(errore|spia|difett)|rivoglio.{0,35}(mio|originale))');
 v_ritiro:=(t~'(pacc(o|hetto).{0,70}(pront|ritir)|pront[ioa].{0,45}(ritir|restitu|rientr)|(?:organizz|prenot|programmar).{0,50}(ritiro|corriere)|(?:quando passa|quando passera|non e ancora passato).{0,30}corriere)' or private.richiesta_restituzione_vecchio(t) or private.richiesta_rientro_dispositivo(t))
  and t!~'(non.{0,15}(pronto|pronta)|non.{0,15}(ritirare|prenotare)|se.{0,30}(pacco|ritiro)|ipotetico)';
 if v_problema and c.id is null then
  -- Non rielabora un vecchio messaggio appartenente a un episodio già chiuso.
  if exists(select 1 from public.assistenze_rientri where pratica_id=p.id and chiusa_at is not null and chiusa_at>=e.created_at) then return '{}'::jsonb; end if;
  insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evento_id,evidenza,aperta_at)
  values(p.id,v_origine,e.id,coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),e.created_at)
  returning * into c;
  v_nuova:=true;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  values(p.id,'apertura_assistenza_rientro','Segnalazione post intervento: verifica urgente. Ammissibilità della garanzia da valutare dal tecnico.',
   '{}'::jsonb,to_jsonb(c),'routine_controllo_k');
 end if;
 v_gia_ritirato:=t~'(gia.{0,30}(ritirat|fatto ritir)|ritirat.{0,20}gia|avete.{0,25}ritirat)';
 v_prenotato_segnalato:=t~'(gls|corriere).{0,60}(codice|numero|prenotazione).{0,40}[0-9]{5,}';
 if v_gia_ritirato or v_prenotato_segnalato then
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',v_gia_ritirato,'prenotazione_segnalata_cliente',v_prenotato_segnalato,'evidenza_ritiro_effettuato',t,'evento_ritiro_effettuato',e.id)
   where pratica_id=p.id and tipo like 'ritiro_%' and stato in ('da_gestire','da_collegare','programmata')
    and coalesce((metadati->>'evento_prenotazione_verificato')::bigint,0)<e.id;
  if v_gia_ritirato then return jsonb_build_object('assistenza_id',c.id,'esito','ritiro_gia_effettuato_da_verificare'); end if;
 end if;
 if not v_ritiro then return jsonb_build_object('assistenza_id',c.id,'aperta',v_nuova); end if;
 select * into a from public.attivita_operatore where pratica_id=p.id and tipo like 'ritiro_%'
  and stato in ('da_gestire','da_collegare','programmata') for update;
 if not found and exists(select 1 from public.attivita_operatore where pratica_id=p.id and tipo like 'ritiro_%'
  and (evento_keplero_id=e.id or coalesce(completata_at,annullata_at)>=e.created_at)) then return jsonb_build_object('esito','episodio_gia_gestito'); end if;
 select servizio into v_servizio from public.v_scelte_cliente where pratica_id=coalesce(v_origine,p.id) and stato='confermata';
 if c.id is not null then v_tipo:='ritiro_verifica_garanzia';
 elsif t~'(reso|rientro|restitu).{0,50}(rimborso|recesso)|rimborso.{0,50}(reso|rientro)' then v_tipo:='ritiro_altro_reso';
 elsif private.richiesta_restituzione_vecchio(t) or t~'(vecchi[oa].{0,40}(restitu|ritir|scambio)|(?:restitu|ritir).{0,40}vecchi[oa])' then v_tipo:='ritiro_programma_scambio';
 elsif v_servizio in ('RI','RE','RC') and not exists(select 1 from public.attivita_operatore where pratica_id=p.id and tipo='ritiro_lavorazione' and completata_at<e.created_at) then v_tipo:='ritiro_lavorazione';
 else v_tipo:='ritiro_da_classificare'; end if;
 if a.id is null then
  insert into public.attivita_operatore(tipo,stato,priorita,pratica_id,pratica_origine_id,assistenza_rientro_id,
   evento_keplero_id,external_key,evidenza,fonte,metadati,richiesta_at)
  values(v_tipo,case when v_origine is null then 'da_collegare' else 'da_gestire' end,
   case when c.id is null then 'alta' else 'urgente' end,p.id,v_origine,c.id,e.id,e.external_key,
   coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),
   'keplero_live',jsonb_build_object('regola','ritiro_contestuale_v2','scelta_servizio',v_servizio),e.created_at) returning * into a;
 else
  -- La prima data, l'evidenza originale e la prenotazione non cambiano con i messaggi successivi.
  update public.attivita_operatore set
   tipo=case when blocco_classificazione then tipo when c.id is not null then 'ritiro_verifica_garanzia'
    when tipo='ritiro_da_classificare' or metadati->>'regola'='rientro_prodotto_v1' then v_tipo else tipo end,
   priorita=case when c.id is not null then 'urgente' else priorita end,
   assistenza_rientro_id=coalesce(assistenza_rientro_id,c.id),pratica_origine_id=coalesce(pratica_origine_id,v_origine),
   stato=case when stato='da_collegare' and v_origine is not null then 'da_gestire' else stato end,
   metadati=metadati||jsonb_build_object('ultimo_evento_ritiro',e.id,'ultima_evidenza',t),updated_at=now()
  where id=a.id returning * into a;
 end if;
 if v_prenotato_segnalato then
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',v_gia_ritirato,'prenotazione_segnalata_cliente',v_prenotato_segnalato,'evidenza_ritiro_effettuato',t,'evento_ritiro_effettuato',e.id)
   where id=a.id and coalesce((metadati->>'evento_prenotazione_verificato')::bigint,0)<e.id;
 end if;
 if c.id is not null and c.stato in ('da_prendere_in_carico','verifica_tecnica') and c.presa_in_carico_at is not null then
  update public.assistenze_rientri set stato='ritiro_da_prenotare',updated_at=now() where id=c.id;
 end if;
 return jsonb_build_object('assistenza_id',c.id,'attivita_id',a.id,'tipo',a.tipo,'stato',a.stato,
  'domanda',case when a.tipo='ritiro_da_classificare' then 'Il pacco contiene il vecchio dispositivo da restituire per lo scambio oppure quello ricevuto da noi che presenta il problema?' end);
end; $function$
;
CREATE OR REPLACE FUNCTION private.rileva_attivita_operativa_evento(p_evento_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_callback := private.richiesta_richiamata_esplicita(v_testo);

  -- Rientro fisico: richiede una formulazione operativa, non la sola parola
  -- "ritiro" usata mentre si conferma un ordine.
  v_ritiro_forte := v_testo ~ (
    '(pacc(o|hetto).*(pront|ritir)|pront[ioa].*(ritir|restitu|rientr)|' ||
    'ritirare.*(pompa|abs|centralina|prodotto|pezzo).*(usat|vecchi)|' ||
    '(non (e|è) ancora passat|quando passa|quando passera|quando passerà).*corriere)'
  );
  v_ritiro_forte := v_ritiro_forte or private.richiesta_restituzione_vecchio(v_testo) or private.richiesta_rientro_dispositivo(v_testo);
  v_ritiro := v_ritiro_forte
    or (
      v_pratica.tipo_flusso = 'assistenza'::public.tipo_flusso
      and v_testo ~ '(programmar|prenotar|organizzar).*(ritiro|corriere)'
    );


  if v_callback and (v_pratica.assistenza_chiusa_at>=v_evento.created_at or exists(
   select 1 from public.attivita_operatore a where a.pratica_id=v_pratica.id and a.tipo like 'richiamata_%'
    and coalesce(a.completata_at,a.annullata_at)>=v_evento.created_at)) then v_callback:=false; end if;
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
    elsif v_pratica.stato_commerciale = 'preventivo_inviato'::public.stato_commerciale
          or (v_preventivo_id is not null
              and v_pratica.stato_commerciale = 'attesa_cliente'::public.stato_commerciale)
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

  perform private.rileva_rientro_evento(p_evento_id);
  return jsonb_build_object('ok', true, 'attivita', v_risultati);
end;
$function$
;

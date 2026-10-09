-- Una sola transazione verifica offerta/conversazione e conserva la prova.
create or replace function private.conferma_ordine_evento_verificato(p_event_id bigint)
returns jsonb language plpgsql set search_path = '' as $function$
declare e public.keplero_live_events%rowtype; v_contesto jsonb; v_esito jsonb;
 v_prima jsonb; v_sorgente public.keplero_live_events%rowtype;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 perform 1 from public.pratiche where id=e.pratica_id for update;
 v_contesto:=private.ordine_da_conferma_letterale(e.id);
 if coalesce(v_contesto->>'confermato','false')<>'true' then
  v_contesto:=private.ordine_da_scelta_e_fiscali(e.id);
 end if;
 if coalesce(v_contesto->>'confermato','false')<>'true' then return '{}'::jsonb; end if;
 select to_jsonb(p) into v_prima from public.pratiche p where p.id=e.pratica_id;
 v_esito:=public.conferma_ordine_da_keplero(e.pratica_id,e.external_key,
  coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio'));
 if v_esito->>'aggiornato'='true' then
  select * into v_sorgente from public.keplero_live_events
   where id=coalesce((v_contesto->>'evento_conferma')::bigint,
     (v_contesto->>'evento_scelta')::bigint,e.id) and pratica_id=e.pratica_id;
  update public.pratiche set ordine_acquisito_at=v_sorgente.created_at,
   dati_raw=coalesce(dati_raw,'{}'::jsonb)||jsonb_build_object('conferma_ordine_verificata',
    v_contesto||jsonb_build_object('event_id',v_sorgente.id,'external_key',e.external_key,
      'confermata_at',v_sorgente.created_at,'registrata_at',now(),
      'messaggio',coalesce(v_sorgente.payload->>'ultimo_messaggio_cliente',
       v_sorgente.payload->>'messaggio_cliente',v_sorgente.payload->>'messaggio')))
   where id=e.pratica_id;
  update public.preventivi set accettato_at=v_sorgente.created_at
   where pratica_id=e.pratica_id and stato='accettato' and accettato_at=now();
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo)
   select e.pratica_id,'conferma_ordine_evento_verificato',
    'Conferma verificata nell’evento '||v_sorgente.id||' del '||v_sorgente.created_at||': '||
    left(coalesce(v_sorgente.payload->>'ultimo_messaggio_cliente',v_sorgente.payload->>'messaggio_cliente',v_sorgente.payload->>'messaggio',''),1000),
    v_prima,to_jsonb(p) from public.pratiche p where p.id=e.pratica_id;
 end if;
 return jsonb_build_object('contesto',v_contesto,'avanzamento',v_esito);
end;
$function$;
revoke all on function private.conferma_ordine_evento_verificato(bigint) from public,anon,authenticated;
grant execute on function private.conferma_ordine_evento_verificato(bigint) to service_role;

-- Manteniamo gestione allegati/errori; aggiungiamo il controllo letterale
-- anche quando il flag trasmesso da K è falso o già positivo.
do $patch$
declare v_def text; v_originale text; v_nuovo text;
begin
 v_def:=pg_get_functiondef('private.processa_evento_keplero()'::regprocedure);
 v_originale:=$old$  if new.pratica_id is not null and not v_ordine then
    v_contesto_ordine := private.ordine_da_scelta_e_fiscali(new.id);
    v_ordine := coalesce((v_contesto_ordine->>'confermato')::boolean,false);
  end if;$old$;
 v_nuovo:=$new$  if new.pratica_id is not null then
    v_contesto_ordine := private.ordine_da_conferma_letterale(new.id);
    if not v_ordine and coalesce(v_contesto_ordine->>'confermato','false')<>'true' then
      v_contesto_ordine := private.ordine_da_scelta_e_fiscali(new.id);
    end if;
    v_ordine := v_ordine or coalesce((v_contesto_ordine->>'confermato')::boolean,false);
  end if;$new$;
 if strpos(v_def,v_originale)=0 then raise exception 'Blocco contesto intake inatteso'; end if;
 v_def:=replace(v_def,v_originale,v_nuovo);
 v_originale:=$old$    v_esito_ordine := public.conferma_ordine_da_keplero($old$;
 v_nuovo:=$new$    if coalesce(v_contesto_ordine->>'confermato','false')='true' then
      v_esito_ordine := private.conferma_ordine_evento_verificato(new.id)->'avanzamento';
    else
    v_esito_ordine := public.conferma_ordine_da_keplero($new$;
 if strpos(v_def,v_originale)=0 then raise exception 'Chiamata conferma intake inattesa'; end if;
 v_def:=replace(v_def,v_originale,v_nuovo);
 v_originale:=$old$    if coalesce(v_esito_ordine ->> 'motivo', '') in ($old$;
 if strpos(v_def,v_originale)=0 then raise exception 'Esito intake inatteso'; end if;
 v_def:=replace(v_def,v_originale,E'    end if;\n\n'||v_originale);
 execute v_def;
end;
$patch$;

-- Le informazioni logistiche successive non cancellano la prova di conferma.
create or replace function public.esito_ordine_contestuale_keplero(p_pratica_id uuid,p_external_key text)
returns jsonb language sql stable security definer set search_path = '' as $function$
select coalesce((
 select jsonb_build_object('confermato',p.stato_commerciale::text='ordine_acquisito',
  'stato_commerciale',p.stato_commerciale,'stato_fatturazione',p.stato_fatturazione,
  'contesto',ep.decisione->'contesto_ordine','avanzamento',ep.decisione->'esito_ordine',
  'messaggio',coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio'))
 from public.pratiche p
 join lateral(select e.* from public.keplero_live_events e
  join private.keplero_event_processing ep on ep.event_id=e.id
  where e.pratica_id=p.id and e.external_key=p_external_key
   and ep.decisione#>>'{contesto_ordine,confermato}'='true'
  order by e.id desc limit 1) e on true
 join private.keplero_event_processing ep on ep.event_id=e.id
 where p.id=p_pratica_id and exists(select 1 from public.keplero_live_links l
  where l.pratica_id=p.id and l.external_key=p_external_key)
),'{"confermato":false}'::jsonb);
$function$;

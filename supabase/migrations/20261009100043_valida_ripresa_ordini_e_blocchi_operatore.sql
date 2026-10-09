-- Validazione della ripresa e protezioni comuni a trigger e HTTP.
create or replace function private.recupera_ordini_contestuali_keplero()
returns jsonb language plpgsql set search_path = '' as $function$
declare v_evento record; v_result jsonb; v_recuperati integer:=0;
begin
 if not pg_try_advisory_xact_lock(20261008,1113) then
  return jsonb_build_object('esito','gia_in_esecuzione'); end if;
 for v_evento in
  select distinct on (p.id) e.*
  from public.pratiche p join public.keplero_live_events e on e.pratica_id=p.id
  where e.created_at>=private.inizio_finestra_controllo_keplero(now(),48)
   and p.tipo_flusso::text='commerciale'
   and p.stato_commerciale::text in ('preventivo_inviato','attesa_cliente')
   and p.stato_fatturazione::text not in ('da_fatturare','fatturato') and not p.blocco_operatore
   and (private.ordine_da_conferma_letterale(e.id)->>'confermato'='true'
    or private.ordine_da_scelta_e_fiscali(e.id)->>'confermato'='true')
  order by p.id,(private.ordine_da_conferma_letterale(e.id)->>'confermato'='true') desc nulls last,e.id desc
  limit 100
 loop
  begin
   v_result:=private.conferma_ordine_evento_verificato(v_evento.id);
   if v_result#>>'{contesto,confermato}'<>'true' then continue; end if;
   insert into private.keplero_event_processing(event_id,pratica_id,versione_regole,stato,decisione,elaborato_at,updated_at)
   values(v_evento.id,v_evento.pratica_id,'2026-10-09-ordini-v3','elaborato',
    jsonb_build_object('contesto_ordine',v_result->'contesto','esito_ordine',v_result->'avanzamento',
      'recupero_ordine_contestuale_at',now()),now(),now())
   on conflict(event_id) do update set
    decisione=coalesce(private.keplero_event_processing.decisione,'{}'::jsonb)||excluded.decisione,
    errore=null,stato=case when private.keplero_event_processing.stato='errore' then 'elaborato'
      else private.keplero_event_processing.stato end,
    tentativi=private.keplero_event_processing.tentativi+1,elaborato_at=now(),updated_at=now();
   if v_result#>>'{avanzamento,aggiornato}'='true' then v_recuperati:=v_recuperati+1; end if;
  exception when others then
   insert into private.keplero_event_processing(event_id,pratica_id,versione_regole,stato,decisione,errore)
   values(v_evento.id,v_evento.pratica_id,'2026-10-09-ordini-v3','errore','{}'::jsonb,sqlerrm)
   on conflict(event_id) do update set stato='errore',errore=excluded.errore,
    tentativi=private.keplero_event_processing.tentativi+1,updated_at=now();
  end;
 end loop;
 return jsonb_build_object('esito','completato','recuperati',v_recuperati);
end;
$function$;

-- Domande su come accettare non generano neppure una falsa segnalazione.
do $patch$
declare v_def text; v_old text;
begin
 v_def:=pg_get_functiondef('private.evidenza_accettazione_controllo(text)'::regprocedure);
 v_old:=$old$ and lower(coalesce(p_testo,'')) !~$old$;
 if strpos(v_def,v_old)=0 then raise exception 'Evidenza indipendente inattesa'; end if;
 execute replace(v_def,v_old,E' and not private.domanda_su_accettazione(p_testo)\n'||v_old);
end;
$patch$;

-- Anche la chiamata HTTP diretta rispetta il blocco dell'operatore.
do $patch$
declare v_def text; v_old text; v_new text;
begin
 v_def:=pg_get_functiondef('public.conferma_ordine_da_keplero(uuid,text,text)'::regprocedure);
 v_old:=$old$  if private.domanda_su_accettazione(p_messaggio_cliente)$old$;
 v_new:=$new$  if v_prima.blocco_operatore then
    return jsonb_build_object('aggiornato',false,'motivo','blocco_operatore','pratica_id',p_pratica_id);
  end if;
  if exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
    and c.telefono_normalizzato=regexp_replace(coalesce(v_prima.telefono,''),'[^0-9]','','g')) then
    return jsonb_build_object('aggiornato',false,'motivo','contatto_operativo','pratica_id',p_pratica_id);
  end if;

  if private.domanda_su_accettazione(p_messaggio_cliente)$new$;
 if strpos(v_def,v_old)=0 then raise exception 'Conferma diretta inattesa'; end if;
 execute replace(v_def,v_old,v_new);
end;
$patch$;


-- Manteniamo la finestra massima di 48 ore lavorative, senza sabato/domenica.
-- Il recupero cerca la conferma nella cronologia, anche se l'ultimo messaggio
-- riguarda GLS o completa i dati cliente. I candidati invalidi non oscurano
-- una conferma precedente valida della stessa offerta.
create or replace function private.recupera_ordini_contestuali_keplero()
returns jsonb language plpgsql set search_path = '' as $function$
declare e record; v_result jsonb; v_recuperati integer:=0;
begin
 if not pg_try_advisory_xact_lock(20261008,1113) then
  return jsonb_build_object('esito','gia_in_esecuzione'); end if;
 for e in
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
   v_result:=private.conferma_ordine_evento_verificato(e.id);
   if v_result#>>'{contesto,confermato}'<>'true' then continue; end if;
   insert into private.keplero_event_processing(event_id,pratica_id,versione_regole,stato,decisione,elaborato_at,updated_at)
   values(e.id,e.pratica_id,'2026-10-09-ordini-v3','elaborato',
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
   values(e.id,e.pratica_id,'2026-10-09-ordini-v3','errore','{}'::jsonb,sqlerrm)
   on conflict(event_id) do update set stato='errore',errore=excluded.errore,
    tentativi=private.keplero_event_processing.tentativi+1,updated_at=now();
  end;
 end loop;
 return jsonb_build_object('esito','completato','recuperati',v_recuperati);
end;
$function$;

-- Il controllo di verifica usa anche segnali più ampi del classificatore.
-- Un'espressione nuova o un pagamento non bastano ad acquisire un ordine:
-- producono una segnalazione verificabile con il messaggio originale.
do $patch$
declare v_def text; v_fin text:=E'\n;\n$function$'; v_aggiunta text;
begin
 v_def:=regexp_replace(pg_get_functiondef('private.candidati_coerenza_keplero()'::regprocedure),'[[:space:]]+$','');
 if right(v_def,length(v_fin))<>v_fin then raise exception 'Definizione controllo inattesa'; end if;
 v_aggiunta:=$addition$
union all
select distinct on (p.id) 'scelta_offerta:'||p.id,p.id,e.id,'scelta_offerta_senza_ordine',
 'Scelta o approvazione della proposta dopo il preventivo, ma ordine non acquisito. Verificare la conferma e il collegamento alla pratica.',left(e.testo,600)
from pratiche p join eventi e on e.pratica_id=p.id
where p.tipo_flusso::text='commerciale'
 and p.stato_commerciale::text<>'ordine_acquisito'
 and p.stato_fatturazione::text not in ('da_fatturare','fatturato')
 and greatest(p.ultimo_preventivo_at,p.preventivo_inviato_at) is not null
 and e.created_at>=greatest(p.ultimo_preventivo_at,p.preventivo_inviato_at)
 and e.testo ~ '(\m(opzione|proposta|offerta|preventivo)\M.{0,80}(scelt|confermat|accettat|approvat)|\m(scelg|scegli|scelt|va bene|sta bene|conferm|accett|approv).{0,80}\m(opzione|proposta|offerta|preventivo)\M|\mpratica confermata\M)'
 and not private.domanda_su_accettazione(e.testo)
 and not private.rinvio_conferma_per_verifiche(e.testo)
 and e.testo !~ '(non.{0,30}(accett|conferm|approv|proced|scegli|scelg|va bene|sta bene)|\m(se|qualora)\M|valutare|valutando|ci penso|forse)'
 and not exists(select 1 from public.keplero_live_events r where r.pratica_id=p.id and r.id>e.id
  and private.revoca_scelta_cliente(coalesce(r.payload->>'ultimo_messaggio_cliente',r.payload->>'messaggio_cliente',r.payload->>'messaggio','')))
union all
select distinct on (p.id) 'pagamento_ordine:'||p.id,p.id,e.id,'pagamento_senza_ordine',
 'Pagamento comunicato dopo il preventivo, ma ordine non acquisito. Verificare conferma, lavorazione e documenti; il pagamento non acquisisce automaticamente l’ordine.',left(e.testo,600)
from pratiche p join eventi e on e.pratica_id=p.id
where p.tipo_flusso::text='commerciale'
 and p.stato_commerciale::text in ('preventivo_inviato','attesa_cliente')
 and p.stato_fatturazione::text not in ('da_fatturare','fatturato')
 and greatest(p.ultimo_preventivo_at,p.preventivo_inviato_at) is not null
 and e.created_at>=greatest(p.ultimo_preventivo_at,p.preventivo_inviato_at)
 and e.testo ~ '(\m(bonifico|pagamento|saldo)\M.{0,40}\m(fatto|effettuat|eseguit|inviat)|\m(ho|abbiamo)\M.{0,30}\m(pagato|saldato)\M)'
 and e.testo !~ '(\m(non|se|domani|quando)\M|faro|farò|provvedo|provveder)'
$addition$;
 execute left(v_def,length(v_def)-length(v_fin))||v_aggiunta||v_fin;
end;
$patch$;

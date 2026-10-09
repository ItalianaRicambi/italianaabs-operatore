-- La scelta inequivocabile dell'offerta acquisisce l'ordine prima dei dati fiscali.
-- Il gate amministrativo resta distinto e continua a bloccare la fatturazione.
create or replace function private.conferma_letterale_offerta(p_testo text)
returns boolean language sql immutable set search_path = '' as $function$
select (
 lower(coalesce(p_testo,'')) ~ '\m(mi|ci)[[:space:]]+sta[[:space:]]+bene\M.{0,55}\m(proposta|offerta|opzione|preventivo)\M'
 or lower(coalesce(p_testo,'')) ~ '\m(scelgo|scegliamo|ho scelto|abbiamo scelto|ho deciso per|abbiamo deciso per|preferisco|preferiamo)\M.{0,65}\m(opzione|proposta|offerta|preventivo|revisione|riparazione|programma scambio)\M'
 or lower(coalesce(p_testo,'')) ~ '\mpratica[[:space:]]+confermata\M'
 or lower(coalesce(p_testo,'')) ~ '\m(vorrei|voglio|vogliamo)[[:space:]]+(revisionare|riparare)\M'
 or lower(coalesce(p_testo,'')) ~ '\m(accetto|accettiamo|confermo|confermiamo|approvo|approviamo)\M.{0,45}\m(preventivo|offerta|ordine|lavorazione|riparazione)\M'
)
and not private.domanda_su_accettazione(p_testo)
and not private.rinvio_conferma_per_verifiche(p_testo)
and lower(coalesce(p_testo,'')) !~ '(non.{0,30}(accett|conferm|approv|proced|scegli|scelg|va bene|mi sta bene|vogli|vorrei|revision|ripar)|rifiut|annull|ci penso|devo valutare|dobbiamo valutare|valutando|pensando|preferirei|sceglierei|sceglieremmo|forse|eventualmente|vi faccio sapere|le faccio sapere|\m(se|qualora)\M.{0,60}(accett|conferm|approv|proced|scegli|scelg|opzione|proposta|riparabile|possibile))'
and lower(btrim(coalesce(p_testo,''))) !~ '^(?:(?:buongiorno|buonasera|ciao|ok)[,!. ]*)?(?:posso|possiamo|potrei|potremmo|vorrei sapere|(e|è) possibile)\M.{0,60}\m(scegli|scelg|accett|conferm|revision|ripar)';
$function$;

create or replace function private.ordine_da_conferma_letterale(p_event_id bigint)
returns jsonb language plpgsql stable set search_path = '' as $function$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype;
 v_quote_at timestamptz; v_testo text;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id;
 if not found or p.tipo_flusso::text<>'commerciale'
  or p.stato_commerciale::text not in ('preventivo_inviato','attesa_cliente')
  or p.stato_fatturazione::text in ('da_fatturare','fatturato') or p.blocco_operatore
  or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true'
 then return '{}'::jsonb; end if;
 if not exists(select 1 from public.keplero_live_links l
   where l.pratica_id=p.id and l.external_key=e.external_key)
  or nullif(p.targa,'') is null
  or upper(regexp_replace(coalesce(e.payload->>'targa',''),'[^A-Za-z0-9]','','g'))<>
     upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))
  or exists(select 1 from public.contatti_operativi c where c.attivo
   and c.blocca_automazioni_commerciali and c.telefono_normalizzato=
    regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g'))
 then return '{}'::jsonb; end if;
 select greatest(p.preventivo_inviato_at,max(pv.inviato_at)) into v_quote_at
  from public.preventivi pv where pv.pratica_id=p.id and pv.stato in ('inviato','accettato');
 if v_quote_at is null or e.created_at<v_quote_at then return '{}'::jsonb; end if;
 v_testo:=coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio','');
 if not private.conferma_letterale_offerta(v_testo)
  or exists(select 1 from public.keplero_live_events r where r.pratica_id=p.id and r.id>e.id
    and private.revoca_scelta_cliente(coalesce(r.payload->>'ultimo_messaggio_cliente',
      r.payload->>'messaggio_cliente',r.payload->>'messaggio','')))
 then return '{}'::jsonb; end if;
 return jsonb_build_object('confermato',true,'regola','conferma_letterale_offerta_v1',
  'evento_conferma',e.id,'confermata_at',e.created_at,'preventivo_inviato_at',v_quote_at);
end;
$function$;

revoke all on function private.conferma_letterale_offerta(text),
 private.ordine_da_conferma_letterale(bigint) from public,anon,authenticated;
grant execute on function private.conferma_letterale_offerta(text),
 private.ordine_da_conferma_letterale(bigint) to service_role;

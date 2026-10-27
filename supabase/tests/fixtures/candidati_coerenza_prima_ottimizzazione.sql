CREATE OR REPLACE FUNCTION private.candidati_coerenza_keplero()
 RETURNS TABLE(chiave text, pratica_id uuid, event_id bigint, regola text, descrizione text, evidenza text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
with eventi as (
  select e.*, lower(trim(coalesce(e.payload->>'ultimo_messaggio_cliente', e.payload->>'messaggio_cliente', e.payload->>'messaggio', ''))) as testo
  from public.keplero_live_events e
  where e.created_at >= private.inizio_finestra_controllo_keplero(now(),48)
    and e.created_at < now() - interval '10 minutes'
), ultime as (
  select distinct on (e.pratica_id) e.* from eventi e
  where e.pratica_id is not null order by e.pratica_id, e.id desc
), pratiche as (
  select p.*, q.inviato_at as ultimo_preventivo_at
  from public.pratiche p
  left join lateral (
    select max(coalesce(pv.inviato_at,pv.creato_at)) inviato_at
    from public.preventivi pv where pv.pratica_id=p.id and pv.stato in ('inviato','accettato')
  ) q on true
  where coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
    and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
    and p.stato_commerciale::text not in ('rifiutato','chiuso')
    and not exists (
      select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
      and c.telefono_normalizzato = regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g')
    )
), conferme as (
  select distinct on (p.id) p.id pratica_id,e.id event_id,e.testo
  from pratiche p join eventi e on e.pratica_id=p.id
  where p.tipo_flusso::text='commerciale'
    and p.stato_commerciale::text <> 'ordine_acquisito'
    and p.stato_fatturazione::text not in ('fatturato','da_fatturare')
    and coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at) is not null
    and e.created_at >= coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at)
    and private.evidenza_accettazione_controllo(e.testo)
    and not private.rinvio_conferma_per_verifiche(e.testo)
    -- Una revoca successiva sospende la segnalazione della vecchia accettazione.
    and not exists (select 1 from eventi r where r.pratica_id=p.id and r.id>e.id
      and private.revoca_scelta_cliente(r.testo))
  order by p.id,e.id desc
), contestuali as (
  select distinct on (p.id) p.id pratica_id,e.id event_id,e.testo
  from pratiche p join eventi e on e.pratica_id=p.id
  where p.tipo_flusso::text='commerciale'
    and p.stato_commerciale::text in ('preventivo_inviato','attesa_cliente')
    and p.stato_fatturazione::text not in ('fatturato','da_fatturare')
    and coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at) is not null
    and e.created_at >= coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at)
    and e.testo ~ '^programma scambio[.! ]*$'
    and exists (select 1 from eventi a where a.pratica_id=p.id and a.id<=e.id
      and a.created_at>=coalesce(p.ultimo_preventivo_at,p.preventivo_inviato_at)
      and a.created_at >= private.inizio_finestra_controllo_keplero(e.created_at,24)
      and a.testo ~ '\m(compro|acquisto|compriamo|acquistiamo)\M'
      and a.testo !~ '(non[[:space:]]+((lo|la)[[:space:]]+)?(compr|acquist)|\mse\M|forse|valutare)')
    and not exists (select 1 from eventi r where r.pratica_id=p.id and r.id>e.id and r.testo ~ '(rifiut|annull|non.{0,25}(accett|compr|acquist))')
  order by p.id,e.id desc
)
select 'ordine:'||c.pratica_id,c.pratica_id,c.event_id,'ordine_non_acquisito',
  'Accettazione letterale dopo il preventivo, ma ordine non acquisito. Verificare offerta e pratica prima di confermare.', left(c.testo,600) from conferme c
union all
select 'contesto:'||c.pratica_id,c.pratica_id,c.event_id,'acquisto_da_verificare',
  'Intenzione di acquisto e scelta Programma Scambio nella stessa pratica. Accettazione da verificare nel contesto.',left(c.testo,600) from contestuali c
union all
select 'completezza:'||p.id,p.id,e.id,'richiesta_completa_non_in_coda',
  'Dati tecnici presenti, ma pratica ancora fuori dalla coda Da preventivare. Verificare eventuali blocchi operatore.',left(e.testo,600)
from pratiche p join ultime e on e.pratica_id=p.id
where p.tipo_flusso::text='commerciale' and p.stato_commerciale::text in ('nuova','raccolta_dati')
  and nullif(trim(p.targa),'') is not null and nullif(trim(p.descrizione_guasto),'') is not null
  and (exists(select 1 from public.codici_identificativi c where c.pratica_id=p.id and nullif(trim(c.codice),'') is not null)
       or exists(select 1 from public.allegati a where a.pratica_id=p.id and nullif(a.url,'') is not null))
  and (p.spie_accese=false or (p.spie_accese=true and exists(select 1 from public.dtc d where d.pratica_id=p.id)))
  and p.ultimo_preventivo_at is null and p.preventivo_inviato_at is null
union all
select 'preventivo:'||p.id,p.id,e.id,'preventivo_non_allineato',
  'Preventivo registrato come inviato, ma pratica ancora in una fase precedente.',left(e.testo,600)
from pratiche p join ultime e on e.pratica_id=p.id
where p.ultimo_preventivo_at is not null and p.stato_commerciale::text in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto')
  and p.stato_fatturazione::text not in ('fatturato','da_fatturare')
union all
select 'allegati:'||p.id,p.id,e.id,'allegati_non_disponibili',
  'K dichiara documenti o immagini senza trasmettere i file. Verificare la conversazione originale.',left(e.testo,600)
from pratiche p join ultime e on e.pratica_id=p.id
where (e.payload->>'allegati_descritti_ma_non_trasmessi'='true' or e.payload->>'stato_lettura_immagini'='file_non_trasmessi_da_keplero')
  and not exists(select 1 from public.allegati a where a.pratica_id=p.id and a.created_at>=e.created_at)
union all
select 'evento:'||e.id,e.pratica_id,e.id,'evento_senza_pratica',
  'Evento ricevuto senza collegamento a una pratica.',left(e.testo,600)
from eventi e where e.pratica_id is null
  and coalesce(e.payload->>'instradamento_sospeso','false') <> 'true'
union all
select 'errore:'||e.id,e.pratica_id,e.id,'errore_elaborazione',
  'Errore nel motore eventi: '||left(coalesce(ep.errore,''),250),left(e.testo,600)
from eventi e join private.keplero_event_processing ep on ep.event_id=e.id where ep.stato='errore'
union all
select 'sospeso:'||e.external_key||':'||md5(coalesce(e.payload->>'marca_veicolo','')||':'||coalesce(e.payload->>'modello_veicolo','')),
  null::uuid,e.id,'nuovo_veicolo_senza_targa',
  'Invio ricevuto ma nuova pratica sospesa: manca la targa. Verificare la conversazione.',left(e.testo,600)
from (select distinct on (external_key,payload->>'marca_veicolo',payload->>'modello_veicolo') *
  from eventi where pratica_id is null and payload->>'instradamento_sospeso'='true'
  order by external_key,payload->>'marca_veicolo',payload->>'modello_veicolo',id desc) e
union all
select distinct on (e.pratica_id) 'scelta_fiscali:'||e.pratica_id,e.pratica_id,e.id,
  'ordine_contestuale_non_acquisito',
  'Scelta di lavorazione seguita da dati fiscali dopo il preventivo, ma ordine non acquisito.',left(e.testo,600)
from eventi e join pratiche p on p.id=e.pratica_id
where private.ordine_da_scelta_e_fiscali(e.id)->>'confermato'='true'
  and not exists (select 1 from eventi r where r.pratica_id=e.pratica_id and r.id>e.id
    and private.revoca_scelta_cliente(r.testo))
union all
select 'pdf_preventivo:'||d.external_id,d.pratica_id,null::bigint,'preventivo_pdf_non_abbinato',
  'PDF ricevuto ma non registrato sulla pratica: '||replace(d.esito,'_',' ')||'.',
  d.nome_file||' | Targa: '||d.targa||' | Data offerta: '||to_char(d.data_offerta at time zone 'Europe/Rome','DD/MM/YYYY HH24:MI')||' | '||coalesce(d.file_url,'')
from public.preventivi_emessi_ricevuti d
where d.risolto_at is null and d.ricevuto_at < now()-interval '10 minutes'
union all
-- Controllo indipendente dal riconoscimento dell'intenzione: segnala anche
-- formulazioni nuove quando i dati fiscali arrivano dopo una vera offerta.
select distinct on (p.id) 'fiscali_dopo_offerta:'||p.id,p.id,e.id,
 'dati_fiscali_senza_ordine',
 'Dati fiscali ricevuti dopo il preventivo ma ordine non acquisito. Verificare la conferma nella conversazione.',
 left(e.testo,600)
from pratiche p join eventi e on e.pratica_id=p.id
where p.tipo_flusso::text='commerciale'
 and p.stato_commerciale::text in ('preventivo_inviato','attesa_cliente')
 and p.stato_fatturazione::text not in ('da_fatturare','fatturato')
 and greatest(p.ultimo_preventivo_at,p.preventivo_inviato_at) is not null
 and e.created_at>=greatest(p.ultimo_preventivo_at,p.preventivo_inviato_at)
 and private.dati_fiscali_cliente(e.testo)
 and not exists(select 1 from eventi r where r.pratica_id=p.id and r.id>=e.id
   and private.revoca_scelta_cliente(r.testo))
union all
select distinct on (p.id) 'fattura_documento:'||p.id,p.id,e.id,
 'fattura_documento_non_allineato',
 'Documento denominato Fattura ricevuto, ma pratica non fatturata. Verificare contenuto, targa e data del PDF prima di allineare.',
 left(e.testo,400)||' | '||coalesce(e.payload->'allegati','[]'::jsonb)::text
from pratiche p join eventi e on e.pratica_id=p.id
where p.tipo_flusso::text='commerciale' and p.stato_fatturazione::text<>'fatturato'
 and exists(
   select 1 from jsonb_array_elements(case when jsonb_typeof(e.payload->'allegati')='array'
     then e.payload->'allegati' else '[]'::jsonb end) a
   where coalesce(a->>'url',a->>'file_url',a#>>'{}','') ~* '(fattura[-_]|fattura%20)'
 )

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

union all select * from private.candidati_flussi_offerta_rientro()
union all select * from private.candidati_errori_flussi()
union all select * from private.candidati_richieste_keplero()
;
$function$

-- L'ultimo messaggio può essere soltanto l'anagrafica dopo la scelta.
-- L'intenzione nel riepilogo diventa operativa solo con dati fiscali letterali,
-- offerta realmente inviata, stessa targa/pratica e nessun rinvio/revoca.
create or replace function private.codice_fiscale_letterale(p_testo text)
returns text language sql immutable security invoker set search_path=''
as $fn$
  select case when count(distinct m[1])=1 then min(m[1]) end
  from regexp_matches(upper(coalesce(p_testo,'')),
    '\m([A-Z]{6}[0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z])\M','g') m
  where lower(coalesce(p_testo,'')) !~ '(esempio|fac.?simile)';
$fn$;

create or replace function private.dati_fiscali_cliente(p_testo text)
returns boolean language sql immutable security invoker set search_path=''
as $fn$
select coalesce(
 p_testo ~* '[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}'
 and (private.codice_fiscale_letterale(p_testo) is not null
      or p_testo ~* '(partita[[:space:]]*iva|p[.]?[[:space:]]*iva)[[:space:]:.]*(IT)?[0-9]{11}\M')
 and lower(p_testo) !~ '(esempio|fac.?simile|annull|non.{0,25}(accett|conferm|proced))',false);
$fn$;

create or replace function private.intenzione_offerta_con_fiscali(p_messaggio text,p_riepilogo text)
returns boolean language sql immutable security invoker set search_path=''
as $fn$
select private.dati_fiscali_cliente(p_messaggio)
 and lower(coalesce(p_riepilogo,'')) ~ '\m(ha ricevuto|ricevut[oa])\M.{0,35}\m(offerta|preventivo)\M'
 and lower(coalesce(p_riepilogo,'')) ~ '\m(intende|vuole|ha deciso di)\M[[:space:]]+procedere\M'
 and not private.revoca_scelta_cliente(p_messaggio)
 and not private.revoca_scelta_cliente(p_riepilogo)
 and lower(coalesce(p_messaggio,'')||' '||coalesce(p_riepilogo,'')) !~
   '(\m(se|forse|eventualmente)\M|valut|in attesa|prima di|confront|dovr[aà]|vorrebbe|intende sapere|non.{0,25}(accett|conferm|proced))';
$fn$;

revoke all on function private.codice_fiscale_letterale(text),
  private.intenzione_offerta_con_fiscali(text,text),private.dati_fiscali_cliente(text)
from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.ordine_da_scelta_e_fiscali(p_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
 v_evento public.keplero_live_events%rowtype;
 v_pratica public.pratiche%rowtype;
 v_scelta public.keplero_live_events%rowtype;
 v_preventivo_at timestamptz;
 v_testo text;
begin
 select * into v_evento from public.keplero_live_events where id=p_event_id;
 if not found or v_evento.pratica_id is null then return '{}'::jsonb; end if;
 select * into v_pratica from public.pratiche where id=v_evento.pratica_id;
 if not found or v_pratica.tipo_flusso::text <> 'commerciale'
    or v_pratica.stato_commerciale::text not in ('preventivo_inviato','attesa_cliente')
    or v_pratica.stato_fatturazione::text in ('da_fatturare','fatturato')
    or v_pratica.blocco_operatore
    or coalesce(v_pratica.dati_raw #>> '{archiviazione_test,archiviata}','false')='true'
    or coalesce(v_pratica.dati_raw #>> '{pratica_duplicata,archiviata}','false')='true'
 then return '{}'::jsonb; end if;
 if not exists(select 1 from public.keplero_live_links l
   where l.pratica_id=v_pratica.id and l.external_key=v_evento.external_key)
 then return '{}'::jsonb; end if;
 -- Il recupero retroattivo non deve riesumare una conferma poi revocata.
 if exists(select 1 from public.keplero_live_events e
   where e.pratica_id=v_pratica.id and e.id>v_evento.id
     and private.revoca_scelta_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
       e.payload->>'messaggio_cliente',e.payload->>'messaggio','')))
 then return '{}'::jsonb; end if;
 if exists (select 1 from public.contatti_operativi c where c.attivo
    and c.blocca_automazioni_commerciali and c.telefono_normalizzato=
      regexp_replace(coalesce(v_pratica.telefono,''),'[^0-9]','','g'))
 then return '{}'::jsonb; end if;

 -- Preferire l'ultimo preventivo: una scelta precedente a una nuova offerta
 -- non autorizza automaticamente l'accettazione della nuova proposta.
 select greatest(v_pratica.preventivo_inviato_at,max(pv.inviato_at))
 into v_preventivo_at from public.preventivi pv
 where pv.pratica_id=v_pratica.id and pv.stato in ('inviato','accettato');
 if v_preventivo_at is null or v_evento.created_at < v_preventivo_at
 then return '{}'::jsonb; end if;
 v_testo := coalesce(v_evento.payload->>'ultimo_messaggio_cliente',
                    v_evento.payload->>'messaggio_cliente',v_evento.payload->>'messaggio','');
 if not private.dati_fiscali_cliente(v_testo)
    or nullif(v_pratica.targa,'') is null
    or upper(regexp_replace(coalesce(v_evento.payload->>'targa',''),'[^A-Za-z0-9]','','g')) <>
       upper(regexp_replace(v_pratica.targa,'[^A-Za-z0-9]','','g'))
 then return '{}'::jsonb; end if;

 select e.* into v_scelta from public.keplero_live_events e
 where e.pratica_id=v_pratica.id and e.external_key=v_evento.external_key
   and e.id<v_evento.id and e.created_at<=v_evento.created_at
   and e.created_at>=v_preventivo_at
   and e.created_at>=private.inizio_finestra_controllo_keplero(v_evento.created_at,48)
   and upper(regexp_replace(coalesce(e.payload->>'targa',''),'[^A-Za-z0-9]','','g')) =
       upper(regexp_replace(v_pratica.targa,'[^A-Za-z0-9]','','g'))
   and private.scelta_lavorazione_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
         e.payload->>'messaggio_cliente',e.payload->>'messaggio',''))
 order by e.created_at desc,e.id desc limit 1;
 if not found then
   if private.intenzione_offerta_con_fiscali(v_testo,coalesce(
        v_evento.payload->>'riepilogo_operativo',
        v_evento.payload->>'descrizione_guasto',
        v_evento.payload->>'richiesta',''))
      and not exists (select 1 from public.keplero_live_events e
        where e.pratica_id=v_pratica.id and e.created_at>=v_preventivo_at
          and e.id<=v_evento.id
          and private.revoca_scelta_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
            e.payload->>'messaggio_cliente',e.payload->>'messaggio','')))
   then
     return jsonb_build_object('confermato',true,
       'regola','intenzione_offerta_e_dati_fiscali_v1','evento_dati_fiscali',v_evento.id);
   end if;
   return '{}'::jsonb;
 end if;
 if exists (select 1 from public.keplero_live_events e
   where e.pratica_id=v_pratica.id and e.id>v_scelta.id
     and e.created_at>=v_scelta.created_at
     and e.created_at<=v_evento.created_at and e.id<=v_evento.id
     and private.revoca_scelta_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
       e.payload->>'messaggio_cliente',e.payload->>'messaggio','')))
 then return '{}'::jsonb; end if;
 return jsonb_build_object('confermato',true,'regola','scelta_lavorazione_e_dati_fiscali_v1',
   'evento_scelta',v_scelta.id,'evento_dati_fiscali',v_evento.id);
end;
$function$;

-- Un CF letterale non richiede l'etichetta "codice fiscale".
-- Manteniamo firma e protezioni dell'intake; arresto se il blocco è inatteso.
do $patch$
declare v_def text; v_vecchio text; v_nuovo text;
begin
 select pg_get_functiondef(p.oid) into strict v_def
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='upsert_keplero_live';
 v_vecchio := $old$  if lower(coalesce(p_ultimo_messaggio_cliente, '')) ~ 'codice[[:space:]_-]*fiscale|c[.]?[[:space:]]*f[.]?' then
    v_codice_fiscale := upper(substring(
      coalesce(p_ultimo_messaggio_cliente, '')
      from '([A-Za-z]{6}[0-9]{2}[A-Za-z][0-9]{2}[A-Za-z][0-9]{3}[A-Za-z])'
    ));
  end if;$old$;
 v_nuovo := '  v_codice_fiscale := private.codice_fiscale_letterale(p_ultimo_messaggio_cliente);';
 if position(v_vecchio in v_def)=0 then raise exception 'Estrattore CF inatteso: modifica non applicata'; end if;
 execute replace(v_def,v_vecchio,v_nuovo);
end;
$patch$;

-- Leggiamo l'esito del trigger, anche quando il parser HTTP non rileva l'ordine.
create or replace function public.esito_ordine_contestuale_keplero(p_pratica_id uuid,p_external_key text)
returns jsonb language sql stable security invoker set search_path=''
as $fn$
select coalesce((
 select jsonb_build_object(
   'confermato',coalesce(ep.decisione#>>'{contesto_ordine,confermato}','false')='true'
     and p.stato_commerciale::text='ordine_acquisito',
   'stato_commerciale',p.stato_commerciale,
   'stato_fatturazione',p.stato_fatturazione,
   'contesto',coalesce(ep.decisione->'contesto_ordine','{}'::jsonb),
   'avanzamento',coalesce(ep.decisione->'esito_ordine','{}'::jsonb),
   'messaggio',e.payload->>'ultimo_messaggio_cliente')
 from public.pratiche p
 join lateral(select * from public.keplero_live_events e
   where e.pratica_id=p.id and e.external_key=p_external_key
   order by e.id desc limit 1) e on true
 join private.keplero_event_processing ep on ep.event_id=e.id
 where p.id=p_pratica_id and exists(select 1 from public.keplero_live_links l
   where l.pratica_id=p.id and l.external_key=p_external_key)
),'{"confermato":false}'::jsonb);
$fn$;
revoke all on function public.esito_ordine_contestuale_keplero(uuid,text) from public,anon,authenticated;
grant execute on function public.esito_ordine_contestuale_keplero(uuid,text) to service_role;

create or replace function private.recupera_ordini_contestuali_keplero()
returns jsonb language plpgsql security invoker set search_path=''
as $fn$
declare v_evento record; v_contesto jsonb; v_esito jsonb; v_recuperati integer:=0;
begin
 if not pg_try_advisory_xact_lock(20261008,1113) then
   return jsonb_build_object('esito','gia_in_esecuzione');
 end if;
 for v_evento in
   select distinct on (p.id) e.*
   from public.pratiche p join public.keplero_live_events e on e.pratica_id=p.id
   where e.created_at >= private.inizio_finestra_controllo_keplero(now(),48)
     and p.tipo_flusso::text='commerciale'
     and p.stato_commerciale::text in ('preventivo_inviato','attesa_cliente')
     and p.stato_fatturazione::text not in ('da_fatturare','fatturato')
     and not p.blocco_operatore
     and private.dati_fiscali_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
       e.payload->>'messaggio_cliente',e.payload->>'messaggio',''))
   order by p.id,e.id desc limit 100
 loop
   begin
     v_contesto:=private.ordine_da_scelta_e_fiscali(v_evento.id);
     if coalesce(v_contesto->>'confermato','false')<>'true' then continue; end if;
     v_esito:=public.conferma_ordine_da_keplero(v_evento.pratica_id,v_evento.external_key,
       v_evento.payload->>'ultimo_messaggio_cliente');
     update private.keplero_event_processing set
       decisione=decisione||jsonb_build_object('contesto_ordine',v_contesto,
         'esito_ordine',v_esito,'recupero_ordine_contestuale_at',now()),
       updated_at=now()
     where event_id=v_evento.id;
     if coalesce(v_esito->>'aggiornato','false')='true' then
       v_recuperati:=v_recuperati+1;
     end if;
   exception when others then
     update private.keplero_event_processing set stato='errore',errore=sqlerrm,updated_at=now()
       where event_id=v_evento.id;
   end;
 end loop;
 return jsonb_build_object('esito','completato','recuperati',v_recuperati);
end;
$fn$;
revoke all on function private.recupera_ordini_contestuali_keplero() from public,anon,authenticated;

select cron.schedule('recupera-ordini-contestuali-keplero','*/5 * * * *',
 'select private.recupera_ordini_contestuali_keplero(); select private.controlla_coerenza_keplero();');

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
;
$function$;

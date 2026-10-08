-- I PDF non abbinati restano persistiti, vengono ritentati e compaiono nel controllo.
create table public.preventivi_emessi_ricevuti (
  external_id text primary key,
  nome_file text not null,
  targa text not null,
  file_url text,
  data_offerta timestamptz not null,
  inviato_at timestamptz not null,
  ricevuto_at timestamptz not null default now(),
  ultimo_tentativo_at timestamptz,
  tentativi integer not null default 0,
  esito text not null default 'ricevuto',
  risultato jsonb not null default '{}'::jsonb,
  pratica_id uuid references public.pratiche(id) on delete set null,
  risolto_at timestamptz
);
alter table public.preventivi_emessi_ricevuti enable row level security;
revoke all on public.preventivi_emessi_ricevuti from public, anon, authenticated;
grant select, insert, update on public.preventivi_emessi_ricevuti to service_role;
create index preventivi_emessi_da_ritentare
  on public.preventivi_emessi_ricevuti (ultimo_tentativo_at, ricevuto_at)
  where risolto_at is null;

create function private.abbina_preventivo_emesso(
  p_external_id text, p_nome_file text, p_targa text, p_file_url text,
  p_data_offerta timestamptz, p_inviato_at timestamptz
) returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_preventivo_id uuid;
  v_pratica_id uuid;
  v_candidati integer;
  v_pr public.pratiche%rowtype;
begin
  select id, pratica_id into v_preventivo_id, v_pratica_id
  from public.preventivi where external_id = p_external_id limit 1;
  if v_preventivo_id is not null then
    return jsonb_build_object('aggiornato', false, 'esito', 'gia_registrato',
      'preventivo_id', v_preventivo_id, 'pratica_id', v_pratica_id, 'targa', p_targa);
  end if;

  select count(*), (array_agg(p.id order by p.created_at))[1]
    into v_candidati, v_pratica_id
  from public.pratiche p
  where upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) = p_targa
    and p.tipo_flusso = 'commerciale'
    and p.stato_commerciale not in ('ordine_acquisito','perso','chiuso','rifiutato')
    and p.stato_fatturazione = 'non_applicabile'
    -- Un'offerta precedente alla nuova pratica non prova l'invio per quella pratica.
    and p.created_at <= p_data_offerta + interval '5 minutes'
    and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}','false') <> 'true'
    and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}','false') <> 'true';

  if v_candidati <> 1 then
    return jsonb_build_object('aggiornato',false,'esito',
      case when v_candidati = 0 then 'nessuna_pratica_compatibile' else 'pratica_ambigua' end,
      'targa',p_targa,'candidati',v_candidati);
  end if;

  select * into v_pr from public.pratiche where id = v_pratica_id for update;
  if v_pr.tipo_flusso <> 'commerciale'
    or v_pr.stato_commerciale in ('ordine_acquisito','perso','chiuso','rifiutato')
    or v_pr.stato_fatturazione <> 'non_applicabile'
    or upper(regexp_replace(coalesce(v_pr.targa,''),'[^A-Za-z0-9]','','g')) <> p_targa
    or coalesce(v_pr.dati_raw #>> '{archiviazione_test,archiviata}','false') = 'true'
    or coalesce(v_pr.dati_raw #>> '{pratica_duplicata,archiviata}','false') = 'true'
  then
    return jsonb_build_object('aggiornato',false,'esito','pratica_non_compatibile',
      'pratica_id',v_pr.id,'numero_pratica',v_pr.numero_pratica,'targa',p_targa);
  end if;

  if exists (
    select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
      and c.telefono_normalizzato = regexp_replace(coalesce(v_pr.telefono,''),'[^0-9]','','g')
  ) or ((coalesce(v_pr.blocco_operatore,false) or coalesce(v_pr.blocco_classificazione_operatore,false))
    and v_pr.stato_commerciale not in ('preventivo_inviato','attesa_cliente'))
  then
    return jsonb_build_object('aggiornato',false,'esito','blocco_operatore',
      'pratica_id',v_pr.id,'numero_pratica',v_pr.numero_pratica,'targa',p_targa);
  end if;

  insert into public.preventivi (
    pratica_id,external_id,stato,file_url,creato_at,inviato_at,note
  ) values (
    v_pr.id,p_external_id,'inviato',p_file_url,p_data_offerta,p_inviato_at,
    'routine_controllo_k | Preventivo riconosciuto dal PDF: ' || p_nome_file ||
    case when p_data_offerta < now() - interval '30 days'
      then ' | preventivo storico: validità commerciale da riconfermare' else '' end
  ) returning id into v_preventivo_id;

  -- Le fasi già avanzate e le decisioni manuali restano preservate.
  if v_pr.stato_commerciale not in ('preventivo_inviato','attesa_cliente') then
    update public.pratiche set
      stato_commerciale = 'preventivo_inviato',
      stato_completezza = 'completa_da_preventivare',
      preventivo_inviato_at = coalesce(preventivo_inviato_at,p_inviato_at),
      nota_incompletezza = case when p_data_offerta < now() - interval '30 days'
        then 'Preventivo storico trovato; validità e condizioni da riconfermare prima di procedere.'
        else null end
    where id = v_pr.id;
  end if;

  insert into public.azioni_operatore (pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  select p.id,'preventivo_emesso_automatico',
    'routine_controllo_k | PDF riconosciuto: ' || p_nome_file,
    jsonb_build_object('stato_commerciale',v_pr.stato_commerciale),
    jsonb_build_object('stato_commerciale',p.stato_commerciale,
      'preventivo_id',v_preventivo_id,'external_id',p_external_id),
    'routine_controllo_k'
  from public.pratiche p where p.id = v_pr.id;

  return jsonb_build_object('aggiornato',true,'esito','preventivo_inviato',
    'preventivo_id',v_preventivo_id,'pratica_id',v_pr.id,
    'numero_pratica',v_pr.numero_pratica,'targa',p_targa);
end;
$fn$;
revoke all on function private.abbina_preventivo_emesso(text,text,text,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function private.abbina_preventivo_emesso(text,text,text,text,timestamptz,timestamptz) to service_role;

create or replace function public.registra_preventivo_emesso_auto(
  p_external_id text, p_nome_file text, p_targa text, p_file_url text,
  p_data_offerta timestamptz, p_inviato_at timestamptz default now()
) returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_id text := nullif(btrim(p_external_id),'');
  v_nome text := btrim(coalesce(p_nome_file,''));
  v_targa text := upper(regexp_replace(coalesce(p_targa,''),'[^A-Za-z0-9]','','g'));
  v_data timestamptz := coalesce(p_data_offerta,p_inviato_at,now());
  v_ricevuto public.preventivi_emessi_ricevuti%rowtype;
  v_result jsonb;
begin
  if v_id is null then raise exception 'external_id obbligatorio'; end if;
  if v_nome !~* '\.pdf$' or v_targa !~ '^[A-Z0-9]{4,12}$'
    or v_targa <> upper(regexp_replace(regexp_replace(v_nome,'\.pdf$','','i'),'[^A-Za-z0-9]','','g'))
  then return jsonb_build_object('aggiornato',false,'esito','nome_file_non_valido','targa',v_targa);
  end if;
  if v_data > now() + interval '1 day' then
    return jsonb_build_object('aggiornato',false,'esito','data_offerta_futura','targa',v_targa);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_id,0));
  insert into public.preventivi_emessi_ricevuti (external_id,nome_file,targa,file_url,data_offerta,inviato_at)
  values (v_id,v_nome,v_targa,nullif(btrim(p_file_url),''),v_data,coalesce(p_inviato_at,v_data))
  on conflict(external_id) do nothing;
  select * into v_ricevuto from public.preventivi_emessi_ricevuti where external_id=v_id for update;
  if v_ricevuto.targa <> v_targa then
    return jsonb_build_object('aggiornato',false,'esito','external_id_in_conflitto','ricevuto',true,'targa',v_targa);
  end if;
  v_result := private.abbina_preventivo_emesso(v_id,v_ricevuto.nome_file,v_ricevuto.targa,
    v_ricevuto.file_url,v_ricevuto.data_offerta,v_ricevuto.inviato_at);
  update public.preventivi_emessi_ricevuti set
    ultimo_tentativo_at=now(),tentativi=tentativi+1,esito=v_result->>'esito',risultato=v_result,
    pratica_id=(v_result->>'pratica_id')::uuid,
    risolto_at=case when v_result->>'aggiornato'='true' or v_result->>'esito'='gia_registrato' then now() else null end
  where external_id=v_id;
  return v_result || jsonb_build_object('ricevuto',true);
end;
$fn$;
revoke all on function public.registra_preventivo_emesso_auto(text,text,text,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.registra_preventivo_emesso_auto(text,text,text,text,timestamptz,timestamptz) to service_role;

create function private.ritenta_preventivi_non_abbinati()
returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare v_doc record; v_result jsonb; v_tentati integer:=0; v_risolti integer:=0;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(20261008,83825) then
    return jsonb_build_object('esito','gia_in_esecuzione');
  end if;
  -- Il lock sui documenti è acquisito dalla RPC nello stesso ordine del webhook.
  for v_doc in
    select * from public.preventivi_emessi_ricevuti where risolto_at is null
      and (ultimo_tentativo_at is null or ultimo_tentativo_at <= now() - interval '4 minutes')
    order by ultimo_tentativo_at nulls first,ricevuto_at limit 100
  loop
    begin
      v_result:=public.registra_preventivo_emesso_auto(v_doc.external_id,v_doc.nome_file,
        v_doc.targa,v_doc.file_url,v_doc.data_offerta,v_doc.inviato_at);
      v_tentati:=v_tentati+1;
      if v_result->>'aggiornato'='true' or v_result->>'esito'='gia_registrato' then v_risolti:=v_risolti+1; end if;
    exception when others then
      update public.preventivi_emessi_ricevuti set ultimo_tentativo_at=now(),
        tentativi=tentativi+1,esito='errore_elaborazione',
        risultato=jsonb_build_object('aggiornato',false,'esito','errore_elaborazione','errore',sqlerrm)
      where external_id=v_doc.external_id;
    end;
  end loop;
  return jsonb_build_object('esito','completato','tentati',v_tentati,'risolti',v_risolti);
end;
$fn$;
revoke all on function private.ritenta_preventivi_non_abbinati() from public,anon,authenticated;
grant execute on function private.ritenta_preventivi_non_abbinati() to service_role;

select cron.schedule('ritenta-preventivi-non-abbinati','*/5 * * * *',
  'select private.ritenta_preventivi_non_abbinati(); select private.controlla_coerenza_keplero();');

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
;
$function$;

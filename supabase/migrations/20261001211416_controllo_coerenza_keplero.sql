-- Controllo indipendente: legge testo letterale e dati persistiti, non modifica
-- stati commerciali. Segnalazioni deduplicate; risoluzione al controllo seguente.
create table public.keplero_controllo_segnalazioni (
  chiave text primary key,
  pratica_id uuid references public.pratiche(id) on delete cascade,
  event_id bigint references public.keplero_live_events(id) on delete cascade,
  regola text not null,
  descrizione text not null,
  evidenza text not null,
  rilevata_at timestamptz not null default now(),
  verificata_at timestamptz not null default now(),
  risolta_at timestamptz
);
alter table public.keplero_controllo_segnalazioni enable row level security;
revoke all on public.keplero_controllo_segnalazioni from public, anon, authenticated;
grant select on public.keplero_controllo_segnalazioni to service_role;

create table public.keplero_controllo_stato (
  id integer primary key check (id = 1),
  ultima_esecuzione_at timestamptz,
  eventi_esaminati integer not null default 0,
  segnalazioni_aperte integer not null default 0,
  risposte_k_disponibili boolean not null default false,
  errore text
);
alter table public.keplero_controllo_stato enable row level security;
revoke all on public.keplero_controllo_stato from public, anon, authenticated;
grant select on public.keplero_controllo_stato to service_role;
insert into public.keplero_controllo_stato(id) values (1);

create function private.evidenza_accettazione_controllo(p_testo text)
returns boolean language sql immutable set search_path = '' as $fn$
  select lower(coalesce(p_testo,'')) ~ '\m(accetto|accettiamo|confermo|confermiamo|approvo|approviamo)\M.{0,45}\m(preventivo|offerta|ordine|lavorazione|riparazione)\M'
     and lower(coalesce(p_testo,'')) !~ '(non.{0,25}(accett|conferm|approv)|\mse\M.{0,30}(accett|conferm|approv)|rifiut|ci penso|valutare|forse|eventualmente)';
$fn$;
revoke all on function private.evidenza_accettazione_controllo(text) from public,anon,authenticated;
-- Verifica delle varianti che avevano eluso il controllo precedente.
do $test$
begin
  if exists (select 1 from (values
    ('Buongiorno, accettiamo l’offerta 2 - Programma Scambio',true),
    ('Confermiamo il preventivo, grazie',true),
    ('Approviamo l''offerta ricevuta',true),
    ('Non accettiamo l''offerta',false),
    ('Se accettiamo l''offerta, quando spedite?',false),
    ('Se confermiamo il preventivo, quanto tempo serve?',false),
    ('Se approviamo l''offerta, potete spedire domani?',false),
    ('Come procediamo per il ritiro?',false),
    ('Ho fatto il bonifico',false),
    ('Programma scambio',false)
  ) as t(frase,atteso) where private.evidenza_accettazione_controllo(frase) is distinct from atteso)
  then raise exception 'Controllo accettazioni: regressione nei casi di riferimento'; end if;
end;
$test$;

create function private.candidati_coerenza_keplero()
returns table(chiave text, pratica_id uuid, event_id bigint, regola text, descrizione text, evidenza text)
language sql stable set search_path = '' as $fn$
with eventi as (
  select e.*, lower(trim(coalesce(e.payload->>'ultimo_messaggio_cliente', e.payload->>'messaggio_cliente', e.payload->>'messaggio', ''))) as testo
  from public.keplero_live_events e
  where e.created_at >= now() - interval '30 days'
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
    -- Una revoca successiva sospende la segnalazione della vecchia accettazione.
    and not exists (select 1 from eventi r where r.pratica_id=p.id and r.id>e.id
      and r.testo ~ '(non.{0,25}(accett|conferm|approv)|rifiut|annull|ci penso|valutare)')
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
      and a.created_at >= e.created_at-interval '24 hours'
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
union all
select 'errore:'||e.id,e.pratica_id,e.id,'errore_elaborazione',
  'Errore nel motore eventi: '||left(coalesce(ep.errore,''),250),left(e.testo,600)
from eventi e join private.keplero_event_processing ep on ep.event_id=e.id where ep.stato='errore';
$fn$;
revoke all on function private.candidati_coerenza_keplero() from public,anon,authenticated;

create function private.controlla_coerenza_keplero()
returns jsonb language plpgsql set search_path = '' as $fn$
declare v_aperte integer; v_eventi integer;
begin
  if not pg_try_advisory_xact_lock(20261001,2114) then
    return jsonb_build_object('esito','gia_in_esecuzione');
  end if;
  insert into public.keplero_controllo_segnalazioni(chiave,pratica_id,event_id,regola,descrizione,evidenza)
  select * from private.candidati_coerenza_keplero()
  on conflict(chiave) do update set event_id=excluded.event_id,descrizione=excluded.descrizione,
    evidenza=excluded.evidenza,verificata_at=now(),risolta_at=null;
  update public.keplero_controllo_segnalazioni s set risolta_at=now(),verificata_at=now()
  where s.risolta_at is null and not exists (select 1 from private.candidati_coerenza_keplero() c where c.chiave=s.chiave);
  select count(*) into v_aperte from public.keplero_controllo_segnalazioni where risolta_at is null;
  select count(*) into v_eventi from public.keplero_live_events where created_at>=now()-interval '30 days' and created_at<now()-interval '10 minutes';
  update public.keplero_controllo_stato set ultima_esecuzione_at=now(),eventi_esaminati=v_eventi,
    segnalazioni_aperte=v_aperte,risposte_k_disponibili=false,errore=null where id=1;
  return jsonb_build_object('esito','completato','segnalazioni_aperte',v_aperte,'eventi_esaminati',v_eventi);
exception when others then
  update public.keplero_controllo_stato set errore=sqlerrm where id=1;
  return jsonb_build_object('esito','errore','errore',sqlerrm);
end;
$fn$;
revoke all on function private.controlla_coerenza_keplero() from public,anon,authenticated;
-- Il job e privato, eseguito come postgres. Nessun RPC pubblico con privilegi.
select cron.schedule('controllo-coerenza-keplero','*/5 * * * *','select private.controlla_coerenza_keplero();');

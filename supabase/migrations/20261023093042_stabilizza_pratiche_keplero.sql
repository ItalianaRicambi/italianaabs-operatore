-- Migrazione atomica: relazioni, prove, registro e motore commerciale.
-- Il riconciliatore resta sospeso fino al collaudo del percorso completo.

-- Un collegamento per episodio, conservato anche se cambia la chiave live.
-- Il campo legacy pratiche.keplero_conversation_id resta unico e compatibile.
create table public.keplero_pratiche_conversazioni (
 sessione uuid not null, pratica_id uuid not null references public.pratiche(id),
 fonte text not null, collegata_at timestamptz not null default now(),
 primary key(sessione,pratica_id)
);
create index keplero_pratiche_conversazioni_pratica on public.keplero_pratiche_conversazioni(pratica_id);
alter table public.keplero_pratiche_conversazioni enable row level security;
revoke all on public.keplero_pratiche_conversazioni from public,anon,authenticated;
grant select,insert,update on public.keplero_pratiche_conversazioni to service_role;

create function private.sessione_chiave_k(p_chiave text)
returns uuid language sql immutable security invoker set search_path='' as $$
 select case when p_chiave ~* '^conversation:[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}(:veicolo:[a-z0-9]+)?$'
 then split_part(p_chiave,':',2)::uuid end;
$$;

insert into public.keplero_pratiche_conversazioni(sessione,pratica_id,fonte,collegata_at)
select p.keplero_conversation_id::uuid,p.id,'campo_legacy',p.created_at from public.pratiche p
where p.keplero_conversation_id~*'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
on conflict do nothing;
insert into public.keplero_pratiche_conversazioni(sessione,pratica_id,fonte,collegata_at)
select private.sessione_chiave_k(l.external_key),l.pratica_id,'chiave_episodio',min(l.created_at)
from (select external_key,pratica_id,created_at from public.keplero_live_links
 union all select external_key,pratica_id,created_at from public.keplero_live_events) l
join public.pratiche p on p.id=l.pratica_id
where private.sessione_chiave_k(l.external_key) is not null
 and (l.external_key!~':veicolo:' or split_part(l.external_key,':',4)=lower(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')))
group by 1,2 on conflict do nothing;

create function private.collega_episodio_conversazione_k()
returns trigger language plpgsql security invoker set search_path='' as $$
declare s uuid:=private.sessione_chiave_k(new.external_key);
begin
 if s is not null and exists(select 1 from public.pratiche p where p.id=new.pratica_id
  and (new.external_key!~':veicolo:' or split_part(new.external_key,':',4)=lower(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')))) then
  insert into public.keplero_pratiche_conversazioni(sessione,pratica_id,fonte)
  values(s,new.pratica_id,'chiave_episodio') on conflict do nothing;
 end if;
 return new;
end; $$;
create trigger zz_collega_episodio_conversazione_k after insert or update on public.keplero_live_links
for each row execute function private.collega_episodio_conversazione_k();

create function private.pratica_nella_conversazione_k(p_pratica uuid,p_sessione uuid)
returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.keplero_pratiche_conversazioni c where c.sessione=p_sessione and c.pratica_id=p_pratica)
 or exists(select 1 from public.pratiche p where p.id=p_pratica and p.keplero_conversation_id=p_sessione::text);
$$;

create function private.collega_pratica_legacy_k()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.keplero_conversation_id~*'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' then
  insert into public.keplero_pratiche_conversazioni(sessione,pratica_id,fonte)
  values(new.keplero_conversation_id::uuid,new.id,'campo_legacy') on conflict do nothing;
 end if;
 return new;
end; $$;
create trigger zz_collega_pratica_legacy_k after insert or update of keplero_conversation_id on public.pratiche
for each row execute function private.collega_pratica_legacy_k();
revoke all on function private.collega_pratica_legacy_k() from public,anon,authenticated;
grant execute on function private.collega_pratica_legacy_k() to service_role;

-- Una sola funzione registra il documento su una pratica già identificata e
-- ricontrolla la prova originale. Mai promozioni per il solo nome del file.
create function private.applica_preventivo_verificato_k(p_documento uuid,p_pratica uuid,p_prova jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.documenti_preventivo_auto%rowtype; p public.pratiche%rowtype;
 m public.keplero_originali%rowtype; a public.azioni_operatore%rowtype;
 qid uuid; qids uuid[]; r jsonb; data_invio timestamptz:=(p_prova->>'inviato_at')::timestamptz;
 sid text:=p_prova->>'fonte_id'; prima jsonb;
begin
 -- Ordine dei lock: pratica, documento, offerta. Tutti i chiamanti del nuovo
 -- percorso usano lo stesso ordine; il lock per pratica serializza i retry.
 select * into p from public.pratiche where id=p_pratica for update;
 select * into d from public.documenti_preventivo_auto where id=p_documento for update;
 if p.id is null or d.id is null then raise exception 'Pratica o documento assente';end if;
 if data_invio is null or data_invio>now()+interval '5 minutes' or nullif(sid,'') is null
  or data_invio<d.data_offerta-interval '5 minutes' then raise exception 'Prova invio non valida';end if;
 if upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) is distinct from d.targa then
  return jsonb_build_object('ok',false,'esito','targa_discordante');end if;
 if p_prova->>'fonte'='keplero_originale_verificato' then
  select * into m from public.keplero_originali where sessione=(p_prova->>'conversazione_id')::uuid
   and messaggio_id=p_prova->>'messaggio_id';
  if m.messaggio_id is null or m.modificato or m.direzione<>'uscita' or m.tipo<>'file'
   or m.sha256_pdf is null or m.sha256_pdf is distinct from d.sha256_pdf or m.targa_pdf is distinct from d.targa
   or m.data_messaggio is distinct from data_invio
   or not private.pratica_nella_conversazione_k(p.id,m.sessione)
   or p_prova->>'fonte_id' is distinct from 'keplero:'||m.sessione||':'||m.messaggio_id
   or p_prova->>'impronta_documento' is distinct from d.impronta
   or p_prova->>'direzione' is distinct from 'uscita' or p_prova->>'esito' is distinct from 'inviato'
   or coalesce((p_prova->>'verificata_originale')::boolean,false) is not true
  then raise exception 'Messaggio originale non verificato';end if;
 elsif p_prova->>'fonte'='operatore' then
  select * into a from public.azioni_operatore where id=(p_prova->>'azione_id')::bigint
   and pratica_id=p.id and private.conferma_invio_operatore_valida(azioni_operatore) and created_at=data_invio;
  if a.id is null or sid<>'operatore:'||a.id then raise exception 'Conferma operatore non verificata';end if;
 else raise exception 'Fonte prova invio non ammessa';end if;
 if d.stato='inviato' then
  if d.pratica_id is distinct from p.id then raise exception 'Documento già attribuito a un altro episodio';end if;
  return jsonb_build_object('ok',true,'esito','gia_registrato','pratica_id',p.id,'preventivo_id',d.preventivo_id);
 end if;
 update public.documenti_preventivo_auto set prova_invio=p_prova,fonte_invio_id=sid where id=d.id;
 if p.tipo_flusso<>'commerciale' or p.stato_commerciale in ('ordine_acquisito','chiuso','perso','rifiutato')
  or p.stato_fatturazione<>'non_applicabile'
  or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true'
 then return jsonb_build_object('ok',false,'esito','stato_avanzato_protetto');end if;
 if p.blocco_operatore or (p.blocco_classificazione_operatore and p.stato_commerciale not in ('preventivo_inviato','attesa_cliente'))
  or exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
   and c.telefono_normalizzato=regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g'))
 then return jsonb_build_object('ok',false,'esito','blocco_operatore');end if;
 if nullif(d.contenuto->>'errore','') is not null or (case when jsonb_typeof(d.contenuto->'opzioni')='array' then jsonb_array_length(d.contenuto->'opzioni')=0 else true end) then
  update public.documenti_preventivo_auto set stato='da_verificare',pratica_id=p.id,prova_invio=p_prova,
   motivo='Invio verificato; lettura del documento da completare.' where id=d.id;
  return jsonb_build_object('ok',false,'esito','lettura_da_verificare','pratica_id',p.id);end if;
 select array_agg(distinct v.preventivo_id) into qids from public.offerte_versioni v
  where v.pratica_id=p.id and v.impronta=d.impronta;
 if cardinality(qids)>1 then return jsonb_build_object('ok',false,'esito','versioni_ambigue');end if;
 qid:=coalesce(d.preventivo_id,qids[1]);
 if qid is not null and not exists(select 1 from public.preventivi q where q.id=qid and q.pratica_id=p.id) then
  raise exception 'Offerta estranea alla pratica';end if;
 prima:=to_jsonb(p);
 if qid is null then
  insert into public.preventivi(pratica_id,external_id,stato,file_url,creato_at,inviato_at,note)
  values(p.id,'documento:'||d.id,'inviato',d.file_url,d.data_offerta,data_invio,'Invio verificato: '||sid) returning id into qid;
 end if;
 update public.preventivi set stato='inviato',inviato_at=coalesce(inviato_at,data_invio)
  where id=qid and stato='bozza';
 update public.documenti_preventivo_auto set pratica_id=p.id,preventivo_id=qid,stato='inviato',
  prova_invio=p_prova,fonte_invio_id=sid,motivo='Invio originale verificato e collegato all’episodio.' where id=d.id;
 update public.pratiche set stato_commerciale=case when stato_commerciale='attesa_cliente' then stato_commerciale else 'preventivo_inviato' end,
  preventivo_inviato_at=coalesce(preventivo_inviato_at,data_invio)
  where id=p.id and (stato_commerciale not in ('preventivo_inviato','attesa_cliente') or preventivo_inviato_at is null);
 r:=public.registra_opzioni_offerta(qid,d.contenuto->'opzioni',d.impronta,d.contenuto->>'testo',
  d.contenuto->>'errore',coalesce(d.contenuto->>'fonte','pdf'),(d.contenuto->>'validita_giorni')::integer,data_invio);
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'preventivo_originale_collegato',sid,prima,(select to_jsonb(pp) from public.pratiche pp where id=p.id),'motore_commerciale');
 return jsonb_build_object('ok',true,'esito','preventivo_inviato','pratica_id',p.id,'preventivo_id',qid,'lettura_offerta',r);
end; $$;

create or replace function private.abbina_documento_preventivo(p_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.documenti_preventivo_auto%rowtype; candidati uuid[]; ha_originale boolean;
begin
 select * into d from public.documenti_preventivo_auto where id=p_id;
 if d.id is null then raise exception 'Documento assente';end if;
 if d.stato='inviato' then return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito','inviato','pratica_id',d.pratica_id);end if;
 select exists(select 1 from public.keplero_originali m where m.sha256_pdf=d.sha256_pdf
  and m.targa_pdf=d.targa and m.direzione='uscita' and m.tipo='file' and not m.modificato) into ha_originale;
 select array_agg(distinct p.id) into candidati from public.pratiche p
 where upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g'))=d.targa
 and p.tipo_flusso='commerciale' and p.stato_commerciale in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto','preventivo_inviato','attesa_cliente','richiesta_verifica')
 and p.stato_fatturazione='non_applicabile'
 and case when ha_originale then exists(select 1 from public.keplero_originali m
   where m.sha256_pdf=d.sha256_pdf and m.targa_pdf=d.targa and m.direzione='uscita' and m.tipo='file' and not m.modificato
   and private.pratica_nella_conversazione_k(p.id,m.sessione))
  else (p.created_at<=d.data_offerta+interval '5 minutes' or (d.ricevuto_at<=p.created_at
   and d.ricevuto_at>=private.inizio_finestra_controllo_keplero(p.created_at,48)
   and d.data_offerta>=private.inizio_finestra_controllo_keplero(d.ricevuto_at,24))) end
 and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
 and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
 if cardinality(candidati)=1 then perform 1 from public.pratiche where id=candidati[1] for update;end if;
 update public.documenti_preventivo_auto set ultimo_tentativo_at=now(),
 pratica_id=case when cardinality(candidati)=1 then candidati[1] end,
 stato=case when coalesce(cardinality(candidati),0)<>1 then 'da_abbinare'
  when prova_invio is not null or nullif(contenuto->>'errore','') is not null then 'da_verificare' else 'pronto' end,
 motivo=case when coalesce(cardinality(candidati),0)=0 then 'Nessun episodio compatibile: verificare targa e collegamento alla conversazione.'
  when cardinality(candidati)>1 then 'Più episodi compatibili: abbinamento da verificare.'
  when nullif(contenuto->>'errore','') is not null then left(contenuto->>'errore',500)
  else 'Documento acquisito; verificare la prova di invio.' end
 where id=d.id and stato<>'inviato' returning * into d;
 return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito',d.stato,'pratica_id',d.pratica_id);
end; $$;

create or replace function public.conferma_invio_documento_preventivo(p_documento_id uuid,p_prova jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.documenti_preventivo_auto%rowtype;
begin
 perform private.abbina_documento_preventivo(p_documento_id);
 select * into d from public.documenti_preventivo_auto where id=p_documento_id;
 if d.pratica_id is null then return jsonb_build_object('ok',false,'esito','da_abbinare');end if;
 return private.applica_preventivo_verificato_k(d.id,d.pratica_id,p_prova);
end; $$;

create or replace function public.registra_pdf_originale_k(p_lease uuid,p_sessione uuid,p_messaggio_id text,p_contenuto jsonb,p_url text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.keplero_originali%rowtype; d public.documenti_preventivo_auto%rowtype; r jsonb;
 gruppi integer; pid uuid; ids uuid[];
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now();
 if not found then raise exception 'Lotto scaduto';end if;
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio_id;
 if m.modificato or m.direzione<>'uscita' or m.tipo<>'file' or m.targa_pdf is null or m.sha256_pdf is null
  or m.testo is distinct from 'attachment:'||p_url then return jsonb_build_object('esito','prova_non_verificata');end if;
 select count(*) into gruppi from (select distinct impronta from public.documenti_preventivo_auto
  where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf) x;
 if gruppi>1 then return jsonb_build_object('esito','documento_ambiguo');end if;
 select * into d from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf
  order by (stato='inviato') desc,ricevuto_at,id limit 1;
 if d.id is null then
  r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','keplero:'||p_sessione||':'||p_messaggio_id,
   'contenuto',p_contenuto,'sha256_pdf',m.sha256_pdf,'nome_file',m.targa_pdf||'.pdf','targa',m.targa_pdf,'file_url',p_url,'data_offerta',m.data_messaggio));
  select * into d from public.documenti_preventivo_auto where id=(r->>'documento_id')::uuid;
 end if;
 if d.stato<>'inviato' then
  perform private.abbina_documento_preventivo(d.id);
  select * into d from public.documenti_preventivo_auto where id=d.id;
 end if;
 if d.pratica_id is null or nullif(p_contenuto->>'errore','') is not null then return jsonb_build_object('esito','da_verificare');end if;
 if not private.pratica_nella_conversazione_k(d.pratica_id,p_sessione) then return jsonb_build_object('esito','conversazione_da_verificare');end if;
 r:=private.applica_preventivo_verificato_k(d.id,d.pratica_id,jsonb_build_object('fonte','keplero_originale_verificato',
  'fonte_id','keplero:'||p_sessione||':'||p_messaggio_id,'direzione','uscita','esito','inviato','impronta_documento',d.impronta,
  'messaggio_id',p_messaggio_id,'conversazione_id',p_sessione,'verificata_originale',true,'inviato_at',m.data_messaggio));
 if r->>'ok'='true' then
  update public.keplero_verifiche_originali set pratica_id=d.pratica_id,esito='preservata',
   motivo='PDF letto e invio verificato sull’episodio corretto.',verificata_at=now(),updated_at=now()
  where sessione=p_sessione and messaggio_id=p_messaggio_id and esito='da_verificare';
 end if;
 return r;
end; $$;

revoke all on function private.sessione_chiave_k(text),private.collega_episodio_conversazione_k(),
 private.pratica_nella_conversazione_k(uuid,uuid),private.applica_preventivo_verificato_k(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.sessione_chiave_k(text),private.collega_episodio_conversazione_k(),
 private.pratica_nella_conversazione_k(uuid,uuid),private.applica_preventivo_verificato_k(uuid,uuid,jsonb) to service_role;
revoke all on function public.registra_pdf_originale_k(uuid,uuid,text,jsonb,text),public.conferma_invio_documento_preventivo(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.registra_pdf_originale_k(uuid,uuid,text,jsonb,text),public.conferma_invio_documento_preventivo(uuid,jsonb) to service_role;

-- Il consenso generico non sceglie l'ultima vettura della chat: se ci sono
-- più episodi con offerta aperta, serve un riferimento esplicito del cliente.
create function private.documento_consenso_univoco_k(p_sessione uuid,p_data timestamptz,p_testo text)
returns uuid language plpgsql security invoker set search_path='' as $$
declare ids uuid[]; dids uuid[]; esplicita boolean; pid uuid; f public.keplero_originali%rowtype;
begin
 select exists(select 1 from public.keplero_pratiche_conversazioni c join public.pratiche p on p.id=c.pratica_id
  where c.sessione=p_sessione and length(coalesce(p.targa,''))>=4
   and position(upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g')) in upper(regexp_replace(coalesce(p_testo,''),'[^A-Za-z0-9]','','g')))>0) into esplicita;
 select array_agg(distinct p.id) into ids
 from public.keplero_pratiche_conversazioni c join public.pratiche p on p.id=c.pratica_id
 join public.documenti_preventivo_auto d on d.pratica_id=p.id
 join public.keplero_originali m on m.sessione=c.sessione and m.sha256_pdf=d.sha256_pdf and m.targa_pdf=d.targa
 where c.sessione=p_sessione and p.tipo_flusso='commerciale'
 and m.direzione='uscita' and m.tipo='file' and not m.modificato and m.data_messaggio<=p_data
 and (esplicita or (p.stato_fatturazione='non_applicabile' and p.stato_commerciale not in ('ordine_acquisito','chiuso','rifiutato','perso')))
 and (not esplicita or position(upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g')) in upper(regexp_replace(coalesce(p_testo,''),'[^A-Za-z0-9]','','g')))>0)
 and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
 and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
 if cardinality(ids) is distinct from 1 then return null;end if;
 pid:=ids[1];
 select m.* into f from public.keplero_originali m join public.pratiche p on p.id=pid
 where m.sessione=p_sessione and m.targa_pdf=upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))
 and m.direzione='uscita' and m.tipo='file' and not m.modificato and m.data_messaggio<=p_data
 order by m.data_messaggio desc,m.messaggio_id desc limit 1;
 -- Stessi byte + impronta + episodio equivalgono a una sola versione, anche
 -- se Drive e WhatsApp hanno prodotto più righe dello stesso documento.
 if (select count(distinct d.impronta) from public.documenti_preventivo_auto d
  where d.sha256_pdf=f.sha256_pdf and d.targa=f.targa_pdf and d.pratica_id=pid)<>1 then return null;end if;
 return (select id from public.documenti_preventivo_auto where sha256_pdf=f.sha256_pdf and targa=f.targa_pdf and pratica_id=pid
  order by (stato='inviato') desc,ricevuto_at,id limit 1);
end; $$;
revoke all on function private.documento_consenso_univoco_k(uuid,timestamptz,text) from public,anon,authenticated;
grant execute on function private.documento_consenso_univoco_k(uuid,timestamptz,text) to service_role;

CREATE OR REPLACE FUNCTION private.valuta_originale_k(p_sessione uuid, p_messaggio_id text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare m public.keplero_originali%rowtype; f public.keplero_originali%rowtype;
 d public.documenti_preventivo_auto%rowtype; q public.offerte_versioni%rowtype;
 p public.pratiche%rowtype; s public.scelte_cliente%rowtype; o public.offerta_opzioni%rowtype;
 ids uuid[]; opzioni uuid[]; n integer; pid uuid; t text; v_tipo text; motivo text; esito text:='da_verificare'; r jsonb; prima jsonb;
begin
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio_id;
 if not m.candidato or m.data_messaggio<now()-interval '30 days' then return;end if;
 if exists(select 1 from public.keplero_verifiche_originali k where k.sessione=p_sessione and k.messaggio_id=p_messaggio_id and k.esito in ('recuperata','preservata','archiviata')) then return;end if;
 -- Collega l'avviso alla conversazione, mai per nome o telefono soltanto.
 select (array_agg(distinct c.pratica_id))[1] into pid from public.keplero_pratiche_conversazioni c where c.sessione=p_sessione having count(distinct c.pratica_id)=1;
 if pid is not null then select * into p from public.pratiche where id=pid;end if;
 motivo:='Possibile conferma o documento originale da verificare.';
 if m.modificato then motivo:='Il messaggio originale è cambiato: stato e prove precedenti conservati.';
 elsif m.revoca then motivo:='Revoca o modifica del cliente: verificare la scelta e l''ordine, senza annullamenti automatici.';
 elsif m.direzione<>'entrata' or m.tipo<>'text' then motivo:='Documento inviato nella chat: leggere il PDF originale prima di aggiornare la fatturazione.';
 elsif lower(m.testo)~'(bonifico|pagamento eseguito)' then motivo:='Pagamento dichiarato dal cliente: verificare la ricevuta e l''accredito; nessuna quietanza automatica.';
 else

  pid:=private.documento_consenso_univoco_k(p_sessione,m.data_messaggio,m.testo);
  if pid is not null then
   select * into d from public.documenti_preventivo_auto where id=pid;
   if private.pratica_nella_conversazione_k(d.pratica_id,p_sessione) then
    select * into p from public.pratiche where id=d.pratica_id for update;
    select * into f from public.keplero_originali where sessione=p_sessione and sha256_pdf=d.sha256_pdf
     and targa_pdf=d.targa and direzione='uscita' and tipo='file' and not modificato and data_messaggio<=m.data_messaggio
     order by data_messaggio desc,messaggio_id desc limit 1;
    select * into q from public.offerte_versioni where pratica_id=p.id and impronta=d.impronta
     and f.data_messaggio<=m.data_messaggio order by versione desc limit 1;
   end if;
  end if;
  if q.id is null then motivo:='Conferma da verificare: manca un PDF originale inviato, identico a un''offerta registrata e abbinata senza ambiguità.';
  elsif p.stato_fatturazione='fatturato' or p.stato_commerciale in ('rifiutato','chiuso')
    or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  then esito:='preservata';motivo:='Pratica conclusa o fatturata: stati preservati.';
  else
   select * into s from public.scelte_cliente where pratica_id=p.id;
   if s.pratica_id is not null or p.blocco_operatore or p.tipo_flusso<>'commerciale' then
    if s.stato='confermata' and m.data_messaggio<=s.richiesta_at then esito:='preservata';motivo:='Conferma già presente: scelta e correzioni operatore preservate.';
    else motivo:='Scelta o blocco già presente: confrontare il messaggio originale con lo stato attuale.';end if;
   elsif q.stato<>'letta' or (q.validita_giorni is not null and m.data_messaggio>f.data_messaggio+make_interval(days=>q.validita_giorni)) then motivo:='Offerta da leggere o scaduta: verifica operatore richiesta.';
   elsif exists(select 1 from public.offerte_versioni successiva where successiva.pratica_id=p.id and successiva.inviato_at>q.inviato_at)
    or exists(select 1 from public.keplero_originali recente where recente.sessione=p_sessione and recente.data_messaggio>m.data_messaggio and recente.direzione='entrata' and recente.candidato and (recente.revoca or (lower(recente.testo)~'(accett|conferm|proced|scelg|ripari|revision)' and lower(recente.testo)~'(ordine|preventivo|offerta|scambio|ripar|revision|opzione)')))
   then motivo:='Esistono messaggi o offerte successivi: verificare la decisione più recente.';
   else
    t:=lower(translate(m.testo,'àèéìòù’','aeeiou'''));
    if nullif(p.targa,'') is not null then t:=regexp_replace(t,'\m'||lower(p.targa)||'\M','','g');end if;
    -- Solo consenso letterale, senza domanda, negazioni, condizioni o futuro.
    if t~'[?]|\m(non|se|qualora|forse|eventualmente|prima|appena|domani|valutare|preferirei|vorrei)\M'
      or private.preferenza_senza_conferma(t) or private.rinvio_conferma_per_verifiche(t)
      or not(t~'\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo|scelgo|scegliamo)\M' or private.scelta_dispositivo_originale(t))
      or not(t~'(ordine|offerta|preventivo|lavorazione|ripar|revision|scambio|rigenerat|opzione|\m(ri|re|rc|ps|psmi)\M)' or btrim(t)~'^(ok[,!. ]*)?(accetto|accettiamo|confermo|confermiamo|procedete|procediamo)[.! ]*$')
    then motivo:='Intenzione, domanda o consenso non conclusivo: verificare con il cliente.';
    else
     select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id;
     if private.scelta_dispositivo_originale(t) then
      select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and servizio in ('RI','RE','RC');
     elsif t~'\mpsmi\M|scambio made in italy' then v_tipo:='PSMI';
     elsif t~'\mps\M' then v_tipo:='PS';
     elsif t~'\mri\M|idraulic' then v_tipo:='RI';
     elsif t~'\mre\M|elettronic' then v_tipo:='RE';
     elsif t~'\mrc\M|revisione completa' then v_tipo:='RC';
     elsif t~'scambio|rigenerat' then
      select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and servizio in ('PS','PSMI');
     end if;
     if v_tipo is not null then select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and servizio=v_tipo;end if;
     n:=(regexp_match(t,'opzione[[:space:]]+([1-8])\M'))[1]::integer;
     if n is not null then select array_agg(id) into opzioni from public.offerta_opzioni where offerta_id=q.id and id=any(opzioni) and numero=n and numero_esplicito;end if;
     -- Alternative multiple o riferimenti economici restano manuali, evitando selezioni parziali.
     if t~'\m(o|oppure|ma|anche)\M|[€]|[0-9]{2,}|\m(ri|re|rc|ps|psmi)\M.{0,30}\m(ri|re|rc|ps|psmi)\M' then opzioni:=null;end if;
     if (case when t~'\mri\M|idraulic' then 1 else 0 end)+(case when t~'\mre\M|elettronic' then 1 else 0 end)+(case when t~'\mrc\M|revisione completa' then 1 else 0 end)+(case when t~'scambio|rigenerat|\m(ps|psmi)\M' then 1 else 0 end)>1 then opzioni:=null;end if;
     if cardinality(opzioni)=1 and p.stato_commerciale in ('preventivo_inviato','attesa_cliente') then
      select * into o from public.offerta_opzioni where id=opzioni[1];prima:=to_jsonb(p);
      insert into public.scelte_cliente(pratica_id,offerta_id,opzione_id,stato,evidenza,richiesta_at,fonte)
       values(p.id,q.id,o.id,'confermata',m.testo,m.data_messaggio,'keplero_originale');
      r:=public.conferma_ordine_da_keplero(p.id,(select external_key from public.keplero_live_links where pratica_id=p.id order by updated_at desc,external_key limit 1),m.testo);
      if coalesce(r->>'aggiornato','false')='true' then
       update public.pratiche set ordine_acquisito_at=m.data_messaggio where id=p.id;
       update public.preventivi set accettato_at=m.data_messaggio where id=q.preventivo_id and stato='accettato';
       esito:='recuperata';motivo:='Consenso originale e alternativa unica verificati. Ordine recuperato; i dati fiscali restano soggetti ai controlli amministrativi.';
       insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
        values(p.id,'ordine_recuperato_originale_k','keplero:'||p_sessione||':'||p_messaggio_id||' - '||left(m.testo,1000),prima,(select to_jsonb(pp) from public.pratiche pp where pp.id=p.id),'routine_originali_k');
      else
       delete from public.scelte_cliente where pratica_id=p.id and fonte='keplero_originale' and richiesta_at=m.data_messaggio;
       motivo:='Conferma originale trattenuta dalle protezioni dello stato: '||coalesce(r->>'motivo','verifica richiesta');
      end if;
     else motivo:='Consenso da verificare: più alternative possibili o stato non compatibile. Nessun importo scelto automaticamente.';end if;
    end if;
   end if;
  end if;
 end if;
 insert into public.keplero_verifiche_originali(sessione,messaggio_id,pratica_id,esito,motivo)
 values(p_sessione,p_messaggio_id,p.id,esito,motivo)
 on conflict(sessione,messaggio_id) do update set pratica_id=excluded.pratica_id,esito=excluded.esito,motivo=excluded.motivo,updated_at=now()
 where public.keplero_verifiche_originali.esito='da_verificare';
end; $function$;



-- Registro di copertura: tutti gli ingressi originali e tutti i webhook hanno
-- un esito persistente. La ricezione e la riuscita commerciale sono distinti.
create table public.keplero_esiti_fonti (
 fonte text not null check(fonte in ('live','originale','documento','richiesta')),
 chiave text not null, sessione uuid, pratica_id uuid references public.pratiche(id),
 data_fonte timestamptz not null, impronta text not null, contenuto_richiesta jsonb,
 stato text not null default 'ricevuto' check(stato in ('ricevuto','applicato','in_attesa','da_verificare','irrilevante')),
 codice text not null default 'in_elaborazione', motivo text not null default 'Evento ricevuto; verifica dell’esito in corso.',
 tentativi integer not null default 0, prossimo_tentativo_at timestamptz not null default now(),
 errore text, verificata_operatore boolean not null default false,
 operatore text, verificata_at timestamptz, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), primary key(fonte,chiave)
);
create index keplero_esiti_pratica on public.keplero_esiti_fonti(pratica_id,stato);
create index keplero_esiti_sessione on public.keplero_esiti_fonti(sessione,data_fonte);
create index keplero_esiti_lavorabili on public.keplero_esiti_fonti(prossimo_tentativo_at,fonte,chiave)
 where stato in ('ricevuto','in_attesa','da_verificare') and not verificata_operatore;
create table public.keplero_esiti_storico (
 id bigint generated always as identity primary key, fonte text not null, chiave text not null,
 stato_prima jsonb, stato_dopo jsonb not null, created_at timestamptz not null default now()
);
create index keplero_esiti_storico_fonte on public.keplero_esiti_storico(fonte,chiave,created_at);
create table public.keplero_lavori_pratiche (
 chiave text primary key, pratica_id uuid references public.pratiche(id), sessione uuid,
 stato text not null default 'aperta' check(stato in ('aperta','in_carico','risolta')),
 priorita integer not null default 2, motivi jsonb not null default '{}'::jsonb,
 responsabile text, presa_in_carico_at timestamptz, scadenza_at timestamptz not null default now()+interval '5 minutes',
 prima_rilevazione_at timestamptz not null default now(),ultimo_controllo_at timestamptz not null default now(),
 risolta_at timestamptz, versione bigint not null default 1
);
create unique index keplero_lavoro_episodio on public.keplero_lavori_pratiche(pratica_id) where pratica_id is not null;
create index keplero_lavori_aperti on public.keplero_lavori_pratiche(priorita,prima_rilevazione_at,chiave) where stato<>'risolta';
create table public.keplero_stato_riconciliazione (
 id boolean primary key default true check(id), attivo boolean not null default false, ultimo_tentativo_at timestamptz,
 ultimo_successo_at timestamptz, errore text, esiti_elaborati integer not null default 0
);
insert into public.keplero_stato_riconciliazione(id) values(true);
alter table public.keplero_esiti_fonti enable row level security;
alter table public.keplero_esiti_storico enable row level security;
alter table public.keplero_lavori_pratiche enable row level security;
alter table public.keplero_stato_riconciliazione enable row level security;
revoke all on public.keplero_esiti_fonti,public.keplero_esiti_storico,public.keplero_lavori_pratiche,public.keplero_stato_riconciliazione from public,anon,authenticated;
grant select,insert,update on public.keplero_esiti_fonti,public.keplero_lavori_pratiche,public.keplero_stato_riconciliazione to service_role;
grant select,insert on public.keplero_esiti_storico to service_role;
grant usage,select on sequence public.keplero_esiti_storico_id_seq to service_role;

create function private.storicizza_esito_k()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op='INSERT' or (old.stato,old.codice,old.pratica_id,old.impronta,old.verificata_operatore)
  is distinct from (new.stato,new.codice,new.pratica_id,new.impronta,new.verificata_operatore) then
  insert into public.keplero_esiti_storico(fonte,chiave,stato_prima,stato_dopo)
  values(new.fonte,new.chiave,case when tg_op='UPDATE' then to_jsonb(old) end,to_jsonb(new));
 end if;
 return new;
end; $$;

create trigger esito_k_storico after insert or update on public.keplero_esiti_fonti
for each row execute function private.storicizza_esito_k();

create function private.conserva_fonte_k(p_fonte text,p_chiave text,p_sessione uuid,p_pratica uuid,p_data timestamptz,p_impronta text)
returns void language plpgsql security invoker set search_path='' as $$
begin
 insert into public.keplero_esiti_fonti(fonte,chiave,sessione,pratica_id,data_fonte,impronta)
 values(p_fonte,p_chiave,p_sessione,p_pratica,p_data,p_impronta)
 on conflict(fonte,chiave) do update set pratica_id=coalesce(excluded.pratica_id,public.keplero_esiti_fonti.pratica_id),
  stato='ricevuto',codice='fonte_aggiornata',impronta=excluded.impronta,
  verificata_operatore=false,operatore=null,verificata_at=null,prossimo_tentativo_at=now(),updated_at=now()
 where public.keplero_esiti_fonti.impronta is distinct from excluded.impronta;
end; $$;

create function private.conserva_ingresso_k()
returns trigger language plpgsql security invoker set search_path='' as $$
declare sid uuid; pid uuid;
begin
 if tg_table_name='keplero_live_events' then
  sid:=private.sessione_chiave_k(new.external_key);
  perform private.conserva_fonte_k('live',new.id::text,sid,new.pratica_id,new.created_at,
   encode(sha256(convert_to(new.payload::text,'UTF8')),'hex'));
 elsif tg_table_name='keplero_originali' then
  if new.direzione='entrata' or (new.direzione='uscita' and new.targa_pdf is not null) or new.modificato then
   select (array_agg(c.pratica_id))[1] into pid from public.keplero_pratiche_conversazioni c
    where c.sessione=new.sessione having count(*)=1;
   perform private.conserva_fonte_k('originale',new.sessione||':'||new.messaggio_id,new.sessione,pid,new.data_messaggio,
    new.impronta||coalesce(new.sha256_pdf,'')||new.modificato::text||coalesce(new.revisione->>'impronta',''));
  end if;
 elsif tg_table_name='documenti_preventivo_auto' then
  perform private.conserva_fonte_k('documento',new.id::text,null,new.pratica_id,new.ricevuto_at,
   new.impronta||coalesce(new.sha256_pdf,'')||new.stato||coalesce(new.pratica_id::text,''));
 end if;
 return new;
end; $$;
create trigger zzzz_conserva_ingresso_k after insert on public.keplero_live_events for each row execute function private.conserva_ingresso_k();
create trigger zzzz_conserva_ingresso_k after insert or update on public.keplero_originali for each row execute function private.conserva_ingresso_k();
create trigger zzzz_conserva_ingresso_k after insert or update on public.documenti_preventivo_auto for each row execute function private.conserva_ingresso_k();

-- Proiezione unica del lavoro residuo per episodio. Non modifica dati tecnici,
-- importi o stati commerciali: li decide il motore degli eventi/prove.
create function private.aggiorna_lavoro_pratica_k(p_id uuid)
returns void language plpgsql security invoker set search_path='' as $$
declare p public.pratiche%rowtype; motivi jsonb:='{}'; prio integer:=3; fonti jsonb; sid uuid;
begin
 select * into p from public.pratiche where id=p_id;
 if p.id is null then return;end if;
 select c.sessione into sid from public.keplero_pratiche_conversazioni c where c.pratica_id=p.id order by collegata_at desc limit 1;
 if coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
  and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
  and not exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
   and c.telefono_normalizzato=regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g')) then
  if p.tipo_flusso='commerciale' and p.stato_commerciale in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto')
   and p.stato_fatturazione='non_applicabile' then
   motivi:=motivi||jsonb_build_object('richiesta_preventivo',jsonb_build_object('azione',
    case when p.stato_commerciale='richiesta_verifica' then 'Attendere o sollecitare i dati richiesti dall’operatore.'
    when p.stato_commerciale='preventivo_pronto' then 'Verificare e inviare il preventivo preparato.'
    when p.stato_completezza='completa_da_preventivare' then 'Preparare il preventivo.'
    else 'Completare o verificare tecnicamente la richiesta di preventivo; non perderne la presa in carico.' end,
    'dati_mancanti',case when jsonb_typeof(p.dati_raw#>'{payload_live,decisione_sistema,completezza,datiMancanti}')='array' then p.dati_raw#>'{payload_live,decisione_sistema,completezza,datiMancanti}' else '[]'::jsonb end,
    'nota',p.nota_incompletezza,'verifica_tecnica',
    p.stato_commerciale in ('nuova','raccolta_dati') and p.stato_completezza<>'completa_da_preventivare'
    and not p.blocco_operatore and not p.blocco_classificazione_operatore
    and nullif(p.targa,'') is not null and nullif(p.descrizione_guasto,'') is not null
    and (jsonb_array_length(case when jsonb_typeof(p.dati_raw->'codici_identificativi_estratti')='array' then p.dati_raw->'codici_identificativi_estratti' else '[]'::jsonb end)>0
     or exists(select 1 from public.codici_identificativi c where c.pratica_id=p.id))));
   prio:=2;
  end if;
  if p.tipo_flusso='commerciale' and p.stato_commerciale in ('preventivo_inviato','attesa_cliente') and p.preventivo_inviato_at is null then
   motivi:=motivi||jsonb_build_object('invio_da_verificare',jsonb_build_object('azione','Verificare la prova e la data di invio senza preparare un duplicato.'));prio:=1;
  end if;
  select jsonb_agg(jsonb_build_object('fonte',e.fonte,'chiave',e.chiave,'codice',e.codice,'motivo',e.motivo,'data',e.data_fonte)
   order by e.data_fonte desc) into fonti from public.keplero_esiti_fonti e where e.pratica_id=p.id
   and e.stato in ('ricevuto','da_verificare','in_attesa') and e.codice not in ('attesa_cliente','dati_amministrativi');
  if fonti is not null then
   motivi:=motivi||jsonb_build_object('eventi_senza_esito',jsonb_build_object('azione','Verificare gli eventi e completare l’azione indicata.','fonti',fonti));
   prio:=1;
   if exists(select 1 from public.keplero_esiti_fonti where pratica_id=p.id and codice in ('consenso_non_registrato','errore_elaborazione')
    and stato in ('ricevuto','in_attesa','da_verificare')) then prio:=0;end if;
  end if;
 end if;
 if motivi<>'{}'::jsonb then
  insert into public.keplero_lavori_pratiche(chiave,pratica_id,sessione,priorita,motivi)
  values('pratica:'||p.id,p.id,sid,prio,motivi)
  on conflict(chiave) do update set sessione=coalesce(excluded.sessione,public.keplero_lavori_pratiche.sessione),
   stato=case when public.keplero_lavori_pratiche.stato='risolta' then 'aperta' else public.keplero_lavori_pratiche.stato end,
   motivi=excluded.motivi,priorita=excluded.priorita,ultimo_controllo_at=now(),risolta_at=null,
   scadenza_at=case when public.keplero_lavori_pratiche.stato='risolta' then now()+interval '5 minutes' else public.keplero_lavori_pratiche.scadenza_at end,
   versione=public.keplero_lavori_pratiche.versione+case when public.keplero_lavori_pratiche.motivi is distinct from excluded.motivi then 1 else 0 end;
 else
  update public.keplero_lavori_pratiche set stato='risolta',motivi='{}',risolta_at=coalesce(risolta_at,now()),ultimo_controllo_at=now(),
   versione=versione+case when stato<>'risolta' then 1 else 0 end where pratica_id=p.id;
 end if;
end; $$;

create function private.ricalcola_lavoro_pratica_k()
returns trigger language plpgsql security invoker set search_path='' as $$
begin perform private.aggiorna_lavoro_pratica_k(new.id);return new;end; $$;
create trigger zzzz_ricalcola_lavoro_k after insert or update on public.pratiche
for each row execute function private.ricalcola_lavoro_pratica_k();

-- Espone al backend solo l’esito necessario, mantenendo privato il registro.
-- Il servizio non riceve permessi diretti di lettura o scrittura sulla tabella.
create function private.leggi_esito_elaborazione_k(p_evento bigint)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('stato',ep.stato,'decisione',jsonb_build_object('esito_ordine',ep.decisione->'esito_ordine'))
 from private.keplero_event_processing ep where ep.event_id=p_evento;
$$;
revoke all on function private.leggi_esito_elaborazione_k(bigint) from public,anon,authenticated;
grant execute on function private.leggi_esito_elaborazione_k(bigint) to service_role;

create function private.valuta_fonte_commerciale_k(p_fonte text,p_chiave text)
returns void language plpgsql security invoker set search_path='' as $$
declare e public.keplero_esiti_fonti%rowtype; m public.keplero_originali%rowtype;
 p public.pratiche%rowtype; d public.documenti_preventivo_auto%rowtype; v public.keplero_verifiche_originali%rowtype;
 v_stato text:='in_attesa'; v_codice text:='da_associare'; v_motivo text:='Associare il messaggio all’episodio corretto.';
 ids uuid[]; did uuid; t text; risultato jsonb; data_pdf timestamptz; handled boolean:=false;
begin
 select * into e from public.keplero_esiti_fonti where fonte=p_fonte and chiave=p_chiave;
 if e.fonte is null or e.verificata_operatore then return;end if;
 if p_fonte='live' then
  select * into p from public.pratiche where id=e.pratica_id;
  if p.id is not null then
   risultato:=private.leggi_esito_elaborazione_k(p_chiave::bigint);
   if risultato is null then v_stato:='in_attesa';v_codice:='elaborazione_non_verificata';v_motivo:='Webhook ricevuto; verificare il risultato del motore prima di dichiararlo elaborato.';
   elsif risultato->>'stato'='errore' then v_stato:='da_verificare';v_codice:='errore_elaborazione';v_motivo:='Rielaborare il webhook: una fase ha restituito errore.';
   elsif risultato#>>'{decisione,esito_ordine,motivo}' in ('preventivo_non_registrato','collegamento_keplero_non_valido','stato_non_abilitato','dati_non_completi','consenso_da_verificare','offerta_non_letta','scelta_offerta_non_verificata','episodio_da_chiarire','offerta_scaduta_o_tempi_discordanti')
    and p.stato_commerciale<>'ordine_acquisito' then
    v_stato:='da_verificare';v_codice:='consenso_non_registrato';v_motivo:='Conferma rilevata ma ordine non acquisito: verificare preventivo, scelta e pratica.';
   elsif risultato->>'stato'='da_verificare' then v_stato:='da_verificare';v_codice:='ingresso_da_verificare';v_motivo:='Completare la verifica dell’episodio o degli allegati indicata dal motore.';
   else v_stato:='applicato';v_codice:='webhook_registrato';v_motivo:='Dati del webhook acquisiti; stato commerciale e requisiti verificabili separatamente.';end if;
  end if;
 elsif p_fonte='documento' then
  select * into d from public.documenti_preventivo_auto where id=p_chiave::uuid;
  e.pratica_id:=d.pratica_id;
  if d.stato='inviato' and d.preventivo_id is not null then
   select * into p from public.pratiche where id=d.pratica_id;
   if p.stato_commerciale in ('preventivo_inviato','attesa_cliente','ordine_acquisito','chiuso','rifiutato','perso') then
    v_stato:='applicato';v_codice:='preventivo_inviato';v_motivo:='Documento letto e invio verificato.';
   else v_stato:='da_verificare';v_codice:='pdf_pratica_disallineati';v_motivo:='PDF già inviato ma pratica ancora in preparazione: verificare lo stato e le decisioni dell’operatore.';end if;
  elsif exists(select 1 from public.documenti_preventivo_auto canonico where canonico.sha256_pdf=d.sha256_pdf
   and canonico.impronta=d.impronta and canonico.pratica_id=d.pratica_id and canonico.stato='inviato') then
   v_stato:='applicato';v_codice:='copia_documento_registrata';v_motivo:='Copia identica del documento già registrato sullo stesso episodio.';
  elsif exists(select 1 from public.keplero_originali o where o.sha256_pdf=d.sha256_pdf and o.targa_pdf=d.targa and o.direzione='uscita' and not o.modificato)
   or d.prova_invio is not null then
   v_stato:='da_verificare';v_codice:='pdf_inviato_non_collegato';v_motivo:=coalesce(d.motivo,'Collegare il documento inviato alla pratica corretta.');
  else v_stato:='in_attesa';v_codice:='attesa_prova_invio';v_motivo:='PDF acquisito; l’emissione non prova l’invio al cliente.';end if;
 elsif p_fonte='originale' then
  select * into m from public.keplero_originali where sessione=e.sessione and messaggio_id=split_part(p_chiave,':',2);
  if m.messaggio_id is null then raise exception 'Fonte originale assente';end if;
  if m.direzione='uscita' and m.targa_pdf is not null then
   select * into d from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf
    order by (stato='inviato') desc,ricevuto_at,id limit 1;
   e.pratica_id:=d.pratica_id;
   if d.stato='inviato' and private.pratica_nella_conversazione_k(d.pratica_id,m.sessione) and not m.modificato then
    v_stato:='applicato';v_codice:='preventivo_inviato';v_motivo:='Invio originale collegato al documento e all’episodio.';
   else v_stato:='da_verificare';v_codice:='pdf_inviato_non_collegato';v_motivo:='PDF inviato nella chat senza collegamento verificato alla pratica.';end if;
  else
   -- L'identità è ricavata dalle relazioni e dai riferimenti dell'originale,
   -- mai assegnando automaticamente l'ultima vettura della conversazione.
   select array_agg(distinct c.pratica_id) into ids from public.keplero_pratiche_conversazioni c join public.pratiche pc on pc.id=c.pratica_id
    where c.sessione=m.sessione and length(coalesce(pc.targa,''))>=4
    and position(upper(regexp_replace(pc.targa,'[^A-Za-z0-9]','','g')) in upper(regexp_replace(m.testo,'[^A-Za-z0-9]','','g')))>0;
   if cardinality(ids)=1 then e.pratica_id:=ids[1];else
    did:=private.documento_consenso_univoco_k(m.sessione,m.data_messaggio,m.testo);
    if did is not null then select pratica_id into e.pratica_id from public.documenti_preventivo_auto where id=did;
    else
     select array_agg(distinct c.pratica_id) into ids from public.keplero_pratiche_conversazioni c where c.sessione=m.sessione;
     e.pratica_id:=case when cardinality(ids)=1 then ids[1] end;
    end if;
   end if;
   select * into p from public.pratiche where id=e.pratica_id;
   t:=lower(btrim(m.testo));
   select * into v from public.keplero_verifiche_originali where sessione=m.sessione and messaggio_id=m.messaggio_id;
   if m.modificato then v_stato:='da_verificare';v_codice:='fonte_modificata';v_motivo:='Originale modificato: confrontare la revisione senza cancellare lo storico.';
   elsif m.revoca then v_stato:='da_verificare';v_codice:='revoca_da_verificare';v_motivo:='Verificare revoca o variazione del cliente; nessun annullamento automatico.';
   elsif v.esito in ('recuperata','preservata','archiviata') then
    v_stato:='applicato';v_codice:='originale_verificato';v_motivo:=v.motivo;
    e.pratica_id:=coalesce(v.pratica_id,e.pratica_id);
   elsif t~'^(ok[,.! ]*)?(grazie( mille| a lei| per la vostra disponibilità)?|perfetto grazie|va bene grazie|buongiorno|buonasera|buona giornata|buona serata)[.! ]*$' then
    v_stato:='irrilevante';v_codice:='cortesia';v_motivo:='Messaggio di cortesia conservato; non modifica né chiude il lavoro della pratica.';
   elsif m.candidato then
    v_stato:='da_verificare';v_codice:=case when lower(m.testo)~'(bonifico|pagamento)' then 'pagamento_da_verificare' else 'consenso_non_registrato' end;
    v_motivo:=coalesce(v.motivo,'Interpretare la risposta originale e verificare offerta, scelta e ordine.');
   elsif p.id is not null then
    select min(o.data_messaggio) into data_pdf from public.keplero_originali o join public.documenti_preventivo_auto dd
     on dd.sha256_pdf=o.sha256_pdf and dd.targa=o.targa_pdf where dd.pratica_id=p.id
     and o.direzione='uscita' and not o.modificato;
    select exists(select 1 from public.keplero_live_events l where l.pratica_id=p.id
     and l.created_at between m.data_messaggio and m.data_messaggio+interval '15 minutes'
     and regexp_replace(lower(coalesce(l.payload->>'ultimo_messaggio_cliente','')),'[[:space:]]+',' ','g')=regexp_replace(t,'[[:space:]]+',' ','g')) into handled;
    if data_pdf is not null and m.data_messaggio<data_pdf then
     v_stato:='applicato';v_codice:='dati_preventivo_acquisiti';v_motivo:='Ingresso precedente al preventivo inviato; richiesta acquisita e documento verificato.';
    elsif p.stato_commerciale in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto','richiesta_verifica') or (p.tipo_flusso='assistenza' and handled) then
     v_stato:=case when handled then 'applicato' else 'da_verificare' end;
     v_codice:=case when handled then 'richiesta_in_carico' else 'ingresso_non_registrato' end;
     v_motivo:=case when handled then 'Richiesta acquisita; il lavoro residuo resta nella coda della pratica.' else 'Messaggio originale senza webhook corrispondente: verificare la richiesta e i dati.' end;
    elsif p.stato_commerciale in ('preventivo_inviato','attesa_cliente') then
     v_stato:='da_verificare';v_codice:='risposta_cliente_da_valutare';v_motivo:='Risposta dopo il preventivo: verificare scelta, richiesta o chiarimento, anche se K ha già risposto.';
    elsif p.stato_commerciale in ('ordine_acquisito','chiuso','rifiutato','perso') then
     v_stato:=case when handled then 'applicato' else 'da_verificare' end;
     v_codice:=case when handled then 'seguito_registrato' else 'seguito_da_verificare' end;
     v_motivo:=case when handled then 'Seguito acquisito; vendita e fatturazione preservate.' else 'Verificare il seguito della pratica conclusa senza riaprire il preventivo.' end;
    end if;
   end if;
  end if;
 end if;
 update public.keplero_esiti_fonti set pratica_id=e.pratica_id,stato=v_stato,codice=v_codice,motivo=v_motivo,
  tentativi=tentativi+1,errore=null,prossimo_tentativo_at=now()+interval '5 minutes',updated_at=now()
  where fonte=p_fonte and chiave=p_chiave and not verificata_operatore;
 if e.pratica_id is not null then perform private.aggiorna_lavoro_pratica_k(e.pratica_id);end if;
exception when others then
 update public.keplero_esiti_fonti set stato='da_verificare',codice='errore_elaborazione',motivo='Errore di elaborazione: originale conservato, verifica tecnica richiesta.',
  errore=sqlstate,tentativi=tentativi+1,prossimo_tentativo_at=now()+interval '5 minutes',updated_at=now() where fonte=p_fonte and chiave=p_chiave;
end; $$;

create function private.riprova_pdf_originale_letto_k(p_sessione uuid,p_messaggio text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.keplero_originali%rowtype; d public.documenti_preventivo_auto%rowtype;
begin
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio;
 if m.modificato or m.direzione<>'uscita' or m.targa_pdf is null or m.sha256_pdf is null then
  return jsonb_build_object('esito','prova_non_verificata');end if;
 if (select count(distinct impronta) from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf)<>1 then
  return jsonb_build_object('esito','documento_assente_o_ambiguo');end if;
 select * into d from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf
  order by (stato='inviato') desc,ricevuto_at,id limit 1;
 return public.conferma_invio_documento_preventivo(d.id,jsonb_build_object('fonte','keplero_originale_verificato',
  'fonte_id','keplero:'||m.sessione||':'||m.messaggio_id,'direzione','uscita','esito','inviato',
  'impronta_documento',d.impronta,'messaggio_id',m.messaggio_id,'conversazione_id',m.sessione,
  'verificata_originale',true,'inviato_at',m.data_messaggio));
end; $$;

create function private.aggiorna_lavori_senza_pratica_k()
returns void language plpgsql security invoker set search_path='' as $$
begin
 -- Una scheda per conversazione, anche quando non esiste ancora la pratica.
 insert into public.keplero_lavori_pratiche(chiave,sessione,priorita,motivi)
 select coalesce('chat:'||sessione,fonte||':'||chiave),sessione,
  min(case when codice='consenso_non_registrato' then 0 else 1 end),
  jsonb_build_object('da_associare',jsonb_build_object('azione','Identificare l’episodio e completare la richiesta.',
   'fonti',jsonb_agg(jsonb_build_object('fonte',fonte,'chiave',chiave,'codice',codice,'motivo',motivo,'data',data_fonte) order by data_fonte desc)))
 from public.keplero_esiti_fonti where pratica_id is null and stato in ('ricevuto','in_attesa','da_verificare')
 group by coalesce('chat:'||sessione,fonte||':'||chiave),sessione
 on conflict(chiave) do update set motivi=excluded.motivi,priorita=excluded.priorita,ultimo_controllo_at=now(),risolta_at=null,
  stato=case when public.keplero_lavori_pratiche.stato='risolta' then 'aperta' else public.keplero_lavori_pratiche.stato end,
  versione=public.keplero_lavori_pratiche.versione+case when public.keplero_lavori_pratiche.motivi is distinct from excluded.motivi then 1 else 0 end;
 update public.keplero_lavori_pratiche l set stato='risolta',motivi='{}',risolta_at=coalesce(risolta_at,now()),ultimo_controllo_at=now()
 where l.pratica_id is null and not exists(select 1 from public.keplero_esiti_fonti e
  where e.pratica_id is null and e.stato in ('ricevuto','in_attesa','da_verificare')
   and coalesce('chat:'||e.sessione,e.fonte||':'||e.chiave)=l.chiave);
end; $$;

-- Il coordinatore usa gli stessi verificatori del canale live e del recupero
-- PDF. Non crea un secondo insieme di regole per accettare ordini.
create function public.riconcilia_esiti_commerciali_k(p_limite integer default 250,p_forza boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e record; p record; m public.keplero_originali%rowtype; n integer:=0;
begin
 if not p_forza and not (select attivo from public.keplero_stato_riconciliazione where id) then
  return jsonb_build_object('esito','sospeso');end if;
 if not pg_try_advisory_xact_lock(20261023,93423) then return jsonb_build_object('esito','in_corso');end if;
 if p_limite not between 1 and 2000 then raise exception 'Limite non valido';end if;
 update public.keplero_stato_riconciliazione set ultimo_tentativo_at=now() where id;
 for e in select fonte,chiave,sessione from public.keplero_esiti_fonti
  where not verificata_operatore and stato in ('ricevuto','in_attesa','da_verificare') and prossimo_tentativo_at<=now()
  order by (stato='ricevuto') desc,
   case when fonte='documento' then 0 when fonte='originale' and codice='pdf_inviato_non_collegato' then 1 when fonte='live' then 2 else 3 end,
   prossimo_tentativo_at,fonte,chiave limit p_limite
 loop
  begin
   if e.fonte='live' then
    perform private.riprocessa_evento_keplero(e.chiave::bigint);
   elsif e.fonte='originale' then
    select * into m from public.keplero_originali where sessione=e.sessione and messaggio_id=split_part(e.chiave,':',2);
    if m.direzione='uscita' and m.targa_pdf is not null then
     perform private.riprova_pdf_originale_letto_k(m.sessione,m.messaggio_id);
    elsif m.candidato then perform private.valuta_originale_k(m.sessione,m.messaggio_id);end if;
   end if;
   perform private.valuta_fonte_commerciale_k(e.fonte,e.chiave);
  exception when others then
   update public.keplero_esiti_fonti set stato='da_verificare',codice='errore_elaborazione',motivo='Elaborazione interrotta: prova conservata e recupero necessario.',
    errore=sqlstate,tentativi=tentativi+1,prossimo_tentativo_at=now()+interval '5 minutes',updated_at=now() where fonte=e.fonte and chiave=e.chiave;
  end;
  n:=n+1;
 end loop;
 for p in select id from public.pratiche where dati_raw->>'origine'='keplero_live'
  and (tipo_flusso='commerciale' or exists(select 1 from public.keplero_esiti_fonti fonte_pratica where fonte_pratica.pratica_id=pratiche.id and fonte_pratica.stato in ('ricevuto','da_verificare','in_attesa')))
 loop perform private.aggiorna_lavoro_pratica_k(p.id);end loop;
 perform private.aggiorna_lavori_senza_pratica_k();
 update public.keplero_stato_riconciliazione set ultimo_successo_at=now(),errore=null,esiti_elaborati=n where id;
 return jsonb_build_object('esito','completato','esiti_elaborati',n);
exception when others then
 update public.keplero_stato_riconciliazione set ultimo_tentativo_at=now(),errore=sqlstate where id;
 return jsonb_build_object('esito','errore','codice',sqlstate);
end; $$;

create function public.esito_registrazione_commerciale_k(p_pratica_id uuid,p_external_key text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.pratiche%rowtype; e record; lavoro public.keplero_lavori_pratiche%rowtype;
begin
 if not exists(select 1 from public.keplero_live_links where pratica_id=p_pratica_id and external_key=p_external_key) then
  raise exception 'Collegamento live non valido';end if;
 select * into p from public.pratiche where id=p_pratica_id;
 for e in select fonte,chiave from public.keplero_esiti_fonti where fonte='live' and pratica_id=p.id
  and stato='ricevuto' order by data_fonte desc limit 20
 loop perform private.valuta_fonte_commerciale_k(e.fonte,e.chiave);end loop;
 perform private.aggiorna_lavoro_pratica_k(p.id);
 select * into lavoro from public.keplero_lavori_pratiche where pratica_id=p.id;
 return jsonb_build_object('versione_contratto','2026-10-23-esiti-v1','pratica_id',p.id,'numero_pratica',p.numero_pratica,
  'ricevuta',true,'ordine_registrato',p.stato_commerciale='ordine_acquisito',
  'preventivo_inviato',p.preventivo_inviato_at is not null and p.stato_commerciale in ('preventivo_inviato','attesa_cliente','ordine_acquisito'),
  'stato_commerciale',p.stato_commerciale,'stato_fatturazione',p.stato_fatturazione,'stato_amministrativo',p.stato_amministrativo,
  'lavoro_aperto',coalesce(lavoro.stato<>'risolta',false),'lavoro_id',lavoro.chiave,'versione_lavoro',lavoro.versione,
  'requisiti',coalesce(lavoro.motivi,'{}'::jsonb),
  'istruzione',case when p.tipo_flusso='assistenza' then 'Richiesta di assistenza registrata per la verifica dell’operatore.'
   when p.tipo_flusso<>'commerciale' then 'Richiesta registrata per la verifica dell’operatore.'
   when p.stato_commerciale='ordine_acquisito' then
   case when p.stato_amministrativo='pronto_fatturazione' then 'Ordine registrato. Nessuna spedizione o prenotazione implicita.'
   else 'Accettazione registrata. Completare o verificare separatamente i dati amministrativi; non chiedere di confermare di nuovo l’ordine.' end
   when p.preventivo_inviato_at is not null then 'Preventivo già inviato. Non dichiarare che deve ancora essere preparato; verificare eventuali richieste del cliente.'
   when p.stato_commerciale in ('preventivo_inviato','attesa_cliente') then 'Stato di invio da verificare sui documenti: non preparare o inviare un duplicato senza controllo.'
   else 'Richiesta ricevuta e presa in carico per preparazione o verifica tecnica. Non dichiarare ordine acquisito né preventivo inviato.' end);
end; $$;

create function public.conserva_richiesta_senza_pratica_k(p_external_key text,p_sessione uuid,p_payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare k text:=encode(sha256(convert_to(p_external_key||':'||p_payload::text,'UTF8')),'hex');
begin
 if nullif(p_external_key,'') is null or length(p_payload::text)>200000 then raise exception 'Richiesta non valida';end if;
 perform private.conserva_fonte_k('richiesta',k,p_sessione,null,now(),k);
 update public.keplero_esiti_fonti set stato='in_attesa',codice='nuovo_episodio_senza_targa',contenuto_richiesta=p_payload,
  motivo='Nuova richiesta conservata: identificare il veicolo senza sovrascrivere la pratica precedente.'
  where fonte='richiesta' and chiave=k and not verificata_operatore;
 perform private.aggiorna_lavori_senza_pratica_k();
 return jsonb_build_object('ricevuta',true,'ordine_registrato',false,'riferimento',k,'azione','richiedi_targa');
end; $$;

create function public.prendi_in_carico_lavoro_k(p_chiave text,p_operatore text,p_versione bigint)
returns void language plpgsql security invoker set search_path='' as $$
begin
 if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4','Manutenzione autorizzata') then raise exception 'Operatore non valido';end if;
 update public.keplero_lavori_pratiche set stato='in_carico',responsabile=p_operatore,presa_in_carico_at=now(),versione=versione+1
 where chiave=p_chiave and stato<>'risolta' and versione=p_versione;
 if not found then raise exception 'La scheda è cambiata: aggiornare la pagina';end if;
end; $$;

create function public.verifica_esito_fonte_k(p_fonte text,p_chiave text,p_impronta text,p_nota text,p_operatore text)
returns void language plpgsql security invoker set search_path='' as $$
declare e public.keplero_esiti_fonti%rowtype;
begin
 if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4','Manutenzione autorizzata')
  or length(btrim(p_nota)) not between 10 and 2000 then raise exception 'Operatore e motivazione richiesti';end if;
 select * into e from public.keplero_esiti_fonti where fonte=p_fonte and chiave=p_chiave for update;
 if e.fonte is null or e.impronta is distinct from p_impronta then raise exception 'La fonte è cambiata: rileggere la prova';end if;
 update public.keplero_esiti_fonti set stato='applicato',codice='verifica_operatore',motivo=btrim(p_nota),
  verificata_operatore=true,operatore=p_operatore,verificata_at=now(),updated_at=now() where fonte=p_fonte and chiave=p_chiave;
 if e.pratica_id is not null then
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  values(e.pratica_id,'verifica_esito_fonte_k',p_fonte||':'||p_chiave||' — '||btrim(p_nota),to_jsonb(e),
   jsonb_build_object('esito','verifica_operatore'),p_operatore);
  perform private.aggiorna_lavoro_pratica_k(e.pratica_id);
 end if;
 perform private.aggiorna_lavori_senza_pratica_k();
end; $$;

revoke all on function private.storicizza_esito_k(),private.conserva_fonte_k(text,text,uuid,uuid,timestamptz,text),
 private.conserva_ingresso_k(),private.aggiorna_lavoro_pratica_k(uuid),private.ricalcola_lavoro_pratica_k(),
 private.valuta_fonte_commerciale_k(text,text),private.riprova_pdf_originale_letto_k(uuid,text),private.aggiorna_lavori_senza_pratica_k() from public,anon,authenticated;
grant execute on function private.storicizza_esito_k(),private.conserva_fonte_k(text,text,uuid,uuid,timestamptz,text),
 private.conserva_ingresso_k(),private.aggiorna_lavoro_pratica_k(uuid),private.ricalcola_lavoro_pratica_k(),
 private.valuta_fonte_commerciale_k(text,text),private.riprova_pdf_originale_letto_k(uuid,text),private.aggiorna_lavori_senza_pratica_k() to service_role;
revoke all on function public.riconcilia_esiti_commerciali_k(integer,boolean),public.esito_registrazione_commerciale_k(uuid,text),
 public.conserva_richiesta_senza_pratica_k(text,uuid,jsonb),public.prendi_in_carico_lavoro_k(text,text,bigint),public.verifica_esito_fonte_k(text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.riconcilia_esiti_commerciali_k(integer,boolean),public.esito_registrazione_commerciale_k(uuid,text),
 public.conserva_richiesta_senza_pratica_k(text,uuid,jsonb),public.prendi_in_carico_lavoro_k(text,text,bigint),public.verifica_esito_fonte_k(text,text,text,text,text) to service_role;

-- Backfill degli ingressi operativi recenti; gli ingressi futuri vengono
-- conservati senza scadenza dal trigger, anche per conversazioni nuove.
insert into public.keplero_esiti_fonti(fonte,chiave,sessione,pratica_id,data_fonte,impronta)
select 'live',id::text,private.sessione_chiave_k(external_key),pratica_id,created_at,
 encode(sha256(convert_to(payload::text,'UTF8')),'hex') from public.keplero_live_events
where created_at>=now()-interval '30 days' on conflict do nothing;
insert into public.keplero_esiti_fonti(fonte,chiave,sessione,data_fonte,impronta)
select 'originale',sessione||':'||messaggio_id,sessione,data_messaggio,
 impronta||coalesce(sha256_pdf,'')||modificato::text||coalesce(revisione->>'impronta','') from public.keplero_originali
where data_messaggio>=now()-interval '30 days' and (direzione='entrata' or targa_pdf is not null or modificato)
on conflict do nothing;
insert into public.keplero_esiti_fonti(fonte,chiave,pratica_id,data_fonte,impronta)
select 'documento',id::text,pratica_id,ricevuto_at,impronta||coalesce(sha256_pdf,'')||stato||coalesce(pratica_id::text,'')
from public.documenti_preventivo_auto on conflict do nothing;

create view public.keplero_lavori_pratiche_elenco with(security_invoker=true) as
select l.chiave,l.pratica_id,l.sessione,l.stato,l.priorita,l.responsabile,l.presa_in_carico_at,l.scadenza_at,
 l.prima_rilevazione_at,l.ultimo_controllo_at,l.risolta_at,l.versione,p.numero_pratica,p.nome_cliente,p.targa,
 coalesce(s.assistente,'2aef20d3-5ef8-4c81-8f21-bd450f22960c'::uuid) assistente,
 coalesce((l.motivi#>>'{richiesta_preventivo,verifica_tecnica}')::boolean,false) verifica_tecnica_necessaria,
 l.motivi#>>'{richiesta_preventivo,azione}' azione_preventivo,
 l.motivi#>'{richiesta_preventivo,dati_mancanti}' dati_mancanti,
 (select count(*) from public.keplero_esiti_fonti e where e.stato in ('ricevuto','in_attesa','da_verificare')
  and (e.pratica_id=l.pratica_id or (l.pratica_id is null and e.pratica_id is null
    and coalesce('chat:'||e.sessione,e.fonte||':'||e.chiave)=l.chiave))) fonti_aperte
from public.keplero_lavori_pratiche l left join public.pratiche p on p.id=l.pratica_id
left join public.keplero_sessioni_originali s on s.sessione=l.sessione;
revoke all on public.keplero_lavori_pratiche_elenco from public,anon,authenticated;
grant select on public.keplero_lavori_pratiche_elenco to service_role;

create function public.stato_esiti_commerciali_k()
returns jsonb language sql stable security invoker set search_path='' as $$
select jsonb_build_object('controllo',(select to_jsonb(s) from public.keplero_stato_riconciliazione s where id),
 'controllo_in_ritardo',not exists(select 1 from public.keplero_stato_riconciliazione where id and ultimo_successo_at>=now()-interval '5 minutes'),
 'lavori_aperti',(select count(*) from public.keplero_lavori_pratiche where stato<>'risolta'),
 'prioritari',(select count(*) from public.keplero_lavori_pratiche where stato<>'risolta' and priorita=0),
 'da_associare',(select count(*) from public.keplero_lavori_pratiche where stato<>'risolta' and pratica_id is null),
 'ingressi_in_elaborazione',(select count(*) from public.keplero_esiti_fonti where stato='ricevuto'),
 'ingressi_in_ritardo',(select count(*) from public.keplero_esiti_fonti where stato='ricevuto' and created_at<now()-interval '5 minutes'),
 'errori',(select count(*) from public.keplero_esiti_fonti where errore is not null and stato='da_verificare'),
 'originali_in_ritardo',not exists(select 1 from public.keplero_recupero_originali where id and automatico and ultimo_successo_at>=now()-interval '10 minutes' and errore_elenco is null),
 'fonte_originali',public.stato_originali_k());
$$;
revoke all on function public.stato_esiti_commerciali_k() from public,anon,authenticated;
grant execute on function public.stato_esiti_commerciali_k() to service_role;
select cron.schedule('riconcilia-esiti-commerciali','* * * * *','select public.riconcilia_esiti_commerciali_k();');
notify pgrst,'reload schema';


-- Un solo punto autorizza l’acquisizione, con offerta letta e scelta verificata.
CREATE OR REPLACE FUNCTION public.conferma_ordine_da_keplero(p_pratica_id uuid, p_external_key text, p_messaggio_cliente text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_prima public.pratiche%rowtype;
  v_dopo public.pratiche%rowtype;
  v_offerta public.offerte_versioni%rowtype; v_testo text; v_sessione uuid; v_evento bigint; v_prova jsonb; v_data_consenso timestamptz;
begin
  if lower(coalesce(p_messaggio_cliente,'')) ~ '\mnon\M.{0,50}\m(scelt[oa]|decis[oa])\M'
    or (lower(coalesce(p_messaggio_cliente,'')) ~ '\m(cliente|proprietario|officina)[[:space:]]+ha[[:space:]]+scelto\M'
       and not private.scelta_conclusa_cliente(p_messaggio_cliente)) then
    return jsonb_build_object('aggiornato',false,'motivo','scelta_riferita_non_conclusa','pratica_id',p_pratica_id);
  end if;

  if private.preferenza_senza_conferma(p_messaggio_cliente) or lower(coalesce(p_messaggio_cliente,'')) ~ '\m(se|qualora)\M.{0,80}(possibil|riparabil|disponib)' then
    return jsonb_build_object('aggiornato',false,'motivo','preferenza_non_confermata');
  end if;
  if p_pratica_id is null then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_non_valida');
  end if;

  select *
  into v_prima
  from public.pratiche
  where id = p_pratica_id
  for update;

  if not found then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_non_trovata');
  end if;

  if not exists (
    select 1
    from public.keplero_live_links
    where external_key = p_external_key
      and pratica_id = p_pratica_id
  ) then
    return jsonb_build_object('aggiornato', false, 'motivo', 'collegamento_keplero_non_valido');
  end if;

  if coalesce(v_prima.dati_raw #>> '{archiviazione_test,archiviata}', 'false') = 'true'
     or coalesce(v_prima.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') = 'true' then
    return jsonb_build_object('aggiornato', false, 'motivo', 'pratica_archiviata');
  end if;

  if v_prima.blocco_operatore then
    return jsonb_build_object('aggiornato',false,'motivo','blocco_operatore','pratica_id',p_pratica_id);
  end if;
  if exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
    and c.telefono_normalizzato=regexp_replace(coalesce(v_prima.telefono,''),'[^0-9]','','g')) then
    return jsonb_build_object('aggiornato',false,'motivo','contatto_operativo','pratica_id',p_pratica_id);
  end if;

  if private.domanda_su_accettazione(p_messaggio_cliente)
     or private.domanda_su_accettazione(v_prima.dati_raw->>'ultimo_messaggio_cliente') then
    return jsonb_build_object('aggiornato',false,'motivo','domanda_su_accettazione_non_e_ordine','pratica_id',p_pratica_id);
  end if;

  if private.scelta_dispositivo_originale(p_messaggio_cliente) and not exists(
    select 1 from public.scelte_cliente s join public.offerta_opzioni o on o.id=s.opzione_id
    where s.pratica_id=p_pratica_id and s.stato='confermata' and o.servizio in ('RI','RE','RC')) then
    return jsonb_build_object('aggiornato',false,'motivo','lavorazione_originale_da_chiarire','pratica_id',p_pratica_id);
  end if;

  -- I controlli terminali vengono eseguiti prima dei prerequisiti per
  -- mantenere la funzione idempotente anche per le pratiche avanzate a mano.
  if v_prima.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale then
    update public.preventivi
    set
      stato = 'accettato',
      accettato_at = coalesce(accettato_at, v_prima.ordine_acquisito_at, now())
    where pratica_id = p_pratica_id
      and stato = 'inviato' and (not exists(select 1 from public.scelte_cliente s where s.pratica_id=p_pratica_id and s.stato='confermata' and s.offerta_id is not null) or id=(select q.preventivo_id from public.scelte_cliente s join public.offerte_versioni q on q.id=s.offerta_id where s.pratica_id=p_pratica_id));

    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'ordine_gia_acquisito',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  if v_prima.stato_fatturazione = 'fatturato'::public.stato_fatturazione then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'pratica_gia_fatturata',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;


  -- Il solo flag AI non può acquisire un ordine. Tutti i chiamanti, inclusi
  -- replay, webhook e originali, attraversano questa stessa verifica.
  v_testo:=coalesce(nullif(btrim(p_messaggio_cliente),''),v_prima.dati_raw->>'ultimo_messaggio_cliente','');
  select id,created_at into v_evento,v_data_consenso from public.keplero_live_events e where e.pratica_id=v_prima.id
   and e.external_key=p_external_key and lower(translate(coalesce(e.payload->>'ultimo_messaggio_cliente',''),'àèéìòù’','aeeiou'''))=lower(translate(v_testo,'àèéìòù’','aeeiou'''))
   order by e.id desc limit 1;
  if v_evento is not null then
   v_prova:=private.ordine_da_conferma_letterale(v_evento);
   if coalesce(v_prova->>'confermato','false')<>'true' then v_prova:=private.ordine_da_scelta_e_fiscali(v_evento);end if;
  end if;
  if not private.conferma_letterale_offerta(v_testo)
   and not exists(select 1 from public.scelte_cliente sc where sc.pratica_id=v_prima.id and sc.stato='confermata')
   and coalesce(v_prova->>'confermato','false')<>'true'
  then return jsonb_build_object('aggiornato',false,'motivo','consenso_da_verificare','pratica_id',v_prima.id);end if;
  select * into v_offerta from public.offerte_versioni where pratica_id=v_prima.id
   order by inviato_at desc,registrata_at desc,versione desc limit 1;
  if v_offerta.id is null or v_offerta.stato<>'letta' then
   return jsonb_build_object('aggiornato',false,'motivo','offerta_non_letta','pratica_id',v_prima.id);end if;
  if not exists(select 1 from public.scelte_cliente sc join public.offerta_opzioni o on o.id=sc.opzione_id
   where sc.pratica_id=v_prima.id and sc.stato='confermata' and sc.offerta_id=v_offerta.id and o.offerta_id=v_offerta.id) then
   return jsonb_build_object('aggiornato',false,'motivo','scelta_offerta_non_verificata','pratica_id',v_prima.id);end if;
  v_data_consenso:=coalesce(v_data_consenso,(select sc.richiesta_at from public.scelte_cliente sc where sc.pratica_id=v_prima.id and sc.stato='confermata' and sc.offerta_id=v_offerta.id),now());
  if v_data_consenso>now()+interval '5 minutes' or v_data_consenso<v_offerta.inviato_at
   or (v_offerta.validita_giorni is not null and v_data_consenso>v_offerta.inviato_at+make_interval(days=>v_offerta.validita_giorni)) then
   return jsonb_build_object('aggiornato',false,'motivo','offerta_scaduta_o_tempi_discordanti','pratica_id',v_prima.id);end if;
  v_sessione:=private.sessione_chiave_k(p_external_key);
  if v_sessione is not null and position(upper(regexp_replace(coalesce(v_prima.targa,''),'[^A-Za-z0-9]','','g'))
   in upper(regexp_replace(v_testo,'[^A-Za-z0-9]','','g')))=0
   and (select count(distinct pc.id) from public.keplero_pratiche_conversazioni c join public.pratiche pc on pc.id=c.pratica_id
    where c.sessione=v_sessione and pc.tipo_flusso='commerciale' and pc.stato_fatturazione='non_applicabile'
    and pc.stato_commerciale in ('preventivo_inviato','attesa_cliente')
    and exists(select 1 from public.offerte_versioni q where q.pratica_id=pc.id)
    and coalesce(pc.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
    and coalesce(pc.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true')>1
   and not exists(select 1 from public.scelte_cliente sc where sc.pratica_id=v_prima.id and sc.protetta_operatore)
  then return jsonb_build_object('aggiornato',false,'motivo','episodio_da_chiarire','pratica_id',v_prima.id);end if;

  -- Una correzione operatore a "Preventivo inviato" è già una prova
  -- sufficiente dell'invio, anche se non esiste un record in preventivi.
  -- Anche un flag/riepilogo positivo può essere errato. Il rinvio espresso
  -- nel messaggio letterale prevale e vale per trigger e chiamata HTTP diretta.
  if private.rinvio_conferma_per_verifiche(coalesce(
    nullif(btrim(p_messaggio_cliente),''),
    v_prima.dati_raw->>'ultimo_messaggio_cliente','')) then
    return jsonb_build_object('aggiornato',false,
      'motivo','cliente_in_verifica_prima_della_conferma','pratica_id',p_pratica_id);
  end if;

  if not exists (
    select 1
    from public.preventivi pv
    where pv.pratica_id = p_pratica_id
      and pv.stato in ('inviato', 'accettato')
  ) and not (
    v_prima.stato_commerciale in (
      'preventivo_inviato'::public.stato_commerciale,
      'attesa_cliente'::public.stato_commerciale
    )
    and v_prima.preventivo_inviato_at is not null
  ) then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'preventivo_non_registrato',
      'pratica_id', p_pratica_id
    );
  end if;

  if v_prima.stato_commerciale not in (
    'da_preventivare'::public.stato_commerciale,
    'preventivo_pronto'::public.stato_commerciale,
    'preventivo_inviato'::public.stato_commerciale,
    'attesa_cliente'::public.stato_commerciale
  ) then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'stato_non_abilitato',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  if
    v_prima.stato_commerciale = 'da_preventivare'::public.stato_commerciale
    and v_prima.stato_completezza <> 'completa_da_preventivare'::public.stato_completezza
  then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'dati_non_completi',
      'stato_commerciale', v_prima.stato_commerciale
    );
  end if;

  update public.pratiche
  set
    tipo_flusso = 'commerciale'::public.tipo_flusso,
    stato_commerciale = 'ordine_acquisito'::public.stato_commerciale,
    stato_fatturazione = 'da_fatturare'::public.stato_fatturazione,
    preventivo_inviato_at = coalesce(preventivo_inviato_at, now()),
    ordine_acquisito_at = coalesce(ordine_acquisito_at, v_data_consenso, now()),
    dati_raw = coalesce(dati_raw,'{}'::jsonb)||case when v_evento is not null and v_prova->>'confermato'='true' then
      jsonb_build_object('conferma_ordine_verificata',v_prova||jsonb_build_object('event_id',v_evento,'external_key',p_external_key,'confermata_at',v_data_consenso,'registrata_at',now(),'messaggio',v_testo)) else '{}'::jsonb end,
    data_fattura = null,
    blocco_classificazione_operatore = true
  where id = p_pratica_id
    and stato_commerciale in (
      'da_preventivare'::public.stato_commerciale,
      'preventivo_pronto'::public.stato_commerciale,
      'preventivo_inviato'::public.stato_commerciale,
      'attesa_cliente'::public.stato_commerciale
    )
  returning * into v_dopo;

  if not found then
    return jsonb_build_object(
      'aggiornato', false,
      'motivo', 'stato_modificato_contemporaneamente'
    );
  end if;

  update public.preventivi
  set
    stato = 'accettato',
    accettato_at = coalesce(accettato_at, v_dopo.ordine_acquisito_at, now())
  where pratica_id = p_pratica_id
    and stato = 'inviato' and (not exists(select 1 from public.scelte_cliente s where s.pratica_id=p_pratica_id and s.stato='confermata' and s.offerta_id is not null) or id=(select q.preventivo_id from public.scelte_cliente s join public.offerte_versioni q on q.id=s.offerta_id where s.pratica_id=p_pratica_id));

  insert into public.azioni_operatore (
    pratica_id,
    azione,
    nota,
    stato_prima,
    stato_dopo
  )
  values (
    p_pratica_id,
    'keplero_ordine_acquisito',
    case
      when nullif(trim(coalesce(p_messaggio_cliente, '')), '') is null
        then 'Keplero ha rilevato una conferma esplicita dell''ordine/preventivo da parte del cliente.'
      else 'Conferma esplicita rilevata da Keplero: ' || left(trim(p_messaggio_cliente), 1000)
    end,
    to_jsonb(v_prima),
    to_jsonb(v_dopo)
  );

  return jsonb_build_object(
    'aggiornato', true,
    'motivo', 'conferma_esplicita_cliente',
    'pratica_id', p_pratica_id,
    'stato_precedente', v_prima.stato_commerciale,
    'stato_commerciale', v_dopo.stato_commerciale,
    'stato_fatturazione', v_dopo.stato_fatturazione
  );
end;
$function$;


CREATE OR REPLACE FUNCTION private.elabora_evento_keplero(p_event_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_evento public.keplero_live_events%rowtype;
begin
 select * into v_evento from public.keplero_live_events where id=p_event_id;
 if not found then raise exception 'Evento non trovato'; end if;
 declare
  v_decisione jsonb := coalesce(v_evento.payload -> 'decisione_sistema', '{}'::jsonb);
  v_versione text := coalesce(
    nullif(v_decisione ->> 'versione_regole', ''),
    'legacy-non-strutturato'
  );
  v_ordine boolean := coalesce(
    (v_decisione #>> '{ordine,confermato}')::boolean,
    (v_evento.payload ->> 'ordine_confermato_rilevato')::boolean,
    false
  );
  v_contesto_ordine jsonb := '{}'::jsonb;
  v_allegati jsonb := '[]'::jsonb;
  v_esito_ordine jsonb := '{}'::jsonb;
  v_esito_allegati jsonb := '{}'::jsonb;
  v_stato text := 'elaborato';
begin
  if v_evento.pratica_id is null then
    v_stato := 'da_verificare';
  end if;

  if v_evento.pratica_id is not null then
    v_contesto_ordine := private.ordine_da_conferma_letterale(v_evento.id);
    if not v_ordine and coalesce(v_contesto_ordine->>'confermato','false')<>'true' then
      v_contesto_ordine := private.ordine_da_scelta_e_fiscali(v_evento.id);
    end if;
    perform private.rileva_scelta_cliente_evento(v_evento.id);
    v_ordine := v_ordine or coalesce((v_contesto_ordine->>'confermato')::boolean,false);
  end if;

  if v_evento.pratica_id is not null and v_ordine then
    if coalesce(v_contesto_ordine->>'confermato','false')='true' then
      v_esito_ordine := private.conferma_ordine_evento_verificato(v_evento.id)->'avanzamento';
      if v_esito_ordine is null then v_esito_ordine:=public.conferma_ordine_da_keplero(v_evento.pratica_id,v_evento.external_key,v_evento.payload->>'ultimo_messaggio_cliente');end if;
    else
    v_esito_ordine := public.conferma_ordine_da_keplero(
      v_evento.pratica_id,
      v_evento.external_key,
      coalesce(
        v_evento.payload ->> 'ultimo_messaggio_cliente',
        v_evento.payload ->> 'messaggio_cliente',
        v_evento.payload ->> 'messaggio'
      )
    );

    end if;

    if coalesce(v_esito_ordine ->> 'motivo', '') in (
      'preventivo_non_registrato',
      'collegamento_keplero_non_valido',
      'stato_non_abilitato',
      'dati_non_completi','consenso_da_verificare','offerta_non_letta','scelta_offerta_non_verificata','episodio_da_chiarire','offerta_scaduta_o_tempi_discordanti'
    ) then
      v_stato := 'da_verificare';
    end if;
  end if;

  with sorgenti as (
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'allegati') = 'array'
          then v_evento.payload -> 'allegati'
        when jsonb_typeof(v_evento.payload -> 'allegati') = 'string'
          then jsonb_build_array(v_evento.payload -> 'allegati')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'attachments') = 'array'
          then v_evento.payload -> 'attachments'
        when jsonb_typeof(v_evento.payload -> 'attachments') = 'string'
          then jsonb_build_array(v_evento.payload -> 'attachments')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'attachment_urls') = 'array'
          then v_evento.payload -> 'attachment_urls'
        when jsonb_typeof(v_evento.payload -> 'attachment_urls') = 'string'
          then jsonb_build_array(v_evento.payload -> 'attachment_urls')
        else '[]'::jsonb
      end
    ) elemento
  ), valori as (
    select case
      when jsonb_typeof(elemento) = 'object' then elemento ->> 'url'
      when jsonb_typeof(elemento) = 'string' then elemento #>> '{}'
      else null
    end valore
    from sorgenti
  ), url as (
    select distinct (regexp_match(valore, 'https?://[^[:space:]<>"]+'))[1] valore
    from valori
    where valore ~ 'https?://'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'url', valore,
    'tipo', case when lower(valore) ~ '[.]pdf([?]|$)' then 'PDF' else 'Allegato' end
  )), '[]'::jsonb)
  into v_allegati
  from url
  where valore is not null;

  if v_evento.pratica_id is not null and jsonb_array_length(v_allegati) > 0 then
    v_esito_allegati := public.sincronizza_allegati_keplero(
      v_evento.pratica_id,
      v_allegati
    );
  elsif v_evento.pratica_id is not null and (
    coalesce(v_evento.payload ->> 'stato_lettura_immagini', '') = 'file_non_trasmessi_da_keplero'
    or coalesce(v_evento.payload ->> 'allegati_descritti_ma_non_trasmessi', 'false') = 'true'
  ) then
    v_stato := 'da_verificare';
  end if;

  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore,
    tentativi, elaborato_at, updated_at
  ) values (
    v_evento.id, v_evento.pratica_id, v_versione, v_stato,
    jsonb_build_object(
      'decisione_ricevuta', v_decisione,
      'esito_ordine', v_esito_ordine,
      'contesto_ordine', v_contesto_ordine,
      'esito_allegati', v_esito_allegati,
      'numero_allegati_url', jsonb_array_length(v_allegati)
    ),
    null, 1, now(), now()
  )
  on conflict (event_id) do update set
    pratica_id = excluded.pratica_id,
    versione_regole = excluded.versione_regole,
    stato = excluded.stato,
    decisione = excluded.decisione,
    errore = null,
    tentativi = private.keplero_event_processing.tentativi + 1,
    elaborato_at = now(),
    updated_at = now();

  return;
exception when others then
  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore
  ) values (
    v_evento.id, v_evento.pratica_id, v_versione, 'errore', v_decisione, sqlerrm
  )
  on conflict (event_id) do update set
    stato = 'errore',
    errore = excluded.errore,
    tentativi = private.keplero_event_processing.tentativi + 1,
    updated_at = now();

  return;
end;

end;
$function$;


-- La scelta breve completa il consenso precedente anche prima dell’acquisizione.
CREATE OR REPLACE FUNCTION private.rileva_scelta_cliente_evento(p_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype; q public.offerte_versioni%rowtype;
 s public.scelte_cliente%rowtype; o public.offerta_opzioni%rowtype; t text; v_stato text; v_count integer;
 v_ids uuid[]; v_riferimento text; v_tipi integer; v_tipo text; v_num integer; v_importo numeric; v_ha_riferimento boolean:=false; v_conferma boolean; v_risposta_breve boolean;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id for update;
 if not found or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then return '{}'::jsonb; end if;
 if not exists(select 1 from public.keplero_live_links where pratica_id=p.id and external_key=e.external_key) then return '{}'::jsonb; end if;
 if nullif(e.payload->>'targa','') is not null and upper(regexp_replace(e.payload->>'targa','[^A-Za-z0-9]','','g'))<>upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) then return '{}'::jsonb; end if;
 t:=lower(translate(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),'àèéìòù’','aeeiou'''));
 if t='' then return '{}'::jsonb; end if;
 select * into s from public.scelte_cliente where pratica_id=p.id;
 if s.evento_id=e.id and s.stato='confermata' then return jsonb_build_object('esito','conferma_preservata');end if;
 if s.protetta_operatore or (s.evento_id is not null and s.evento_id>e.id) then return jsonb_build_object('esito','scelta_preservata'); end if;
 if private.revoca_scelta_cliente(t) then
  if s.pratica_id is null then return '{}'::jsonb; end if;
  v_stato:=case when s.stato='confermata' then 'modifica_da_verificare' else 'revocata' end;
  v_ids:=array[s.opzione_id];
  select * into q from public.offerte_versioni where id=s.offerta_id;
 else
  if private.domanda_su_accettazione(t) then return '{}'::jsonb; end if;
  if t~'\mnon\M.{0,20}\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo|scelgo|scegliamo|ho deciso|ha deciso)\M' then return '{}'::jsonb; end if;
  v_risposta_breve:=btrim(t)~'^((la|solo)[[:space:]]+)?(ri|re|rc|ps|psmi|opzione[[:space:]]+[1-8]|programma scambio( made in italy)?)([.! ]*$|[,; ]+\m(se|qualora|altrimenti)\M)';
  v_risposta_breve:=v_risposta_breve or private.scelta_dispositivo_originale(t);
  if not v_risposta_breve and t!~'(opzione|offerta|proposta|preventivo|ordine|lavorazione|ripar|revision|programma scambio|€|\m(ri|re|rc|ps|psmi|prezzo|importo|euro)\M)'
   and btrim(t)!~'^(?:(?:buongiorno|buonasera|ciao|ok)[,!. ]*)?(accetto|accettiamo|confermo|confermiamo|procedete|procediamo)[.! ]*$' then return '{}'::jsonb; end if;
  if t !~ '\m(preferisco|preferiamo|preferirei|preferiremmo|sceglierei|sceglieremmo|scelgo|scegliamo|accetto|accettiamo|confermo|confermiamo|procedete|procediamo)\M|scelt|deciso per|sta bene|pratica confermata|vorrei revisionare|voglio riparare' and not v_risposta_breve then return '{}'::jsonb; end if;
  select * into q from public.offerte_versioni where pratica_id=p.id and inviato_at<=e.created_at
   order by inviato_at desc,registrata_at desc,versione desc limit 1;
  if q.id is null and not exists(select 1 from public.preventivi where pratica_id=p.id and coalesce(inviato_at,creato_at)<=e.created_at) then return '{}'::jsonb; end if;
  select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id;
  v_riferimento:=(regexp_split_to_array(t,'\m(se|qualora|altrimenti)\M'))[1];
  v_riferimento:=regexp_replace(v_riferimento,'\mnon\M[[:space:]]+(?:(?:voglio|vogliamo|preferisco|il|la)[[:space:]]+)?(?:programma scambio(?: made in italy)?|revisione completa|ri|re|rc|psmi|ps)\M',' ','g');
  v_tipi:=(case when v_riferimento~'\mrc\M|revisione completa' then 1 else 0 end)+(case when v_riferimento~'\mri\M|idraulic' then 1 else 0 end)+(case when v_riferimento~'\mre\M|elettronic' then 1 else 0 end)
   +(case when v_riferimento~'\mpsmi\M|programma scambio made in italy' then 1 else 0 end)
   +(case when regexp_replace(v_riferimento,'programma scambio made in italy','psmi','g')~'\mps\M|programma scambio' then 1 else 0 end);
  if v_riferimento ~ '\mpsmi\M|programma scambio made in italy' then v_tipo:='PSMI';
  elsif v_riferimento ~ '\mps\M|programma scambio' then v_tipo:='PS';
  elsif v_riferimento ~ '\mri\M|idraulic' then v_tipo:='RI';
  elsif v_riferimento ~ '\mre\M|elettronic' then v_tipo:='RE';
  elsif v_riferimento ~ '\mrc\M|revisione completa' then v_tipo:='RC'; end if;
  if v_riferimento ~ '(programma scambio|\mps\M)' and v_riferimento !~ '(made in italy|\mpsmi\M)' and v_riferimento !~ '\mps\M' then
   if exists(select 1 from public.offerta_opzioni where offerta_id=q.id and servizio='PSMI') then v_tipo:='SCAMBIO_GENERICO'; end if;
  end if;
  if v_tipo is not null then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids)
    and (servizio=v_tipo or (v_tipo='SCAMBIO_GENERICO' and servizio in ('PS','PSMI')));
  end if;
  if private.scelta_dispositivo_originale(t) or t~'\m(riparare|revisionare)\M[[:space:]]+(la mia|la nostra|il mio|il nostro)\M' then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids) and servizio in ('RI','RE','RC');
  end if;
  v_num:=(regexp_match(v_riferimento,'(?:opzione|offerta|proposta)\s*(?:n[.]?\s*)?([1-8])\M'))[1]::integer;
  if v_num is null then
   v_num:=case when v_riferimento~'\mprima\M.{0,20}(proposta|offerta|opzione)|\m(prima proposta|prima offerta|prima opzione)\M' then 1
    when v_riferimento~'\mseconda\M.{0,20}(proposta|offerta|opzione)' then 2
    when v_riferimento~'\mterza\M.{0,20}(proposta|offerta|opzione)' then 3 end;
  end if;
  if v_num is not null then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids) and numero=v_num and numero_esplicito;
  end if;
  v_importo:=private.importo_riferimento_offerta((regexp_match(v_riferimento,'(?:€\s*|quella di\s*|quello di\s*|da\s+)([0-9]{1,3}(?:[.][0-9]{3})+(?:,[0-9]{2})?|[0-9]{2,5}(?:[,.][0-9]{2})?)'))[1]);
  if v_importo is null then v_importo:=private.importo_riferimento_offerta((regexp_match(v_riferimento,'([0-9]{1,3}(?:[.][0-9]{3})+(?:,[0-9]{2})?|[0-9]{2,5}(?:[,.][0-9]{2})?)\s*(?:euro|€)'))[1]); end if;
  if v_importo is not null then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids) and importo=v_importo and (v_tipo is not null or v_num is not null or iva_inclusa=true);
  end if;
  if v_tipi>1 or v_riferimento~'(opzione|offerta|proposta)[[:space:]]*[1-8].{0,20}((opzione|offerta|proposta)[[:space:]]*[1-8]|\me\M[[:space:]]*[1-8])' then v_ids:=null; end if;
  v_count:=coalesce(cardinality(v_ids),0);
  -- Più servizi o alternative sono una scelta condizionata/ambigua, mai un ordine incondizionato.
  v_conferma:=not private.preferenza_senza_conferma(t) and not private.rinvio_conferma_per_verifiche(t)
   and t !~ '\m(se|qualora|altrimenti|eventualmente|forse)\M'
   and (private.conferma_letterale_offerta(t) or t ~ '\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo|scelgo|scegliamo)\M|ha deciso per');
  if v_risposta_breve and s.stato='da_chiarire' and s.offerta_id=q.id and s.richiesta_at>=q.inviato_at and s.richiesta_at<=e.created_at
   and private.conferma_letterale_offerta(s.evidenza) and not private.preferenza_senza_conferma(s.evidenza)
   and not exists(select 1 from public.keplero_live_events r where r.pratica_id=p.id and r.id>s.evento_id and r.id<e.id
    and private.revoca_scelta_cliente(coalesce(r.payload->>'ultimo_messaggio_cliente',''))) then v_conferma:=true; end if;
  if v_risposta_breve and s.stato='confermata' and s.offerta_id=q.id and cardinality(v_ids)=1
   and s.opzione_id=v_ids[1] and not private.preferenza_senza_conferma(t)
   and not private.rinvio_conferma_per_verifiche(t) and t !~ '\m(se|qualora|altrimenti|eventualmente|forse)\M'
  then return jsonb_build_object('esito','conferma_preservata');end if;
  v_stato:=case when t~'\m(se|qualora|altrimenti)\M' then 'condizionata'
   when v_conferma and v_count=1 and q.stato='letta' then 'confermata'
   when v_conferma or v_count<>1 then 'da_chiarire' else 'preferenza' end;
  if q.validita_giorni is not null and e.created_at>q.inviato_at+make_interval(days=>q.validita_giorni) then v_stato:='da_chiarire'; end if;
  if s.stato in ('confermata','modifica_da_verificare') then
   if s.offerta_id is distinct from q.id or s.opzione_id is distinct from (v_ids)[1] or v_stato<>'confermata' then
    v_stato:='modifica_da_verificare'; v_ids:=array[s.opzione_id]; select * into q from public.offerte_versioni where id=s.offerta_id;
   else return jsonb_build_object('esito','conferma_preservata'); end if;
  end if;
 end if;
 select * into o from public.offerta_opzioni where id=case when cardinality(v_ids)=1 then v_ids[1] else null end;
 if s.evento_id=e.id and s.offerta_id is not distinct from q.id and s.opzione_id is not distinct from o.id and s.stato=v_stato then return jsonb_build_object('esito','evento_gia_elaborato'); end if;
 insert into public.scelte_cliente(pratica_id,offerta_id,opzione_id,stato,evento_id,evidenza,richiesta_at,fonte)
 values(p.id,q.id,o.id,v_stato,e.id,coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),e.created_at,'keplero_live')
 on conflict(pratica_id) do update set offerta_id=excluded.offerta_id,opzione_id=excluded.opzione_id,
  stato=excluded.stato,evento_id=excluded.evento_id,evidenza=excluded.evidenza,richiesta_at=excluded.richiesta_at,updated_at=now();
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'scelta_cliente_rilevata',v_stato||' - '||coalesce(o.servizio,'soluzione da chiarire'),to_jsonb(s),
  jsonb_build_object('offerta_id',q.id,'opzione_id',o.id,'event_id',e.id,'stato',v_stato,'evidenza',t),'routine_controllo_k');
 if v_stato='confermata' and not p.blocco_operatore then perform public.conferma_ordine_da_keplero(p.id,e.external_key,t); end if;
 return jsonb_build_object('stato',v_stato,'offerta_id',q.id,'opzione_id',o.id,'servizio',o.servizio);
end; $function$;


revoke all on function private.rileva_scelta_cliente_evento(bigint) from public,anon,authenticated;
grant execute on function private.rileva_scelta_cliente_evento(bigint) to service_role;

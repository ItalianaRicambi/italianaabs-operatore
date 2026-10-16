select pg_catalog.pg_advisory_xact_lock(20261008,83825);
-- Drive prova la preparazione del documento, non l'invio al cliente.
create table public.documenti_preventivo_auto (
 id uuid primary key default gen_random_uuid(),
 external_id text not null check(length(external_id) between 1 and 255),
 impronta text not null check(impronta ~ '^[a-f0-9]{64}$'),
 sha256_pdf text check(sha256_pdf ~ '^[a-f0-9]{64}$'),
 nome_file text not null, targa text not null, file_url text,
 data_offerta timestamptz not null, ricevuto_at timestamptz not null default now(),
 contenuto jsonb not null,
 pratica_id uuid references public.pratiche(id),
 stato text not null default 'da_abbinare' check(stato in ('da_abbinare','pronto','da_verificare','inviato')),
 motivo text, ultimo_tentativo_at timestamptz,
 prova_invio jsonb, fonte_invio_id text unique, preventivo_id uuid references public.preventivi(id),
 unique(external_id,impronta)
);
alter table public.documenti_preventivo_auto enable row level security;
revoke all on public.documenti_preventivo_auto from public,anon,authenticated;
grant select,insert,update on public.documenti_preventivo_auto to service_role;
create index documenti_preventivo_pratica on public.documenti_preventivo_auto(pratica_id,data_offerta desc);
create index documenti_preventivo_pendenti on public.documenti_preventivo_auto(ultimo_tentativo_at) where stato<>'inviato';

create function private.abbina_documento_preventivo(p_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.documenti_preventivo_auto%rowtype; candidati uuid[];
begin
 select * into d from public.documenti_preventivo_auto where id=p_id for update;
 if d.id is null then raise exception 'Documento assente'; end if;
 if d.stato='inviato' then return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito','inviato','pratica_id',d.pratica_id); end if;
 -- Una targa condivisa da più episodi non permette di scegliere arbitrariamente.
 select array_agg(p.id) into candidati from public.pratiche p
 where upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g'))=d.targa
 and p.tipo_flusso='commerciale' and p.stato_commerciale in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto','preventivo_inviato','attesa_cliente','richiesta_verifica')
 and p.stato_fatturazione='non_applicabile'
 and p.created_at<=d.data_offerta+interval '5 minutes'
 and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
 and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
 update public.documenti_preventivo_auto set ultimo_tentativo_at=now(),
 pratica_id=case when cardinality(candidati)=1 then candidati[1] end,
 stato=case when coalesce(cardinality(candidati),0)<>1 then 'da_abbinare'
   when prova_invio is not null or nullif(contenuto->>'errore','') is not null then 'da_verificare' else 'pronto' end,
 motivo=case when coalesce(cardinality(candidati),0)=0 then 'Nessuna pratica compatibile con targa e data del documento.'
   when cardinality(candidati)>1 then 'Più pratiche compatibili: verificare l’abbinamento.'
   when prova_invio is not null then 'Invio rilevato: aggiornamento della pratica da verificare.'
   when nullif(contenuto->>'errore','') is not null then left(contenuto->>'errore',500)
   else 'PDF acquisito. Invio al cliente non ancora verificato.' end
 where id=d.id returning * into d;
 -- Nessuna modifica a classificazione, completezza o stato della pratica.
 return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito',d.stato,'pratica_id',d.pratica_id);
end; $$;
revoke all on function private.abbina_documento_preventivo(uuid) from public,anon,authenticated;
grant execute on function private.abbina_documento_preventivo(uuid) to service_role;

create function public.registra_documento_preventivo_auto(p_dati jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.documenti_preventivo_auto%rowtype; c jsonb:=p_dati->'contenuto';
 t text:=upper(regexp_replace(coalesce(p_dati->>'targa',''),'[^A-Za-z0-9]','','g'));
 data_doc timestamptz:=(p_dati->>'data_offerta')::timestamptz;
begin
 if coalesce(p_dati->>'external_id','')='' or length(p_dati->>'external_id')>255
 or coalesce(c->>'impronta','')!~'^[a-f0-9]{64}$'
 or t!~'^[A-Z0-9]{4,12}$' or coalesce(p_dati->>'nome_file','')!~*'\.pdf$'
 or upper(regexp_replace(regexp_replace(regexp_replace(p_dati->>'nome_file','\.pdf$','','i'),'\s*\([0-9]+\)$',''),'[^A-Za-z0-9]','','g'))<>t
 or data_doc is null or data_doc>now()+interval '1 day'
 or jsonb_typeof(c->'opzioni') is distinct from 'array' or jsonb_array_length(c->'opzioni')>8
 then raise exception 'Documento preventivo non valido'; end if;
 if nullif(c->>'errore','') is null and jsonb_array_length(c->'opzioni')=0 then raise exception 'Alternative assenti'; end if;
 if exists(select 1 from jsonb_array_elements(c->'opzioni') o where
 coalesce(o->>'servizio','') not in ('RI','RE','PS','PSMI') or (o->>'importo')::numeric<=0
 or (o->>'importo')::numeric>100000 or (o->>'importo')::numeric is null
 or (o->>'numero')::int not between 1 and 8 or (o->>'numero')::int is null)
 then raise exception 'Alternative non valide'; end if;
 insert into public.documenti_preventivo_auto(external_id,impronta,sha256_pdf,nome_file,targa,file_url,data_offerta,contenuto)
 values(p_dati->>'external_id',c->>'impronta',p_dati->>'sha256_pdf',p_dati->>'nome_file',t,
 nullif(p_dati->>'file_url',''),data_doc,c)
 on conflict(external_id,impronta) do nothing;
 select * into d from public.documenti_preventivo_auto where external_id=p_dati->>'external_id' and impronta=c->>'impronta' for update;
 -- Retry tardivi non cambiano i dati/documenti già collegati.
 if d.targa<>t then raise exception 'Identità documento discordante'; end if;
 return private.abbina_documento_preventivo(d.id);
end; $$;
revoke all on function public.registra_documento_preventivo_auto(jsonb) from public,anon,authenticated;
grant execute on function public.registra_documento_preventivo_auto(jsonb) to service_role;

-- Chiamata esclusivamente dal server DOPO verifica dell'originale, mai dal testo di K.
create function public.conferma_invio_documento_preventivo(p_documento_id uuid,p_prova jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.documenti_preventivo_auto%rowtype; p public.pratiche%rowtype; a public.azioni_operatore%rowtype;
 r jsonb; invio timestamptz:=(p_prova->>'inviato_at')::timestamptz; fonte_id text:=p_prova->>'fonte_id';
begin
 select * into d from public.documenti_preventivo_auto where id=p_documento_id for update;
 if d.id is null then raise exception 'Documento assente'; end if;
 if coalesce(fonte_id,'')='' or length(fonte_id)>255 or invio is null or invio>now()+interval '5 minutes'
 or invio<d.data_offerta-interval '5 minutes' then raise exception 'Prova invio non valida'; end if;
 if d.stato='inviato' then return jsonb_build_object('ok',true,'esito','gia_registrato','preventivo_id',d.preventivo_id); end if;
 perform private.abbina_documento_preventivo(d.id);
 select * into d from public.documenti_preventivo_auto where id=d.id;
 if d.pratica_id is null then return jsonb_build_object('ok',false,'esito','da_abbinare'); end if;
 select * into p from public.pratiche where id=d.pratica_id;
 if p_prova->>'fonte'='operatore' then
  select * into a from public.azioni_operatore where id=(p_prova->>'azione_id')::bigint
  and pratica_id=p.id and azione='commerciale_preventivo_inviato'
  and operatore in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') and created_at=invio;
  if a.id is null or fonte_id<>'operatore:'||a.id then raise exception 'Conferma operatore non verificata'; end if;
 elsif p_prova->>'fonte'='keplero_originale_verificato' then
  if p_prova->>'direzione' is distinct from 'uscita' or p_prova->>'esito' is distinct from 'inviato'
   or p_prova->>'impronta_documento' is distinct from d.impronta
   or coalesce(p_prova->>'messaggio_id','')!~'^[A-Za-z0-9_-]{1,100}$'
   or coalesce(p_prova->>'conversazione_id','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   or fonte_id<>'keplero:'||(p_prova->>'conversazione_id')||':'||(p_prova->>'messaggio_id')
   or p.keplero_conversation_id::text is distinct from p_prova->>'conversazione_id'
   or coalesce((p_prova->>'verificata_originale')::boolean,false) is not true
  then raise exception 'Messaggio originale non verificato'; end if;
 else raise exception 'Fonte prova invio non ammessa'; end if;
 -- La prova non sostituisce una correzione umana o riapre ordini già avanzati.
 if p.stato_commerciale in ('ordine_acquisito','chiuso','perso','rifiutato') or p.stato_fatturazione<>'non_applicabile'
 then return jsonb_build_object('ok',false,'esito','stato_avanzato_protetto'); end if;
 update public.documenti_preventivo_auto set prova_invio=p_prova,fonte_invio_id=fonte_id where id=d.id;
 r:=public.registra_preventivo_con_offerta('drive:'||encode(sha256(convert_to(d.external_id,'UTF8')),'hex')||':'||d.impronta,d.targa||'.pdf',d.targa,d.file_url,d.data_offerta,invio,d.contenuto);
 if r->>'preventivo_id' is null then
  update public.documenti_preventivo_auto set stato='da_verificare',motivo='Invio verificato; aggiornamento protetto: '||coalesce(r->>'esito','da verificare') where id=d.id;
  return r;
 end if;
 if r->>'pratica_id' is distinct from d.pratica_id::text then raise exception 'Abbinamento del preventivo discordante'; end if;
 update public.documenti_preventivo_auto set stato='inviato',motivo='Invio verificato.',
  prova_invio=p_prova,fonte_invio_id=fonte_id,preventivo_id=(r->>'preventivo_id')::uuid where id=d.id;
 return r||jsonb_build_object('ok',true,'documento_id',d.id);
end; $$;
revoke all on function public.conferma_invio_documento_preventivo(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.conferma_invio_documento_preventivo(uuid,jsonb) to service_role;

create function private.documento_dopo_conferma_operatore()
returns trigger language plpgsql security invoker set search_path='' as $$
declare doc uuid;
begin
 if new.azione<>'commerciale_preventivo_inviato' or new.operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') then return new; end if;
 -- Un unico documento recente: più versioni/copie richiedono verifica, non una scelta arbitraria.
 select (array_agg(id))[1] into doc from public.documenti_preventivo_auto
 where pratica_id=new.pratica_id and stato in ('pronto','da_verificare')
 and data_offerta between new.created_at-interval '30 days' and new.created_at+interval '5 minutes'
 having count(*)=1;
 if doc is not null then
  perform public.conferma_invio_documento_preventivo(doc,jsonb_build_object('fonte','operatore','fonte_id','operatore:'||new.id,'azione_id',new.id,'inviato_at',new.created_at));
 end if;
 return new;
end; $$;
revoke all on function private.documento_dopo_conferma_operatore() from public,anon,authenticated;
grant execute on function private.documento_dopo_conferma_operatore() to service_role;
create trigger documento_dopo_conferma_operatore after insert on public.azioni_operatore
 for each row execute function private.documento_dopo_conferma_operatore();

create function private.ritenta_documenti_preventivo()
returns integer language plpgsql security invoker set search_path='' as $$
declare d record; n integer:=0;
begin
 for d in select id,prova_invio from public.documenti_preventivo_auto where stato<>'inviato'
 and (ultimo_tentativo_at is null or ultimo_tentativo_at<now()-interval '4 minutes') order by ultimo_tentativo_at nulls first limit 100
 loop
  perform private.abbina_documento_preventivo(d.id);
  if d.prova_invio is not null then perform public.conferma_invio_documento_preventivo(d.id,d.prova_invio); end if;
  n:=n+1;
 end loop;
 return n;
end; $$;
revoke all on function private.ritenta_documenti_preventivo() from public,anon,authenticated;
grant execute on function private.ritenta_documenti_preventivo() to service_role;
select cron.schedule('ritenta-documenti-preventivo','*/5 * * * *','select private.ritenta_documenti_preventivo();');
-- I vecchi preventivi già segnati inviati non vengono riclassificati senza esame.
-- Si recuperano solo documenti pendenti, completi di lettura verificabile.
insert into public.documenti_preventivo_auto(external_id,impronta,nome_file,targa,file_url,data_offerta,ricevuto_at,contenuto)
 select external_id,contenuto_offerta->>'impronta',nome_file,targa,file_url,data_offerta,ricevuto_at,contenuto_offerta
 from public.preventivi_emessi_ricevuti where risolto_at is null
 and contenuto_offerta->>'impronta' ~ '^[a-f0-9]{64}$'
 on conflict do nothing;
create or replace function private.ritenta_preventivi_non_abbinati()
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_doc record; v_result jsonb; v_tentati integer:=0; v_risolti integer:=0;
begin
 if not pg_catalog.pg_try_advisory_xact_lock(20261008,83825) then return jsonb_build_object('esito','gia_in_esecuzione'); end if;
 for v_doc in select * from public.preventivi_emessi_ricevuti old
 where risolto_at is null
 and not exists(select 1 from public.documenti_preventivo_auto d where d.external_id=old.external_id)
 and (ultimo_tentativo_at is null or ultimo_tentativo_at<=now()-interval '4 minutes')
 order by ultimo_tentativo_at nulls first,ricevuto_at limit 100 loop
  begin
   v_result:=public.registra_preventivo_emesso_auto(v_doc.external_id,v_doc.nome_file,v_doc.targa,v_doc.file_url,v_doc.data_offerta,v_doc.inviato_at);
   v_tentati:=v_tentati+1;
   if v_result->>'aggiornato'='true' or v_result->>'esito'='gia_registrato' then v_risolti:=v_risolti+1; end if;
  exception when others then
   update public.preventivi_emessi_ricevuti set ultimo_tentativo_at=now(),tentativi=tentativi+1,esito='errore_elaborazione',
   risultato=jsonb_build_object('aggiornato',false,'esito','errore_elaborazione','errore',sqlerrm) where external_id=v_doc.external_id;
  end;
 end loop;
 return jsonb_build_object('esito','completato','tentati',v_tentati,'risolti',v_risolti);
end; $$;
select private.ritenta_documenti_preventivo();
notify pgrst,'reload schema';

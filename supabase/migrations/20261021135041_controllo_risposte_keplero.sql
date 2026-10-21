-- Controllo indipendente dalle azioni AI. Nessun invio automatico al cliente.
alter table public.keplero_originali add column consegna jsonb;
update public.keplero_originali set consegna=jsonb_build_object('whatsapp_message',originale->'whatsapp_message','metadata',originale->'metadata');
create table public.keplero_snapshot_invalidi (
 sessione uuid not null references public.keplero_sessioni_originali(sessione),impronta text not null,
 snapshot jsonb not null,creato_at timestamptz not null default now(),primary key(sessione,impronta)
);
create table public.keplero_risposte_verificate (
 sessione uuid not null,messaggio_id text not null,motivo text not null check(length(motivo) between 5 and 1000),
 operatore text not null,impronta_verificata text not null,verificata_at timestamptz not null default now(),primary key(sessione,messaggio_id),
 foreign key(sessione,messaggio_id) references public.keplero_originali(sessione,messaggio_id)
);
create table public.keplero_segnalazioni_esterne (
 id uuid primary key default gen_random_uuid(),nome text not null,telefono text not null,
 testo text not null check(length(testo) between 1 and 30000),data_messaggio timestamptz not null,
 fonte text not null,nota text not null,esito text not null default 'aperta' check(esito in ('aperta','verificata')),
 operatore text,verificata_at timestamptz,creata_at timestamptz not null default now()
);
alter table public.keplero_snapshot_invalidi enable row level security;
alter table public.keplero_risposte_verificate enable row level security;
alter table public.keplero_segnalazioni_esterne enable row level security;
revoke all on public.keplero_snapshot_invalidi,public.keplero_risposte_verificate,public.keplero_segnalazioni_esterne from public,anon,authenticated;
grant select,insert,update on public.keplero_snapshot_invalidi,public.keplero_risposte_verificate,public.keplero_segnalazioni_esterne to service_role;
create function public.conserva_snapshot_invalido_k(p_lease uuid,p_sessione uuid,p_snapshot jsonb)
returns void language plpgsql set search_path='' as $$
begin
 if not exists(select 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now())
 or not exists(select 1 from public.keplero_sessioni_originali where sessione=p_sessione and lease=p_lease) then raise exception 'Lotto scaduto';end if;
 if jsonb_typeof(p_snapshot)<>'array' or octet_length(p_snapshot::text)>20000000 then raise exception 'Snapshot non valido';end if;
 insert into public.keplero_snapshot_invalidi(sessione,impronta,snapshot)
 values(p_sessione,encode(sha256(convert_to(p_snapshot::text,'UTF8')),'hex'),p_snapshot) on conflict do nothing;
end; $$;
create or replace function public.errore_originali_k(p_lease uuid,p_sessione uuid,p_errore text)
returns void language plpgsql set search_path='' as $$
begin
 update public.keplero_sessioni_originali set errore=case when p_errore in ('non_configurato','non_autorizzato','non_disponibile','risposta_non_valida','limite_superato','conversazione_non_valida')
 or p_errore~'^(lettura|normalizzazione|registro|pdf_lettura|pdf_registro|rivalutazione)_(fallita|[A-Z0-9]{5}|http_[0-9]{3})$' then p_errore else 'lettura_non_completata' end,lease=null
 where sessione=p_sessione and lease=p_lease and exists(select 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now());
end; $$;
-- Latest inbound is the acknowledgement key: a later client message always reopens.
create view public.keplero_risposte_in_attesa with(security_invoker=true) as
with clienti as (
 select distinct on(o.sessione) o.* from public.keplero_originali o
 where o.direzione='entrata' order by o.sessione,o.data_messaggio desc,length(o.messaggio_id) desc,o.messaggio_id desc
)
select c.sessione,c.messaggio_id,c.data_messaggio,coalesce(c.revisione->>'testo',c.testo) as testo,s.assistente,
 case when exists(select 1 from public.keplero_originali f where f.sessione=c.sessione and f.direzione='uscita' and f.data_messaggio>=c.data_messaggio and f.consegna#>>'{whatsapp_message,status}'='failed')
 then 'Invio fallito: verificare e rispondere al cliente.' else 'Messaggio cliente senza risposta verificabile: controllare la chat, anche se assegnata a un operatore.' end as motivo,
 p.id as pratica_id,p.nome_cliente,p.telefono,p.numero_pratica
from clienti c join public.keplero_sessioni_originali s using(sessione)
left join lateral(select p1.id,p1.nome_cliente,p1.telefono,p1.numero_pratica from public.pratiche p1 where p1.keplero_conversation_id=c.sessione::text order by p1.updated_at desc limit 1)p on true
where c.data_messaggio>=private.inizio_finestra_controllo_keplero(now(),48) and c.data_messaggio<now()-interval '15 minutes'
 and not exists(select 1 from public.keplero_risposte_verificate v where v.sessione=c.sessione and v.messaggio_id=c.messaggio_id and v.impronta_verificata=coalesce(c.revisione->>'impronta',c.impronta))
 and not exists(select 1 from public.keplero_originali r where r.sessione=c.sessione and r.direzione='uscita'
 and (r.data_messaggio>c.data_messaggio or (r.data_messaggio=c.data_messaggio and length(r.messaggio_id)=length(c.messaggio_id) and r.messaggio_id>c.messaggio_id))
 and not r.modificato and length(trim(r.testo))>0
 and (case when s.assistente='2aef20d3-5ef8-4c81-8f21-bd450f22960c' or s.assistente is null then
 (r.consegna#>>'{whatsapp_message,status}' in ('delivered','read') or r.consegna#>>'{metadata,origin}'='whatsapp_coexistence')
 else coalesce(r.consegna#>>'{whatsapp_message,status}','') not in ('failed','pending','sent') end));
revoke all on public.keplero_risposte_in_attesa from public,anon,authenticated;
grant select on public.keplero_risposte_in_attesa to service_role;
create function public.controllo_risposte_k()
returns jsonb language sql stable set search_path='' as $$
select jsonb_build_object(
 'inizio',private.inizio_finestra_controllo_keplero(now(),48),'stato',public.stato_originali_k(),
 'recenti',(select count(*) from public.keplero_sessioni_originali where attivita_at>=private.inizio_finestra_controllo_keplero(now(),48)),
 'incomplete',(select count(*) from public.keplero_sessioni_originali where attivita_at>=private.inizio_finestra_controllo_keplero(now(),48) and (ultimo_successo_at is null or ultimo_successo_at<attivita_at or errore is not null)),
 'totale',(select count(*) from public.keplero_risposte_in_attesa),
 'chat',(select coalesce(jsonb_agg(x),'[]') from (select * from public.keplero_risposte_in_attesa order by data_messaggio limit 200)x),
 'esterne',(select coalesce(jsonb_agg(x),'[]') from(select * from public.keplero_segnalazioni_esterne where esito='aperta' order by data_messaggio limit 200)x),
 'errori',(select coalesce(jsonb_agg(x),'[]') from(select sessione,attivita_at,errore from public.keplero_sessioni_originali where errore is not null order by attivita_at desc limit 50)x));
$$;
create function public.verifica_risposta_k(p_sessione uuid,p_messaggio_id text,p_motivo text,p_operatore text)
returns void language plpgsql set search_path='' as $$
begin
 if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') or p_operatore is null then raise exception 'Operatore non valido';end if;
 insert into public.keplero_risposte_verificate(sessione,messaggio_id,motivo,operatore,impronta_verificata)
 select p_sessione,p_messaggio_id,p_motivo,p_operatore,coalesce(revisione->>'impronta',impronta) from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio_id
 on conflict(sessione,messaggio_id) do update set motivo=excluded.motivo,operatore=excluded.operatore,impronta_verificata=excluded.impronta_verificata,verificata_at=now();
end; $$;
revoke all on function public.conserva_snapshot_invalido_k(uuid,uuid,jsonb),public.controllo_risposte_k(),public.verifica_risposta_k(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.conserva_snapshot_invalido_k(uuid,uuid,jsonb),public.controllo_risposte_k(),public.verifica_risposta_k(uuid,text,text,text) to service_role;

create or replace function public.registra_originali_k(p_lease uuid,p_sessione uuid,p_messaggi jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare x jsonb; v_id text; m record;
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now() for update;
 if not found or not exists(select 1 from public.keplero_sessioni_originali where sessione=p_sessione and lease=p_lease) then raise exception 'Lettura scaduta';end if;
 if jsonb_typeof(p_messaggi)<>'array' or jsonb_array_length(p_messaggi)>5000 then raise exception 'Snapshot non valido';end if;
 if exists(select 1 from jsonb_array_elements(p_messaggi) a group by a->>'id' having count(*)>1) then raise exception 'ID duplicati';end if;
 for x in select value from jsonb_array_elements(p_messaggi) loop
  v_id:=x->>'id';
  if v_id is null or v_id!~'^[A-Za-z0-9_-]{1,100}$' or x->>'impronta'!~'^[a-f0-9]{64}$' or length(x->>'testo')>30000 or (x->>'data')::timestamptz>now()+interval '5 minutes' then raise exception 'Originale non valido';end if;
  if exists(select 1 from public.keplero_originali where sessione=p_sessione and messaggio_id=v_id and impronta<>x->>'impronta' and coalesce(revisione->>'impronta','')<>x->>'impronta') then
   update public.keplero_verifiche_originali set esito='da_verificare',operatore=null,verificata_at=null,updated_at=now() where sessione=p_sessione and messaggio_id=v_id;
  end if;
  insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,targa_pdf,sha256_pdf,originale,consegna)
  values(p_sessione,v_id,(x->>'data')::timestamptz,x->>'data_originale',x->>'direzione',x->>'tipo',x->>'testo',x->>'impronta',(x->>'candidato')::boolean,(x->>'revoca')::boolean,x->>'targa_pdf',x->>'sha256_pdf',x->'originale',jsonb_build_object('whatsapp_message',x->'originale'->'whatsapp_message','metadata',x->'originale'->'metadata'))
  on conflict(sessione,messaggio_id) do update set
   consegna=excluded.consegna,
   modificato=public.keplero_originali.modificato or public.keplero_originali.impronta<>excluded.impronta,
   revisione=case when public.keplero_originali.impronta<>excluded.impronta then x else public.keplero_originali.revisione end,
   candidato=public.keplero_originali.candidato or excluded.candidato or public.keplero_originali.impronta<>excluded.impronta,
   sha256_pdf=case when public.keplero_originali.impronta=excluded.impronta then coalesce(public.keplero_originali.sha256_pdf,excluded.sha256_pdf) else public.keplero_originali.sha256_pdf end;
 end loop;
 for m in select messaggio_id from public.keplero_originali where sessione=p_sessione and candidato and data_messaggio>now()-interval '30 days' order by data_messaggio desc,messaggio_id desc loop
  begin
   perform private.valuta_originale_k(p_sessione,m.messaggio_id);
  exception when others then
   insert into public.keplero_verifiche_originali(sessione,messaggio_id,esito,motivo)
   values(p_sessione,m.messaggio_id,'da_verificare','Errore nella regola: originale conservato, verifica operatore richiesta.')
   on conflict(sessione,messaggio_id) do update set esito='da_verificare',motivo=excluded.motivo,updated_at=now();
  end;
 end loop;
 update public.keplero_sessioni_originali set ultimo_successo_at=now(),errore=null,messaggi=jsonb_array_length(p_messaggi) where sessione=p_sessione;
 return jsonb_build_object('esito','completato','messaggi',jsonb_array_length(p_messaggi));
end; $$;


notify pgrst,'reload schema';

create or replace function public.registra_pdf_originale_k(p_lease uuid,p_sessione uuid,p_messaggio_id text,p_contenuto jsonb,p_url text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.keplero_originali%rowtype; d public.documenti_preventivo_auto%rowtype; r jsonb; ids uuid[];
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now();
 if not found then raise exception 'Lotto scaduto';end if;
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio_id;
 if m.modificato or m.direzione<>'uscita' or m.targa_pdf is null or m.sha256_pdf is null
 or m.testo is distinct from 'attachment:'||p_url then return jsonb_build_object('esito','prova_non_verificata'); end if;
 select array_agg(id) into ids from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf;
 if cardinality(ids)=1 then select * into d from public.documenti_preventivo_auto where id=ids[1];
 elsif coalesce(cardinality(ids),0)=0 then
  r:=public.registra_documento_preventivo_auto(jsonb_build_object('external_id','keplero:'||p_sessione||':'||p_messaggio_id,
   'contenuto',p_contenuto,'sha256_pdf',m.sha256_pdf,'nome_file',m.targa_pdf||'.pdf','targa',m.targa_pdf,'file_url',p_url,'data_offerta',m.data_messaggio));
  select * into d from public.documenti_preventivo_auto where id=(r->>'documento_id')::uuid;
 else return jsonb_build_object('esito','documento_ambiguo');end if;
 if d.pratica_id is null or nullif(p_contenuto->>'errore','') is not null then return jsonb_build_object('esito','da_verificare');end if;
 if not exists(select 1 from public.pratiche p where p.id=d.pratica_id and p.keplero_conversation_id=p_sessione::text) then return jsonb_build_object('esito','conversazione_da_verificare');end if;
 return public.conferma_invio_documento_preventivo(d.id,jsonb_build_object('fonte','keplero_originale_verificato',
  'fonte_id','keplero:'||p_sessione||':'||p_messaggio_id,'direzione','uscita','esito','inviato','impronta_documento',d.impronta,
  'messaggio_id',p_messaggio_id,'conversazione_id',p_sessione,'verificata_originale',true,'inviato_at',m.data_messaggio));
end; $$;

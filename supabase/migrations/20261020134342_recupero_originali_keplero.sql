-- Originali separati dai webhook AI: nessun replay di eventi logistici.
create table public.keplero_recupero_originali (
 id boolean primary key default true check(id), automatico boolean not null default false,
 lease uuid, scade_at timestamptz, ultimo_tentativo_at timestamptz, ultimo_successo_at timestamptz,
 elenco_at timestamptz, errore_elenco text
);
insert into public.keplero_recupero_originali(id) values(true);
create table public.keplero_sessioni_originali (
 sessione uuid primary key, ultimo_tentativo_at timestamptz, ultimo_successo_at timestamptz,
 errore text, lease uuid, messaggi integer not null default 0, attivita_at timestamptz, assistente uuid
);
create table public.keplero_originali (
 sessione uuid not null, messaggio_id text not null, data_messaggio timestamptz not null,
 data_originale text not null, direzione text not null check(direzione in ('entrata','uscita','ignota')),
 tipo text not null, testo text not null check(length(testo)<=30000), impronta text not null,
 candidato boolean not null, revoca boolean not null, targa_pdf text, sha256_pdf text,
 originale jsonb, modificato boolean not null default false, revisione jsonb, ricevuto_at timestamptz not null default now(),
 primary key(sessione,messaggio_id), check(impronta~'^[a-f0-9]{64}$'), check(sha256_pdf is null or sha256_pdf~'^[a-f0-9]{64}$')
);
create index keplero_originali_data on public.keplero_originali(sessione,data_messaggio);
create table public.keplero_verifiche_originali (
 sessione uuid not null, messaggio_id text not null, pratica_id uuid references public.pratiche(id),
 esito text not null check(esito in ('da_verificare','recuperata','preservata','archiviata')),
 motivo text not null, operatore text, verificata_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 primary key(sessione,messaggio_id), foreign key(sessione,messaggio_id) references public.keplero_originali(sessione,messaggio_id)
);
create table public.keplero_ticket_originali(impronta text primary key,scade_at timestamptz not null);
alter table public.keplero_recupero_originali enable row level security;
alter table public.keplero_sessioni_originali enable row level security;
alter table public.keplero_originali enable row level security;
alter table public.keplero_verifiche_originali enable row level security;
alter table public.keplero_ticket_originali enable row level security;
revoke all on public.keplero_recupero_originali,public.keplero_sessioni_originali,public.keplero_originali,public.keplero_verifiche_originali,public.keplero_ticket_originali from public,anon,authenticated;
grant select,insert,update,delete on public.keplero_recupero_originali,public.keplero_sessioni_originali,public.keplero_originali,public.keplero_verifiche_originali,public.keplero_ticket_originali to service_role;

create function public.autorizza_worker_originali_k(p_token text)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if p_token is null or p_token!~'^[A-Za-z0-9-]{64,100}$' then return false;end if;
 delete from public.keplero_ticket_originali where impronta=encode(sha256(convert_to(p_token,'UTF8')),'hex') and scade_at>now();
 return found;
end; $$;

create function public.inizia_recupero_originali_k()
returns jsonb language plpgsql security invoker set search_path='' as $$
declare l uuid; ids uuid[];
begin
 perform 1 from public.keplero_recupero_originali where id for update;
 if exists(select 1 from public.keplero_recupero_originali where scade_at>now()) then return jsonb_build_object('lease',null,'sessioni','[]'::jsonb);end if;
 insert into public.keplero_sessioni_originali(sessione)
 select distinct keplero_conversation_id::uuid from public.pratiche
 where keplero_conversation_id~*'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
 and updated_at>now()-interval '30 days'
 on conflict do nothing;
 select array_agg(sessione) into ids from (
 select s.sessione from public.keplero_sessioni_originali s
 where exists(select 1 from public.pratiche p where p.keplero_conversation_id=s.sessione::text and p.updated_at>now()-interval '30 days')
 order by s.ultimo_tentativo_at nulls first,s.sessione limit 8) x;
 l:=gen_random_uuid();
 update public.keplero_recupero_originali set lease=l,scade_at=now()+interval '4 minutes',ultimo_tentativo_at=now() where id;
 update public.keplero_sessioni_originali set lease=l,ultimo_tentativo_at=now() where sessione=any(ids);
 return jsonb_build_object('lease',l,'sessioni',coalesce(to_jsonb(ids),'[]'::jsonb));
end; $$;

create function private.valuta_originale_k(p_sessione uuid,p_messaggio_id text)
returns void language plpgsql security invoker set search_path='' as $$
declare m public.keplero_originali%rowtype; f public.keplero_originali%rowtype;
 d public.documenti_preventivo_auto%rowtype; q public.offerte_versioni%rowtype;
 p public.pratiche%rowtype; s public.scelte_cliente%rowtype; o public.offerta_opzioni%rowtype;
 ids uuid[]; opzioni uuid[]; n integer; pid uuid; t text; v_tipo text; motivo text; esito text:='da_verificare'; r jsonb; prima jsonb;
begin
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio_id;
 if not m.candidato or m.data_messaggio<now()-interval '30 days' then return;end if;
 if exists(select 1 from public.keplero_verifiche_originali k where k.sessione=p_sessione and k.messaggio_id=p_messaggio_id and k.esito in ('recuperata','preservata','archiviata')) then return;end if;
 -- Collega l'avviso alla conversazione, mai per nome o telefono soltanto.
 select (array_agg(distinct coalesce(pratica_origine_id,id)))[1] into pid from public.pratiche where keplero_conversation_id=p_sessione::text having count(distinct coalesce(pratica_origine_id,id))=1;
 if pid is not null then select * into p from public.pratiche where id=pid;end if;
 motivo:='Possibile conferma o documento originale da verificare.';
 if m.modificato then motivo:='Il messaggio originale è cambiato: stato e prove precedenti conservati.';
 elsif m.revoca then motivo:='Revoca o modifica del cliente: verificare la scelta e l''ordine, senza annullamenti automatici.';
 elsif m.direzione<>'entrata' or m.tipo<>'text' then motivo:='Documento inviato nella chat: leggere il PDF originale prima di aggiornare la fatturazione.';
 elsif lower(m.testo)~'(bonifico|pagamento eseguito)' then motivo:='Pagamento dichiarato dal cliente: verificare la ricevuta e l''accredito; nessuna quietanza automatica.';
 else
  -- L'ultimo PDF con targa esatta deve avere gli stessi byte del documento già registrato.
  select * into f from public.keplero_originali where sessione=p_sessione and direzione='uscita' and tipo='file'
   and targa_pdf is not null and data_messaggio<=m.data_messaggio order by data_messaggio desc,messaggio_id desc limit 1;
  select array_agg(id) into ids from public.documenti_preventivo_auto where sha256_pdf=f.sha256_pdf and targa=f.targa_pdf and pratica_id is not null and not f.modificato;
  if cardinality(ids)=1 then
   select * into d from public.documenti_preventivo_auto where id=ids[1];
   if exists(select 1 from public.pratiche pc join public.pratiche destinazione on destinazione.id=d.pratica_id
     where pc.keplero_conversation_id=p_sessione::text
     and (pc.id=destinazione.id or pc.pratica_origine_id=destinazione.id
       or (regexp_replace(pc.telefono,'[^0-9]','','g')=regexp_replace(destinazione.telefono,'[^0-9]','','g') and pc.targa=destinazione.targa))) then
    select * into p from public.pratiche where id=d.pratica_id for update;
    select * into q from public.offerte_versioni where pratica_id=p.id and impronta=d.impronta and inviato_at<=m.data_messaggio order by versione desc limit 1;
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
    or exists(select 1 from public.keplero_originali recente where recente.sessione=p_sessione and recente.data_messaggio>m.data_messaggio and recente.direzione='entrata' and recente.candidato and (recente.revoca or lower(recente.testo)~'(accett|conferm|proced|scelg|ripari|revision)'))
   then motivo:='Esistono messaggi o offerte successivi: verificare la decisione più recente.';
   else
    t:=lower(translate(m.testo,'àèéìòù’','aeeiou'''));
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
      r:=public.conferma_ordine_da_keplero(p.id,(select external_key from public.keplero_live_links where pratica_id=p.id),m.testo);
      if coalesce(r->>'aggiornato','false')='true' then
       update public.pratiche set ordine_acquisito_at=m.data_messaggio where id=p.id;
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
end; $$;

create function public.registra_originali_k(p_lease uuid,p_sessione uuid,p_messaggi jsonb)
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
  insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,targa_pdf,sha256_pdf,originale)
  values(p_sessione,v_id,(x->>'data')::timestamptz,x->>'data_originale',x->>'direzione',x->>'tipo',x->>'testo',x->>'impronta',(x->>'candidato')::boolean,(x->>'revoca')::boolean,x->>'targa_pdf',x->>'sha256_pdf',x->'originale')
  on conflict(sessione,messaggio_id) do update set
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

create function public.errore_originali_k(p_lease uuid,p_sessione uuid,p_errore text)
returns void language plpgsql security invoker set search_path='' as $$
begin
 update public.keplero_sessioni_originali set errore=case when p_errore in ('non_configurato','non_autorizzato','non_disponibile','risposta_non_valida','limite_superato','conversazione_non_valida') then p_errore else 'lettura_non_completata' end,lease=null
 where sessione=p_sessione and lease=p_lease and exists(select 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now());
end; $$;
create function public.termina_recupero_originali_k(p_lease uuid)
returns void language plpgsql security invoker set search_path='' as $$
begin
 update public.keplero_recupero_originali set ultimo_successo_at=case when not exists(select 1 from public.keplero_sessioni_originali where lease=p_lease or (ultimo_tentativo_at>now()-interval '90 seconds' and errore is not null)) then now() else ultimo_successo_at end,lease=null,scade_at=null where lease=p_lease and scade_at>now();
end; $$;

create function public.stato_originali_k()
returns jsonb language sql stable security invoker set search_path='' as $$
select jsonb_build_object('automatico',s.automatico,'elenco_at',s.elenco_at,'errore_elenco',s.errore_elenco,'ultimo_tentativo',s.ultimo_tentativo_at,'ultimo_successo',s.ultimo_successo_at,
 'sessioni',(select count(*) from public.keplero_sessioni_originali),'errori',(select count(*) from public.keplero_sessioni_originali where errore is not null),
 'da_verificare',(select count(*) from public.keplero_verifiche_originali where esito='da_verificare'),
 'recuperate',(select count(*) from public.keplero_verifiche_originali where esito='recuperata'),
 'piu_vecchia',(select min(ultimo_successo_at) from public.keplero_sessioni_originali)) from public.keplero_recupero_originali s where id;
$$;
create function public.archivia_verifica_originale_k(p_sessione uuid,p_messaggio_id text,p_operatore text)
returns void language plpgsql security invoker set search_path='' as $$
begin
 if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') or p_operatore is null then raise exception 'Operatore richiesto';end if;
 update public.keplero_verifiche_originali set esito='archiviata',operatore=p_operatore,verificata_at=now(),updated_at=now() where sessione=p_sessione and messaggio_id=p_messaggio_id and esito='da_verificare';
end; $$;
create function private.avvia_originali_k()
returns void language plpgsql security invoker set search_path='' as $$
declare t text;
begin
 if not exists(select 1 from public.keplero_recupero_originali where automatico and (scade_at is null or scade_at<=now())) then return;end if;
 delete from public.keplero_ticket_originali where scade_at<=now();
 t:=gen_random_uuid()::text||gen_random_uuid()::text;
 insert into public.keplero_ticket_originali values(encode(sha256(convert_to(t,'UTF8')),'hex'),now()+interval '2 minutes');
 perform net.http_post(url:='https://italianaabs-operatore.vercel.app/api/keplero/recupera',headers:=jsonb_build_object('Authorization','Bearer '||t,'Content-Type','application/json'),body:='{}',timeout_milliseconds:=180000);
end; $$;
revoke all on function public.autorizza_worker_originali_k(text),public.inizia_recupero_originali_k(),public.registra_originali_k(uuid,uuid,jsonb),public.errore_originali_k(uuid,uuid,text),public.termina_recupero_originali_k(uuid),public.stato_originali_k(),public.archivia_verifica_originale_k(uuid,text,text),private.valuta_originale_k(uuid,text),private.avvia_originali_k() from public,anon,authenticated;
grant execute on function public.autorizza_worker_originali_k(text),public.inizia_recupero_originali_k(),public.registra_originali_k(uuid,uuid,jsonb),public.errore_originali_k(uuid,uuid,text),public.termina_recupero_originali_k(uuid),public.stato_originali_k(),public.archivia_verifica_originale_k(uuid,text,text),private.valuta_originale_k(uuid,text) to service_role;
revoke all on function private.avvia_originali_k() from service_role;
select cron.schedule('recupera-originali-keplero','* * * * *','select private.avvia_originali_k();');
notify pgrst,'reload schema';

-- Elenco indipendente dall'AI, comprese le conversazioni interamente manuali.
create function public.avvia_lotto_originali_k()
returns jsonb language plpgsql security invoker set search_path='' as $$
declare s public.keplero_recupero_originali%rowtype; l uuid;
begin
 select * into s from public.keplero_recupero_originali where id for update;
 if s.scade_at>now() then return jsonb_build_object('lease',null); end if;
 l:=gen_random_uuid();
 update public.keplero_recupero_originali set lease=l,scade_at=now()+interval '4 minutes',ultimo_tentativo_at=now() where id;
 return jsonb_build_object('lease',l,'scopri',s.elenco_at is null or s.elenco_at<now()-interval '5 minutes');
end; $$;
create function public.registra_elenco_originali_k(p_lease uuid,p_sessioni jsonb)
returns void language plpgsql security invoker set search_path='' as $$
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now() for update;
 if not found then raise exception 'Lotto scaduto';end if;
 if jsonb_typeof(p_sessioni)<>'array' or jsonb_array_length(p_sessioni)>20000 then raise exception 'Elenco non valido';end if;
 insert into public.keplero_sessioni_originali(sessione,attivita_at,assistente)
 select (x->>'sessione')::uuid,max((x->>'attivita')::timestamptz),min(x->>'assistente')::uuid from jsonb_array_elements(p_sessioni) x
 where (x->>'attivita')::timestamptz>now()-interval '30 days' group by x->>'sessione'
 on conflict(sessione) do update set attivita_at=greatest(public.keplero_sessioni_originali.attivita_at,excluded.attivita_at),assistente=excluded.assistente;
 update public.keplero_recupero_originali set elenco_at=now(),errore_elenco=null where lease=p_lease;
end; $$;
create function public.errore_elenco_originali_k(p_lease uuid,p_errore text)
returns void language sql security invoker set search_path='' as $$
 update public.keplero_recupero_originali set errore_elenco=left(p_errore,180) where lease=p_lease;
$$;
create function public.seleziona_sessioni_originali_k(p_lease uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare ids uuid[];
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now() for update;
 if not found then raise exception 'Lotto scaduto';end if;
 insert into public.keplero_sessioni_originali(sessione,attivita_at)
 select keplero_conversation_id::uuid,max(updated_at) from public.pratiche
 where keplero_conversation_id~*'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' and updated_at>now()-interval '30 days'
 group by keplero_conversation_id on conflict do nothing;
 select array_agg(sessione) into ids from (
 select s.sessione from public.keplero_sessioni_originali s
 where (s.ultimo_successo_at is null or s.ultimo_successo_at<s.attivita_at or s.errore is not null)
 and (s.ultimo_tentativo_at is null or s.ultimo_tentativo_at<now()-interval '5 minutes')
 order by s.attivita_at desc nulls last,s.ultimo_tentativo_at nulls first,s.sessione limit 8) x;
 update public.keplero_sessioni_originali set lease=p_lease,ultimo_tentativo_at=now() where sessione=any(ids);
 return coalesce(to_jsonb(ids),'[]');
end; $$;
create function public.registra_pdf_originale_k(p_lease uuid,p_sessione uuid,p_messaggio_id text,p_contenuto jsonb,p_url text)
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
 return public.conferma_invio_documento_preventivo(d.id,jsonb_build_object('fonte','keplero_originale_verificato',
  'fonte_id','keplero:'||p_sessione||':'||p_messaggio_id,'direzione','uscita','esito','inviato','impronta_documento',d.impronta,
  'messaggio_id',p_messaggio_id,'conversazione_id',p_sessione,'verificata_originale',true,'inviato_at',m.data_messaggio));
end; $$;
create function public.rivaluta_originali_k(p_lease uuid,p_sessione uuid)
returns void language plpgsql security invoker set search_path='' as $$
declare m record;
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now();
 if not found then raise exception 'Lotto scaduto';end if;
 for m in select messaggio_id from public.keplero_originali where sessione=p_sessione and candidato and data_messaggio>now()-interval '30 days' order by data_messaggio desc loop
  begin
   perform private.valuta_originale_k(p_sessione,m.messaggio_id);
  exception when others then
   insert into public.keplero_verifiche_originali(sessione,messaggio_id,esito,motivo) values(p_sessione,m.messaggio_id,'da_verificare','Errore nella regola: originale conservato.')
   on conflict(sessione,messaggio_id) do update set motivo=excluded.motivo,esito='da_verificare';
  end;
 end loop;
 update public.keplero_sessioni_originali set lease=null,ultimo_successo_at=now(),errore=null where sessione=p_sessione and lease=p_lease;
end; $$;
revoke all on function public.avvia_lotto_originali_k(),public.registra_elenco_originali_k(uuid,jsonb),public.errore_elenco_originali_k(uuid,text),public.seleziona_sessioni_originali_k(uuid),public.registra_pdf_originale_k(uuid,uuid,text,jsonb,text),public.rivaluta_originali_k(uuid,uuid) from public,anon,authenticated;
grant execute on function public.avvia_lotto_originali_k(),public.registra_elenco_originali_k(uuid,jsonb),public.errore_elenco_originali_k(uuid,text),public.seleziona_sessioni_originali_k(uuid),public.registra_pdf_originale_k(uuid,uuid,text,jsonb,text),public.rivaluta_originali_k(uuid,uuid) to service_role;
create index keplero_originali_pratica_verifica on public.keplero_verifiche_originali(pratica_id);
notify pgrst,'reload schema';

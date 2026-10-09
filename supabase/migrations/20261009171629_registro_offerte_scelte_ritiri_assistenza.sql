-- Registro versionato: il consenso appartiene a una precisa offerta.
create table public.offerte_versioni (
 id uuid primary key default gen_random_uuid(), pratica_id uuid not null references public.pratiche(id),
 preventivo_id uuid not null references public.preventivi(id), versione integer not null,
 impronta text not null, targa text not null, file_url text, inviato_at timestamptz not null,
 stato text not null check(stato in ('letta','da_verificare')), errore text, testo_documento text,
 fonte text not null, validita_giorni integer check(validita_giorni between 1 and 365),
 registrata_at timestamptz not null default now(),
 unique(preventivo_id,impronta), unique(preventivo_id,versione), unique(id,pratica_id)
);
create table public.offerta_opzioni (
 id uuid primary key default gen_random_uuid(), offerta_id uuid not null references public.offerte_versioni(id),
 numero integer not null check(numero between 1 and 8), numero_esplicito boolean not null,
 servizio text not null check(servizio in ('RI','RE','PS','PSMI')), descrizione text not null,
 importo numeric(10,2) not null check(importo>0 and importo<=100000), valuta text not null default 'EUR' check(valuta='EUR'),
 iva_inclusa boolean, condizioni text, reso_vecchio boolean,
 unique(offerta_id,numero), unique(id,offerta_id)
);
create table public.scelte_cliente (
 pratica_id uuid primary key references public.pratiche(id), offerta_id uuid references public.offerte_versioni(id),
 opzione_id uuid, stato text not null check(stato in ('preferenza','condizionata','confermata','da_chiarire','revocata','modifica_da_verificare')),
 evento_id bigint references public.keplero_live_events(id), evidenza text not null, richiesta_at timestamptz not null,
 fonte text not null, protetta_operatore boolean not null default false, operatore text,
 updated_at timestamptz not null default now(),
 foreign key(opzione_id,offerta_id) references public.offerta_opzioni(id,offerta_id),
 foreign key(offerta_id,pratica_id) references public.offerte_versioni(id,pratica_id),
 check(opzione_id is null or offerta_id is not null)
);
create table public.assistenze_rientri (
 id uuid primary key default gen_random_uuid(), pratica_id uuid not null references public.pratiche(id),
 pratica_origine_id uuid references public.pratiche(id), evento_id bigint references public.keplero_live_events(id),
 stato text not null default 'da_prendere_in_carico' check(stato in ('da_prendere_in_carico','verifica_tecnica','ritiro_da_prenotare','ritiro_prenotato','ricevuto','in_lavorazione','esito_comunicato','chiusa')),
 priorita text not null default 'urgente' check(priorita in ('alta','urgente')),
 evidenza text not null, aperta_at timestamptz not null, presa_in_carico_at timestamptz,
 operatore text, nota text, esito_tecnico text, chiusa_at timestamptz, updated_at timestamptz not null default now()
);
create unique index assistenza_rientro_aperta_unica on public.assistenze_rientri(pratica_id) where chiusa_at is null;
create index offerte_pratica_invio on public.offerte_versioni(pratica_id,inviato_at desc);
create index opzioni_offerta on public.offerta_opzioni(offerta_id);
create index assistenza_origine on public.assistenze_rientri(pratica_origine_id);
create index scelte_evento on public.scelte_cliente(evento_id);
create index offerte_preventivo on public.offerte_versioni(preventivo_id);
alter table public.offerte_versioni enable row level security;
alter table public.offerta_opzioni enable row level security;
alter table public.scelte_cliente enable row level security;
alter table public.assistenze_rientri enable row level security;
revoke all on public.offerte_versioni,public.offerta_opzioni,public.scelte_cliente,public.assistenze_rientri from anon,authenticated;
grant all on public.offerte_versioni,public.offerta_opzioni,public.scelte_cliente,public.assistenze_rientri to service_role;

alter table public.attivita_operatore drop constraint attivita_operatore_tipo_check;
alter table public.attivita_operatore add constraint attivita_operatore_tipo_check check(tipo in (
 'ritiro_programma_scambio','ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_da_classificare','ritiro_altro_reso',
 'richiamata_post_preventivo','richiamata_post_vendita','richiamata_da_classificare'));
alter table public.attivita_operatore add column assistenza_rientro_id uuid references public.assistenze_rientri(id),
 add column presa_in_carico_at timestamptz, add column blocco_classificazione boolean not null default false,
 add column riferimento_ritiro text, add column data_ritiro_prevista date;
create index attivita_assistenza_rientro on public.attivita_operatore(assistenza_rientro_id);
-- Un episodio logistico attivo per pratica, indipendente dal nome assegnato.
-- Le righe storiche non vengono eliminate né riscritte.
create unique index ritiro_attivo_unico_pratica on public.attivita_operatore(pratica_id)
 where tipo like 'ritiro_%' and stato in ('da_gestire','da_collegare','programmata');

create or replace function private.preferenza_senza_conferma(p_testo text)
returns boolean language sql immutable set search_path='' as $$
 select lower(coalesce(p_testo,'')) ~ '\m(preferisco|preferiamo|preferirei|preferiremmo|sceglierei|sceglieremmo)\M'
 and lower(coalesce(p_testo,'')) !~ '\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo)\M|pratica confermata';
$$;

create or replace function public.registra_opzioni_offerta(p_preventivo_id uuid,p_opzioni jsonb,p_impronta text,
 p_testo text default null,p_errore text default null,p_fonte text default 'pdf',p_validita_giorni integer default null,p_inviato_at timestamptz default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare q public.preventivi%rowtype; p public.pratiche%rowtype; v_id uuid; v_num integer; o jsonb; e record;
begin
 select * into q from public.preventivi where id=p_preventivo_id for update;
 if not found then raise exception 'Preventivo non trovato'; end if;
 select * into p from public.pratiche where id=q.pratica_id for update;
 if length(coalesce(p_impronta,'')) not between 8 and 160 then raise exception 'Impronta documento non valida'; end if;
 if jsonb_typeof(p_opzioni)<>'array' or jsonb_array_length(p_opzioni)>8 then raise exception 'Alternative non valide'; end if;
 if p_errore is null and jsonb_array_length(p_opzioni)=0 then raise exception 'Alternative assenti'; end if;
 if p_validita_giorni is not null and p_validita_giorni not between 1 and 365 then raise exception 'Validità non valida'; end if;
 if exists(select 1 from jsonb_array_elements(p_opzioni) x group by (x->>'numero')::integer having count(*)>1) then raise exception 'Alternative duplicate'; end if;
 select id into v_id from public.offerte_versioni where preventivo_id=q.id and impronta=p_impronta;
 if v_id is not null then return jsonb_build_object('ok',true,'offerta_id',v_id,'duplicato',true); end if;
 select coalesce(max(versione),0)+1 into v_num from public.offerte_versioni where preventivo_id=q.id;
 insert into public.offerte_versioni(pratica_id,preventivo_id,versione,impronta,targa,file_url,inviato_at,stato,errore,testo_documento,fonte,validita_giorni)
 values(p.id,q.id,v_num,p_impronta,coalesce(p.targa,''),q.file_url,coalesce(p_inviato_at,q.inviato_at,q.creato_at),
  case when p_errore is null then 'letta' else 'da_verificare' end,p_errore,left(p_testo,200000),p_fonte,p_validita_giorni) returning id into v_id;
 if p_errore is null then
  for o in select * from jsonb_array_elements(p_opzioni) loop
   insert into public.offerta_opzioni(offerta_id,numero,numero_esplicito,servizio,descrizione,importo,iva_inclusa,valuta,condizioni,reso_vecchio)
   values(v_id,(o->>'numero')::integer,coalesce((o->>'numero_esplicito')::boolean,true),o->>'servizio',
    coalesce(o->>'descrizione',o->>'servizio'),(o->>'importo')::numeric,(o->>'iva_inclusa')::boolean,
    coalesce(o->>'valuta','EUR'),left(o->>'condizioni',6000),(o->>'reso_vecchio')::boolean);
  end loop;
 end if;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'registro_offerta_versione','Versione '||v_num||' - '||coalesce(p_errore,'alternative registrate'),
  '{}'::jsonb,jsonb_build_object('offerta_id',v_id,'numero_opzioni',jsonb_array_length(p_opzioni)),p_fonte);
 -- Consensi arrivati prima della lettura del PDF vengono rielaborati con la loro data originale.
 for e in select id from public.keplero_live_events where pratica_id=p.id
  and created_at>=coalesce(p_inviato_at,q.inviato_at,q.creato_at) order by id loop
  perform private.rileva_scelta_cliente_evento(e.id);
 end loop;
 return jsonb_build_object('ok',true,'offerta_id',v_id,'versione',v_num,'stato',case when p_errore is null then 'letta' else 'da_verificare' end);
end; $$;

create or replace function private.rileva_scelta_cliente_evento(p_event_id bigint)
returns jsonb language plpgsql set search_path='' as $$
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
 if s.protetta_operatore or (s.evento_id is not null and s.evento_id>e.id) then return jsonb_build_object('esito','scelta_preservata'); end if;
 if private.revoca_scelta_cliente(t) then
  if s.pratica_id is null then return '{}'::jsonb; end if;
  v_stato:=case when s.stato='confermata' then 'modifica_da_verificare' else 'revocata' end;
  v_ids:=array[s.opzione_id];
  select * into q from public.offerte_versioni where id=s.offerta_id;
 else
  if private.domanda_su_accettazione(t) then return '{}'::jsonb; end if;
  if t~'\mnon\M.{0,20}\m(accetto|accettiamo|confermo|confermiamo|procedete|procediamo|scelgo|scegliamo|ho deciso|ha deciso)\M' then return '{}'::jsonb; end if;
  v_risposta_breve:=btrim(t)~'^((la|solo)[[:space:]]+)?(ri|re|ps|psmi|opzione[[:space:]]+[1-8]|programma scambio( made in italy)?)([.! ]*$|[,; ]+\m(se|qualora|altrimenti)\M)';
  if not v_risposta_breve and t!~'(opzione|offerta|proposta|preventivo|ordine|lavorazione|ripar|revision|programma scambio|€|\m(ri|re|ps|psmi|prezzo|importo|euro)\M)'
   and btrim(t)!~'^(?:(?:buongiorno|buonasera|ciao|ok)[,!. ]*)?(accetto|accettiamo|confermo|confermiamo|procedete|procediamo)[.! ]*$' then return '{}'::jsonb; end if;
  if t !~ '\m(preferisco|preferiamo|preferirei|preferiremmo|sceglierei|sceglieremmo|scelgo|scegliamo|accetto|accettiamo|confermo|confermiamo|procedete|procediamo)\M|scelt|deciso per|sta bene|pratica confermata|vorrei revisionare|voglio riparare' and not v_risposta_breve then return '{}'::jsonb; end if;
  select * into q from public.offerte_versioni where pratica_id=p.id and inviato_at<=e.created_at
   order by inviato_at desc,registrata_at desc,versione desc limit 1;
  if q.id is null and not exists(select 1 from public.preventivi where pratica_id=p.id and coalesce(inviato_at,creato_at)<=e.created_at) then return '{}'::jsonb; end if;
  select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id;
  v_riferimento:=(regexp_split_to_array(t,'\m(se|qualora|altrimenti)\M'))[1];
  v_riferimento:=regexp_replace(v_riferimento,'\mnon\M[[:space:]]+(?:(?:voglio|vogliamo|preferisco|il|la)[[:space:]]+)?(?:programma scambio(?: made in italy)?|ri|re|psmi|ps)\M',' ','g');
  v_tipi:=(case when v_riferimento~'\mri\M|idraulic' then 1 else 0 end)+(case when v_riferimento~'\mre\M|elettronic' then 1 else 0 end)
   +(case when v_riferimento~'\mpsmi\M|programma scambio made in italy' then 1 else 0 end)
   +(case when regexp_replace(v_riferimento,'programma scambio made in italy','psmi','g')~'\mps\M|programma scambio' then 1 else 0 end);
  if v_riferimento ~ '\mpsmi\M|programma scambio made in italy' then v_tipo:='PSMI';
  elsif v_riferimento ~ '\mps\M|programma scambio' then v_tipo:='PS';
  elsif v_riferimento ~ '\mri\M|idraulic' then v_tipo:='RI';
  elsif v_riferimento ~ '\mre\M|elettronic' then v_tipo:='RE'; end if;
  if v_riferimento ~ '(programma scambio|\mps\M)' and v_riferimento !~ '(made in italy|\mpsmi\M)' and v_riferimento !~ '\mps\M' then
   if exists(select 1 from public.offerta_opzioni where offerta_id=q.id and servizio='PSMI') then v_tipo:='SCAMBIO_GENERICO'; end if;
  end if;
  if v_tipo is not null then
   v_ha_riferimento:=true;
   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids)
    and (servizio=v_tipo or (v_tipo='SCAMBIO_GENERICO' and servizio in ('PS','PSMI')));
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
  v_importo:=replace((regexp_match(v_riferimento,'(?:€\s*|quella di\s*|quello di\s*|da\s+)([0-9]{2,5}(?:[,.][0-9]{2})?)'))[1],',','.')::numeric;
  if v_importo is null then v_importo:=replace((regexp_match(v_riferimento,'([0-9]{2,5}(?:[,.][0-9]{2})?)\s*(?:euro|€)'))[1],',','.')::numeric; end if;
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
  if v_risposta_breve and s.stato='da_chiarire' and s.offerta_id=q.id and p.stato_commerciale::text='ordine_acquisito' and p.ordine_acquisito_at>=q.inviato_at and not private.preferenza_senza_conferma(s.evidenza) then v_conferma:=true; end if;
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
end; $$;

create or replace function public.correggi_scelta_cliente(p_pratica_id uuid,p_opzione_id uuid,p_stato text,p_nota text,p_operatore text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare o public.offerta_opzioni%rowtype; q public.offerte_versioni%rowtype; s public.scelte_cliente%rowtype;
begin
 if p_stato not in ('preferenza','condizionata','confermata','da_chiarire','revocata') or nullif(trim(p_nota),'') is null or nullif(trim(p_operatore),'') is null then raise exception 'Stato, motivazione e operatore richiesti'; end if;
 perform 1 from public.pratiche where id=p_pratica_id for update;
 select * into o from public.offerta_opzioni where id=p_opzione_id;
 select * into q from public.offerte_versioni where id=o.offerta_id and pratica_id=p_pratica_id;
 if p_opzione_id is not null and q.id is null then raise exception 'Alternativa estranea alla pratica'; end if;
 if p_stato='confermata' and (o.id is null or q.stato<>'letta') then raise exception 'Selezionare una alternativa verificata'; end if;
 select * into s from public.scelte_cliente where pratica_id=p_pratica_id;
 insert into public.scelte_cliente(pratica_id,offerta_id,opzione_id,stato,evidenza,richiesta_at,fonte,protetta_operatore,operatore)
 values(p_pratica_id,q.id,o.id,p_stato,trim(p_nota),now(),'operatore',true,p_operatore)
 on conflict(pratica_id) do update set offerta_id=excluded.offerta_id,opzione_id=excluded.opzione_id,stato=excluded.stato,
  evidenza=excluded.evidenza,richiesta_at=excluded.richiesta_at,fonte='operatore',protetta_operatore=true,operatore=p_operatore,evento_id=null,updated_at=now();
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p_pratica_id,'correzione_scelta_cliente',p_nota,to_jsonb(s),jsonb_build_object('opzione_id',o.id,'stato',p_stato),p_operatore);
 return jsonb_build_object('ok',true);
end; $$;

create or replace view public.v_scelte_cliente with(security_invoker=true) as
select s.*,o.servizio,o.importo,o.iva_inclusa,o.numero,o.condizioni,o.reso_vecchio,q.versione,q.file_url,q.inviato_at,
 exists(select 1 from public.keplero_live_events e where e.pratica_id=s.pratica_id and e.created_at>=s.richiesta_at
  and lower(coalesce(e.payload->>'ultimo_messaggio_cliente',''))!~'(acconto|anticipo|non.{0,20}(pagato|bonifico|versato))'
  and replace((regexp_match(lower(coalesce(e.payload->>'ultimo_messaggio_cliente','')),'(?:bonifico|pagato|versato).{0,20}(?:di|da)[[:space:]]+([0-9]{2,5}(?:[,.][0-9]{2})?)'))[1],',','.')::numeric<>o.importo) prezzo_da_verificare,
 exists(select 1 from public.offerte_versioni nuova where nuova.pratica_id=s.pratica_id and (nuova.inviato_at>q.inviato_at or (nuova.preventivo_id=q.preventivo_id and nuova.versione>q.versione))) offerta_successiva
from public.scelte_cliente s left join public.offerta_opzioni o on o.id=s.opzione_id left join public.offerte_versioni q on q.id=s.offerta_id;
grant select on public.v_scelte_cliente to service_role;
revoke all on public.v_scelte_cliente from anon,authenticated;

create or replace function public.contesto_offerta_keplero(p_pratica_id uuid,p_external_key text)
returns jsonb language sql stable security invoker set search_path='' as $$
 select case when not exists(select 1 from public.keplero_live_links where pratica_id=p_pratica_id and external_key=p_external_key)
 then jsonb_build_object('stato','collegamento_non_valido') else jsonb_build_object(
 'offerta',(select to_jsonb(q)-'testo_documento' from public.offerte_versioni q where pratica_id=p_pratica_id order by inviato_at desc,registrata_at desc limit 1),
 'opzioni',coalesce((select jsonb_agg(to_jsonb(o) order by o.numero) from public.offerta_opzioni o where offerta_id=(select id from public.offerte_versioni where pratica_id=p_pratica_id order by inviato_at desc,registrata_at desc limit 1)),'[]'::jsonb),
 'scelta',(select to_jsonb(s) from public.v_scelte_cliente s where pratica_id=p_pratica_id),
 'istruzioni','Usare solo le opzioni di questa offerta. Una preferenza non conferma un ordine. Una scelta ambigua richiede una sola domanda mirata. Coupon, tempi e disponibilità restano soggetti alle condizioni e alla verifica operatore.') end;
$$;
create or replace function private.rileva_rientro_evento(p_event_id bigint)
returns jsonb language plpgsql set search_path='' as $$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype; a public.attivita_operatore%rowtype;
 c public.assistenze_rientri%rowtype; t text; v_origine uuid; v_num integer; v_problema boolean; v_ritiro boolean;
 v_tipo text; v_servizio text; v_nuova boolean:=false; v_gia_ritirato boolean; v_prenotato_segnalato boolean;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id for update;
 if not found or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then return '{}'::jsonb; end if;
 if nullif(e.payload->>'targa','') is not null and upper(regexp_replace(e.payload->>'targa','[^A-Za-z0-9]','','g'))<>upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) then return '{}'::jsonb; end if;
 t:=lower(translate(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),'àèéìòù’','aeeiou'''));
 if t='' then return '{}'::jsonb; end if;
 v_origine:=p.pratica_origine_id;
 if v_origine is null and (p.stato_commerciale::text='ordine_acquisito' or p.stato_fatturazione::text='fatturato') then v_origine:=p.id; end if;
 if v_origine is null and nullif(p.targa,'') is not null then
  select count(*),min(x.id::text)::uuid into v_num,v_origine from public.pratiche x
  where x.id<>p.id and upper(regexp_replace(coalesce(x.targa,''),'[^A-Za-z0-9]','','g'))=upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))
   and (x.stato_commerciale::text='ordine_acquisito' or x.stato_fatturazione::text='fatturato')
   and (x.cliente_id=p.cliente_id or (nullif(p.telefono,'') is not null and regexp_replace(x.telefono,'[^0-9]','','g')=regexp_replace(p.telefono,'[^0-9]','','g')))
   and coalesce(x.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
   and coalesce(x.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
  if v_num<>1 then v_origine:=null; end if;
 end if;
 select * into c from public.assistenze_rientri where pratica_id=p.id and chiusa_at is null for update;
 -- Il problema deve riguardare un intervento/prodotto precedente, oppure essere una richiesta esplicita di garanzia.
 v_problema:= t~'(in garanzia|rientro.{0,25}garanzia|dopo.{0,35}(vostra riparazione|vostro intervento)|(?:ricambio|pezzo|dispositivo|centralina|modulo).{0,40}(ricevuto da voi|fornito da voi|fornito).{0,70}(difett|non funzion|errato))'
  or (((p.stato_fatturazione::text='fatturato' and coalesce(p.data_fattura,p.ordine_acquisito_at,p.created_at)<=e.created_at) or p.tipo_assistenza::text in ('post_riparazione','garanzia') or e.payload->>'tipo_assistenza' in ('post_riparazione','post_scambio','post_installazione'))
   and t~'(non.{0,30}(risolto|funziona)|stess[oa].{0,20}(difetto|problema)|problema.{0,30}(persiste|rimane)|dopo.{0,25}(montaggio|riparazione|sostituzione)|(?:pezzo|modulo|pompa).{0,25}(difettoso|sbagliato)|(?:ricevuto|montato|installato).{0,100}(errore|spia|difett)|rivoglio.{0,35}(mio|originale))');
 v_ritiro:=(t~'(pacc(o|hetto).{0,70}(pront|ritir)|pront[ioa].{0,45}(ritir|restitu|rientr)|(restitu|rientr).{0,70}(pompa|abs|centralina|prodotto|pezzo)|(?:organizz|prenot|programmar).{0,50}(ritiro|corriere)|(?:quando passa|quando passera|non e ancora passato).{0,30}corriere)' or private.richiesta_restituzione_vecchio(t))
  and t!~'(non.{0,15}(pronto|pronta)|non.{0,15}(ritirare|prenotare)|se.{0,30}(pacco|ritiro)|ipotetico)';
 if v_problema and c.id is null then
  -- Non rielabora un vecchio messaggio appartenente a un episodio già chiuso.
  if exists(select 1 from public.assistenze_rientri where pratica_id=p.id and chiusa_at is not null and chiusa_at>=e.created_at) then return '{}'::jsonb; end if;
  insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evento_id,evidenza,aperta_at)
  values(p.id,v_origine,e.id,coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),e.created_at)
  returning * into c;
  v_nuova:=true;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  values(p.id,'apertura_assistenza_rientro','Segnalazione post intervento: verifica urgente. Ammissibilità della garanzia da valutare dal tecnico.',
   '{}'::jsonb,to_jsonb(c),'routine_controllo_k');
 end if;
 v_gia_ritirato:=t~'(gia.{0,30}(ritirat|fatto ritir)|ritirat.{0,20}gia|avete.{0,25}ritirat)';
 v_prenotato_segnalato:=t~'(gls|corriere).{0,60}(codice|numero|prenotazione).{0,40}[0-9]{5,}';
 if v_gia_ritirato or v_prenotato_segnalato then
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',true,'evidenza_ritiro_effettuato',t,'evento_ritiro_effettuato',e.id)
   where pratica_id=p.id and tipo like 'ritiro_%' and stato in ('da_gestire','da_collegare','programmata')
    and coalesce((metadati->>'evento_prenotazione_verificato')::bigint,0)<e.id;
  if v_gia_ritirato then return jsonb_build_object('assistenza_id',c.id,'esito','ritiro_gia_effettuato_da_verificare'); end if;
 end if;
 if not v_ritiro then return jsonb_build_object('assistenza_id',c.id,'aperta',v_nuova); end if;
 select * into a from public.attivita_operatore where pratica_id=p.id and tipo like 'ritiro_%'
  and stato in ('da_gestire','da_collegare','programmata') for update;
 if not found and exists(select 1 from public.attivita_operatore where pratica_id=p.id and tipo like 'ritiro_%'
  and (evento_keplero_id=e.id or coalesce(completata_at,annullata_at)>=e.created_at)) then return jsonb_build_object('esito','episodio_gia_gestito'); end if;
 select servizio into v_servizio from public.v_scelte_cliente where pratica_id=coalesce(v_origine,p.id) and stato='confermata';
 if c.id is not null then v_tipo:='ritiro_verifica_garanzia';
 elsif t~'(reso|rientro|restitu).{0,50}(rimborso|recesso)|rimborso.{0,50}(reso|rientro)' then v_tipo:='ritiro_altro_reso';
 elsif private.richiesta_restituzione_vecchio(t) or t~'(vecchi[oa].{0,40}(restitu|ritir|scambio)|(?:restitu|ritir).{0,40}vecchi[oa])' then v_tipo:='ritiro_programma_scambio';
 elsif v_servizio in ('RI','RE') and not exists(select 1 from public.attivita_operatore where pratica_id=p.id and tipo='ritiro_lavorazione' and completata_at<e.created_at) then v_tipo:='ritiro_lavorazione';
 else v_tipo:='ritiro_da_classificare'; end if;
 if a.id is null then
  insert into public.attivita_operatore(tipo,stato,priorita,pratica_id,pratica_origine_id,assistenza_rientro_id,
   evento_keplero_id,external_key,evidenza,fonte,metadati,richiesta_at)
  values(v_tipo,case when v_origine is null then 'da_collegare' else 'da_gestire' end,
   case when c.id is null then 'alta' else 'urgente' end,p.id,v_origine,c.id,e.id,e.external_key,
   coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),
   'keplero_live',jsonb_build_object('regola','ritiro_contestuale_v2','scelta_servizio',v_servizio),e.created_at) returning * into a;
 else
  -- La prima data, l'evidenza originale e la prenotazione non cambiano con i messaggi successivi.
  update public.attivita_operatore set
   tipo=case when blocco_classificazione then tipo when c.id is not null then 'ritiro_verifica_garanzia'
    when tipo='ritiro_da_classificare' or metadati->>'regola'='rientro_prodotto_v1' then v_tipo else tipo end,
   priorita=case when c.id is not null then 'urgente' else priorita end,
   assistenza_rientro_id=coalesce(assistenza_rientro_id,c.id),pratica_origine_id=coalesce(pratica_origine_id,v_origine),
   stato=case when stato='da_collegare' and v_origine is not null then 'da_gestire' else stato end,
   metadati=metadati||jsonb_build_object('ultimo_evento_ritiro',e.id,'ultima_evidenza',t),updated_at=now()
  where id=a.id returning * into a;
 end if;
 if v_prenotato_segnalato then
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',true,'evidenza_ritiro_effettuato',t,'evento_ritiro_effettuato',e.id)
   where id=a.id and coalesce((metadati->>'evento_prenotazione_verificato')::bigint,0)<e.id;
 end if;
 if c.id is not null and c.stato in ('da_prendere_in_carico','verifica_tecnica') and c.presa_in_carico_at is not null then
  update public.assistenze_rientri set stato='ritiro_da_prenotare',updated_at=now() where id=c.id;
 end if;
 return jsonb_build_object('assistenza_id',c.id,'attivita_id',a.id,'tipo',a.tipo,'stato',a.stato,
  'domanda',case when a.tipo='ritiro_da_classificare' then 'Il pacco contiene il vecchio dispositivo da restituire per lo scambio oppure quello ricevuto da noi che presenta il problema?' end);
end; $$;

create or replace function public.gestisci_ritiro_assistenza(p_pratica_id uuid,p_attivita_id uuid default null,
 p_assistenza_id uuid default null,p_azione text default null,p_tipo text default null,p_nota text default null,
 p_riferimento text default null,p_data_ritiro date default null,p_operatore text default null,p_origine_numero bigint default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.attivita_operatore%rowtype; c public.assistenze_rientri%rowtype; v_prima jsonb; v_origine uuid;
begin
 if nullif(trim(p_operatore),'') is null then raise exception 'Operatore richiesto'; end if;
 perform 1 from public.pratiche where id=p_pratica_id for update;
 if not found then raise exception 'Pratica non trovata'; end if;
 if p_attivita_id is not null then
  select * into a from public.attivita_operatore where id=p_attivita_id and pratica_id=p_pratica_id for update;
  if not found or a.tipo not like 'ritiro_%' or a.stato in ('annullata','completata') then raise exception 'Ritiro non attivo o estraneo alla pratica'; end if;
  v_prima:=to_jsonb(a); p_assistenza_id:=coalesce(p_assistenza_id,a.assistenza_rientro_id);
 end if;
 if p_assistenza_id is not null then
  select * into c from public.assistenze_rientri where id=p_assistenza_id and pratica_id=p_pratica_id for update;
  if not found or c.chiusa_at is not null then raise exception 'Assistenza non attiva o estranea alla pratica'; end if;
  v_prima:=coalesce(v_prima,to_jsonb(c));
 end if;
 if a.id is null and c.id is null then raise exception 'Selezionare ritiro o assistenza'; end if;
 if p_origine_numero is not null then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Ritiro e motivazione del collegamento richiesti'; end if;
  select x.id into v_origine from public.pratiche x join public.pratiche y on y.id=p_pratica_id
  where x.numero_pratica=p_origine_numero and (x.stato_commerciale::text='ordine_acquisito' or x.stato_fatturazione::text='fatturato')
   and (nullif(y.targa,'') is null or upper(x.targa)=upper(y.targa));
  if v_origine is null then raise exception 'Ordine non trovato o targa incompatibile'; end if;
  update public.attivita_operatore set pratica_origine_id=v_origine,stato=case when stato='da_collegare' then 'da_gestire' else stato end where id=a.id;
  a.pratica_origine_id:=v_origine;
  update public.assistenze_rientri set pratica_origine_id=v_origine where id=c.id;
 end if;
 if p_azione='prendi_in_carico' then
  update public.attivita_operatore set presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,updated_at=now() where id=a.id;
  update public.assistenze_rientri set presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,
   stato=case when stato='da_prendere_in_carico' then case when a.id is null then 'verifica_tecnica' else 'ritiro_da_prenotare' end else stato end,updated_at=now() where id=c.id;
 elsif p_azione='classifica' then
  if a.id is null or p_tipo not in ('ritiro_lavorazione','ritiro_programma_scambio','ritiro_verifica_garanzia','ritiro_da_classificare','ritiro_altro_reso') or nullif(trim(p_nota),'') is null then raise exception 'Tipo e motivazione richiesti'; end if;
  if p_tipo='ritiro_verifica_garanzia' and c.id is null then
   insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evidenza,aperta_at,operatore,presa_in_carico_at,stato)
   values(p_pratica_id,a.pratica_origine_id,p_nota,a.richiesta_at,p_operatore,now(),'ritiro_da_prenotare') returning * into c;
  end if;
  update public.attivita_operatore set tipo=p_tipo,blocco_classificazione=true,nota=p_nota,operatore=p_operatore,
   priorita=case when p_tipo='ritiro_verifica_garanzia' then 'urgente' else priorita end,assistenza_rientro_id=coalesce(assistenza_rientro_id,c.id),updated_at=now() where id=a.id;
 elsif p_azione='verifica_prenotazione' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Registrare la verifica effettuata'; end if;
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',false,'verifica_prenotazione',p_nota,'evento_prenotazione_verificato',coalesce((metadati->>'evento_ritiro_effettuato')::bigint,0)),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
 elsif p_azione='programma' then
  if a.metadati->>'ritiro_gia_effettuato_segnalato'='true' then raise exception 'Il cliente segnala un ritiro già effettuato: verificarlo prima di prenotare nuovamente'; end if;
  if a.id is null or a.pratica_origine_id is null or a.tipo='ritiro_da_classificare' then raise exception 'Classificare e collegare prima il ritiro'; end if;
  if nullif(trim(p_riferimento),'') is null or p_data_ritiro is null then raise exception 'Riferimento prenotazione e data richiesti'; end if;
  update public.attivita_operatore set stato='programmata',programmata_at=coalesce(programmata_at,now()),
   riferimento_ritiro=p_riferimento,data_ritiro_prevista=p_data_ritiro,presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,nota=p_nota,updated_at=now() where id=a.id;
  update public.assistenze_rientri set stato='ritiro_prenotato',presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,updated_at=now() where id=c.id;
 elsif p_azione='completa' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Registrare la prova del ritiro effettuato'; end if;
  update public.attivita_operatore set stato='completata',completata_at=now(),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
  -- Ritiro effettuato non equivale a ricezione in laboratorio o risoluzione del guasto.
 elsif p_azione='annulla' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Motivazione richiesta'; end if;
  update public.attivita_operatore set stato='annullata',annullata_at=now(),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
 elsif p_azione in ('verifica_tecnica','ritiro_da_prenotare','ricevuto','in_lavorazione','esito_comunicato','chiudi') then
  if c.id is null or c.presa_in_carico_at is null then raise exception 'Prendere prima in carico l’assistenza'; end if;
  if p_azione='chiudi' and exists(select 1 from public.attivita_operatore where assistenza_rientro_id=c.id and stato in ('da_gestire','da_collegare','programmata')) then raise exception 'Completare o annullare prima il ritiro ancora aperto'; end if;
  if p_azione='chiudi' and (c.stato<>'esito_comunicato' or nullif(trim(p_nota),'') is null) then raise exception 'Comunicare e registrare prima l’esito tecnico'; end if;
  if p_azione='esito_comunicato' and nullif(trim(p_nota),'') is null then raise exception 'Esito tecnico obbligatorio'; end if;
  update public.assistenze_rientri set stato=case when p_azione='chiudi' then 'chiusa' else p_azione end,
   nota=coalesce(nullif(trim(p_nota),''),nota),esito_tecnico=case when p_azione='esito_comunicato' then p_nota else esito_tecnico end,
   chiusa_at=case when p_azione='chiudi' then now() else null end,operatore=p_operatore,updated_at=now() where id=c.id;
 else raise exception 'Azione non riconosciuta'; end if;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p_pratica_id,'ritiro_assistenza_'||p_azione,p_nota,v_prima,
  jsonb_build_object('attivita',(select to_jsonb(x) from public.attivita_operatore x where id=a.id),
   'assistenza',(select to_jsonb(x) from public.assistenze_rientri x where id=c.id)),p_operatore);
 return jsonb_build_object('ok',true,'azione',p_azione);
end; $$;

create or replace function private.trg_flussi_offerta_rientro()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform private.rileva_scelta_cliente_evento(new.id);
 perform private.rileva_rientro_evento(new.id);
 return new;
exception when others then
 insert into private.keplero_event_processing(event_id,pratica_id,versione_regole,stato,decisione,errore)
 values(new.id,new.pratica_id,'offerte-rientri-v2','errore','{}'::jsonb,sqlerrm)
 on conflict(event_id) do update set stato='errore',errore='offerte-rientri-v2: '||excluded.errore,updated_at=now();
 return new;
end; $$;
create trigger zz_flussi_offerta_rientro after insert or update of pratica_id,payload on public.keplero_live_events
 for each row execute function private.trg_flussi_offerta_rientro();

create or replace function private.recupera_flussi_offerta_rientro()
returns jsonb language plpgsql set search_path='' as $$
declare e record; v_num integer:=0;
begin
 if not pg_try_advisory_xact_lock(20261009,1716) then return jsonb_build_object('esito','gia_in_esecuzione'); end if;
 for e in select id from public.keplero_live_events where created_at>=private.inizio_finestra_controllo_keplero(now(),48)
  and pratica_id is not null order by id loop
  begin
   perform private.rileva_scelta_cliente_evento(e.id);
   perform private.rileva_rientro_evento(e.id);
   v_num:=v_num+1;
  exception when others then
   insert into private.keplero_event_processing(event_id,pratica_id,versione_regole,stato,decisione,errore)
   select id,pratica_id,'offerte-rientri-v2','errore','{}'::jsonb,sqlerrm from public.keplero_live_events where id=e.id
   on conflict(event_id) do update set stato='errore',errore=excluded.errore,updated_at=now();
  end;
 end loop;
 return jsonb_build_object('eventi_esaminati',v_num);
end; $$;

create or replace function public.contesto_rientro_keplero(p_pratica_id uuid,p_external_key text)
returns jsonb language sql stable security invoker set search_path='' as $$
 select case when not exists(select 1 from public.keplero_live_links where pratica_id=p_pratica_id and external_key=p_external_key)
 then jsonb_build_object('stato','collegamento_non_valido') else jsonb_build_object(
 'assistenza',(select to_jsonb(c) from public.assistenze_rientri c where pratica_id=p_pratica_id and chiusa_at is null),
 'ritiro',(select to_jsonb(a) from public.attivita_operatore a where pratica_id=p_pratica_id and tipo like 'ritiro_%' and stato in ('da_gestire','da_collegare','programmata')),
 'istruzioni','La richiesta registrata non equivale a prenotazione corriere o accettazione tecnica della garanzia. Un ritiro già programmato non va duplicato. Per un ritiro da classificare chiarire se contiene il vecchio dispositivo da scambio o quello ricevuto da noi che presenta il problema. Non richiedere nuovamente dati già disponibili.') end;
$$;

create or replace function private.candidati_flussi_offerta_rientro()
returns table(chiave text,pratica_id uuid,event_id bigint,regola text,descrizione text,evidenza text)
language sql stable set search_path='' as $$
 select 'assistenza_non_assegnata:'||c.id,c.pratica_id,c.evento_id,'assistenza_urgente_non_assegnata',
 'Rientro di assistenza urgente senza presa in carico da oltre 30 minuti lavorativi.',left(c.evidenza,600)
 from public.assistenze_rientri c where chiusa_at is null and presa_in_carico_at is null
  and public.minuti_lavorativi_trascorsi(aperta_at,now())>=30
 union all
 select 'ritiro_ambiguo:'||a.id,a.pratica_id,a.evento_keplero_id,'ritiro_da_classificare',
 'Ritiro rilevato: classificazione o ordine di origine da chiarire.',left(a.evidenza,600)
 from public.attivita_operatore a where a.tipo like 'ritiro_%' and a.stato in ('da_gestire','da_collegare','programmata')
  and (a.tipo='ritiro_da_classificare' or a.pratica_origine_id is null)
 union all
 select 'offerta_illeggibile:'||q.id,q.pratica_id,null::bigint,'offerta_da_verificare',
 'Alternative del preventivo non leggibili: verifica del documento richiesta.',coalesce(q.errore,'Alternative assenti')
 from public.offerte_versioni q where stato='da_verificare'
  and not exists(select 1 from public.offerte_versioni n where n.preventivo_id=q.preventivo_id and n.registrata_at>q.registrata_at)
 union all
 select 'scelta_ambigua:'||s.pratica_id,s.pratica_id,s.evento_id,'scelta_cliente_da_chiarire',
 'Scelta del cliente da chiarire o modifica di una scelta già confermata.',left(s.evidenza,600)
 from public.scelte_cliente s where stato in ('da_chiarire','modifica_da_verificare')
 union all
 select 'scelta_nuova_offerta:'||s.pratica_id,s.pratica_id,s.evento_id,'scelta_versione_precedente',
 'Nuovo preventivo dopo la scelta: verificare la versione concordata con il cliente.',left(s.evidenza,600)
 from public.v_scelte_cliente s where offerta_successiva and stato='confermata'
 union all
 select 'prezzo_scelta:'||s.pratica_id,s.pratica_id,s.evento_id,'prezzo_scelta_da_verificare',
 'Importo di pagamento segnalato diverso dal preventivo scelto: verificare il prezzo concordato.',left(s.evidenza,600)
 from public.v_scelte_cliente s where prezzo_da_verificare;
$$;

-- Le funzioni sono riservate alla route autenticata lato server.
revoke all on function public.registra_opzioni_offerta(uuid,jsonb,text,text,text,text,integer,timestamptz),
 public.correggi_scelta_cliente(uuid,uuid,text,text,text),public.contesto_offerta_keplero(uuid,text),
 public.contesto_rientro_keplero(uuid,text),public.gestisci_ritiro_assistenza(uuid,uuid,uuid,text,text,text,text,date,text,bigint) from public,anon,authenticated;
grant execute on function public.registra_opzioni_offerta(uuid,jsonb,text,text,text,text,integer,timestamptz),
 public.correggi_scelta_cliente(uuid,uuid,text,text,text),public.contesto_offerta_keplero(uuid,text),
 public.contesto_rientro_keplero(uuid,text),public.gestisci_ritiro_assistenza(uuid,uuid,uuid,text,text,text,text,date,text,bigint) to service_role;
revoke all on function private.preferenza_senza_conferma(text),private.rileva_scelta_cliente_evento(bigint),
 private.rileva_rientro_evento(bigint),private.trg_flussi_offerta_rientro(),private.recupera_flussi_offerta_rientro(),
 private.candidati_flussi_offerta_rientro() from public,anon,authenticated;
grant execute on function private.preferenza_senza_conferma(text),private.rileva_scelta_cliente_evento(bigint),
 private.rileva_rientro_evento(bigint),private.recupera_flussi_offerta_rientro(),private.candidati_flussi_offerta_rientro() to service_role;

CREATE OR REPLACE FUNCTION private.rileva_attivita_operativa_evento(p_evento_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_evento public.keplero_live_events%rowtype;
  v_pratica public.pratiche%rowtype;
  v_messaggio text;
  v_testo text;
  v_callback boolean := false;
  v_ritiro boolean := false;
  v_ritiro_forte boolean := false;
  v_tipo_attivita text;
  v_stato_attivita text := 'da_gestire';
  v_preventivo_id uuid;
  v_origine_id uuid;
  v_numero_origini integer := 0;
  v_attivita_id uuid;
  v_inserita boolean := false;
  v_risultati jsonb := '[]'::jsonb;
  v_prima jsonb;
  v_dopo jsonb;
begin
  select * into v_evento
  from public.keplero_live_events
  where id = p_evento_id;

  if not found or v_evento.pratica_id is null then
    return jsonb_build_object('ok', true, 'esito', 'evento_senza_pratica');
  end if;

  select * into v_pratica
  from public.pratiche
  where id = v_evento.pratica_id;

  if not found then
    return jsonb_build_object('ok', true, 'esito', 'pratica_non_trovata');
  end if;

  v_messaggio := trim(coalesce(
    v_evento.payload ->> 'ultimo_messaggio_cliente',
    v_evento.payload ->> 'messaggio_cliente',
    v_evento.payload ->> 'messaggio',
    ''
  ));
  v_testo := lower(v_messaggio);

  if v_testo = '' then
    return jsonb_build_object('ok', true, 'esito', 'messaggio_assente');
  end if;

  -- Richiesta esplicita del cliente. I boilerplate Voice e le intenzioni del
  -- cliente di richiamare lui stesso non sono richieste di ricontatto.
  v_callback := private.richiesta_richiamata_esplicita(v_testo);

  -- Rientro fisico: richiede una formulazione operativa, non la sola parola
  -- "ritiro" usata mentre si conferma un ordine.
  v_ritiro_forte := v_testo ~ (
    '(pacc(o|hetto).*(pront|ritir)|pront[ioa].*(ritir|restitu|rientr)|' ||
    '(restitu|rientr).*(pompa|abs|centralina|prodotto|pezzo)|' ||
    'ritirare.*(pompa|abs|centralina|prodotto|pezzo).*(usat|vecchi)|' ||
    '(non (e|è) ancora passat|quando passa|quando passera|quando passerà).*corriere)'
  );
  v_ritiro_forte := v_ritiro_forte or private.richiesta_restituzione_vecchio(v_testo);
  v_ritiro := v_ritiro_forte
    or (
      v_pratica.tipo_flusso = 'assistenza'::public.tipo_flusso
      and v_testo ~ '(programmar|prenotar|organizzar).*(ritiro|corriere)'
    );

  if v_callback then
    select a.id into v_attivita_id
    from public.attivita_operatore a
    where a.evento_keplero_id = v_evento.id
      and a.tipo in (
        'richiamata_post_preventivo',
        'richiamata_post_vendita',
        'richiamata_da_classificare'
      )
    limit 1;

    if v_attivita_id is not null then
      v_risultati := v_risultati || jsonb_build_array(jsonb_build_object(
        'tipo', 'richiamata_gia_elaborata', 'attivita_id', v_attivita_id
      ));
    else
    select pr.id into v_preventivo_id
    from public.preventivi pr
    where pr.pratica_id = v_pratica.id
      and pr.stato in ('inviato', 'accettato')
      and pr.inviato_at is not null
    order by pr.inviato_at desc
    limit 1;

    if v_pratica.stato_fatturazione = 'fatturato'::public.stato_fatturazione
       or v_pratica.stato_commerciale = 'ordine_acquisito'::public.stato_commerciale
       or v_pratica.tipo_flusso = 'assistenza'::public.tipo_flusso
    then
      v_tipo_attivita := 'richiamata_post_vendita';
    elsif v_pratica.stato_commerciale = 'preventivo_inviato'::public.stato_commerciale
          or (v_preventivo_id is not null
              and v_pratica.stato_commerciale = 'attesa_cliente'::public.stato_commerciale)
    then
      v_tipo_attivita := 'richiamata_post_preventivo';
    else
      v_tipo_attivita := 'richiamata_da_classificare';
      v_stato_attivita := 'da_collegare';
    end if;

    insert into public.attivita_operatore (
      tipo, stato, priorita, pratica_id, preventivo_id, evento_keplero_id,
      external_key, evidenza, fonte, metadati, richiesta_at
    ) values (
      v_tipo_attivita, v_stato_attivita, 'alta', v_pratica.id,
      v_preventivo_id, v_evento.id, v_evento.external_key, v_messaggio,
      'keplero_live', jsonb_build_object('regola', 'richiamata_esplicita_v1'),
      v_evento.created_at
    )
    on conflict (pratica_id, tipo)
      where stato in ('da_gestire', 'da_collegare', 'programmata')
    do update set
      evidenza = excluded.evidenza,
      evento_keplero_id = excluded.evento_keplero_id,
      external_key = excluded.external_key,
      richiesta_at = greatest(public.attivita_operatore.richiesta_at, excluded.richiesta_at),
      updated_at = now()
    returning id, (created_at = updated_at) into v_attivita_id, v_inserita;

    if v_inserita then
      insert into public.azioni_operatore (
        pratica_id, azione, nota, stato_prima, stato_dopo, operatore
      ) values (
        v_pratica.id,
        'routine_controllo_k_attivita_richiamata',
        'Richiesta di contatto telefonico rilevata dal testo letterale del cliente.',
        '{}'::jsonb,
        jsonb_build_object(
          'attivita_id', v_attivita_id,
          'tipo', v_tipo_attivita,
          'stato', v_stato_attivita,
          'evento_keplero_id', v_evento.id,
          'evidenza', v_messaggio
        ),
        'routine_controllo_k'
      );
    end if;

    v_risultati := v_risultati || jsonb_build_array(jsonb_build_object(
      'tipo', v_tipo_attivita, 'attivita_id', v_attivita_id
    ));
    end if;
  end if;

  perform private.rileva_rientro_evento(p_evento_id);
  return jsonb_build_object('ok', true, 'attivita', v_risultati);
end;
$function$;

CREATE OR REPLACE FUNCTION public.conferma_ordine_da_keplero(p_pratica_id uuid, p_external_key text, p_messaggio_cliente text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_prima public.pratiche%rowtype;
  v_dopo public.pratiche%rowtype;
begin
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
    ordine_acquisito_at = coalesce(ordine_acquisito_at, now()),
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


create or replace function private.candidati_errori_flussi()
returns table(chiave text,pratica_id uuid,event_id bigint,regola text,descrizione text,evidenza text)
language sql stable set search_path='' as $$
 select 'flusso_errore:'||e.id,e.pratica_id,e.id,'errore_flusso_offerta_ritiro',
 'Elaborazione offerta/ritiro non completata: verifica tecnica richiesta.',left(ep.errore,600)
 from private.keplero_event_processing ep join public.keplero_live_events e on e.id=ep.event_id
 where ep.stato='errore' and (ep.versione_regole='offerte-rientri-v2' or ep.errore like 'offerte-rientri-v2:%')
 union all
 select distinct on(e.pratica_id) 'ritiro_non_registrato:'||e.pratica_id,e.pratica_id,e.id,'ritiro_non_registrato',
 'Messaggio con pacco pronto per il ritiro senza attività registrata.',left(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),600)
 from public.keplero_live_events e join public.pratiche p on p.id=e.pratica_id
 where e.created_at>=private.inizio_finestra_controllo_keplero(now(),48) and e.created_at<now()-interval '10 minutes'
  and lower(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''))~'(pacco.{0,50}pronto.{0,50}ritiro|pronto.{0,40}ritirare)'
  and not exists(select 1 from public.attivita_operatore a where a.pratica_id=e.pratica_id and a.tipo like 'ritiro_%'
   and (a.stato in ('da_gestire','da_collegare','programmata') or coalesce(a.completata_at,a.annullata_at)>=e.created_at))
  and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
  and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
$$;
revoke all on function private.candidati_errori_flussi() from public,anon,authenticated;

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
;
$function$;


select cron.schedule('recupera-offerte-ritiri-assistenza','*/5 * * * *','select private.recupera_flussi_offerta_rientro(); select private.controlla_coerenza_keplero();');

-- Anche i PDF arrivati prima della pratica conservano la lettura per il successivo abbinamento.
alter table public.preventivi_emessi_ricevuti add column contenuto_offerta jsonb;
create or replace function public.registra_preventivo_con_offerta(p_external_id text,p_nome_file text,p_targa text,
 p_file_url text,p_data_offerta timestamptz,p_inviato_at timestamptz,p_contenuto jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r jsonb; v_offerta jsonb;
begin
 r:=public.registra_preventivo_emesso_auto(p_external_id,p_nome_file,p_targa,p_file_url,p_data_offerta,p_inviato_at);
 if coalesce(r->>'ricevuto','false')='true' and r->>'esito'<>'external_id_in_conflitto' then
  update public.preventivi_emessi_ricevuti set contenuto_offerta=p_contenuto||jsonb_build_object('inviato_at',p_inviato_at) where external_id=p_external_id;
 end if;
 if r->>'preventivo_id' is not null then
  v_offerta:=public.registra_opzioni_offerta((r->>'preventivo_id')::uuid,p_contenuto->'opzioni',p_contenuto->>'impronta',
   p_contenuto->>'testo',p_contenuto->>'errore',coalesce(p_contenuto->>'fonte','pdf'),(p_contenuto->>'validita_giorni')::integer,p_inviato_at);
 end if;
 return r||jsonb_build_object('lettura_offerta',v_offerta);
end; $$;
create or replace function private.ritenta_letture_offerte()
returns integer language plpgsql set search_path='' as $$
declare d record; v_num integer:=0;
begin
 for d in select pr.id,doc.contenuto_offerta c from public.preventivi_emessi_ricevuti doc
  join public.preventivi pr on pr.external_id=doc.external_id
  where doc.contenuto_offerta is not null and not exists(select 1 from public.offerte_versioni q where q.preventivo_id=pr.id and q.impronta=doc.contenuto_offerta->>'impronta') loop
  perform public.registra_opzioni_offerta(d.id,d.c->'opzioni',d.c->>'impronta',d.c->>'testo',d.c->>'errore',coalesce(d.c->>'fonte','pdf'),(d.c->>'validita_giorni')::integer,(d.c->>'inviato_at')::timestamptz);
  v_num:=v_num+1;
 end loop;
 return v_num;
end; $$;
revoke all on function public.registra_preventivo_con_offerta(text,text,text,text,timestamptz,timestamptz,jsonb),private.ritenta_letture_offerte() from public,anon,authenticated;
grant execute on function public.registra_preventivo_con_offerta(text,text,text,text,timestamptz,timestamptz,jsonb),private.ritenta_letture_offerte() to service_role;
select cron.schedule('ritenta-letture-offerte','*/5 * * * *','select private.ritenta_letture_offerte();');

-- Le route server con security invoker possono usare i controlli letterali privati.
grant execute on function private.rinvio_conferma_per_verifiche(text),private.domanda_su_accettazione(text),
 private.revoca_scelta_cliente(text),private.conferma_letterale_offerta(text),private.richiesta_restituzione_vecchio(text) to service_role;

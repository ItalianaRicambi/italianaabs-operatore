-- Evasione distinta dalla fatturazione. Nessuna fattura, importo o pratica viene riscritta.
create table public.evasioni_pratiche (
 pratica_id uuid primary key references public.pratiche(id),
 stato text not null check(stato in ('da_evadere','evaso','da_verificare')),
 revisione integer not null default 1,
 nota text not null,
 operatore text,
 updated_at timestamptz not null default now()
);
alter table public.evasioni_pratiche enable row level security;
revoke all on public.evasioni_pratiche from public,anon,authenticated;
grant select,insert,update on public.evasioni_pratiche to service_role;

insert into public.evasioni_pratiche(pratica_id,stato,nota)
select id,case when stato_fatturazione='fatturato' then 'da_verificare' else 'da_evadere' end,
 case when stato_fatturazione='fatturato' then 'Storico: fattura presente, evasione non attestata. Verificare prima di classificare.'
 else 'Ordine acquisito: evasione da gestire separatamente dalla fatturazione.' end
from public.pratiche where tipo_flusso='commerciale' and stato_commerciale='ordine_acquisito'
and coalesce(dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
and coalesce(dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';

create function private.apri_evasione_ordine() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.tipo_flusso='commerciale' and new.stato_commerciale='ordine_acquisito' then
  if tg_op='INSERT' or old.stato_commerciale is distinct from new.stato_commerciale then
   insert into public.evasioni_pratiche(pratica_id,stato,nota)
   values(new.id,'da_evadere','Nuovo ordine acquisito: evasione non ancora attestata.')
   on conflict(pratica_id) do nothing;
  end if;
 end if;
 return new;
end $$;
revoke all on function private.apri_evasione_ordine() from public,anon,authenticated;
create trigger ordine_apri_evasione after insert or update of stato_commerciale on public.pratiche
for each row execute function private.apri_evasione_ordine();

create function public.aggiorna_evasione_pratica(p_pratica_id uuid,p_revisione integer,p_stato text,p_nota text,p_operatore text)
returns boolean language plpgsql security invoker set search_path='' as $$
declare v public.evasioni_pratiche; n public.evasioni_pratiche;
begin
 if p_stato is null or p_stato not in ('da_evadere','evaso','da_verificare') or length(btrim(coalesce(p_nota,''))) not between 12 and 2000
 or p_operatore is null or p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4')
 then raise exception 'Stato, operatore e prova o motivazione richiesti'; end if;
 perform 1 from public.pratiche where id=p_pratica_id and tipo_flusso='commerciale' and stato_commerciale='ordine_acquisito' for update;
 if not found then raise exception 'Ordine non attivo: aggiornare la pagina';end if;
 if exists(select 1 from public.pratiche where id=p_pratica_id and nullif(shopify_order_id,'') is not null)
 or exists(select 1 from public.ordini_shopify where pratica_id=p_pratica_id)
 then raise exception 'Evasione Shopify: aggiornare il sistema originale, non la pratica'; end if;
 select * into v from public.evasioni_pratiche where pratica_id=p_pratica_id for update;
 if v.pratica_id is null or v.revisione is distinct from p_revisione then raise exception 'Revisione cambiata: aggiornare la pagina';end if;
 update public.evasioni_pratiche set stato=p_stato,nota=btrim(p_nota),operatore=p_operatore,revisione=revisione+1,updated_at=now()
 where pratica_id=p_pratica_id returning * into n;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p_pratica_id,'evasione_ordine',p_nota,to_jsonb(v),to_jsonb(n),p_operatore);
 return true;
end $$;
revoke all on function public.aggiorna_evasione_pratica(uuid,integer,text,text,text) from public,anon,authenticated;
grant execute on function public.aggiorna_evasione_pratica(uuid,integer,text,text,text) to service_role;

create table public.verifiche_acquisizione_ordini (
 id uuid primary key default gen_random_uuid(),
 pratica_id uuid not null references public.pratiche(id),
 evento_id bigint not null references public.keplero_live_events(id),
 messaggio text not null,
 impronta text not null,
 evento_at timestamptz not null,
 risolta_at timestamptz,
 nota text,
 operatore text,
 unique(pratica_id,impronta)
);
create index verifiche_acquisizione_evento_idx on public.verifiche_acquisizione_ordini(evento_id);
alter table public.verifiche_acquisizione_ordini enable row level security;
revoke all on public.verifiche_acquisizione_ordini from public,anon,authenticated;
grant select,insert,update on public.verifiche_acquisizione_ordini to service_role;

-- Solo una richiesta di verifica, MAI un ordine automatico. Nessun riepilogo AI.
create function private.possibile_ordine_letterale(t text) returns boolean
language sql immutable set search_path='' as $$
 select coalesce(
  lower(t) ~ '\m(accetto|accettiamo|confermo|confermiamo|approvo|approviamo)\M.{0,100}\m(offerta|preventivo|lavorazione|riparazione|ordine)\M'
  or lower(t) ~ '\mordine[[:space:]]+(fatto|effettuato|inserito|completato)\M'
  or lower(t) ~ '\m(voglio|vogliamo|intendo|intendiamo)[[:space:]]+procedere\M.{0,80}\m(lavorazione|riparazione)\M',false)
 and lower(coalesce(t,'')) !~ '\m(non|forse|se|qualora|vorrei|vorremmo|confermerei|confermeremmo)\M'
 and coalesce(t,'') not like '%?%'
$$;
revoke all on function private.possibile_ordine_letterale(text) from public,anon,authenticated;
grant execute on function private.possibile_ordine_letterale(text) to service_role;

create function private.registra_verifica_acquisizione() returns trigger language plpgsql security definer set search_path='' as $$
declare t text := btrim(new.payload->>'ultimo_messaggio_cliente');
begin
 if new.pratica_id is not null and private.possibile_ordine_letterale(t) then
  insert into public.verifiche_acquisizione_ordini(pratica_id,evento_id,messaggio,impronta,evento_at)
  values(new.pratica_id,new.id,left(t,4000),md5(lower(t)),new.created_at)
  on conflict(pratica_id,impronta) do nothing;
 end if;
 return new;
end $$;
revoke all on function private.registra_verifica_acquisizione() from public,anon,authenticated;
create trigger zz_verifica_acquisizione after insert or update of pratica_id,payload on public.keplero_live_events
for each row execute function private.registra_verifica_acquisizione();

-- Finestra iniziale richiesta, weekend sospeso; i sospetti raccolti restano fino a verifica.
insert into public.verifiche_acquisizione_ordini(pratica_id,evento_id,messaggio,impronta,evento_at)
select distinct on(pratica_id,md5(lower(btrim(payload->>'ultimo_messaggio_cliente'))))
 pratica_id,id,left(btrim(payload->>'ultimo_messaggio_cliente'),4000),
 md5(lower(btrim(payload->>'ultimo_messaggio_cliente'))),created_at
from public.keplero_live_events
where created_at >= private.inizio_finestra_controllo_keplero(now(),48) and pratica_id is not null
and private.possibile_ordine_letterale(payload->>'ultimo_messaggio_cliente')
order by pratica_id,md5(lower(btrim(payload->>'ultimo_messaggio_cliente'))),id
on conflict(pratica_id,impronta) do nothing;

create function public.risolvi_verifica_acquisizione(p_id uuid,p_nota text,p_operatore text)
returns boolean language plpgsql security invoker set search_path='' as $$
declare v public.verifiche_acquisizione_ordini;
begin
 if length(btrim(coalesce(p_nota,''))) not between 12 and 2000 or p_operatore is null
 or p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') then raise exception 'Motivo e operatore richiesti'; end if;
 select * into v from public.verifiche_acquisizione_ordini where id=p_id for update;
 if v.id is null then raise exception 'Verifica non trovata'; end if;
 if v.risolta_at is not null then return false;end if;
 update public.verifiche_acquisizione_ordini set risolta_at=now(),nota=btrim(p_nota),operatore=p_operatore where id=p_id;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(v.pratica_id,'verifica_acquisizione_ordine',p_nota,to_jsonb(v),jsonb_build_object('risolta',true),p_operatore);
 return true;
end $$;
revoke all on function public.risolvi_verifica_acquisizione(uuid,text,text) from public,anon,authenticated;
grant execute on function public.risolvi_verifica_acquisizione(uuid,text,text) to service_role;

create view public.v_evasioni_pratiche with(security_invoker=true) as
select e.*,p.numero_pratica,p.targa,p.stato_fatturazione::text,p.shopify_order_id,p.blocco_operatore
from public.evasioni_pratiche e join public.pratiche p on p.id=e.pratica_id
where p.tipo_flusso='commerciale' and p.stato_commerciale='ordine_acquisito'
and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
revoke all on public.v_evasioni_pratiche from public,anon,authenticated;
grant select on public.v_evasioni_pratiche to service_role;

create view public.v_verifiche_acquisizione_ordini with(security_invoker=true) as
select v.*,p.numero_pratica,p.targa,p.stato_commerciale::text,p.blocco_operatore,
 exists(select 1 from public.keplero_live_events e where e.pratica_id=p.id and e.created_at>v.evento_at
 and lower(e.payload->>'ultimo_messaggio_cliente') ~ '(annull|revoc|non conferm|non proced|non accett)') as possibile_revoca
from public.verifiche_acquisizione_ordini v join public.pratiche p on p.id=v.pratica_id
where v.risolta_at is null and p.tipo_flusso='commerciale'
and p.stato_commerciale in ('preventivo_inviato','attesa_cliente','da_preventivare','preventivo_pronto')
and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
revoke all on public.v_verifiche_acquisizione_ordini from public,anon,authenticated;
grant select on public.v_verifiche_acquisizione_ordini to service_role;

-- Risolve soltanto il riordino certo degli eventi di annullamento.
create or replace function public.registra_ordine_shopify(p_dati jsonb, p_valutazione jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_shop text := p_dati->>'shop';
  v_order text := p_dati->>'ordine_id';
  v_at timestamptz;
  v_row public.ordini_shopify;
  v_pratica uuid;
  v_count integer;
begin
  if v_shop is distinct from 'j4mqgv-am.myshopify.com'
     or coalesce(v_order,'') !~ '^[0-9]{1,20}$'
     or jsonb_typeof(p_dati) is distinct from 'object'
     or jsonb_typeof(p_valutazione) is distinct from 'object'
     or octet_length(p_dati::text) > 1000000
     or jsonb_typeof(p_valutazione->'attivo') is distinct from 'boolean'
     or jsonb_typeof(p_valutazione->'pronto_ordine') is distinct from 'boolean'
     or jsonb_typeof(p_valutazione->'pagamento_richiesto') is distinct from 'boolean'
     or jsonb_typeof(p_valutazione->'verifica_iva') is distinct from 'boolean'
  then raise exception 'Dati Shopify non validi'; end if;
  v_at := (p_dati->>'aggiornato_shopify_at')::timestamptz;
  if v_at is null then raise exception 'Revisione Shopify mancante'; end if;

  -- Serializza anche la prima consegna concorrente, quando la riga non esiste.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('shopify:' || v_shop || ':' || v_order, 0));
  select * into v_row from public.ordini_shopify where shop = v_shop and ordine_id = v_order for update;
  if found then
    if v_at < v_row.aggiornato_shopify_at then
      return jsonb_build_object('esito','evento_superato','id',v_row.id);
    elsif v_row.dati->'annullato' = 'true'::jsonb and p_dati->'annullato' = 'false'::jsonb
      and v_at > v_row.aggiornato_shopify_at then
      update public.ordini_shopify set conflitto = true, pronto_ordine = false, attivo = false, ricevuto_at = now() where id = v_row.id;
      return jsonb_build_object('esito','conflitto_da_verificare','id',v_row.id);
    elsif v_at = v_row.aggiornato_shopify_at then
      if v_row.dati = p_dati then
        return jsonb_build_object('esito','duplicato','id',v_row.id);
      end if;
      -- Arricchimento compatibile della stessa revisione; mai sovrascrivere uno stato noto.
      if (v_row.dati - 'stato_evasione') = (p_dati - 'stato_evasione')
         and coalesce(v_row.dati->>'stato_evasione','da_verificare') = 'da_verificare'
         and p_dati->>'stato_evasione' in ('da_evadere','parziale','evaso') then
        update public.ordini_shopify set dati=p_dati,valutazione=p_valutazione,
          pronto_ordine=(p_valutazione->>'pronto_ordine')::boolean and not conflitto,
          ricevuto_at=now() where id=v_row.id;
        return jsonb_build_object('esito','evasione_integrata','id',v_row.id);
      end if;
      if (v_row.dati - 'stato_evasione') = (p_dati - 'stato_evasione')
         and v_row.dati->>'stato_evasione' in ('da_evadere','parziale','evaso')
         and coalesce(p_dati->>'stato_evasione','da_verificare')='da_verificare' then
        return jsonb_build_object('esito','duplicato_pre_arricchimento','id',v_row.id);
      end if;
      -- Annullamento irreversibile: a parità di timestamp prevale il suo
      -- snapshot, ma solo se identità, righe e stato del pagamento coincidono.
      -- Gli importi correnti possono azzerarsi durante l'annullamento.
      if (v_row.dati - array['annullato','totale','iva']) = (p_dati - array['annullato','totale','iva'])
         and v_row.dati->'annullato' = 'true'::jsonb and p_dati->'annullato' = 'false'::jsonb then
        return jsonb_build_object('esito','evento_pre_annullamento','id',v_row.id);
      elsif ((v_row.dati - array['annullato','totale','iva']) = (p_dati - array['annullato','totale','iva'])
         and v_row.dati->'annullato' = 'false'::jsonb and p_dati->'annullato' = 'true'::jsonb
         and p_valutazione->'attivo' = 'false'::jsonb and p_valutazione->'pronto_ordine' = 'false'::jsonb) is not true then
        update public.ordini_shopify set conflitto = true, pronto_ordine = false,
          attivo = case when p_dati->'annullato' = 'true'::jsonb then false else attivo end,
          ricevuto_at = now() where id = v_row.id;
        return jsonb_build_object('esito','conflitto_da_verificare','id',v_row.id);
      end if;
    end if;
  end if;
  -- Nessun abbinamento per nome, email o targa; il riferimento deve essere univoco.
  select count(*), (array_agg(id))[1] into v_count, v_pratica from public.pratiche
    where shopify_order_id in (v_order, 'gid://shopify/Order/' || v_order);
  if v_count <> 1 then v_pratica := null; end if;
  insert into public.ordini_shopify (shop,ordine_id,aggiornato_shopify_at,dati,valutazione,attivo,pronto_ordine,pagamento_richiesto,verifica_iva,pratica_id)
  values (v_shop,v_order,v_at,p_dati,p_valutazione,(p_valutazione->>'attivo')::boolean,
    (p_valutazione->>'pronto_ordine')::boolean,(p_valutazione->>'pagamento_richiesto')::boolean,(p_valutazione->>'verifica_iva')::boolean,v_pratica)
  on conflict (shop,ordine_id) do update set aggiornato_shopify_at = excluded.aggiornato_shopify_at,
    dati = excluded.dati, valutazione = excluded.valutazione, attivo = excluded.attivo,
    pronto_ordine = excluded.pronto_ordine, pagamento_richiesto = excluded.pagamento_richiesto,
    verifica_iva = excluded.verifica_iva, pratica_id = coalesce(excluded.pratica_id, public.ordini_shopify.pratica_id),
    conflitto = false, ricevuto_at = now()
  returning * into v_row;
  return jsonb_build_object('esito','registrato','id',v_row.id);
end;
$$;
revoke all on function public.registra_ordine_shopify(jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.registra_ordine_shopify(jsonb,jsonb) to service_role;

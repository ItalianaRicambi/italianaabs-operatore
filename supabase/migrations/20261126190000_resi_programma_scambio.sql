-- Registro per singola fornitura. Nessun dato cliente nel codice di rilascio.
create table public.resi_scambio (
 id uuid primary key default gen_random_uuid(),
 fattura text not null, data_fattura date not null, cliente text not null,
 veicolo text not null, componente text not null, sigla text not null
   check(sigla in ('MBO','EB','BDM','PSMI','MBMI','ARMI')),
 pratica_id uuid references public.pratiche(id) on delete set null,
 spedizione date, fonte text not null, nota text not null default '',
 stato text not null default 'verifica' check(stato in
 ('verifica','attesa','montaggio','accordo','assistenza','presa','reso','escluso','decaduta')),
 prossima date, ultimo_invio date, presa text, revisione integer not null default 1,
 unico_tentativo uuid, decisione jsonb, comunicazione jsonb,
 unique(fattura,veicolo,componente),
 check (stato not in ('attesa','montaggio') or (spedizione is not null and prossima is not null))
);
create index resi_scambio_veicolo on public.resi_scambio (veicolo);
create table public.resi_scambio_eventi (
 id uuid primary key default gen_random_uuid(), reso_id uuid not null references public.resi_scambio(id),
 chiave text not null, tipo text not null, autore text not null,
 data_evento timestamptz not null default now(), dettagli jsonb not null,
 unique(reso_id,chiave)
);
alter table public.resi_scambio enable row level security;
alter table public.resi_scambio_eventi enable row level security;
revoke all on public.resi_scambio,public.resi_scambio_eventi from public,anon,authenticated;
grant select, insert, update on public.resi_scambio to service_role;
grant select, insert on public.resi_scambio_eventi to service_role;

-- Algoritmo gregoriano per il lunedì di Pasqua anche negli anni successivi.
create function public.resi_lunedi_pasqua(anno integer) returns date
language sql immutable strict set search_path='' as $$
 with x as (select anno%19 a, anno/100 b, anno%100 c),
 y as (select *, (19*a+b-b/4-(b-(b+8)/25+1)/3+15)%30 h from x),
 z as (select *, (32+2*(b%4)+2*(c/4)-h-(c%4))%7 l from y),
 d as (select h+l-7*((a+11*h+22*l)/451)+114 n from z)
 select make_date(anno,n/31,n%31+1)+1 from d
$$;
create function public.resi_lavorativo(g date) returns boolean
language sql stable strict set search_path='' as $$
 select extract(isodow from g)<6
 and to_char(g,'MM-DD') not in ('01-01','01-06','04-25','05-01','06-02','08-15','10-04','11-01','12-08','12-25','12-26')
 and g<>public.resi_lunedi_pasqua(extract(year from g)::int)
 and not exists(select 1 from public.followup_dati_chiusure where g between data_inizio and data_fine)
 and not exists(select 1 from public.chiusure_aziendali where g between data_inizio and data_fine)
$$;
create function public.resi_aggiungi_lavorativi(base date, giorni integer) returns date
language plpgsql stable strict set search_path='' as $$
declare g date := base; n integer := 0;
begin
 if giorni not between 0 and 260 then raise exception 'Intervallo non valido'; end if;
 while n<giorni loop
  g:=g+1;
  if public.resi_lavorativo(g) then n:=n+1; end if;
 end loop;
 return g;
end $$;
create view public.v_resi_scambio with (security_invoker=true) as
 select r.*, (spedizione+interval '6 months')::date as sei_mesi,
 (spedizione+interval '6 months')::date <= (now() at time zone 'Europe/Rome')::date
 and stato not in ('reso','presa','escluso','decaduta')
 and (stato<>'accordo' or prossima is null or prossima <= (now() at time zone 'Europe/Rome')::date) as riesame
 from public.resi_scambio r;
revoke all on public.v_resi_scambio from public,anon,authenticated;
grant select on public.v_resi_scambio to service_role;

-- Un evento identificato dalla fonte si applica una sola volta. Il lock e la
-- revisione impediscono di scavalcare una risposta o una decisione concorrente.
create function public.evento_reso_scambio(p_id uuid,p_revisione integer,p_tipo text,
 p_chiave text,p_autore text,p_dati jsonb) returns uuid
language plpgsql set search_path='' as $$
declare r public.resi_scambio; eid uuid; token uuid; oggi date:=(now() at time zone 'Europe/Rome')::date;
 data_rif date:=(p_dati->>'data')::date; motivo text:=trim(coalesce(p_dati->>'nota',''));
 limite date; operatore boolean:=p_autore in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4');
begin
 if nullif(trim(p_chiave),'') is null or p_dati is null or p_autore is null
 or not (operatore or p_autore='Routine resi') then raise exception 'Evento non valido'; end if;
 select * into strict r from public.resi_scambio where id=p_id for update;
 select id into eid from public.resi_scambio_eventi where reso_id=r.id and chiave=p_chiave;
 if found then
  if p_tipo='tentativo' then raise exception 'Tentativo già acquisito: riconciliare'; end if;
  return eid;
 end if;
 if r.revisione is distinct from p_revisione then raise exception 'Pratica aggiornata: rileggerla'; end if;
 limite := (r.spedizione+interval '6 months')::date;
 if r.stato='decaduta' and p_tipo not in ('comunicata','rettifica') then raise exception 'Decisione già registrata'; end if;
 if r.stato in ('escluso','reso') and p_tipo not in ('rettifica','inviato','rifiutato') then raise exception 'Fornitura chiusa'; end if;
 if p_tipo='tentativo' then
  if r.unico_tentativo is not null or r.stato not in ('attesa','montaggio') or limite is null
   or oggi>=limite or r.prossima is null or r.prossima>oggi or not public.resi_lavorativo(oggi)
   or coalesce(p_dati->>'canale','') not in ('WhatsApp','Email')
   or coalesce(trim(p_dati->>'testo'),'')='' or coalesce(trim(p_dati->>'verifica'),'')=''
   or coalesce(trim(p_dati->>'destinatario'),'')='' then raise exception 'Invio non ammissibile'; end if;
  token:=gen_random_uuid(); r.unico_tentativo:=token;
 elsif p_tipo in ('inviato','rifiutato') then
  if r.unico_tentativo is null or r.unico_tentativo is distinct from (p_dati->>'token')::uuid
   or nullif(trim(p_dati->>'prova'),'') is null then raise exception 'Tentativo o prova mancante'; end if;
  r.unico_tentativo:=null;
  if p_tipo='inviato' then
   r.ultimo_invio:=oggi;
   if r.stato in ('attesa','montaggio') then r.stato:='attesa'; r.prossima:=public.resi_aggiungi_lavorativi(oggi,15); end if;
  end if;
 elsif p_tipo='storico_invio' then
  if data_rif is null or data_rif>oggi or r.unico_tentativo is not null or nullif(p_dati->>'prova','') is null
   or r.spedizione is null or data_rif<r.spedizione then raise exception 'Storico non verificato'; end if;
  r.ultimo_invio:=greatest(r.ultimo_invio,data_rif);
  if r.stato='attesa' then r.prossima:=public.resi_aggiungi_lavorativi(r.ultimo_invio,15); end if;
 elsif p_tipo='spedizione' then
  if data_rif is null or data_rif>oggi or motivo='' then raise exception 'Data e prova spedizione richieste'; end if;
  r.spedizione:=data_rif; r.fonte:=motivo;
  if r.stato='attesa' then r.prossima:=public.resi_aggiungi_lavorativi(coalesce(r.ultimo_invio,data_rif),
    case when r.ultimo_invio is null then 20 else 15 end); end if;
 elsif p_tipo='attiva' then
  if r.spedizione is null or motivo='' or r.stato not in ('verifica','assistenza','accordo','presa') then raise exception 'Verificare prima la fornitura'; end if;
  r.stato:='attesa'; r.prossima:=public.resi_aggiungi_lavorativi(coalesce(r.ultimo_invio,r.spedizione),
    case when r.ultimo_invio is null then 20 else 15 end);
 elsif p_tipo in ('montaggio','vago','accordo') then
  if data_rif is null or motivo='' then raise exception 'Data e riscontro richiesti'; end if;
  if p_tipo='accordo' then r.stato:='accordo'; r.prossima:=data_rif;
  else
   r.stato:='montaggio';
   r.prossima:=public.resi_aggiungi_lavorativi(data_rif,case when p_tipo='montaggio' then 3 else 4 end);
  end if;
 elsif p_tipo in ('verifica','assistenza','presa','reso','escluso','rettifica') then
  if motivo='' or (p_tipo='rettifica' and not operatore) then raise exception 'Verifica richiesta'; end if;
  r.stato:=case when p_tipo='rettifica' then 'verifica' else p_tipo end;
  r.prossima:=null;
  if p_tipo='presa' then r.presa:=nullif(trim(p_dati->>'presa'),'');
    if r.presa is null then raise exception 'Inserire riferimento presa'; end if; end if;
  if p_tipo='rettifica' then r.decisione:=null; r.comunicazione:=null; end if;
 elsif p_tipo='decaduta' then
  if not operatore or limite is null or oggi<limite or r.unico_tentativo is not null
   or r.stato in ('presa','reso','assistenza','escluso') or (r.stato='accordo' and r.prossima>oggi)
   or motivo='' or nullif(trim(p_dati->>'clausola'),'') is null then raise exception 'Verifica operatore e clausola necessarie'; end if;
  r.stato:='decaduta'; r.prossima:=null;
  r.decisione:=p_dati||jsonb_build_object('operatore',p_autore,'registrata_at',now());
 elsif p_tipo='comunicata' then
  if not operatore or r.decisione is null or r.comunicazione is not null or data_rif is null or data_rif>oggi
   or nullif(trim(p_dati->>'testo'),'') is null or coalesce(p_dati->>'canale','') not in ('WhatsApp','Email','PEC','Raccomandata')
   or nullif(trim(p_dati->>'prova'),'') is null then raise exception 'Inserire copia e prova della comunicazione'; end if;
  r.comunicazione:=p_dati||jsonb_build_object('operatore',p_autore,'registrata_at',now());
 else raise exception 'Evento sconosciuto'; end if;
 update public.resi_scambio set stato=r.stato, spedizione=r.spedizione, fonte=r.fonte, prossima=r.prossima,
  nota=coalesce(nullif(motivo,''),r.nota), ultimo_invio=r.ultimo_invio,presa=r.presa,
  decisione=r.decisione,comunicazione=r.comunicazione,unico_tentativo=r.unico_tentativo,revisione=revisione+1
  where id=r.id;
 insert into public.resi_scambio_eventi(id,reso_id,chiave,tipo,autore,dettagli)
 values(coalesce(token,gen_random_uuid()),r.id,p_chiave,p_tipo,p_autore,p_dati) returning id into eid;
 return eid;
end $$;
revoke all on function public.evento_reso_scambio(uuid,integer,text,text,text,jsonb),public.resi_aggiungi_lavorativi(date,integer),
 public.resi_lunedi_pasqua(integer),public.resi_lavorativo(date) from public,anon,authenticated;
grant execute on function public.evento_reso_scambio(uuid,integer,text,text,text,jsonb),public.resi_aggiungi_lavorativi(date,integer),
 public.resi_lunedi_pasqua(integer),public.resi_lavorativo(date) to service_role;

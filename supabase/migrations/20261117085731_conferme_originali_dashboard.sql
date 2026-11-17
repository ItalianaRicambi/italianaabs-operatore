-- Gli originali sono una seconda fonte: la mancata consegna del webhook non
-- deve nascondere un'accettazione. Questa coda NON acquisisce ordini.
alter table public.verifiche_acquisizione_ordini
 alter column evento_id drop not null,
 add column originale_sessione uuid,
 add column originale_messaggio_id text,
 add constraint verifica_originale_fk foreign key(originale_sessione,originale_messaggio_id)
 references public.keplero_originali(sessione,messaggio_id) match full,
 add constraint verifica_fonte_presente check(evento_id is not null or originale_sessione is not null);
create index verifiche_acquisizione_originale_idx
 on public.verifiche_acquisizione_ordini(originale_sessione,originale_messaggio_id);

create function private.accoda_verifica_originale_ordine(p_sessione uuid,p_messaggio text)
returns void language plpgsql security definer set search_path='' as $$
declare m public.keplero_originali; pid uuid; t text;
begin
 select * into m from public.keplero_originali
 where sessione=p_sessione and messaggio_id=p_messaggio;
 if m.sessione is null or m.direzione<>'entrata' or m.tipo<>'text'
 or m.data_messaggio<private.inizio_finestra_controllo_keplero(now(),48)
 or m.data_messaggio>now()+interval '5 minutes' then return; end if;
 t:=btrim(m.testo);
 -- Non dipende da candidato, decisione_sistema o dal riepilogo dell'AI.
 if not private.possibile_ordine_letterale(t) then return; end if;
 if exists(select 1 from public.keplero_verifiche_originali k
  where k.sessione=p_sessione and k.messaggio_id=p_messaggio
  and k.esito in ('archiviata','preservata') and k.operatore is not null) then return; end if;
 select (array_agg(distinct pratica_id))[1] into pid
 from public.keplero_pratiche_conversazioni where sessione=p_sessione
 having count(distinct pratica_id)=1;
 -- Mai scegliere una pratica per telefono o tra più veicoli della stessa chat.
 if pid is null then return; end if;
 insert into public.verifiche_acquisizione_ordini
 (pratica_id,messaggio,impronta,evento_at,originale_sessione,originale_messaggio_id)
 values(pid,left(t,4000),md5(lower(t)),m.data_messaggio,m.sessione,m.messaggio_id)
 on conflict(pratica_id,impronta) do update
 set originale_sessione=excluded.originale_sessione,
     originale_messaggio_id=excluded.originale_messaggio_id
 where public.verifiche_acquisizione_ordini.originale_sessione is null;
end $$;
revoke all on function private.accoda_verifica_originale_ordine(uuid,text) from public,anon,authenticated;

create function private.verifica_ordine_da_originale() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform private.accoda_verifica_originale_ordine(new.sessione,new.messaggio_id);
 return new;
end $$;
revoke all on function private.verifica_ordine_da_originale() from public,anon,authenticated;
create trigger zz_verifica_ordine_originale after insert or update on public.keplero_originali
for each row execute function private.verifica_ordine_da_originale();

-- Copre anche il caso in cui l'originale arrivi prima del collegamento pratica.
create function private.verifica_ordini_al_collegamento() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform private.accoda_verifica_originale_ordine(m.sessione,m.messaggio_id)
 from public.keplero_originali m where m.sessione=new.sessione
 and m.data_messaggio>=private.inizio_finestra_controllo_keplero(now(),48)
 and m.direzione='entrata' and m.tipo='text';
 return new;
end $$;
revoke all on function private.verifica_ordini_al_collegamento() from public,anon,authenticated;
create trigger zz_verifica_ordini_al_collegamento after insert or update
on public.keplero_pratiche_conversazioni for each row
execute function private.verifica_ordini_al_collegamento();

-- Mantiene compatibili le colonne esistenti; le nuove prove sono in coda.
-- Un controllo aperto rimane visibile fino a verifica, anche se più vecchio
-- della finestra di acquisizione. Raccolta dati non equivale a "nessun ordine".
create or replace view public.v_verifiche_acquisizione_ordini with(security_invoker=true) as
select v.id,v.pratica_id,v.evento_id,v.messaggio,v.impronta,v.evento_at,v.risolta_at,v.nota,v.operatore,
 p.numero_pratica,p.targa,p.stato_commerciale::text,p.blocco_operatore,
 (exists(select 1 from public.keplero_live_events e where e.pratica_id=p.id and e.created_at>v.evento_at
   and lower(e.payload->>'ultimo_messaggio_cliente') ~ '(annull|revoc|non conferm|non proced|non accett)')
 or exists(select 1 from public.keplero_originali m
   join public.keplero_pratiche_conversazioni c on c.sessione=m.sessione
   where c.pratica_id=p.id and m.direzione='entrata' and m.data_messaggio>v.evento_at
   and (m.revoca or lower(m.testo) ~ '(annull|revoc|non conferm|non proced|non accett)'))
 or coalesce(o.revoca,false)) as possibile_revoca,
 v.originale_sessione,v.originale_messaggio_id,p.blocco_classificazione_operatore,
 coalesce(o.modificato or md5(lower(btrim(o.testo)))<>v.impronta,false) as prova_modificata,
 (v.originale_sessione is not null and
   ((select count(*) from public.keplero_pratiche_conversazioni c where c.sessione=v.originale_sessione)<>1
   or not exists(select 1 from public.keplero_pratiche_conversazioni c
    where c.sessione=v.originale_sessione and c.pratica_id=v.pratica_id))) as collegamento_da_verificare
from public.verifiche_acquisizione_ordini v join public.pratiche p on p.id=v.pratica_id
left join public.keplero_originali o on o.sessione=v.originale_sessione and o.messaggio_id=v.originale_messaggio_id
where v.risolta_at is null and p.tipo_flusso='commerciale'
and p.stato_commerciale not in ('ordine_acquisito','rifiutato','chiuso')
and not exists(select 1 from public.keplero_verifiche_originali k
 where k.sessione=v.originale_sessione and k.messaggio_id=v.originale_messaggio_id
 and k.esito in ('archiviata','preservata') and k.operatore is not null)
and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
revoke all on public.v_verifiche_acquisizione_ordini from public,anon,authenticated;
grant select on public.v_verifiche_acquisizione_ordini to service_role;

do $$ begin
 perform private.accoda_verifica_originale_ordine(m.sessione,m.messaggio_id)
 from public.keplero_originali m
 where m.data_messaggio>=private.inizio_finestra_controllo_keplero(now(),48)
 and m.direzione='entrata' and m.tipo='text';
end $$;

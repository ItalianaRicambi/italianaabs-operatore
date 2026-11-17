-- Coda di verifica, NON riconoscitore di acquisizione automatica.
-- Una domanda logistica in una frase successiva non cancella la scelta precedente.
create function private.conferma_contestuale_da_verificare(t text) returns boolean
language sql immutable set search_path='' as $$
 select lower(coalesce(t,'')) !~ '\m(non|forse|se|qualora|vorrei|vorremmo|confermerei|confermeremmo|annullo|annulliamo|revoco|revochiamo)\M'
 and (private.possibile_ordine_letterale(t) or exists (
   select 1 from regexp_split_to_table(lower(coalesce(t,'')), E'[.!;\\n\\r]+') s
   where s not like '%?%' and (
    private.possibile_ordine_letterale(s)
    or s ~ '^\s*(ok[, ]*|sì[, ]*|si[, ]*)?(facciamo|scelgo|scegliamo|procediamo con)\M.{0,80}\m(originale|lavorazione|riparazione|programma scambio|offerta|preventivo)\M'
   )
  )
 )
$$;
revoke all on function private.conferma_contestuale_da_verificare(text) from public,anon,authenticated;
grant execute on function private.conferma_contestuale_da_verificare(text) to service_role;

create or replace function private.registra_verifica_acquisizione() returns trigger
language plpgsql security definer set search_path='' as $$
declare t text := btrim(new.payload->>'ultimo_messaggio_cliente');
begin
 if new.pratica_id is not null
 and new.created_at>=private.inizio_finestra_controllo_keplero(now(),48)
 and new.created_at<=now()+interval '5 minutes'
 and private.conferma_contestuale_da_verificare(t) then
  insert into public.verifiche_acquisizione_ordini(pratica_id,evento_id,messaggio,impronta,evento_at)
  values(new.pratica_id,new.id,left(t,4000),md5(lower(t)),new.created_at)
  on conflict(pratica_id,impronta) do nothing;
 end if;
 return new;
end $$;

create or replace function private.accoda_verifica_originale_ordine(p_sessione uuid,p_messaggio text)
returns void language plpgsql security definer set search_path='' as $$
declare m public.keplero_originali; pid uuid; t text;
begin
 select * into m from public.keplero_originali
 where sessione=p_sessione and messaggio_id=p_messaggio;
 if m.sessione is null or m.direzione<>'entrata' or m.tipo<>'text'
 or m.data_messaggio<private.inizio_finestra_controllo_keplero(now(),48)
 or m.data_messaggio>now()+interval '5 minutes' then return; end if;
 t:=btrim(m.testo);
 if not private.conferma_contestuale_da_verificare(t) then return; end if;
 if exists(select 1 from public.keplero_verifiche_originali k
  where k.sessione=p_sessione and k.messaggio_id=p_messaggio
  and k.esito in ('archiviata','preservata') and k.operatore is not null) then return; end if;
 select (array_agg(distinct pratica_id))[1] into pid
 from public.keplero_pratiche_conversazioni where sessione=p_sessione
 having count(distinct pratica_id)=1;
 if pid is null then return; end if;
 insert into public.verifiche_acquisizione_ordini
 (pratica_id,messaggio,impronta,evento_at,originale_sessione,originale_messaggio_id)
 values(pid,left(t,4000),md5(lower(t)),m.data_messaggio,m.sessione,m.messaggio_id)
 on conflict(pratica_id,impronta) do update
 set originale_sessione=excluded.originale_sessione,
     originale_messaggio_id=excluded.originale_messaggio_id
 where public.verifiche_acquisizione_ordini.originale_sessione is null;
end $$;

-- Backfill idempotente dei soli messaggi nella finestra autorizzata.
insert into public.verifiche_acquisizione_ordini(pratica_id,evento_id,messaggio,impronta,evento_at)
select distinct on(pratica_id,md5(lower(btrim(payload->>'ultimo_messaggio_cliente'))))
 pratica_id,id,left(btrim(payload->>'ultimo_messaggio_cliente'),4000),
 md5(lower(btrim(payload->>'ultimo_messaggio_cliente'))),created_at
from public.keplero_live_events
where created_at>=private.inizio_finestra_controllo_keplero(now(),48)
and created_at<=now()+interval '5 minutes' and pratica_id is not null
and private.conferma_contestuale_da_verificare(payload->>'ultimo_messaggio_cliente')
order by pratica_id,md5(lower(btrim(payload->>'ultimo_messaggio_cliente'))),id
on conflict(pratica_id,impronta) do nothing;
do $$ begin
 perform private.accoda_verifica_originale_ordine(m.sessione,m.messaggio_id)
 from public.keplero_originali m
 where m.data_messaggio>=private.inizio_finestra_controllo_keplero(now(),48)
 and m.direzione='entrata' and m.tipo='text';
end $$;

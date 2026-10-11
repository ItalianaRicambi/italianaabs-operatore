-- Coda transazionale; nessun recupero/invio delle prenotazioni storiche.
create table public.notifiche_email_logistica (
 id uuid primary key default gen_random_uuid(),
 attivita_id uuid not null references public.attivita_operatore(id) on delete cascade,
 pratica_id uuid not null references public.pratiche(id) on delete cascade,
 tipo text not null default 'presa_prenotata' check(tipo='presa_prenotata'),
 revisione integer not null,
 riferimento text not null,
 data_ritiro date not null,
 destinatario text,
 stato text not null default 'in_attesa' check(stato in ('in_attesa','da_verificare','in_invio','inviata','errore','esito_incerto','annullata')),
 motivo text,
 tentativi integer not null default 0,
 token uuid,
 avviata_at timestamptz,
 inviata_at timestamptz,
 message_id text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(attivita_id,revisione)
);
alter table public.notifiche_email_logistica enable row level security;
revoke all on public.notifiche_email_logistica from public,anon,authenticated;
grant select,insert,update on public.notifiche_email_logistica to service_role;
create index notifiche_email_logistica_pratica on public.notifiche_email_logistica(pratica_id);
create index notifiche_email_logistica_coda on public.notifiche_email_logistica(stato,created_at);

create table private.config_email_logistica (
 id boolean primary key default true check(id),
 abilitata boolean not null default false,
 password_id uuid,
 worker_token_id uuid not null,
 test_at timestamptz,
 test_message_id text,
 operatore text,
 updated_at timestamptz not null default now()
);
revoke all on private.config_email_logistica from public,anon,authenticated,service_role;
insert into private.config_email_logistica(worker_token_id)
values(vault.create_secret(gen_random_uuid()::text||gen_random_uuid()::text,'email_logistica_worker_token','Autorizzazione worker notifiche logistiche'));

create function private.trg_accoda_email_presa()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_revisione integer;
begin
 if tg_op='UPDATE' and row(new.stato,new.tipo,new.pratica_id,new.pratica_origine_id,new.riferimento_ritiro,new.data_ritiro_prevista,new.metadati->>'prenotazione_confermata')
  is not distinct from row(old.stato,old.tipo,old.pratica_id,old.pratica_origine_id,old.riferimento_ritiro,old.data_ritiro_prevista,old.metadati->>'prenotazione_confermata') then return new; end if;
 update public.notifiche_email_logistica set stato='annullata',motivo='Prenotazione modificata o ritiro chiuso.',updated_at=now()
 where attivita_id=new.id and stato in ('in_attesa','da_verificare','errore');
 if new.stato<>'programmata' or new.tipo not in ('ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_programma_scambio')
  or new.pratica_origine_id is null or coalesce(new.metadati->>'prenotazione_confermata','false')<>'true'
  or new.data_ritiro_prevista is null or new.riferimento_ritiro is null then return new; end if;
 select coalesce(max(revisione),0)+1 into v_revisione from public.notifiche_email_logistica where attivita_id=new.id;
 insert into public.notifiche_email_logistica(attivita_id,pratica_id,revisione,riferimento,data_ritiro)
 values(new.id,new.pratica_id,v_revisione,new.riferimento_ritiro,new.data_ritiro_prevista);
 return new;
end; $$;
revoke all on function private.trg_accoda_email_presa() from public,anon,authenticated,service_role;
create trigger accoda_email_presa after insert or update on public.attivita_operatore
for each row execute function private.trg_accoda_email_presa();

create function private.valida_email_presa(p_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare n public.notifiche_email_logistica%rowtype; a public.attivita_operatore%rowtype;
 p public.pratiche%rowtype; c public.clienti%rowtype; e text; ce text;
begin
 select * into n from public.notifiche_email_logistica where id=p_id;
 select * into a from public.attivita_operatore where id=n.attivita_id;
 if a.stato<>'programmata' or a.tipo not in ('ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_programma_scambio')
  or a.pratica_origine_id is null or coalesce(a.metadati->>'prenotazione_confermata','false')<>'true'
  or a.pratica_id is distinct from n.pratica_id or a.riferimento_ritiro is distinct from n.riferimento
  or a.data_ritiro_prevista is distinct from n.data_ritiro then
  return jsonb_build_object('stato','annullata','motivo','Prenotazione non più attuale.'); end if;
 if n.data_ritiro<(now() at time zone 'Europe/Rome')::date then return jsonb_build_object('stato','da_verificare','motivo','Data ritiro trascorsa.'); end if;
 if n.riferimento!~'^P3[ -]?[0-9]{6,15}$' then return jsonb_build_object('stato','da_verificare','motivo','Codice P3 incompleto o non riconosciuto.'); end if;
 select * into p from public.pratiche where id=n.pratica_id;
 if coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then
  return jsonb_build_object('stato','annullata','motivo','Pratica archiviata o duplicata.'); end if;
 if p.cliente_id is not null then
  select * into c from public.clienti where id=p.cliente_id;
  if coalesce(c.da_verificare,false) or coalesce(c.possibile_duplicato,false) then
   return jsonb_build_object('stato','da_verificare','motivo','Anagrafica cliente da verificare.'); end if;
 end if;
 e:=nullif(lower(trim(p.email_cliente)),''); ce:=nullif(lower(trim(c.email)),'');
 if e is not null and ce is not null and e<>ce then return jsonb_build_object('stato','da_verificare','motivo','Email della pratica diversa dall’anagrafica.'); end if;
 e:=coalesce(e,ce);
 if e is null or length(e)>254 or e!~'^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
  or e in ('info@italianaabs.com','spedizioni@italianaabs.com') then
  return jsonb_build_object('stato','da_verificare','motivo','Email cliente mancante o non valida.'); end if;
 return jsonb_build_object('stato','in_attesa','destinatario',e);
end; $$;
revoke all on function private.valida_email_presa(uuid) from public,anon,authenticated;
grant execute on function private.valida_email_presa(uuid) to service_role;

create function public.prendi_email_logistica(p_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.notifiche_email_logistica%rowtype; candidato record; v jsonb;
begin
 update public.notifiche_email_logistica set stato='esito_incerto',motivo='Worker interrotto: verificare il messaggio prima di riprovare.',updated_at=now()
 where stato='in_invio' and avviata_at<now()-interval '10 minutes' and (p_id is null or id=p_id);
 if not exists(select 1 from private.config_email_logistica where abilitata and password_id is not null) then return null; end if;
 for candidato in select id,attivita_id from public.notifiche_email_logistica where stato='in_attesa' and (p_id is null or id=p_id) order by created_at,id limit 50 loop
  -- Stesso ordine di lock del trigger: attività, poi coda.
  perform 1 from public.attivita_operatore where id=candidato.attivita_id for update skip locked;
  if not found then continue; end if;
  select * into n from public.notifiche_email_logistica where id=candidato.id and stato='in_attesa' for update skip locked;
  if not found then continue; end if;
  v:=private.valida_email_presa(n.id);
  if exists(select 1 from public.notifiche_email_logistica where attivita_id=n.attivita_id and id<>n.id and stato in ('in_invio','esito_incerto')) then
   v:=jsonb_build_object('stato','da_verificare','motivo','Un avviso precedente ha un invio in corso o un esito incerto. Verificarlo prima di inviare la correzione.');
  end if;
  if v->>'stato'<>'in_attesa' then
   update public.notifiche_email_logistica set stato=v->>'stato',motivo=v->>'motivo',updated_at=now() where id=n.id;
   continue;
  end if;
  update public.notifiche_email_logistica set stato='in_invio',destinatario=v->>'destinatario',token=gen_random_uuid(),
   tentativi=tentativi+1,avviata_at=now(),motivo=null,message_id='<'||id||'@italianaabs.com>',updated_at=now() where id=n.id returning * into n;
  return jsonb_build_object('id',n.id,'token',n.token,'destinatario',n.destinatario,'riferimento',n.riferimento,'data_ritiro',n.data_ritiro,'revisione',n.revisione);
 end loop;
 return null;
end; $$;

create function public.esito_email_logistica(p_id uuid,p_token uuid,p_stato text,p_motivo text default null)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if p_stato not in ('inviata','errore','esito_incerto') then raise exception 'Esito non valido'; end if;
 update public.notifiche_email_logistica set stato=p_stato,motivo=left(p_motivo,500),
  inviata_at=case when p_stato='inviata' then now() else null end,updated_at=now()
 where id=p_id and token=p_token and stato in ('in_invio','esito_incerto');
 return found;
end; $$;

create function public.rivaluta_email_logistica(p_id uuid,p_operatore text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.notifiche_email_logistica%rowtype; v jsonb; aid uuid;
begin
 if nullif(p_operatore,'') is null then raise exception 'Operatore richiesto'; end if;
 select attivita_id into aid from public.notifiche_email_logistica where id=p_id;
 perform 1 from public.attivita_operatore where id=aid for update;
 select * into n from public.notifiche_email_logistica where id=p_id for update;
 if n.stato not in ('da_verificare','errore') then raise exception 'Invio non ripetibile: verificare lo storico.'; end if;
 v:=private.valida_email_presa(p_id);
 update public.notifiche_email_logistica set stato=v->>'stato',motivo=v->>'motivo',updated_at=now() where id=p_id;
 insert into public.azioni_operatore(pratica_id,azione,nota,operatore)
 values(n.pratica_id,'rivaluta_email_logistica','Avviso '||n.id||': '||coalesce(v->>'motivo','Rimesso in coda'),p_operatore);
 return v;
end; $$;

-- La password è leggibile solo dal backend e non torna mai all’interfaccia.
create function public.risolvi_email_logistica(p_id uuid,p_esito text,p_evidenza text,p_operatore text)
returns void language plpgsql security invoker set search_path='' as $$
declare n public.notifiche_email_logistica%rowtype;
begin
 if p_esito not in ('inviata','errore') or length(trim(p_evidenza)) not between 20 and 2000 or nullif(p_operatore,'') is null then raise exception 'Esito e prova della verifica richiesti'; end if;
 select * into n from public.notifiche_email_logistica where id=p_id for update;
 if n.stato<>'esito_incerto' then raise exception 'Avviso non in attesa di verifica'; end if;
 update public.notifiche_email_logistica set stato=p_esito,motivo='Esito verificato dall’operatore: '||left(p_evidenza,450),
  token=null,inviata_at=case when p_esito='inviata' then now() else null end,updated_at=now() where id=p_id;
 insert into public.azioni_operatore(pratica_id,azione,nota,operatore)
 values(n.pratica_id,'risolvi_esito_email_logistica','Avviso '||n.id||' / '||p_esito||': '||p_evidenza,p_operatore);
end; $$;

create function public.configurazione_email_logistica(p_segreti boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c private.config_email_logistica%rowtype; v jsonb;
begin
 select * into c from private.config_email_logistica where id;
 v:=jsonb_build_object('abilitata',c.abilitata,'configurata',c.password_id is not null,'test_at',c.test_at,'test_message_id',c.test_message_id);
 if p_segreti then v:=v||jsonb_build_object('password',(select decrypted_secret from vault.decrypted_secrets where id=c.password_id)); end if;
 return v;
end; $$;

create function public.salva_smtp_logistica(p_password text,p_message_id text,p_operatore text)
returns void language plpgsql security definer set search_path='' as $$
declare c private.config_email_logistica%rowtype; sid uuid;
begin
 if length(p_password) not between 1 and 1000 or nullif(p_message_id,'') is null or nullif(p_operatore,'') is null then raise exception 'Configurazione incompleta'; end if;
 select * into c from private.config_email_logistica where id for update;
 if c.password_id is null then sid:=vault.create_secret(p_password,'email_logistica_smtp','Password spedizioni@italianaabs.com');
 else sid:=c.password_id; perform vault.update_secret(sid,p_password); end if;
 update private.config_email_logistica set password_id=sid,abilitata=false,test_at=now(),test_message_id=p_message_id,operatore=p_operatore,updated_at=now() where id;
end; $$;

create function public.abilita_email_logistica(p_abilitata boolean,p_operatore text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if nullif(p_operatore,'') is null then raise exception 'Operatore richiesto'; end if;
 if p_abilitata and not exists(select 1 from private.config_email_logistica where password_id is not null and test_at>now()-interval '7 days') then raise exception 'Collaudo SMTP richiesto'; end if;
 update private.config_email_logistica set abilitata=p_abilitata,operatore=p_operatore,updated_at=now() where id;
end; $$;

create function public.autorizza_worker_email_logistica(p_token text)
returns boolean language sql security definer set search_path='' as $$
 select coalesce(length(p_token)>=64 and p_token=(select s.decrypted_secret from private.config_email_logistica c join vault.decrypted_secrets s on s.id=c.worker_token_id where c.id),false);
$$;

-- Restrizioni anche per le funzioni SECURITY DEFINER che accedono al Vault.
do $$ declare f text; begin
 foreach f in array array['prendi_email_logistica(uuid)','esito_email_logistica(uuid,uuid,text,text)','rivaluta_email_logistica(uuid,text)',
  'risolvi_email_logistica(uuid,text,text,text)','configurazione_email_logistica(boolean)','salva_smtp_logistica(text,text,text)','abilita_email_logistica(boolean,text)','autorizza_worker_email_logistica(text)'] loop
  execute 'revoke all on function public.'||f||' from public,anon,authenticated';
  execute 'grant execute on function public.'||f||' to service_role';
 end loop;
end $$;

create extension if not exists pg_net with schema extensions;
create function private.avvia_worker_email_logistica()
returns void language plpgsql security definer set search_path='' as $$
declare t text;
begin
 if not exists(select 1 from private.config_email_logistica where abilitata) then return; end if;
 select s.decrypted_secret into t from private.config_email_logistica c join vault.decrypted_secrets s on s.id=c.worker_token_id where c.id;
 perform net.http_post(url:='https://italianaabs-operatore.vercel.app/api/logistica/email',
  headers:=jsonb_build_object('Authorization','Bearer '||t,'Content-Type','application/json'),body:='{}'::jsonb,timeout_milliseconds:=55000);
end; $$;
revoke all on function private.avvia_worker_email_logistica() from public,anon,authenticated,service_role;
select cron.schedule('invio-email-logistica','*/5 * * * *','select private.avvia_worker_email_logistica()');
notify pgrst,'reload schema';

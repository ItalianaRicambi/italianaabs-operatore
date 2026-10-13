create table public.richieste_email (
 id uuid primary key default gen_random_uuid(), fingerprint text not null unique check (fingerprint ~ '^[a-f0-9]{64}$'),
 mailbox text not null check (mailbox='info@italianaabs.com'), sender text not null,
 subject text not null, content text not null, conversation_id uuid not null,
 stato text not null default 'in_elaborazione' check (stato in ('in_elaborazione','errore','registrata','da_classificare','esclusa','gestita')),
 motivo text, pratica_id uuid references public.pratiche(id) on delete set null,
 token uuid, lease_at timestamptz, consegne integer not null default 1,
 allegati_da_verificare boolean not null default false,
 gestita_da text, gestita_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.richieste_email enable row level security;
revoke all on public.richieste_email from public,anon,authenticated;
grant select,insert,update on public.richieste_email to service_role;
create index richieste_email_created_idx on public.richieste_email(created_at desc);
create index richieste_email_stato_idx on public.richieste_email(stato,created_at desc);

create function public.registra_richiesta_email(p_dati jsonb) returns jsonb
language plpgsql security invoker set search_path=public,pg_temp as $$
declare r public.richieste_email; acquisita boolean:=false;
begin
 if p_dati->>'mailbox' is distinct from 'info@italianaabs.com'
   or coalesce(p_dati->>'sender','') !~ '^[^[:space:]<>@]+@[^[:space:]<>@]+[.][^[:space:]<>@]+$'
   or length(coalesce(p_dati->>'content',''))>250000
   or length(coalesce(p_dati->>'subject',''))>2000 then raise exception 'Dati email non validi'; end if;
 insert into public.richieste_email(fingerprint,mailbox,sender,subject,content,conversation_id,token,lease_at)
 values(p_dati->>'fingerprint',p_dati->>'mailbox',p_dati->>'sender',p_dati->>'subject',p_dati->>'content',(p_dati->>'conversation_id')::uuid,gen_random_uuid(),now())
 on conflict(fingerprint) do update set consegne=richieste_email.consegne+1,updated_at=now()
 returning * into r;
 if r.consegne=1 then acquisita:=true;
 elsif r.stato='errore' or (r.stato='in_elaborazione' and r.lease_at<now()-interval '2 minutes') then
  update public.richieste_email set stato='in_elaborazione',token=gen_random_uuid(),lease_at=now(),updated_at=now() where id=r.id returning * into r;
  acquisita:=true;
 end if;
 return to_jsonb(r)-'token'||jsonb_build_object('token',case when acquisita then r.token else null end);
end $$;

create function public.esito_richiesta_email(p_id uuid,p_token uuid,p_stato text,p_pratica_id uuid,p_motivo text,p_allegati_da_verificare boolean) returns boolean
language plpgsql security invoker set search_path=public,pg_temp as $$
declare r public.richieste_email;
begin
 if p_stato not in ('errore','registrata','da_classificare','esclusa') then raise exception 'Esito non valido'; end if;
 update public.richieste_email set stato=p_stato,pratica_id=p_pratica_id,motivo=left(p_motivo,2000),allegati_da_verificare=p_allegati_da_verificare,token=null,lease_at=null,updated_at=now()
 where id=p_id and token=p_token and stato='in_elaborazione' returning * into r;
 if not found then return false; end if;
 if p_pratica_id is not null then
  update public.pratiche set email_cliente=r.sender
  where id=p_pratica_id and email_cliente is null
    and not coalesce(blocco_operatore,false)
    and not ('email_cliente'=any(coalesce(campi_bloccati_operatore,'{}'::text[])));
 end if;
 return true;
end $$;

create function public.gestisci_richiesta_email(p_id uuid,p_operatore text) returns boolean
language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') then raise exception 'Operatore non valido'; end if;
 update public.richieste_email set stato='gestita',gestita_da=p_operatore,gestita_at=now(),updated_at=now()
 where id=p_id and stato in ('registrata','da_classificare'); return found;
end $$;

create function public.stato_richieste_email() returns jsonb
language sql stable security invoker set search_path=public,pg_temp as $$
 select jsonb_build_object('ricevute',count(*),'da_classificare',count(*) filter(where stato='da_classificare'),
  'errori',count(*) filter(where stato='errore' or (stato='in_elaborazione' and lease_at<now()-interval '2 minutes')),
  'ultima_ricezione',max(created_at),'allegati_da_verificare',count(*) filter(where allegati_da_verificare and stato<>'gestita')) from public.richieste_email
$$;
revoke execute on function public.registra_richiesta_email(jsonb),public.esito_richiesta_email(uuid,uuid,text,uuid,text,boolean),public.gestisci_richiesta_email(uuid,text),public.stato_richieste_email() from public,anon,authenticated;
grant execute on function public.registra_richiesta_email(jsonb),public.esito_richiesta_email(uuid,uuid,text,uuid,text,boolean),public.gestisci_richiesta_email(uuid,text),public.stato_richieste_email() to service_role;

-- Il worker usa il ciclo di recupero originali già autenticato e schedulato.
-- Questa migrazione non modifica l'abilitazione o il cutover.
create table public.followup_dati_controlli (
 pratica_id uuid primary key references public.pratiche(id) on delete cascade,
 controllata_at timestamptz not null
);
alter table public.followup_dati_controlli enable row level security;
revoke all on public.followup_dati_controlli from public,anon,authenticated;
grant select,insert,update on public.followup_dati_controlli to service_role;

create function public.followup_dati_lotto()
returns uuid[] language sql security invoker set search_path='' as $$
 with candidati as (
  select p.id
  from public.followup_dati_config cfg
  join public.pratiche p on p.tipo_flusso='commerciale'
  join public.keplero_sessioni_originali s on p.keplero_conversation_id=s.sessione::text
  left join public.followup_dati_controlli c on c.pratica_id=p.id
  where cfg.id and cfg.enabled and cfg.transport_verified and cfg.accept_requests_after is not null
   and not p.blocco_operatore and not p.blocco_classificazione_operatore
   and coalesce(cardinality(p.campi_bloccati_operatore),0)=0
   and (
    (p.stato_commerciale in ('nuova','raccolta_dati','richiesta_verifica') and p.stato_completezza='dati_mancanti')
    or (p.stato_commerciale='ordine_acquisito' and p.stato_fatturazione='da_fatturare' and p.stato_amministrativo='dati_mancanti')
   )
   and exists(select 1 from public.keplero_originali m where m.sessione=s.sessione
    and m.direzione='uscita' and m.tipo='text' and not m.modificato
    and m.data_messaggio>=cfg.accept_requests_after
    and m.data_messaggio<=now()-interval '24 hours'
    and (m.testo like 'Per preparare il preventivo ci servono ancora: %'
     or m.testo=p.messaggio_richiesta_amministrativa))
   and not exists(select 1 from public.followup_dati_invii i where i.pratica_id=p.id
    and i.fase=case when p.stato_commerciale='ordine_acquisito' then 'fatturazione' else 'preventivo' end
    and (i.stato='cancelled' or i.attivita_id is not null
     or (i.stato in ('claimed','ambiguous') and (i.tentativo_at is null or i.tentativo_at<now()-interval '3 days'))))
   and (c.controllata_at is null or c.controllata_at<now()-interval '4 minutes')
  order by c.controllata_at nulls first,p.id
  limit 2 for update of p skip locked
 ), aggiornati as (
  insert into public.followup_dati_controlli(pratica_id,controllata_at)
  select id,now() from candidati
  on conflict(pratica_id) do update set controllata_at=excluded.controllata_at
  returning pratica_id
 )
 select coalesce(array_agg(pratica_id),'{}'::uuid[]) from aggiornati;
$$;

-- Le attestazioni derivano dal database e dal webhook WhatsApp autenticato.
-- Un episodio ambiguo o un numero non riconducibile al webhook viene escluso.
create function public.followup_dati_contesto(p_pratica uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
 p public.pratiche%rowtype;
 k public.keplero_sessioni_originali%rowtype;
 i public.followup_dati_invii%rowtype;
 e jsonb;
 fase_corrente text;
 telefono text;
 telefono_evento text;
 fiscale jsonb;
 fiscale_ok boolean:=false;
begin
 select * into p from public.pratiche where id=p_pratica;
 if not found or p.tipo_flusso is distinct from 'commerciale'
  or p.blocco_operatore or p.blocco_classificazione_operatore or coalesce(cardinality(p.campi_bloccati_operatore),0)>0
  or p.stato_commerciale in ('rifiutato','chiuso','perso') or p.stato_fatturazione='fatturato' or p.data_fattura is not null
  or p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='true'
  or p.dati_raw#>>'{archiviazione_test,archiviata}'='true'
  or p.dati_raw#>>'{pratica_duplicata,archiviata}'='true'
  or exists(select 1 from public.documenti_amministrativi d where d.pratica_id=p.id and d.tipo_documento in ('fattura','proforma'))
 then return null;end if;
 select * into k from public.keplero_sessioni_originali where sessione::text=p.keplero_conversation_id;
 if not found or k.assistente is null or k.errore is not null
  or exists(select 1 from public.keplero_pratiche_conversazioni where sessione=k.sessione and pratica_id<>p.id)
 then return null;end if;
 select payload into e from public.keplero_live_events
 where pratica_id=p.id and (external_key='conversation:'||k.sessione::text
  or external_key like 'conversation:'||k.sessione::text||':veicolo:%')
 order by created_at desc,id desc limit 1;
 if lower(coalesce(e->>'channel',e->>'canale',''))<>'whatsapp'
  or coalesce(e->>'is_group',e->>'gruppo','false')='true'
  or e#>>'{decisione_sistema,blocco_contatto_operativo}'='true'
 then return null;end if;
 telefono:=public.normalizza_telefono_cliente(p.telefono);
 telefono_evento:=public.normalizza_telefono_cliente(coalesce(e->>'telefono',e->>'phone',e->>'whatsapp'));
 -- Il flusso automatico pilota usa numeri mobili italiani riscontrati in entrambe le fonti.
 if telefono is null or telefono !~ '^3[0-9]{9}$' or telefono is distinct from telefono_evento
  or exists(select 1 from public.contatti_operativi where telefono_normalizzato='39'||telefono and attivo and blocca_automazioni_commerciali)
 then return null;end if;

 if p.stato_commerciale='ordine_acquisito' and p.stato_fatturazione='da_fatturare' and p.stato_amministrativo='dati_mancanti' then
  fase_corrente:='fatturazione';
  fiscale:=private.verifica_dati_cliente_fatturazione(p.cliente_id);
  if coalesce(fiscale->>'completi','true')<>'false'
   or exists(select 1 from public.clienti c where c.id=p.cliente_id and (c.da_verificare or c.possibile_duplicato))
  then return null;end if;
  fiscale_ok:=coalesce(p.dati_raw#>>'{fic_anagrafica,stato}' in ('nuovo','riconosciuto')
   and p.dati_raw#>>'{fic_anagrafica,firma}'=md5(jsonb_build_array(p.dati_raw->'anagrafica_estratta',p.email_cliente,p.telefono,p.cliente_id)::text)
   and (p.dati_raw#>>'{fic_anagrafica,verificato_at}')::timestamptz between now()-interval '1 hour' and now(),false);
  if not fiscale_ok then return null;end if;
 elsif p.stato_commerciale in ('nuova','raccolta_dati','richiesta_verifica') and p.stato_completezza='dati_mancanti'
  and p.preventivo_inviato_at is null and not exists(select 1 from public.preventivi where pratica_id=p.id) then
  fase_corrente:='preventivo';
 else return null;
 end if;

 select * into i from public.followup_dati_invii a where a.pratica_id=p.id and a.fase=fase_corrente;
 return jsonb_build_object(
  'id',p.id,'practiceNumber',p.numero_pratica,'session',k.sessione,'assistant',k.assistente,
  'to','+39'||telefono,'phase',fase_corrente,'updatedAt',p.updated_at,'commercialState',p.stato_commerciale,
  'completeness',p.stato_completezza,'note',p.nota_incompletezza,'fiscalText',p.messaggio_richiesta_amministrativa,
  'fiscalFields',p.campi_richiesta_amministrativa,'missingFiscal',fiscale->'campi','fiscalChecked',fiscale_ok,
  'quoteHashes',(select coalesce(jsonb_agg(distinct d.sha256_pdf),'[]'::jsonb)
    from public.documenti_preventivo_auto d where d.pratica_id=p.id and d.stato='inviato' and d.sha256_pdf is not null),
  'ledger',jsonb_build_object('state',coalesce(i.stato,'none'),'sentAt',i.inviata_at,'messageId',i.provider_message_id),
  'storedAttempt',case when i.stato in ('claimed','ambiguous') and i.tentativo_at>=now()-interval '3 days'
   then jsonb_build_object('claim',i.claim,'attempt',i.tentativo) end
 );
end; $$;

create table public.followup_dati_formulazioni (
 pratica_id uuid not null references public.pratiche(id) on delete cascade,
 fase text not null check(fase in ('preventivo','fatturazione')),
 testo text not null check(length(testo) between 1 and 1000),
 proposta_at timestamptz not null default now(),
 primary key(pratica_id,fase,testo)
);
alter table public.followup_dati_formulazioni enable row level security;
revoke all on public.followup_dati_formulazioni from public,anon,authenticated;
grant select,insert on public.followup_dati_formulazioni to service_role;

-- Suggerisce la formulazione esatta una sola volta per la stessa richiesta.
-- La registrazione dell'invio avviene solo in seguito, dall'originale consegnato.
create function public.followup_dati_proponi(p_pratica uuid,p_sessione uuid,p_fase text,p_testo text)
returns boolean language plpgsql security invoker set search_path='' as $$
declare p public.pratiche%rowtype;
begin
 if not exists(select 1 from public.followup_dati_config where id and enabled and transport_verified and accept_requests_after is not null)
  or p_testo is null or length(p_testo) not between 1 and 1000
  or p_fase is null or p_fase not in ('preventivo','fatturazione') then return false;end if;
 select * into p from public.pratiche where id=p_pratica;
 if not found or p.keplero_conversation_id is distinct from p_sessione::text or p.tipo_flusso is distinct from 'commerciale'
  or p.blocco_operatore or p.blocco_classificazione_operatore or coalesce(cardinality(p.campi_bloccati_operatore),0)>0
  or p.stato_fatturazione='fatturato' or p.data_fattura is not null
  or p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='true'
  or exists(select 1 from public.keplero_pratiche_conversazioni where sessione=p_sessione and pratica_id<>p.id)
  or exists(select 1 from public.documenti_amministrativi d where d.pratica_id=p.id and d.tipo_documento in ('fattura','proforma'))
 then return false;end if;
 if p_fase='preventivo' and (p.stato_completezza is distinct from 'dati_mancanti'
  or p.stato_commerciale not in ('nuova','raccolta_dati','richiesta_verifica') or p.preventivo_inviato_at is not null
  or p_testo not like 'Per preparare il preventivo ci servono ancora: %'
  or exists(select 1 from public.preventivi where pratica_id=p.id)) then return false;end if;
 if p_fase='fatturazione' and (p.stato_commerciale is distinct from 'ordine_acquisito'
  or p.stato_fatturazione is distinct from 'da_fatturare' or p.stato_amministrativo is distinct from 'dati_mancanti'
  or p_testo is distinct from p.messaggio_richiesta_amministrativa) then return false;end if;
 insert into public.followup_dati_formulazioni(pratica_id,fase,testo) values(p.id,p_fase,p_testo) on conflict do nothing;
 return found;
end; $$;

revoke all on function public.followup_dati_lotto(),public.followup_dati_contesto(uuid),public.followup_dati_proponi(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.followup_dati_lotto(),public.followup_dati_contesto(uuid),public.followup_dati_proponi(uuid,uuid,text,text) to service_role;
notify pgrst,'reload schema';

-- Registro tecnico per un collaudo dei soli due modelli sul numero interno.
-- Le prove sono predisposte dall'amministratore, mai dai webhook cliente.
create table public.followup_dati_collaudo (
 fase text primary key check(fase in ('preventivo','fatturazione')),
 sessione uuid not null,
 telefono text not null check(telefono ~ '^\+[1-9][0-9]{7,14}$'),
 scadenza timestamptz not null,
 tentativo jsonb,
 esito text not null default 'pronto' check(esito in ('pronto','in_corso','confermato','incerto','rifiutato')),
 conferma jsonb
);
alter table public.followup_dati_collaudo enable row level security;
revoke all on public.followup_dati_collaudo from public,anon,authenticated;
grant select,update on public.followup_dati_collaudo to service_role;

-- Le funzioni del worker collegano prova live, destinatario e guardie del registro.
create function public.followup_dati_registra_worker(
 p_pratica uuid,p_fase text,p_sessione uuid,p_messaggio text,p_campi text[],p_impronta text
) returns uuid language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio
   and impronta=p_impronta and not modificato) then return null;end if;
 return public.registra_richiesta_followup_dati(p_pratica,p_fase,p_sessione,p_messaggio,p_campi);
end; $$;

create function public.followup_dati_inizia_worker(
 p_claim uuid,p_pratica_updated_at timestamptz,p_verificata_at timestamptz,p_impronta text,p_campi text[],p_tentativo jsonb,p_rinvio jsonb
) returns boolean language plpgsql security invoker set search_path='' as $$
declare p_id uuid; c jsonb;
begin
 select pratica_id into p_id from public.followup_dati_invii where claim=p_claim;
 if not found then return false;end if;
 perform 1 from public.pratiche where id=p_id for update;
 if not found then return false;end if;
 c:=public.followup_dati_contesto(p_id);
 if c is null or c->>'to' is distinct from p_tentativo->>'to'
  or c->>'session' is distinct from p_tentativo->>'session'
  or c->>'phase' is distinct from p_tentativo->>'phase' then return false;end if;
 return public.inizia_invio_followup_dati(p_claim,p_pratica_updated_at,p_verificata_at,p_impronta,p_campi,p_tentativo,p_rinvio);
end; $$;
revoke all on function public.followup_dati_registra_worker(uuid,text,uuid,text,text[],text),
 public.followup_dati_inizia_worker(uuid,timestamptz,timestamptz,text,text[],jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.followup_dati_registra_worker(uuid,text,uuid,text,text[],text),
 public.followup_dati_inizia_worker(uuid,timestamptz,timestamptz,text,text[],jsonb,jsonb) to service_role;
notify pgrst,'reload schema';

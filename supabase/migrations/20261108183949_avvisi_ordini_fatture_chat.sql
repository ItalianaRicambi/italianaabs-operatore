set local lock_timeout='3s';
set local statement_timeout='30s';

create table public.fic_controlli_pdf_chat (
 sessione uuid not null, messaggio_id text not null,
 esito text not null default 'pendente' check(esito in ('pendente','non_fattura','non_riconosciuto','fatturata')),
 ultimo_tentativo_at timestamptz not null default now(),
 primary key(sessione,messaggio_id),
 foreign key(sessione,messaggio_id) references public.keplero_originali(sessione,messaggio_id)
);
alter table public.fic_controlli_pdf_chat enable row level security;
revoke all on public.fic_controlli_pdf_chat from public,anon,authenticated;
grant select,insert,update on public.fic_controlli_pdf_chat to service_role;

create function public.fic_documenti_chat_da_controllare()
returns jsonb language plpgsql security invoker set search_path='' as $$
declare ids jsonb; risultato jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('sessione',m.sessione,'id',m.messaggio_id)),'[]') into ids from (
  select k.sessione,k.messaggio_id from public.keplero_originali k
  left join public.fic_controlli_pdf_chat c using(sessione,messaggio_id)
  where k.direzione='uscita' and k.tipo='file' and not k.modificato and k.testo~*'\.pdf$'
   and k.data_messaggio>now()-interval '30 days'
   and (c.sessione is null or (c.esito='pendente' and c.ultimo_tentativo_at<now()-interval '30 minutes'))
  order by c.ultimo_tentativo_at nulls first,k.data_messaggio desc,k.sessione,k.messaggio_id limit 2
 ) m;
 insert into public.fic_controlli_pdf_chat(sessione,messaggio_id)
 select (x->>'sessione')::uuid,x->>'id' from jsonb_array_elements(ids) x
 on conflict(sessione,messaggio_id) do update set ultimo_tentativo_at=now();
 select coalesce(jsonb_agg(jsonb_build_object('sessione',k.sessione,'id',k.messaggio_id,'data',k.data_messaggio,
  'direzione',k.direzione,'tipo',k.tipo,'testo',k.testo,'originale',k.originale,'sha256_pdf',k.sha256_pdf)),'[]') into risultato
 from public.keplero_originali k join jsonb_array_elements(ids) x on k.sessione=(x->>'sessione')::uuid and k.messaggio_id=x->>'id';
 return risultato;
end; $$;

create function public.fic_esito_controllo_pdf(p_sessione uuid,p_messaggio text,p_esito text)
returns void language sql security invoker set search_path='' as $$
 update public.fic_controlli_pdf_chat set esito=p_esito,ultimo_tentativo_at=now() where sessione=p_sessione and messaggio_id=p_messaggio;
$$;
revoke all on function public.fic_documenti_chat_da_controllare(),public.fic_esito_controllo_pdf(uuid,text,text) from public,anon,authenticated;
grant execute on function public.fic_documenti_chat_da_controllare(),public.fic_esito_controllo_pdf(uuid,text,text) to service_role;

create or replace function public.fic_ordini_da_controllare()
returns jsonb language sql security invoker set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
  select p.id,coalesce(nullif(p.dati_raw#>>'{anagrafica_estratta,partita_iva}',''),c.partita_iva) as partita_iva,
   coalesce(nullif(p.dati_raw#>>'{anagrafica_estratta,codice_fiscale}',''),c.codice_fiscale) as codice_fiscale,
   coalesce(p.email_cliente,c.email) as email,coalesce(p.telefono,c.telefono) as telefono
  from public.pratiche p left join public.clienti c on c.id=p.cliente_id
  where p.tipo_flusso='commerciale' and p.stato_commerciale='ordine_acquisito' and p.stato_fatturazione='da_fatturare'
   and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
   and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
   and (p.dati_raw#>>'{fic_anagrafica,verificato_at}' is null
     or (p.dati_raw#>>'{fic_anagrafica,verificato_at}')::timestamptz<now()-interval '1 hour')
  order by p.dati_raw#>>'{fic_anagrafica,verificato_at}' nulls first,p.ordine_acquisito_at desc nulls last,p.id limit 2
 ) x;
$$;

create or replace function public.fic_registra_controllo_cliente(p_pratica uuid,p_clienti jsonb,p_esito text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.pratiche%rowtype; c jsonb; cid uuid; ids uuid[]; imp uuid; iva text; cf text; stato text:=p_esito; completo boolean;
begin
 if p_esito is null or p_clienti is null or p_esito not in ('riconosciuto','ambiguo','nuovo','identita_mancante','errore') or jsonb_typeof(p_clienti)<>'array'
 or jsonb_array_length(p_clienti)>10 then raise exception 'Riscontro cliente non valido';end if;
 select * into p from public.pratiche where id=p_pratica for update;
 if not found or p.stato_commerciale<>'ordine_acquisito' or p.stato_fatturazione<>'da_fatturare' then return jsonb_build_object('esito','non_applicabile');end if;
 if p_esito='riconosciuto' then
  if jsonb_array_length(p_clienti)<>1 then raise exception 'Cliente non univoco';end if;
  c:=p_clienti->0;
  if coalesce(c->>'id','')!~'^[1-9][0-9]*$' or nullif(btrim(c->>'name'),'') is null then raise exception 'Cliente FIC non valido';end if;
  iva:=regexp_replace(upper(regexp_replace(coalesce(c->>'vat_number',''),'[^A-Za-z0-9]','','g')),'^IT(?=[0-9]{11}$)','');
  cf:=upper(regexp_replace(coalesce(c->>'tax_code',''),'[^A-Za-z0-9]','','g'));
  perform pg_advisory_xact_lock(hashtextextended('fic_cliente:'||coalesce(nullif(iva,''),cf),0));
  select array_agg(id) into ids from public.clienti where (iva<>'' and partita_iva_normalizzata=iva) or (cf<>'' and codice_fiscale_normalizzato=cf);
  if cardinality(ids)>1 or (iva='' and cf='') then stato:='ambiguo';
  elsif p.blocco_operatore or p.blocco_classificazione_operatore then stato:='ambiguo';
  elsif p.cliente_id is not null and (cardinality(ids) is distinct from 1 or ids[1]<>p.cliente_id) then stato:='ambiguo';
  else
   cid:=ids[1];
   if cid is null then
    insert into public.clienti_importazioni(fonte,nome_file,file_sha256,righe_origine,righe_inserite,stato,completed_at)
    values('fatture_in_cloud','API verifica ordine',encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex'),1,1,'completata',now()) returning id into imp;
    completo:=nullif(btrim(c->>'address_street'),'') is not null and nullif(btrim(c->>'address_city'),'') is not null and nullif(btrim(c->>'address_postal_code'),'') is not null;
    insert into public.clienti(fonte,external_id,source_record_key,denominazione,indirizzo_fatturazione,comune,cap,provincia,paese,email,telefono,partita_iva,codice_fiscale,pec,codice_sdi,
      partita_iva_normalizzata,codice_fiscale_normalizzato,email_normalizzata,telefono_normalizzato,dati_fiscali_completi,source_fingerprint,source_row_number,importazione_id)
    values('fatture_in_cloud',c->>'id','api:'||(c->>'id'),c->>'name',c->>'address_street',c->>'address_city',c->>'address_postal_code',c->>'address_province',
      case upper(c->>'country') when 'ITALIA' then 'IT' when 'ITALY' then 'IT' when 'SVIZZERA' then 'CH' else c->>'country' end,
      c->>'email',c->>'phone',nullif(iva,''),nullif(cf,''),c->>'certified_email',c->>'ei_code',iva,cf,
      coalesce(public.normalizza_email_cliente(c->>'email'),''),coalesce(public.normalizza_telefono_cliente(c->>'phone'),''),completo,
      encode(sha256(convert_to(c::text,'UTF8')),'hex'),2,imp) returning id into cid;
   end if;
   if exists(select 1 from public.clienti where id=cid and (da_verificare or possibile_duplicato
     or (iva<>'' and partita_iva_normalizzata<>'' and partita_iva_normalizzata<>iva)
     or (cf<>'' and codice_fiscale_normalizzato<>'' and codice_fiscale_normalizzato<>cf))) then stato:='ambiguo';
   else
    -- Integra solo campi vuoti; i valori già presenti restano protetti.
    update public.clienti set
      indirizzo_fatturazione=coalesce(nullif(btrim(indirizzo_fatturazione),''),c->>'address_street'),
      cap=coalesce(nullif(btrim(cap),''),c->>'address_postal_code'),
      comune=coalesce(nullif(btrim(comune),''),c->>'address_city'),
      provincia=coalesce(nullif(btrim(provincia),''),c->>'address_province'),
      email=coalesce(nullif(btrim(email),''),c->>'email'),
      pec=coalesce(nullif(btrim(pec),''),c->>'certified_email'),
      codice_sdi=coalesce(nullif(btrim(codice_sdi),''),c->>'ei_code')
    where id=cid;
    -- Non rimuove segnalazioni o campi da verificare impostati nell'anagrafica.
    update public.clienti set dati_fiscali_completi=true where id=cid
      and not da_verificare and not possibile_duplicato and cardinality(campi_amministrativi_mancanti)=0
      and nullif(btrim(indirizzo_fatturazione),'') is not null and nullif(btrim(cap),'') is not null
      and nullif(btrim(comune),'') is not null and (nullif(partita_iva,'') is not null or nullif(codice_fiscale,'') is not null);
    update public.pratiche set cliente_id=cid,fonte_collegamento_cliente=case when fonte_collegamento_cliente='operatore' then fonte_collegamento_cliente else 'automatico' end,
      cliente_collegato_at=coalesce(cliente_collegato_at,now()) where id=p.id;
    update public.pratiche set stato_amministrativo='cliente_riconosciuto',stato_amministrativo_at=now() where id=p.id;
   end if;
  end if;
 end if;
 if stato='nuovo' then perform public.valuta_collegamento_cliente(p.id);end if;
 if stato='ambiguo' then update public.pratiche set stato_amministrativo='corrispondenza_ambigua',stato_amministrativo_at=now() where id=p.id;end if;
 update public.pratiche set dati_raw=coalesce(dati_raw,'{}')||jsonb_build_object('fic_anagrafica',jsonb_build_object(
   'stato',stato,'verificato_at',now(),'clienti_trovati',jsonb_array_length(p_clienti),'cliente_fic_id',case when stato='riconosciuto' then c->>'id' end)) where id=p.id;
 perform public.prepara_richiesta_dati_amministrativi(p.id);
 return jsonb_build_object('esito',stato);
end;
$$;

create or replace function public.fic_segnala_fattura_chat(p_sessione uuid,p_messaggio text)
returns void language sql security invoker set search_path='' as $$
 insert into public.keplero_verifiche_originali(sessione,messaggio_id,esito,motivo)
 select sessione,messaggio_id,'da_verificare','Fattura nella chat: verificare corrispondenza con Fatture in Cloud, destinatario e pratica.'
 from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio
 on conflict(sessione,messaggio_id) do update set motivo=excluded.motivo,updated_at=now()
 where public.keplero_verifiche_originali.esito='da_verificare';
$$;

create or replace function public.fic_registra_fattura_chat(p_sessione uuid,p_messaggio text,p_pdf jsonb,p_fic jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.keplero_originali%rowtype; p public.pratiche%rowtype; c public.clienti%rowtype; ids uuid[]; did uuid; precedente jsonb; iva text; cf text;
begin
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio;
 if m.messaggio_id is null or m.modificato or m.tipo<>'file' or m.direzione<>'uscita'
  or coalesce(p_pdf->>'sha256_pdf','')!~'^[a-f0-9]{64}$' or (m.sha256_pdf is not null and m.sha256_pdf is distinct from p_pdf->>'sha256_pdf')
  or not coalesce(((m.originale->>'sender_type'='user' and m.originale#>>'{metadata,origin}'='whatsapp_coexistence')
    or m.originale#>>'{whatsapp_message,status}' in ('delivered','read')),false) then raise exception 'Prova WhatsApp non valida';end if;
 if p_pdf->>'tipo' is distinct from 'fattura' or p_fic->>'tipo' is distinct from 'invoice'
  or p_fic->>'valuta' is distinct from 'EUR' or coalesce(p_fic->>'id','')!~'^[1-9][0-9]*$'
  or nullif(p_pdf->>'numero','') is null or p_pdf->>'numero' is distinct from p_fic->>'numero'
  or coalesce(p_pdf->>'data','')!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  or p_pdf->>'data' is distinct from p_fic->>'data' or (p_pdf->>'data')::date>(m.data_messaggio at time zone 'Europe/Rome')::date
  or (p_pdf->>'importo')::numeric is distinct from (p_fic->>'importo')::numeric or coalesce((p_pdf->>'importo')::numeric,0)<=0
  or coalesce(p_pdf->>'targa','')!~'^[A-Z0-9]{4,12}$' then raise exception 'Fattura non verificata';end if;
 iva:=regexp_replace(upper(regexp_replace(coalesce(p_fic->>'partitaIva',''),'[^A-Za-z0-9]','','g')),'^IT(?=[0-9]{11}$)','');
 cf:=upper(regexp_replace(coalesce(p_fic->>'codiceFiscale',''),'[^A-Za-z0-9]','','g'));
 if (iva='' and cf='') or (iva<>'' and iva<>regexp_replace(upper(regexp_replace(coalesce(p_pdf#>>'{cliente,partita_iva}',''),'[^A-Za-z0-9]','','g')),'^IT(?=[0-9]{11}$)',''))
  or (cf<>'' and cf<>upper(regexp_replace(coalesce(p_pdf#>>'{cliente,codice_fiscale}',''),'[^A-Za-z0-9]','','g'))) then raise exception 'Destinatario discordante';end if;
 select array_agg(id) into ids from public.pratiche where tipo_flusso='commerciale' and stato_commerciale='ordine_acquisito'
  and upper(regexp_replace(coalesce(targa,''),'[^A-Za-z0-9]','','g'))=p_pdf->>'targa'
  and private.pratica_nella_conversazione_k(id,p_sessione)
  and (created_at at time zone 'Europe/Rome')::date<=(p_pdf->>'data')::date
  and coalesce(dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true' and coalesce(dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
 if cardinality(ids) is distinct from 1 then raise exception 'Pratica non univoca';end if;
 select * into p from public.pratiche where id=ids[1] for update;
 select * into c from public.clienti where id=p.cliente_id;
 if c.id is null or c.da_verificare or c.possibile_duplicato or (iva<>'' and c.partita_iva_normalizzata<>'' and iva<>c.partita_iva_normalizzata)
  or (cf<>'' and c.codice_fiscale_normalizzato<>'' and cf<>c.codice_fiscale_normalizzato)
  or not ((iva<>'' and iva=c.partita_iva_normalizzata) or (cf<>'' and cf=c.codice_fiscale_normalizzato))
  or p.blocco_operatore or p.blocco_classificazione_operatore or coalesce(p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}','false')='true'
  then raise exception 'Anagrafica o blocco da verificare';end if;
 perform pg_advisory_xact_lock(hashtextextended('fic_fattura:'||(p_fic->>'id'),0));
 select id into did from public.documenti_amministrativi where provider='fatture_in_cloud' and external_document_id=p_fic->>'id';
 if did is not null then
  if not exists(select 1 from public.documenti_amministrativi where id=did and pratica_id=p.id) then raise exception 'Fattura già abbinata';end if;
  return jsonb_build_object('esito','gia_registrata');
 end if;
 if p.stato_fatturazione is distinct from 'da_fatturare' then raise exception 'Stato fatturazione protetto';end if;
 precedente:=to_jsonb(p);
 insert into public.documenti_amministrativi(pratica_id,provider,external_document_id,tipo_documento,numero_documento,data_documento,importo,stato,documento_url,dati_raw)
 values(p.id,'fatture_in_cloud',p_fic->>'id','fattura',p_fic->>'numero',(p_fic->>'data')::date,(p_fic->>'importo')::numeric,'emessa',substring(m.testo from 12),
  jsonb_build_object('fonte','fattura_chat_verificata','sessione',p_sessione,'messaggio_id',p_messaggio,'sha256_pdf',p_pdf->>'sha256_pdf','fic',p_fic)) returning id into did;
 update public.pratiche set numero_fattura=p_fic->>'numero' where id=p.id;
 if not exists(select 1 from public.pratiche where id=p.id and stato_fatturazione='fatturato') then raise exception 'Stato fattura non aggiornato';end if;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'fattura_chat_verificata','Fattura verificata nella chat e in Fatture in Cloud',precedente,(select to_jsonb(x) from public.pratiche x where id=p.id),null);
 update public.keplero_verifiche_originali set esito='recuperata',pratica_id=p.id,motivo='Fattura verificata in Fatture in Cloud e nella chat.',verificata_at=now(),updated_at=now()
 where sessione=p_sessione and messaggio_id=p_messaggio and esito='da_verificare';
 return jsonb_build_object('esito','fatturata','pratica_id',p.id,'documento_id',did);
end;
$$;

revoke all on function public.fic_ordini_da_controllare(),public.fic_registra_controllo_cliente(uuid,jsonb,text),public.fic_segnala_fattura_chat(uuid,text),public.fic_registra_fattura_chat(uuid,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.fic_ordini_da_controllare(),public.fic_registra_controllo_cliente(uuid,jsonb,text),public.fic_segnala_fattura_chat(uuid,text),public.fic_registra_fattura_chat(uuid,text,jsonb,jsonb) to service_role;
create or replace function public.contesto_cliente_keplero(p_pratica_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_pratica public.pratiche%rowtype;
  v_cliente public.clienti%rowtype;
  v_ids uuid[];
  v_telefono text;
  v_email text;
  v_piva text;
  v_campi text[];
begin
  select * into v_pratica from public.pratiche where id = p_pratica_id;
  if not found then
    raise exception 'Pratica non trovata';
  end if;

  if v_pratica.stato_commerciale='ordine_acquisito' and v_pratica.stato_fatturazione='da_fatturare'
    and coalesce(v_pratica.dati_raw#>>'{fic_anagrafica,stato}','in_attesa') not in ('riconosciuto','nuovo') then
    return jsonb_build_object('stato','verifica_fatture_in_cloud','cliente_riconosciuto',false,
      'richiedere_anagrafica_completa',false,
      'istruzione',case when v_pratica.dati_raw#>>'{fic_anagrafica,stato}'='identita_mancante'
        then 'Per verificare il cliente in Fatture in Cloud chiedi solo partita IVA o codice fiscale, se non già forniti. Conserva gli altri dati.'
        else 'Il controllo su Fatture in Cloud è in attesa o richiede verifica operatore. Non chiedere nuovamente tutti i dati al cliente e non considerarlo automaticamente nuovo.' end);
  end if;

  v_telefono := public.normalizza_telefono_cliente(coalesce(v_pratica.telefono, ''));
  v_email := public.normalizza_email_cliente(coalesce(v_pratica.email_cliente, ''));
  v_piva := upper(regexp_replace(coalesce(
    v_pratica.dati_raw #>> '{anagrafica_estratta,partita_iva}',
    v_pratica.dati_raw #>> '{payload_live,partita_iva}', ''
  ), '[^A-Za-z0-9]', '', 'g'));

  if v_pratica.cliente_id is not null and v_pratica.fonte_collegamento_cliente = 'operatore' then
    v_ids := array[v_pratica.cliente_id];
  else
    select array_agg(c.id) into v_ids
    from public.clienti c
    where c.id = v_pratica.cliente_id
      or (v_email <> '' and c.email_normalizzata = v_email)
      or (v_piva <> '' and c.partita_iva_normalizzata = v_piva)
      or (length(v_telefono) >= 8 and exists (
        select 1
        from regexp_split_to_table(coalesce(c.telefono, ''), '[/;,|\n\r]+') as numeri(numero)
        where public.normalizza_telefono_cliente(numeri.numero) = v_telefono
      ));
  end if;

  if coalesce(cardinality(v_ids), 0) = 0 then
    return jsonb_build_object(
      'stato', 'non_trovato', 'cliente_riconosciuto', false,
      'richiedere_anagrafica_completa', false,
      'nome_attivita_acquisito', nullif(coalesce(
        v_pratica.dati_raw #>> '{anagrafica_estratta,ragione_sociale}',
        v_pratica.dati_raw #>> '{payload_live,nome_attivita}', ''
      ), ''),
      'istruzione', 'Nessuna corrispondenza certa in anagrafica: conserva tutti i dati già ricevuti nel testo e nelle immagini e chiedi solo quelli realmente mancanti.'
    );
  end if;

  if cardinality(v_ids) > 1 then
    return jsonb_build_object(
      'stato', 'ambiguo', 'cliente_riconosciuto', false,
      'richiedere_anagrafica_completa', false,
      'istruzione', 'Più anagrafiche compatibili: inoltra la verifica all’operatore, senza ricominciare la raccolta di dati già forniti e senza scegliere un cliente arbitrariamente.'
    );
  end if;

  select * into v_cliente from public.clienti where id = v_ids[1];
  if v_cliente.da_verificare or v_cliente.possibile_duplicato then
    return jsonb_build_object(
      'stato', 'da_verificare', 'cliente_riconosciuto', false,
      'richiedere_anagrafica_completa', false,
      'istruzione', 'L’anagrafica trovata richiede verifica dell’operatore: non chiedere nuovamente tutti i dati al cliente.'
    );
  end if;

  v_campi := coalesce(v_cliente.campi_amministrativi_mancanti, '{}'::text[]);
  if nullif(btrim(v_cliente.email), '') is null
     and nullif(btrim(v_pratica.email_cliente), '') is null
     and not ('email' = any(v_campi)) then
    v_campi := array_append(v_campi, 'email');
  end if;

  return jsonb_build_object(
    'stato', 'riconosciuto', 'cliente_riconosciuto', true,
    'denominazione', v_cliente.denominazione,
    'dati_fiscali_completi', v_cliente.dati_fiscali_completi and cardinality(v_campi) = 0,
    'campi_mancanti', to_jsonb(v_campi),
    'richiedere_anagrafica_completa', false,
    'istruzione', case
      when v_cliente.dati_fiscali_completi and cardinality(v_campi) = 0
        then 'Cliente già riconosciuto e dati fiscali completi: NON chiedere nome, ragione sociale, partita IVA, codice fiscale, indirizzo o email. Chiedi solo eventuali variazioni o un diverso luogo di ritiro/spedizione quando necessario.'
      else 'Cliente già riconosciuto: NON richiedere nome o tutti i dati fiscali. Dopo una reale accettazione chiedi soltanto i campi mancanti indicati, sottraendo quelli già ricevuti nella conversazione o nelle immagini.'
    end
  );
end;
$$;

revoke all on function public.contesto_cliente_keplero(uuid) from public, anon, authenticated;
grant execute on function public.contesto_cliente_keplero(uuid) to service_role;

notify pgrst,'reload schema';

set local lock_timeout='3s';

create or replace function public.trigger_valuta_collegamento_cliente()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='UPDATE' and new.stato_fatturazione is not distinct from old.stato_fatturazione
   and new.telefono is not distinct from old.telefono and new.email_cliente is not distinct from old.email_cliente
   and (new.dati_raw-'fic_anagrafica') is not distinct from (old.dati_raw-'fic_anagrafica') then return new;end if;
 if new.stato_fatturazione='da_fatturare' then perform public.valuta_collegamento_cliente(new.id);end if;
 return new;
end;$$;
create or replace function public.fic_registra_controllo_cliente(p_pratica uuid,p_clienti jsonb,p_esito text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.pratiche%rowtype; c jsonb; cid uuid; ids uuid[]; imp uuid; iva text; cf text; stato text:=p_esito; completo boolean; identita public.clienti%rowtype; iva_p text; cf_p text; corrisponde boolean;
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
  select * into identita from public.clienti where id=p.cliente_id;
  iva_p:=regexp_replace(upper(regexp_replace(coalesce(nullif(p.dati_raw#>>'{anagrafica_estratta,partita_iva}',''),identita.partita_iva,''),'[^A-Za-z0-9]','','g')),'^IT(?=[0-9]{11}$)','');
  cf_p:=upper(regexp_replace(coalesce(nullif(p.dati_raw#>>'{anagrafica_estratta,codice_fiscale}',''),identita.codice_fiscale,''),'[^A-Za-z0-9]','','g'));
  corrisponde:=coalesce((iva_p<>'' and iva_p=iva) or (cf_p<>'' and cf_p=cf)
    or (nullif(public.normalizza_email_cliente(coalesce(p.email_cliente,identita.email)),'')=public.normalizza_email_cliente(c->>'email'))
    or (length(public.normalizza_telefono_cliente(coalesce(p.telefono,identita.telefono)))>=8 and exists(
      select 1 from regexp_split_to_table(coalesce(c->>'phone',''),'[/;,|\n]+') tel
      where public.normalizza_telefono_cliente(tel)=public.normalizza_telefono_cliente(coalesce(p.telefono,identita.telefono)))),false);
  if not corrisponde or (iva_p<>'' and iva<>'' and iva_p<>iva) or (cf_p<>'' and cf<>'' and cf_p<>cf) then
    update public.pratiche set dati_raw=dati_raw||jsonb_build_object('fic_anagrafica',jsonb_build_object('stato','ambiguo','verificato_at',now())) where id=p.id;
    return jsonb_build_object('esito','ambiguo');
  end if;
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
 if exists(select 1 from public.documenti_amministrativi where tipo_documento='fattura' and pratica_id<>p.id
   and (provider='fatture_in_cloud' and external_document_id=p_fic->>'id'
     or numero_documento=p_fic->>'numero' and data_documento=(p_fic->>'data')::date)) then raise exception 'Fattura già abbinata';end if;
 select id into did from public.documenti_amministrativi where tipo_documento='fattura' and pratica_id=p.id
   and (provider='fatture_in_cloud' and external_document_id=p_fic->>'id'
     or numero_documento=p_fic->>'numero' and data_documento=(p_fic->>'data')::date) order by created_at limit 1;
 if did is not null then
  if not exists(select 1 from public.documenti_amministrativi where id=did and pratica_id=p.id) then raise exception 'Fattura già abbinata';end if;
  return jsonb_build_object('esito','gia_registrata');
 end if;
 if p.stato_fatturazione is distinct from 'da_fatturare' then raise exception 'Stato fatturazione protetto';end if;
 precedente:=to_jsonb(p);
 insert into public.documenti_amministrativi(pratica_id,provider,external_document_id,tipo_documento,numero_documento,data_documento,importo,stato,documento_url,dati_raw)
 values(p.id,'fatture_in_cloud',p_fic->>'id','fattura',p_fic->>'numero',(p_fic->>'data')::date,(p_fic->>'importo')::numeric,'emessa',substring(m.testo from 12),
  jsonb_build_object('fonte','fattura_chat_verificata','sessione',p_sessione,'messaggio_id',p_messaggio,'sha256_pdf',p_pdf->>'sha256_pdf','fic',p_fic)) returning id into did;
 if not exists(select 1 from public.pratiche where id=p.id and stato_fatturazione='fatturato') then raise exception 'Stato fattura non aggiornato';end if;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'fattura_chat_verificata','Fattura verificata nella chat e in Fatture in Cloud',precedente,(select to_jsonb(x) from public.pratiche x where id=p.id),null);
 update public.keplero_verifiche_originali set esito='recuperata',pratica_id=p.id,motivo='Fattura verificata in Fatture in Cloud e nella chat.',verificata_at=now(),updated_at=now()
 where sessione=p_sessione and messaggio_id=p_messaggio and esito='da_verificare';
 return jsonb_build_object('esito','fatturata','pratica_id',p.id,'documento_id',did);
end;
$$;


notify pgrst,'reload schema';

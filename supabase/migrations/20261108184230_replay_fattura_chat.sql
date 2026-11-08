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
  if p.stato_fatturazione is distinct from 'fatturato' then raise exception 'Documento già presente da verificare';end if;
  return jsonb_build_object('esito','gia_registrata');
 end if;
 if p.blocco_operatore or p.blocco_classificazione_operatore or coalesce(p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}','false')='true' then raise exception 'Blocco operatore da rispettare';end if;
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

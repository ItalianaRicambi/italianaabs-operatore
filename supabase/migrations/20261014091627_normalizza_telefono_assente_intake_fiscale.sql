create or replace function private.crea_cliente_fiscale_intake(p_pratica_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.pratiche; a jsonb; cid uuid; iid uuid; h text; ident text;
begin
 select * into p from public.pratiche where id=p_pratica_id for update;
 a:=p.dati_raw->'anagrafica_estratta';
 if not found or p.stato_commerciale<>'ordine_acquisito' or p.stato_fatturazione<>'da_fatturare'
   or p.cliente_id is not null or p.blocco_operatore
   or 'cliente_id'=any(coalesce(p.campi_bloccati_operatore,'{}'::text[]))
   or coalesce(p.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}','false')='true'
   or a->>'_fonte' is distinct from 'keplero_dati_fiscali'
   or jsonb_array_length(coalesce(a->'_conflitti','[]'::jsonb))>0 then return null;end if;
 if nullif(btrim(a->>'denominazione'),'') is null
   or nullif(btrim(a->>'indirizzo_fatturazione'),'') is null
   or nullif(btrim(a->>'comune'),'') is null
   or coalesce(a->>'cap','')!~'^[0-9]{5}$'
   or coalesce(coalesce(a->>'email',a->>'pec'),'')!~'^[^[:space:]<>@]+@[^[:space:]<>@]+[.][^[:space:]<>@]+$'
   or not (coalesce(a->>'partita_iva','')~'^[0-9]{11}$'
     or coalesce(a->>'codice_fiscale','')~'^([A-Z]{6}[A-Z0-9]{2}[A-Z][A-Z0-9]{2}[A-Z][A-Z0-9]{3}[A-Z]|[0-9]{11})$')
   then return null;end if;
 ident:=coalesce(nullif(a->>'partita_iva',''),a->>'codice_fiscale');
 perform pg_advisory_xact_lock(hashtextextended('anagrafica_fiscale:'||ident,0));
 -- Una anagrafica già presente, anche incompleta/duplicata, richiede l'abbinamento esistente.
 if exists(select 1 from public.clienti c
   where (nullif(a->>'partita_iva','') is not null and c.partita_iva_normalizzata=a->>'partita_iva')
      or (nullif(a->>'codice_fiscale','') is not null and c.codice_fiscale_normalizzato=a->>'codice_fiscale'))
   then return null;end if;
 h:=encode(sha256(convert_to('keplero_fiscale:'||p.id::text,'UTF8')),'hex');
 insert into public.clienti_importazioni(fonte,nome_file,file_sha256,righe_origine,righe_inserite,stato,riepilogo,completed_at)
 values('altro','Anagrafica fiscale Keplero',h,1,1,'completata',
   jsonb_build_object('pratica_id',p.id,'tipo','dati_fiscali_cliente'),now())
 returning id into iid;
 insert into public.clienti(fonte,source_record_key,denominazione,indirizzo_fatturazione,comune,cap,
  provincia,paese,email,telefono,partita_iva,codice_fiscale,pec,codice_sdi,
  partita_iva_normalizzata,codice_fiscale_normalizzato,email_normalizzata,telefono_normalizzato,
  dati_fiscali_completi,source_fingerprint,source_row_number,importazione_id)
 values('altro','keplero_fiscale:'||p.id::text,a->>'denominazione',a->>'indirizzo_fatturazione',
  a->>'comune',a->>'cap',a->>'provincia',coalesce(a->>'paese','IT'),
  lower(coalesce(a->>'email',a->>'pec')),coalesce(a->>'telefono',p.telefono),
  a->>'partita_iva',a->>'codice_fiscale',a->>'pec',a->>'codice_sdi',
  coalesce(a->>'partita_iva',''),coalesce(a->>'codice_fiscale',''),
  public.normalizza_email_cliente(coalesce(a->>'email',a->>'pec')),
  coalesce(public.normalizza_telefono_cliente(coalesce(a->>'telefono',p.telefono)),''),
  true,h,2,iid) returning id into cid;
 update public.pratiche set cliente_id=cid,fonte_collegamento_cliente='automatico',
  cliente_collegato_at=now(),stato_amministrativo='pronto_fatturazione',
  nota_amministrativa='Anagrafica fiscale completa acquisita dalla conversazione Keplero.'
 where id=p.id;
 return jsonb_build_object('esito','pronto_fatturazione','pratica_id',p.id,'cliente_id',cid,'fonte','keplero_dati_fiscali');
end $$;


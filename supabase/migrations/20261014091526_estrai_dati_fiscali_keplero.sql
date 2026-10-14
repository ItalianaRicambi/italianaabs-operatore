
-- Conserva l'anagrafica fiscale ricevuta da K separatamente dalla logistica.
create or replace function private.anagrafica_fiscale_intake(p_payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 t text := coalesce(p_payload->>'dati_fiscali_testo','');
 j jsonb := case when jsonb_typeof(p_payload->'anagrafica_fiscale')='object'
   then p_payload->'anagrafica_fiscale' else '{}'::jsonb end;
 r jsonb := '{}'::jsonb; coppia text; k text; v text; campo text;
begin
 -- Il formato etichettato non interpreta indirizzi di ritiro come fiscali.
 if t ~ '^(FATTURAZIONE|ANAGRAFICA)[|]' then
  foreach coppia in array string_to_array(t,'|') loop
   k:=upper(btrim(split_part(coppia,':',1)));
   v:=nullif(btrim(substr(coppia,position(':' in coppia)+1)),'');
   if position(':' in coppia)=0 or v is null then continue; end if;
   campo:=case k when 'DENOMINAZIONE' then 'denominazione'
     when 'RAGIONE_SOCIALE' then 'denominazione' when 'NOME' then 'denominazione'
     when 'INDIRIZZO_FATTURAZIONE' then 'indirizzo_fatturazione'
     when 'INDIRIZZO' then 'indirizzo_fatturazione' when 'CAP' then 'cap'
     when 'COMUNE' then 'comune' when 'PROVINCIA' then 'provincia'
     when 'PAESE' then 'paese' when 'PIVA' then 'partita_iva'
     when 'PARTITA_IVA' then 'partita_iva' when 'CF' then 'codice_fiscale'
     when 'CODICE_FISCALE' then 'codice_fiscale' when 'EMAIL' then 'email'
     when 'PEC' then 'pec' when 'SDI' then 'codice_sdi'
     when 'TELEFONO' then 'telefono' else null end;
   if campo is not null then
    if r ? campo and upper(r->>campo)<>upper(v) then
      r:=r||jsonb_build_object('_conflitti',coalesce(r->'_conflitti','[]'::jsonb)||to_jsonb(campo));
    else r:=r||jsonb_build_object(campo,v); end if;
   end if;
  end loop;
 end if;
 foreach campo in array array['denominazione','indirizzo_fatturazione','cap','comune',
  'provincia','paese','partita_iva','codice_fiscale','email','pec','codice_sdi','telefono'] loop
  v:=nullif(btrim(j->>campo),'');
  if v is not null and v !~ '[{}]' then
   if r ? campo and upper(r->>campo)<>upper(v) then
    r:=r||jsonb_build_object('_conflitti',coalesce(r->'_conflitti','[]'::jsonb)||to_jsonb(campo));
   else r:=r||jsonb_build_object(campo,v); end if;
  end if;
 end loop;
 if r='{}'::jsonb then return r; end if;
 if r ? 'partita_iva' then r:=jsonb_set(r,'{partita_iva}',to_jsonb(regexp_replace(r->>'partita_iva','[^A-Za-z0-9]','','g')));end if;
 if r ? 'codice_fiscale' then r:=jsonb_set(r,'{codice_fiscale}',to_jsonb(upper(regexp_replace(r->>'codice_fiscale','[^A-Za-z0-9]','','g'))));end if;
 r:=r||jsonb_build_object('_fonte','keplero_dati_fiscali','_testo',t);
 return r;
end $$;


revoke all on function private.anagrafica_fiscale_intake(jsonb) from public,anon,authenticated;
grant execute on function private.anagrafica_fiscale_intake(jsonb) to service_role;

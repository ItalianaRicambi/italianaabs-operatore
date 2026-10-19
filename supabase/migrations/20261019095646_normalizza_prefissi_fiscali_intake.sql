-- Equivalenza di formato, senza inventare identificativi o cambiare il testo
-- originale: IT + 11 cifre è la rappresentazione europea del numero italiano.
create or replace function private.normalizza_anagrafica_fiscale_intake(p_dati jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $$
declare r jsonb:=coalesce(p_dati,'{}'::jsonb); k text; v text;
begin
 if jsonb_typeof(r)<>'object' then return '{}'::jsonb;end if;
 foreach k in array array['partita_iva','codice_fiscale'] loop
  if nullif(btrim(r->>k),'') is null then continue;end if;
  v:=upper(regexp_replace(r->>k,'[^A-Za-z0-9]','','g'));
  if v ~ '^IT[0-9]{11}$' then v:=substr(v,3);end if;
  r:=jsonb_set(r,array[k],to_jsonb(v));
 end loop;
 return r;
end $$;
revoke all on function private.normalizza_anagrafica_fiscale_intake(jsonb) from public,anon,authenticated;
grant execute on function private.normalizza_anagrafica_fiscale_intake(jsonb) to service_role;

do $patch$
declare d text; a text;
begin
 d:=pg_get_functiondef('private.anagrafica_fiscale_intake(jsonb)'::regprocedure);
 a:=' if t ~ ''^(FATTURAZIONE|ANAGRAFICA)[|]'' then';
 if position(a in d)=0 or position('private.normalizza_anagrafica_fiscale_intake' in d)>0 then raise exception 'Estrattore fiscale inatteso';end if;
 d:=replace(d,a,' j:=private.normalizza_anagrafica_fiscale_intake(j);'||chr(10)||a);
 a:='   if campo is not null then';
 if position(a in d)=0 then raise exception 'Campi fiscali inattesi';end if;
 d:=replace(d,a,a||chr(10)||'    if campo in (''partita_iva'',''codice_fiscale'') then v:=private.normalizza_anagrafica_fiscale_intake(jsonb_build_object(campo,v))->>campo;end if;');
 execute d;

 d:=pg_get_functiondef('private.accumula_anagrafica_fiscale_keplero()'::regprocedure);
 a:=' precedente:=coalesce(new.dati_raw->''anagrafica_estratta'',''{}''::jsonb);';
 if position(a in d)=0 then raise exception 'Accumulo fiscale inatteso';end if;
 execute replace(d,a,' precedente:=private.normalizza_anagrafica_fiscale_intake(coalesce(new.dati_raw->''anagrafica_estratta'',''{}''::jsonb));');

 -- Consente di rivalutare anche i dati già ricevuti, senza riscrivere eventi
 -- o anagrafiche esistenti e senza rimuovere conflitti o blocchi operatore.
 d:=pg_get_functiondef('private.crea_cliente_fiscale_intake(uuid)'::regprocedure);
 a:=' a:=p.dati_raw->''anagrafica_estratta'';';
 if position(a in d)=0 then raise exception 'Creazione anagrafica inattesa';end if;
 execute replace(d,a,' a:=private.normalizza_anagrafica_fiscale_intake(p.dati_raw->''anagrafica_estratta'');');
end $patch$;
notify pgrst,'reload schema';

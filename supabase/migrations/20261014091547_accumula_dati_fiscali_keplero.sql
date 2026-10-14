create or replace function private.accumula_anagrafica_fiscale_keplero()
returns trigger language plpgsql security invoker set search_path='' as $$
declare a jsonb; precedente jsonb; k text; v jsonb; conflitti jsonb;
begin
 a:=private.anagrafica_fiscale_intake(coalesce(new.dati_raw->'payload_live','{}'::jsonb));
 if a='{}'::jsonb then return new; end if;
 precedente:=coalesce(new.dati_raw->'anagrafica_estratta','{}'::jsonb);
 conflitti:=coalesce(precedente->'_conflitti','[]'::jsonb)||coalesce(a->'_conflitti','[]'::jsonb);
 for k,v in select key,value from jsonb_each(a) where key !~ '^_' loop
  if precedente ? k and nullif(btrim(precedente->>k),'') is not null
     and upper(regexp_replace(precedente->>k,'[[:space:]]+',' ','g'))
       <>upper(regexp_replace(a->>k,'[[:space:]]+',' ','g')) then
    conflitti:=conflitti||to_jsonb(k);
  else precedente:=precedente||jsonb_build_object(k,v);end if;
 end loop;
 precedente:=precedente||jsonb_build_object('_fonte','keplero_dati_fiscali',
   '_conflitti',conflitti,'_testo',a->>'_testo');
 new.dati_raw:=coalesce(new.dati_raw,'{}'::jsonb)||jsonb_build_object('anagrafica_estratta',precedente);
 return new;
end $$;

create trigger trg_01_accumula_anagrafica_fiscale_keplero
before insert or update of dati_raw on public.pratiche for each row
execute function private.accumula_anagrafica_fiscale_keplero();


revoke all on function private.accumula_anagrafica_fiscale_keplero() from public,anon,authenticated;
grant execute on function private.accumula_anagrafica_fiscale_keplero() to service_role;

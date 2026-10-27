-- Regressione dei permessi reali del backend. Tutte le fixture sono annullate.
begin;
set local role service_role;
do $test$
declare old_id uuid; new_id uuid; before_old jsonb; before_new jsonb; result jsonb;
begin
  if has_function_privilege('anon', 'public.attiva_pratica_conversazione_keplero(text,uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.attiva_pratica_conversazione_keplero(text,uuid)', 'EXECUTE')
     or has_table_privilege('anon', 'public.keplero_live_links', 'DELETE')
     or has_table_privilege('authenticated', 'public.keplero_live_links', 'DELETE') then
    raise exception 'Accesso client non consentito';
  end if;
  insert into public.pratiche(nome_cliente,targa) values('Test rollback attivazione precedente','TSTX001') returning id into old_id;
  insert into public.pratiche(nome_cliente,targa) values('Test rollback attivazione nuova','TSTX002') returning id into new_id;
  insert into public.keplero_live_links(external_key,pratica_id) values
    ('test:permessi:conversazione',old_id),('test:permessi:conversazione:veicolo:tstx002',new_id);
  select to_jsonb(p) into before_old from public.pratiche p where id=old_id;
  select to_jsonb(p) into before_new from public.pratiche p where id=new_id;
  result:=public.attiva_pratica_conversazione_keplero('test:permessi:conversazione',new_id);
  if result->>'attiva' is distinct from 'true'
     or (select pratica_id from public.keplero_live_links where external_key='test:permessi:conversazione') is distinct from new_id
     or exists(select 1 from public.keplero_live_links where external_key='test:permessi:conversazione:veicolo:tstx002') then
    raise exception 'Attivazione non completata';
  end if;
  perform public.attiva_pratica_conversazione_keplero('test:permessi:conversazione',new_id);
  if (select count(*) from public.keplero_live_links where pratica_id=new_id)<>1 then
    raise exception 'Replay non idempotente';
  end if;
  if before_old is distinct from (select to_jsonb(p) from public.pratiche p where id=old_id)
     or before_new is distinct from (select to_jsonb(p) from public.pratiche p where id=new_id) then
    raise exception 'Dati o stati delle pratiche modificati';
  end if;
end $test$;
rollback;

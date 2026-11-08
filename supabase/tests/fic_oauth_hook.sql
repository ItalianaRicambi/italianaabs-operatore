-- Run after the audience migration. All fixtures are rolled back.
begin;
insert into fic_private.oauth_audiences(client_id,user_id,audience) values
('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','https://example.test/mcp');
do $$
declare
  event jsonb := '{"user_id":"22222222-2222-4222-8222-222222222222","authentication_method":"oauth_provider/authorization_code","claims":{"sub":"22222222-2222-4222-8222-222222222222","client_id":"11111111-1111-4111-8111-111111111111","aud":"authenticated","scope":"email","exp":2000000000,"iat":1999996400}}';
  result jsonb;
begin
  result := public.fic_oauth_access_token_hook(event);
  if result#>>'{claims,aud}' is distinct from 'https://example.test/mcp' then raise exception 'audience mismatch'; end if;
  if (result->'claims')-'aud' is distinct from (event->'claims')-'aud' then raise exception 'other claims changed'; end if;
  event := jsonb_set(event,'{authentication_method}','"token_refresh"');
  if public.fic_oauth_access_token_hook(event)#>>'{claims,aud}' is distinct from 'https://example.test/mcp' then raise exception 'refresh audience mismatch'; end if;
  event := event #- '{claims,client_id}';
  if public.fic_oauth_access_token_hook(event) <> event then raise exception 'direct session changed'; end if;
  event := jsonb_set(event,'{claims,user_metadata}','{"client_id":"11111111-1111-4111-8111-111111111111"}');
  if public.fic_oauth_access_token_hook(event) <> event then raise exception 'user metadata trusted'; end if;
  event := jsonb_set(event,'{claims,client_id}','"00000000-0000-0000-0000-000000000000"');
  if public.fic_oauth_access_token_hook(event) <> event then raise exception 'other client changed'; end if;
  event := jsonb_set(event,'{claims,client_id}','"11111111-1111-4111-8111-111111111111"');
  event := jsonb_set(event,'{claims,sub}','"00000000-0000-0000-0000-000000000000"');
  if public.fic_oauth_access_token_hook(event) <> event then raise exception 'other user changed'; end if;
  if has_function_privilege('anon','public.fic_oauth_access_token_hook(jsonb)','execute')
    or has_function_privilege('authenticated','public.fic_oauth_access_token_hook(jsonb)','execute')
    or has_table_privilege('authenticated','fic_private.oauth_audiences','select') then
    raise exception 'public access to hook/configuration';
  end if;
  if not has_function_privilege('supabase_auth_admin','public.fic_oauth_access_token_hook(jsonb)','execute')
    or not has_table_privilege('supabase_auth_admin','fic_private.oauth_audiences','select')
    or not has_schema_privilege('supabase_auth_admin','fic_private','usage') then
    raise exception 'missing auth service grants';
  end if;
end $$;
rollback;
select 'OAuth hook regression checks passed' as result;

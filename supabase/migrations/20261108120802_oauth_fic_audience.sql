-- Runtime bindings are inserted separately; no account IDs or secrets in source.
create schema if not exists fic_private;
revoke all on schema fic_private from public, anon, authenticated;
grant usage on schema fic_private to supabase_auth_admin;

create table fic_private.oauth_audiences (
  client_id uuid not null,
  user_id uuid not null,
  audience text not null check (audience ~ '^https://[^/?#]+/mcp$'),
  primary key (client_id, user_id)
);
alter table fic_private.oauth_audiences enable row level security;
revoke all on fic_private.oauth_audiences from public, anon, authenticated, service_role;
grant select on fic_private.oauth_audiences to supabase_auth_admin;
create policy oauth_audiences_auth_read on fic_private.oauth_audiences
  for select to supabase_auth_admin using (true);

-- Selected manually under Authentication > Auth Hooks > Custom Access Token.
-- Runs as supabase_auth_admin; no elevated function privileges are needed.
create function public.fic_oauth_access_token_hook(event jsonb)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
declare
  claims jsonb := event->'claims';
  target_audience text;
begin
  if jsonb_typeof(claims) is distinct from 'object' then
    return event;
  end if;

  -- Use only issuer-controlled claims, never user_metadata. Password sessions
  -- and other clients/users retain their original claims and audience.
  select a.audience into target_audience
    from fic_private.oauth_audiences a
    where a.client_id::text = claims->>'client_id'
      and a.user_id::text = claims->>'sub'
      and a.user_id::text = event->>'user_id';

  if target_audience is not null then
    claims := jsonb_set(claims, '{aud}', to_jsonb(target_audience));
    return jsonb_set(event, '{claims}', claims);
  end if;
  return event;
end;
$$;
revoke all on function public.fic_oauth_access_token_hook(jsonb)
  from public, anon, authenticated, service_role;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.fic_oauth_access_token_hook(jsonb) to supabase_auth_admin;

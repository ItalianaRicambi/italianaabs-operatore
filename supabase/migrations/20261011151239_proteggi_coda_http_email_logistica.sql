-- pg_net conserva anche gli header di autenticazione nella coda HTTP.
-- Il worker viene chiamato esclusivamente da una funzione privata come postgres.
revoke all on all tables in schema net from public,anon,authenticated,service_role;
revoke all on all sequences in schema net from public,anon,authenticated,service_role;
revoke all on all functions in schema net from public,anon,authenticated,service_role;
revoke all on schema net from public,anon,authenticated,service_role;

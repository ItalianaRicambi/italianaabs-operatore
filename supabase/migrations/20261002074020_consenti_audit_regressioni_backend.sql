-- Il backend registra i tentativi bloccati senza esporre l'audit ai client.
grant usage on schema private to service_role;
grant insert on table private.regressioni_stato_bloccate to service_role;
grant usage on sequence private.regressioni_stato_bloccate_id_seq to service_role;

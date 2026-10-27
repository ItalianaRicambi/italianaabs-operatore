-- La RPC SECURITY INVOKER sposta la chiave della conversazione sulla nuova
-- pratica eliminando il collegamento provvisorio. Il backend aveva SELECT,
-- INSERT e UPDATE ma non DELETE: il passaggio falliva con 42501.
-- Nessun permesso aggiunto ai ruoli client; RLS e RPC restano invariati.
grant delete on table public.keplero_live_links to service_role;

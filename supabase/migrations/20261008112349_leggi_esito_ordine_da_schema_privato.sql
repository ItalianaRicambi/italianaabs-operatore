-- Il webhook deve leggere l'esito del motore nello schema privato.
-- Usiamo una sola funzione di lettura con parametri e collegamento verificati,
-- accessibile esclusivamente al servizio; non concediamo SELECT sulla tabella.
-- search_path resta vuoto e tutte le relazioni della funzione sono qualificate.
alter function public.esito_ordine_contestuale_keplero(uuid,text) security definer;
revoke all on function public.esito_ordine_contestuale_keplero(uuid,text) from public,anon,authenticated;
grant execute on function public.esito_ordine_contestuale_keplero(uuid,text) to service_role;

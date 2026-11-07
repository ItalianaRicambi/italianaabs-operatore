-- L'applicazione usa RPC dal server con service_role, mai da sessioni anon/authenticated.
-- Necessario prima di pubblicare il frontend OAuth con una chiave publishable.
do $$ declare f record; begin
  for f in select p.oid::regprocedure as firma from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef and p.proname=any(array[
      'aggiorna_blocco_classificazione_operatore','aggiorna_dati_pratica_operatore','aggiorna_stato_assistenza_operatore',
      'aggiungi_dtc_operatore','applica_azione_operatore_estesa','audit_pratiche','gestisci_conferma_cliente_pratica',
      'gestisci_da_preventivare_at','gestisci_da_verificare_at','gestisci_timer_assistenza','marca_assistenza_operatore',
      'marca_commerciale_operatore','minuti_lavorativi_trascorsi','proponi_assistenza_ai','rls_auto_enable','verifica_dtc_operatore'])
  loop
    execute format('revoke execute on function %s from public,anon,authenticated',f.firma);
    execute format('grant execute on function %s to service_role',f.firma);
  end loop;
end $$;

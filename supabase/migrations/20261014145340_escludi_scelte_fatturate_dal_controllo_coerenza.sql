-- Gli avvisi commerciali seguono la stessa regola della coda scelte.
-- Storico delle scelte, assistenze e logistica restano indipendenti.
create or replace function private.candidati_flussi_offerta_rientro()
returns table(chiave text,pratica_id uuid,event_id bigint,regola text,descrizione text,evidenza text)
language sql stable security invoker set search_path='' as $$
 with candidati(chiave,pratica_id,event_id,regola,descrizione,evidenza) as (
 select 'assistenza_non_assegnata:'||c.id,c.pratica_id,c.evento_id,'assistenza_urgente_non_assegnata',
 'Rientro di assistenza urgente senza presa in carico da oltre 30 minuti lavorativi.',left(c.evidenza,600)
 from public.assistenze_rientri c where chiusa_at is null and presa_in_carico_at is null
  and public.minuti_lavorativi_trascorsi(aperta_at,now())>=30
 union all
 select 'ritiro_ambiguo:'||a.id,a.pratica_id,a.evento_keplero_id,'ritiro_da_classificare',
 'Ritiro rilevato: classificazione o ordine di origine da chiarire.',left(a.evidenza,600)
 from public.attivita_operatore a where a.tipo like 'ritiro_%' and a.stato in ('da_gestire','da_collegare','programmata')
  and (a.tipo='ritiro_da_classificare' or a.pratica_origine_id is null)
 union all
 select 'offerta_illeggibile:'||q.id,q.pratica_id,null::bigint,'offerta_da_verificare',
 'Alternative del preventivo non leggibili: verifica del documento richiesta.',coalesce(q.errore,'Alternative assenti')
 from public.offerte_versioni q where stato='da_verificare'
  and not exists(select 1 from public.offerte_versioni n where n.preventivo_id=q.preventivo_id and n.registrata_at>q.registrata_at)
 union all
 select 'scelta_ambigua:'||s.pratica_id,s.pratica_id,s.evento_id,'scelta_cliente_da_chiarire',
 'Scelta del cliente da chiarire o modifica di una scelta già confermata.',left(s.evidenza,600)
 from public.scelte_cliente s where stato in ('da_chiarire','modifica_da_verificare')
 union all
 select 'scelta_nuova_offerta:'||s.pratica_id,s.pratica_id,s.evento_id,'scelta_versione_precedente',
 'Nuovo preventivo dopo la scelta: verificare la versione concordata con il cliente.',left(s.evidenza,600)
 from public.v_scelte_cliente s where offerta_successiva and stato='confermata'
 union all
 select 'prezzo_scelta:'||s.pratica_id,s.pratica_id,s.evento_id,'prezzo_scelta_da_verificare',
 'Importo di pagamento segnalato diverso dal preventivo scelto: verificare il prezzo concordato.',left(s.evidenza,600)
 from public.v_scelte_cliente s where prezzo_da_verificare
 )
 select c.* from candidati c
 where c.regola not in ('scelta_cliente_da_chiarire','scelta_versione_precedente','prezzo_scelta_da_verificare')
 or exists (
   select 1 from public.pratiche p where p.id=c.pratica_id
    and p.tipo_flusso='commerciale'
    and p.stato_fatturazione<>'fatturato'
    and p.stato_commerciale not in ('chiuso','rifiutato')
 );
$$;

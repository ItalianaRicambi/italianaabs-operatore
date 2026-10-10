-- La SELECT a.* della vista originale non include le colonne aggiunte dopo
-- la sua creazione. Manteniamo ordine, tipi, filtro e permessi esistenti,
-- aggiungendo in coda i dati necessari alla scheda e alla gestione dei ritiri.
create or replace view public.v_attivita_operatore_aperte
with (security_invoker = true)
as
select
  a.id, a.tipo, a.stato, a.priorita, a.pratica_id, a.pratica_origine_id,
  a.preventivo_id, a.evento_keplero_id, a.external_key, a.evidenza,
  a.fonte, a.nota, a.metadati, a.richiesta_at, a.programmata_at,
  a.completata_at, a.annullata_at, a.operatore, a.created_at, a.updated_at,
  'ABS-' || lpad(p.numero_pratica::text, 6, '0') as codice_pratica,
  p.nome_cliente, p.telefono, p.targa, p.marca_veicolo, p.modello_veicolo,
  p.tipo_flusso, p.stato_commerciale, p.stato_fatturazione, p.stato_assistenza,
  case when po.id is null then null
    else 'ABS-' || lpad(po.numero_pratica::text, 6, '0')
  end as codice_pratica_origine,
  po.stato_logistica as stato_logistica_origine,
  a.assistenza_rientro_id,
  a.presa_in_carico_at,
  a.blocco_classificazione,
  a.riferimento_ritiro,
  a.data_ritiro_prevista
from public.attivita_operatore a
join public.pratiche p on p.id = a.pratica_id
left join public.pratiche po on po.id = a.pratica_origine_id
where a.stato in ('da_gestire', 'da_collegare', 'programmata');

notify pgrst, 'reload schema';

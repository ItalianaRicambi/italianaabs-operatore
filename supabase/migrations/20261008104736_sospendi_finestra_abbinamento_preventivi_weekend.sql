-- Le finestre di riconciliazione sospendono il conteggio sabato e domenica.
grant execute on function private.inizio_finestra_controllo_keplero(timestamptz,integer) to service_role;

create or replace function private.abbina_preventivo_emesso(
  p_external_id text, p_nome_file text, p_targa text, p_file_url text,
  p_data_offerta timestamptz, p_inviato_at timestamptz
) returns jsonb language plpgsql security invoker set search_path = '' as $fn$
declare
  v_preventivo_id uuid;
  v_pratica_id uuid;
  v_candidati integer;
  v_pr public.pratiche%rowtype;
begin
  select id, pratica_id into v_preventivo_id, v_pratica_id
  from public.preventivi where external_id = p_external_id limit 1;
  if v_preventivo_id is not null then
    return jsonb_build_object('aggiornato', false, 'esito', 'gia_registrato',
      'preventivo_id', v_preventivo_id, 'pratica_id', v_pratica_id, 'targa', p_targa);
  end if;

  select count(*), (array_agg(p.id order by p.created_at))[1]
    into v_candidati, v_pratica_id
  from public.pratiche p
  where upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) = p_targa
    and p.tipo_flusso = 'commerciale'
    and p.stato_commerciale not in ('ordine_acquisito','perso','chiuso','rifiutato')
    and p.stato_fatturazione = 'non_applicabile'
    -- I vecchi PDF non sono attribuiti a nuove pratiche. Un PDF recente già\n    -- in attesa prima della creazione della pratica può essere recuperato.
    and (
      p.created_at <= p_data_offerta + interval '5 minutes'
      or exists (
        select 1 from public.preventivi_emessi_ricevuti d
        where d.external_id=p_external_id
          and d.ricevuto_at<=p.created_at
          and d.ricevuto_at>=private.inizio_finestra_controllo_keplero(p.created_at,48)
          and p_data_offerta>=private.inizio_finestra_controllo_keplero(d.ricevuto_at,24)
      )
    )
    and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}','false') <> 'true'
    and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}','false') <> 'true';

  if v_candidati <> 1 then
    return jsonb_build_object('aggiornato',false,'esito',
      case when v_candidati = 0 then 'nessuna_pratica_compatibile' else 'pratica_ambigua' end,
      'targa',p_targa,'candidati',v_candidati);
  end if;

  select * into v_pr from public.pratiche where id = v_pratica_id for update;
  if v_pr.tipo_flusso <> 'commerciale'
    or v_pr.stato_commerciale in ('ordine_acquisito','perso','chiuso','rifiutato')
    or v_pr.stato_fatturazione <> 'non_applicabile'
    or upper(regexp_replace(coalesce(v_pr.targa,''),'[^A-Za-z0-9]','','g')) <> p_targa
    or coalesce(v_pr.dati_raw #>> '{archiviazione_test,archiviata}','false') = 'true'
    or coalesce(v_pr.dati_raw #>> '{pratica_duplicata,archiviata}','false') = 'true'
  then
    return jsonb_build_object('aggiornato',false,'esito','pratica_non_compatibile',
      'pratica_id',v_pr.id,'numero_pratica',v_pr.numero_pratica,'targa',p_targa);
  end if;

  if exists (
    select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
      and c.telefono_normalizzato = regexp_replace(coalesce(v_pr.telefono,''),'[^0-9]','','g')
  ) or ((coalesce(v_pr.blocco_operatore,false) or coalesce(v_pr.blocco_classificazione_operatore,false))
    and v_pr.stato_commerciale not in ('preventivo_inviato','attesa_cliente'))
  then
    return jsonb_build_object('aggiornato',false,'esito','blocco_operatore',
      'pratica_id',v_pr.id,'numero_pratica',v_pr.numero_pratica,'targa',p_targa);
  end if;

  insert into public.preventivi (
    pratica_id,external_id,stato,file_url,creato_at,inviato_at,note
  ) values (
    v_pr.id,p_external_id,'inviato',p_file_url,p_data_offerta,p_inviato_at,
    'routine_controllo_k | Preventivo riconosciuto dal PDF: ' || p_nome_file ||
    case when p_data_offerta < now() - interval '30 days'
      then ' | preventivo storico: validità commerciale da riconfermare' else '' end
  ) returning id into v_preventivo_id;

  -- Le fasi già avanzate e le decisioni manuali restano preservate.
  if v_pr.stato_commerciale not in ('preventivo_inviato','attesa_cliente') then
    update public.pratiche set
      stato_commerciale = 'preventivo_inviato',
      stato_completezza = 'completa_da_preventivare',
      preventivo_inviato_at = coalesce(preventivo_inviato_at,p_inviato_at),
      nota_incompletezza = case when p_data_offerta < now() - interval '30 days'
        then 'Preventivo storico trovato; validità e condizioni da riconfermare prima di procedere.'
        else null end
    where id = v_pr.id;
  end if;

  insert into public.azioni_operatore (pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  select p.id,'preventivo_emesso_automatico',
    'routine_controllo_k | PDF riconosciuto: ' || p_nome_file,
    jsonb_build_object('stato_commerciale',v_pr.stato_commerciale),
    jsonb_build_object('stato_commerciale',p.stato_commerciale,
      'preventivo_id',v_preventivo_id,'external_id',p_external_id),
    'routine_controllo_k'
  from public.pratiche p where p.id = v_pr.id;

  return jsonb_build_object('aggiornato',true,'esito','preventivo_inviato',
    'preventivo_id',v_preventivo_id,'pratica_id',v_pr.id,
    'numero_pratica',v_pr.numero_pratica,'targa',p_targa);
end;
$fn$;
revoke all on function private.abbina_preventivo_emesso(text,text,text,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function private.abbina_preventivo_emesso(text,text,text,text,timestamptz,timestamptz) to service_role;

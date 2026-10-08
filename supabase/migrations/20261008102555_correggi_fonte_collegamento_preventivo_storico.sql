create or replace function private.riconosci_preventivo_gia_inviato(p_pratica_id uuid)
returns boolean language plpgsql security invoker set search_path = '' as $fn$
declare
  v_pr public.pratiche%rowtype;
  v_prova record;
  v_count integer;
begin
  select * into v_pr from public.pratiche where id=p_pratica_id for update;
  if not found or v_pr.tipo_flusso<>'commerciale'
    or v_pr.stato_commerciale not in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto')
    or v_pr.stato_fatturazione<>'non_applicabile'
    or coalesce(v_pr.blocco_operatore,false) or coalesce(v_pr.blocco_classificazione_operatore,false)
    or length(btrim(coalesce(v_pr.nome_cliente,'')))<5
    or coalesce(v_pr.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
    or coalesce(v_pr.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true'
  then return false; end if;

  with prove as (
    select distinct s.id origine_id,q.id preventivo_id,q.inviato_at,a.value->>'url' url
    from public.pratiche s join public.preventivi q on q.pratica_id=s.id
    cross join lateral jsonb_array_elements(case when jsonb_typeof(s.dati_raw->'messaggi_keplero')='array'
      then s.dati_raw->'messaggi_keplero' else '[]'::jsonb end) m
    cross join lateral jsonb_array_elements(case when jsonb_typeof(v_pr.dati_raw->'allegati_keplero')='array'
      then v_pr.dati_raw->'allegati_keplero' else '[]'::jsonb end) a
    where s.id<>v_pr.id and s.tipo_flusso='commerciale'
      and s.stato_commerciale in ('preventivo_inviato','attesa_cliente')
      and s.stato_fatturazione='non_applicabile' and q.stato='inviato'
      and q.inviato_at<v_pr.created_at
      and upper(regexp_replace(coalesce(s.targa,''),'[^A-Za-z0-9]','','g'))=
        upper(regexp_replace(coalesce(v_pr.targa,''),'[^A-Za-z0-9]','','g'))
      and lower(btrim(s.nome_cliente))=lower(btrim(v_pr.nome_cliente))
      and s.tipo_componente=v_pr.tipo_componente
      and (v_pr.pratica_origine_id is null or v_pr.pratica_origine_id=s.id)
      and m.value->>'sender'='assistant'
      and m.value->>'operator'='keplero'
      and m.value->>'message'='attachment:'||(a.value->>'url')
      and right(upper(a.value->>'url'),length(regexp_replace(v_pr.targa,'[^A-Za-z0-9]','','g'))+4)=
        upper(regexp_replace(v_pr.targa,'[^A-Za-z0-9]','','g')||'.pdf')
      and exists (
        select 1
        from jsonb_array_elements_text(case when jsonb_typeof(s.dati_raw->'dtc_estratti')='array'
          then s.dati_raw->'dtc_estratti' else '[]'::jsonb end) sd(code),
        jsonb_array_elements_text(case when jsonb_typeof(v_pr.dati_raw->'dtc_estratti')='array'
          then v_pr.dati_raw->'dtc_estratti' else '[]'::jsonb end) nd(code)
        where length(substring(sd.code from '^[A-Za-z0-9]+'))>=4
          and upper(substring(sd.code from '^[A-Za-z0-9]+'))=upper(substring(nd.code from '^[A-Za-z0-9]+'))
      )
  ), singola as (select *,count(*) over() candidati from prove)
  select * into v_prova from singola limit 1;
  if not found or v_prova.candidati<>1 then return false; end if;

  update public.pratiche set
    stato_commerciale='preventivo_inviato',preventivo_inviato_at=v_prova.inviato_at,
    pratica_origine_id=v_prova.origine_id,fonte_collegamento_origine='automatico',
    pratica_origine_collegata_at=now(),
    nota_incompletezza=case when v_prova.inviato_at<now()-interval '30 days'
      then 'Preventivo già inviato nella pratica precedente; validità e condizioni da riconfermare.'
      else null end,
    dati_raw=coalesce(dati_raw,'{}'::jsonb)||jsonb_build_object('preventivo_gia_inviato',
      jsonb_build_object('pratica_origine_id',v_prova.origine_id,'preventivo_id',v_prova.preventivo_id,
        'prova_allegato',v_prova.url,'riconosciuto_at',now()))
  where id=v_pr.id;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
  values(v_pr.id,'preventivo_gia_inviato_riconosciuto',
    'Stesso PDF già inviato da K al medesimo cliente: '||v_prova.url||
      case when v_prova.inviato_at<now()-interval '30 days' then ' | validità commerciale da riconfermare' else '' end,
    jsonb_build_object('stato_commerciale',v_pr.stato_commerciale),
    jsonb_build_object('stato_commerciale','preventivo_inviato','pratica_origine_id',v_prova.origine_id,
      'preventivo_id',v_prova.preventivo_id),'routine_controllo_k');
  return true;
end;
$fn$;
revoke all on function private.riconosci_preventivo_gia_inviato(uuid) from public,anon,authenticated;
grant execute on function private.riconosci_preventivo_gia_inviato(uuid) to service_role;

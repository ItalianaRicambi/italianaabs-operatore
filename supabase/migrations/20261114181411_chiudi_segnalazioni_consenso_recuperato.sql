create or replace function private.controlla_ordini_contesto(p_limite integer default 50)
returns jsonb language plpgsql set search_path = '' as $$
declare r record; d jsonb; n integer:=0; errori integer:=0;
begin
 if not pg_try_advisory_xact_lock(7114142026) then return '{"occupato":true}'::jsonb; end if;
 -- Independent reconciliation: include old open quotes, no 30-day cutoff.
 insert into private.controlli_ordini_contesto(pratica_id)
 select p.id from public.pratiche p where p.tipo_flusso='commerciale'
  and p.stato_commerciale in ('preventivo_inviato','attesa_cliente') and p.stato_fatturazione<>'fatturato'
  and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
  and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
  and exists(select 1 from public.offerte_versioni where pratica_id=p.id)
 on conflict do nothing;
 for r in select * from private.controlli_ordini_contesto
  where controllata_at is null or richiesta_at>controllata_at or controllata_at<now()-interval '1 day' or (errore is not null and controllata_at<now()-interval '5 minutes')
  order by coalesce(controllata_at,'-infinity'::timestamptz),richiesta_at
  limit greatest(1,least(p_limite,200)) for update skip locked
 loop
  begin
   d:=private.applica_ordine_contesto(r.pratica_id);
   -- Resolve only the exact originals used as evidence. Other requests and
   -- subsequent logistics messages keep their own independent disposition.
   update public.keplero_esiti_fonti f set stato='applicato',
    codice='ordine_contestuale_registrato',
    motivo='Accettazione e dati fiscali riconciliati: ordine acquisito e da fatturare.',
    errore=null,updated_at=now()
   from public.pratiche p
   where p.id=r.pratica_id and p.stato_commerciale='ordine_acquisito'
    and p.dati_raw ? 'conferma_ordine_contesto'
    and f.fonte='originale' and not f.verificata_operatore
    and f.stato in ('ricevuto','in_attesa','da_verificare')
    and f.codice in ('consenso_non_registrato','risposta_cliente_da_valutare')
    and f.chiave in (
     (p.dati_raw#>>'{conferma_ordine_contesto,sessione}')||':'||(p.dati_raw#>>'{conferma_ordine_contesto,intenzione_id}'),
     (p.dati_raw#>>'{conferma_ordine_contesto,sessione}')||':'||(p.dati_raw#>>'{conferma_ordine_contesto,scelta_id}'),
     (p.dati_raw#>>'{conferma_ordine_contesto,sessione}')||':'||(p.dati_raw#>>'{conferma_ordine_contesto,fiscali_id}')
    );
   if found then perform private.aggiorna_lavoro_pratica_k(r.pratica_id); end if;
   update private.controlli_ordini_contesto set controllata_at=clock_timestamp(),esito=d,errore=null,tentativi=tentativi+1
    where pratica_id=r.pratica_id;
  exception when others then
   errori:=errori+1;
   update private.controlli_ordini_contesto set controllata_at=clock_timestamp(),errore=SQLSTATE||': '||SQLERRM,
    esito=jsonb_build_object('decisione','errore','motivo','errore_controllo'),tentativi=tentativi+1 where pratica_id=r.pratica_id;
   perform private.segnala_ordine_contesto(r.pratica_id,jsonb_build_object('motivo','errore_controllo','codice',SQLSTATE));
  end;
  n:=n+1;
 end loop;
 return jsonb_build_object('controllate',n,'errori',errori);
end $$;


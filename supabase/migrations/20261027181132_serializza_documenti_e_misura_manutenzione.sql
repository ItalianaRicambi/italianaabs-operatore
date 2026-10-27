-- Evita il deadlock osservato il 27/10 tra manutenzione e recupero PDF.
create or replace function private.ritenta_documenti_preventivo()
returns integer language plpgsql security invoker set search_path='' as $$
declare d record; n integer:=0;
begin
 -- Stesso lock del coordinatore: nessuna attesa e nessun lock sulle pratiche se occupato.
 if not pg_catalog.pg_try_advisory_xact_lock(20261015,94749) then return 0; end if;
 for d in select id,prova_invio from public.documenti_preventivo_auto where stato<>'inviato'
 and (ultimo_tentativo_at is null or ultimo_tentativo_at<now()-interval '4 minutes') order by ultimo_tentativo_at nulls first limit 100
 loop
  perform private.abbina_documento_preventivo(d.id);
  if d.prova_invio is not null then perform public.conferma_invio_documento_preventivo(d.id,d.prova_invio); end if;
  n:=n+1;
 end loop;
 return n;
end; $$;
revoke all on function private.ritenta_documenti_preventivo() from public,anon,authenticated;
grant execute on function private.ritenta_documenti_preventivo() to service_role;

create or replace function private.esegui_manutenzione_keplero()
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_finestra timestamptz:=date_bin(interval '5 minutes',now(),'2000-01-01'::timestamptz);
 v_fase text; v_risultati jsonb:='{}'; v_esito jsonb; v_inizio_fase timestamptz;
begin
 if not pg_catalog.pg_try_advisory_xact_lock(20261015,94749) then
  return jsonb_build_object('esito','gia_in_esecuzione'); end if;
 if exists(select 1 from private.keplero_manutenzione_esecuzioni where finestra=v_finestra and completata_at is not null) then
  return jsonb_build_object('esito','finestra_gia_elaborata'); end if;
 insert into private.keplero_manutenzione_esecuzioni(finestra) values(v_finestra)
 on conflict(finestra) do update set iniziata_at=now();
 -- Un solo ordine di esecuzione per tutti i job che scrivono sulle pratiche.
 foreach v_fase in array array['gestisci_code_automatiche','ritenta_preventivi_non_abbinati',
  'recupera_preventivi_gia_inviati','ritenta_letture_offerte','recupera_ordini_contestuali_keplero',
  'recupera_flussi_offerta_rientro','recupera_eventi_keplero_falliti','riprova_prenotazioni_prese','controlla_coerenza_keplero'] loop
  v_inizio_fase:=clock_timestamp();
  begin
   execute format('select to_jsonb(private.%I())',v_fase) into v_esito;
   v_risultati:=v_risultati||jsonb_build_object(v_fase,jsonb_build_object('ok',true,'risultato',v_esito,'durata_ms',round(extract(epoch from (clock_timestamp()-v_inizio_fase))*1000)));
  exception when others then
   v_risultati:=v_risultati||jsonb_build_object(v_fase,jsonb_build_object('ok',false,'errore',sqlerrm,'sqlstate',sqlstate,'durata_ms',round(extract(epoch from (clock_timestamp()-v_inizio_fase))*1000)));
  end;
 end loop;
 update private.keplero_manutenzione_esecuzioni set completata_at=clock_timestamp(),risultati=v_risultati where finestra=v_finestra;
 return v_risultati;
end; $$;
revoke all on function private.esegui_manutenzione_keplero() from public,anon,authenticated;


-- Mantiene la frequenza di cinque minuti; evita la partenza contemporanea.
-- La protezione effettiva resta il lock anche per chiamate manuali e ritardi cron.
do $$
declare v_job_id bigint;
begin
 select jobid into strict v_job_id from cron.job
 where jobname='ritenta-documenti-preventivo'
   and command='select private.ritenta_documenti_preventivo();';
 perform cron.alter_job(v_job_id,schedule:='3-59/5 * * * *');
end; $$;

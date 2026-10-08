-- Due ritardi che attraversano il fine settimana; dati annullati al termine.
begin;
set local role service_role;
do $test$
declare
  v_lunedi timestamptz := (date_trunc('week',now() at time zone 'Europe/Rome') + interval '9 hours') at time zone 'Europe/Rome';
  v_venerdi timestamptz;
  v_data timestamptz;
  v_targa text;
  v_id text;
  v_i integer;
begin
  v_venerdi:=v_lunedi-interval '3 days';
  for v_i in 1..2 loop
    v_targa:='TSTW00'||v_i;
    v_id:='test:preventivi:weekend:'||v_i;
    perform public.registra_preventivo_emesso_auto(v_id,v_targa||'.pdf',v_targa,null,
      v_venerdi-interval '30 minutes',v_venerdi-interval '30 minutes');
    update public.preventivi_emessi_ricevuti
      set ricevuto_at=case when v_i=1 then v_venerdi else v_lunedi-interval '30 minutes' end,
        ultimo_tentativo_at=now()-interval '5 minutes'
      where external_id=v_id;
    insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,created_at)
    values(v_targa,'Test weekend rollback','commerciale','raccolta_dati',v_lunedi);
    perform private.ritenta_preventivi_non_abbinati();
    if not exists(select 1 from public.pratiche where targa=v_targa and stato_commerciale='preventivo_inviato')
      or not exists(select 1 from public.preventivi_emessi_ricevuti where external_id=v_id and risolto_at is not null)
    then raise exception 'Conteggio weekend attivo nel caso %',v_i; end if;
  end loop;
end;
$test$;
reset role;
rollback;

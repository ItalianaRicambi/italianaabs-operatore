create trigger trg_zzzz_valida_dati_fatturazione
before insert or update on public.pratiche
for each row execute function private.valida_dati_fatturazione();

create trigger trg_rivalida_pratiche_cliente_fiscale
after update of denominazione,indirizzo_fatturazione,cap,comune,partita_iva,codice_fiscale,
  dati_fiscali_completi,campi_amministrativi_mancanti,da_verificare,possibile_duplicato on public.clienti
for each row execute function private.rivalida_pratiche_cliente_fiscale();

-- La view esistente conserva colonne, permessi e dipendenze.
do $view$
declare definizione text; precedente text;
begin
  definizione:=pg_get_viewdef('public.v_coda_operatore'::regclass,true);
  precedente:='WHEN stato_commerciale = ''ordine_acquisito''::stato_commerciale AND stato_fatturazione = ''da_fatturare''::stato_fatturazione THEN ''ORDINE ACQUISITO - DA FATTURARE''::text';
  if position(precedente in definizione)=0 then raise exception 'Coda fatturazione inattesa: controllare la view prima della migrazione'; end if;
  definizione:=replace(definizione,precedente,
    'WHEN stato_commerciale = ''ordine_acquisito''::stato_commerciale AND stato_fatturazione = ''da_fatturare''::stato_fatturazione AND stato_amministrativo = ''pronto_fatturazione''::stato_amministrativo AND cliente_id IS NOT NULL THEN ''ORDINE ACQUISITO - DA FATTURARE''::text
     WHEN stato_commerciale = ''ordine_acquisito''::stato_commerciale AND stato_fatturazione = ''da_fatturare''::stato_fatturazione THEN ''ORDINE ACQUISITO - IN ATTESA DATI CLIENTE''::text');
  definizione:=replace(definizione,
    'WHEN stato_commerciale = ''ordine_acquisito''::stato_commerciale AND stato_fatturazione = ''da_fatturare''::stato_fatturazione THEN 2',
    'WHEN stato_commerciale = ''ordine_acquisito''::stato_commerciale AND stato_fatturazione = ''da_fatturare''::stato_fatturazione AND stato_amministrativo = ''pronto_fatturazione''::stato_amministrativo AND cliente_id IS NOT NULL THEN 2
     WHEN stato_commerciale = ''ordine_acquisito''::stato_commerciale AND stato_fatturazione = ''da_fatturare''::stato_fatturazione THEN 4');
  perform set_config('search_path','public,pg_temp',true);
  execute 'CREATE OR REPLACE VIEW public.v_coda_operatore AS '||definizione;
end;
$view$;

-- Riallinea gli ordini pendenti: nessun ordine o fattura viene annullato.
update public.pratiche set stato_amministrativo=stato_amministrativo
where stato_fatturazione='da_fatturare';
do $backfill$
declare p uuid;
begin
  for p in select id from public.pratiche where stato_fatturazione='da_fatturare' loop
    perform public.prepara_richiesta_dati_amministrativi(p);
  end loop;
end;
$backfill$;

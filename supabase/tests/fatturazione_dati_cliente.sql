-- Esegue i percorsi reali con il ruolo HTTP, senza lasciare dati di prova.
begin;
set local role service_role;
do $test$
declare
  p uuid; c uuid; q uuid; esito jsonb; bloccata boolean;
begin
  insert into public.pratiche(nome_cliente,targa,tipo_flusso,stato_commerciale,
    stato_fatturazione,ordine_acquisito_at)
  values('Test fatturazione rollback','TSTF001','commerciale','ordine_acquisito','da_fatturare',now()) returning id into p;
  update public.pratiche set stato_amministrativo='pronto_fatturazione' where id=p;
  if not exists(select 1 from public.pratiche where id=p and stato_amministrativo='dati_mancanti')
     or exists(select 1 from public.v_coda_operatore where id=p and coda='ORDINE ACQUISITO - DA FATTURARE') then
    raise exception 'Senza cliente collegato la pratica risulta pronta'; end if;
  bloccata:=false;
  begin
    update public.pratiche set stato_fatturazione='fatturato' where id=p;
  exception when raise_exception then bloccata:=true; end;
  if not bloccata then raise exception 'Fattura permessa senza dati cliente'; end if;

  perform public.gestisci_sospensione_fatturazione(p,true,'Operatore 1');
  bloccata:=false;
  begin
    perform public.gestisci_sospensione_fatturazione(p,false,'Operatore 1');
  exception when raise_exception then bloccata:=true; end;
  if not bloccata then raise exception 'Rilascio permesso senza cliente'; end if;
  esito:=public.crea_e_collega_cliente_pratica(p,'Test fiscale rollback','Via Test 1','Novara','28100',
    p_codice_fiscale=>'TSTFSC80A01F952A',p_email=>'fatturazione@test.invalid');
  c:=(esito->>'cliente_id')::uuid;
  if exists(select 1 from public.pratiche where id=p and stato_amministrativo='pronto_fatturazione') then
    raise exception 'La creazione del cliente ha annullato la sospensione'; end if;
  update public.pratiche set dati_raw='{"ordine_confermato":true,"sospensione_fatturazione_operatore":{"attiva":false}}',
    stato_amministrativo='pronto_fatturazione' where id=p;
  perform public.valuta_collegamento_cliente(p);
  perform public.prepara_richiesta_dati_amministrativi(p);
  if not exists(select 1 from public.pratiche where id=p
    and dati_raw#>>'{sospensione_fatturazione_operatore,attiva}'='true'
    and stato_amministrativo='dati_mancanti' and stato_commerciale='ordine_acquisito') then
    raise exception 'Un payload o una rivalutazione ha cancellato la sospensione'; end if;
  perform public.gestisci_sospensione_fatturazione(p,false,'Operatore 1');
  if not exists(select 1 from public.v_coda_operatore where id=p and coda='ORDINE ACQUISITO - DA FATTURARE') then
    raise exception 'Cliente completo confermato non abilitato'; end if;

  -- Un flag "completo" obsoleto non prevale sull'assenza dell'indirizzo.
  update public.clienti set indirizzo_fatturazione=null,dati_fiscali_completi=true,
    campi_amministrativi_mancanti='{}'::text[] where id=c;
  if exists(select 1 from public.pratiche where id=p and stato_amministrativo='pronto_fatturazione')
    or not exists(select 1 from public.pratiche where id=p and 'indirizzo_fatturazione'=any(campi_richiesta_amministrativa)) then
    raise exception 'Dati rimossi non hanno sospeso la fatturazione e preparato i mancanti'; end if;
  bloccata:=false;
  begin
    perform public.gestisci_sospensione_fatturazione(p,false,'Operatore 1');
  exception when raise_exception then bloccata:=true; end;
  if not bloccata then raise exception 'Rilascio permesso con flag completo ma dati assenti'; end if;
  update public.clienti set indirizzo_fatturazione='Via Test 1' where id=c;
  if not exists(select 1 from public.pratiche where id=p and stato_amministrativo='pronto_fatturazione') then
    raise exception 'Anagrafica completata non rivalutata'; end if;
  update public.clienti set possibile_duplicato=true where id=c;
  if exists(select 1 from public.pratiche where id=p and stato_amministrativo='pronto_fatturazione') then
    raise exception 'Anagrafica ambigua ammessa alla fatturazione'; end if;
  update public.clienti set possibile_duplicato=false where id=c;
  update public.pratiche set stato_fatturazione='fatturato',data_fattura=now() where id=p;
  update public.pratiche set cliente_id=null,dati_raw='{"evento_storico":true}' where id=p;
  if not exists(select 1 from public.pratiche where id=p and stato_fatturazione='fatturato') then
    raise exception 'Fattura storica alterata da successivo evento'; end if;

  -- La domanda letterale prevale sulla conferma falsa anche nella RPC.
  insert into public.pratiche(nome_cliente,targa,tipo_flusso,stato_commerciale,preventivo_inviato_at,
    dati_raw) values('Test domanda rollback','TSTF002','commerciale','preventivo_inviato',now()-interval '1 hour',
    '{"ultimo_messaggio_cliente":"Come accetto l’offerta?","ordine_confermato":true}') returning id into q;
  insert into public.keplero_live_links(external_key,pratica_id) values('test:fatturazione:domanda',q);
  esito:=public.conferma_ordine_da_keplero(q,'test:fatturazione:domanda','Il cliente ha accettato il preventivo');
  if esito->>'motivo'<>'domanda_su_accettazione_non_e_ordine'
    or exists(select 1 from public.pratiche where id=q and stato_commerciale='ordine_acquisito') then
    raise exception 'Domanda scambiata per ordine: %',esito; end if;
  if not private.domanda_su_accettazione('Ok..come fare per procedere')
    or private.domanda_su_accettazione('Accetto il preventivo. Come dobbiamo procedere?') then
    raise exception 'Domanda e conferma reale non distinte'; end if;
end;
$test$;
reset role;
rollback;

-- Eseguire dopo la migrazione. Fixture isolate, rollback integrale.
begin;
set local role service_role;
do $test$
declare p uuid; p2 uuid; d jsonb; v jsonb; r jsonb; prima jsonb; testo text; n integer;
begin
  testo:=E'Fattura nr. TEST-RICONCILIA\nP.IVA: 02439670031\nDocumento originale sintetico per test di regressione, non destinato al cliente.';
  d:=jsonb_build_object('verificata',true,'tipo','fattura','numero','TEST-RICONCILIA','data',current_date,
    'targa','TRC0001','importo',447,'testo_documento',testo,'impronta',encode(sha256(convert_to(testo,'UTF8')),'hex'),
    'fonte_id','drive:test','documento_url','https://drive.google.com/file/d/test/view',
    'cliente',jsonb_build_object('denominazione','Test riconciliazione fattura','indirizzo_fatturazione','Via Test 12',
      'comune','Roma','cap','00123','paese','IT','codice_fiscale','TSTFSC82A01F952A'));
  v:='{"episodio_verificato":true,"motivazione":"Fixture: verificati originale, destinatario, targa, veicolo e cronologia.","stato_commerciale_atteso":"preventivo_inviato","stato_fatturazione_atteso":"non_applicabile"}';
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,stato_fatturazione,
    blocco_classificazione_operatore,campi_bloccati_operatore)
    values('TRC0001','Test','commerciale','preventivo_inviato','non_applicabile',true,array['targa','descrizione_guasto']) returning id into p;
  select to_jsonb(x) into prima from public.pratiche x where id=p;
  -- Pro-forma, prova assente, impronta errata, data storica e snapshot obsoleto non autorizzano il recupero.
  for n in 1..5 loop
    begin
      perform public.riconcilia_fattura_episodio_verificato(p,
        d||case n when 1 then '{"tipo":"proforma"}'::jsonb when 3 then '{"impronta":"errata"}'::jsonb
          when 4 then jsonb_build_object('data',current_date-1) else '{}'::jsonb end,
        v||case n when 2 then '{"episodio_verificato":false}'::jsonb when 5 then '{"stato_commerciale_atteso":"ordine_acquisito"}'::jsonb else '{}'::jsonb end);
      raise exception 'TEST: input non valido accettato';
    exception when others then if sqlerrm like 'TEST:%' then raise;end if; end;
    if (select to_jsonb(x) from public.pratiche x where id=p) is distinct from prima then raise exception 'TEST: rollback non completo';end if;
  end loop;
  -- Un secondo episodio attivo rende l'abbinamento ambiguo anche con stessa targa.
  insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale) values('TRC0001','Altro episodio','commerciale','preventivo_inviato') returning id into p2;
  begin
    perform public.riconcilia_fattura_episodio_verificato(p,d,v);
    raise exception 'TEST: episodi ambigui accettati';
  exception when others then if sqlerrm<>'Più episodi per la stessa targa: verifica manuale richiesta' then raise;end if;end;
  -- Si cambia SOLO la targa della fixture, non si archivia una pratica reale.
  update public.pratiche set targa='TRC0002' where id=p2;
  r:=public.riconcilia_fattura_episodio_verificato(p,d,v);
  if r->>'esito'<>'fatturata' or not exists(select 1 from public.pratiche where id=p and stato_fatturazione='fatturato'
    and stato_commerciale='ordine_acquisito' and blocco_classificazione_operatore and campi_bloccati_operatore=array['targa','descrizione_guasto']) then
    raise exception 'TEST: recupero o protezioni errati';end if;
  if not exists(select 1 from public.azioni_operatore where pratica_id=p and azione='fattura_episodio_riconciliata'
    and stato_prima->>'stato_commerciale'='preventivo_inviato') then raise exception 'TEST: audit assente';end if;
  r:=public.riconcilia_fattura_episodio_verificato(p,d,v);
  if r->>'esito'<>'gia_registrato' or (select count(*) from public.documenti_amministrativi where pratica_id=p)<>1 then
    raise exception 'TEST: replay non idempotente';end if;
  -- Simula aggiornamenti tardivi del riconoscitore e un nuovo evento ordine.
  update public.pratiche set stato_fatturazione='da_fatturare',stato_commerciale='preventivo_inviato',data_fattura=null where id=p;
  update public.pratiche set stato_fatturazione='non_applicabile' where id=p;
  if not exists(select 1 from public.pratiche where id=p and stato_fatturazione='fatturato' and stato_commerciale='ordine_acquisito'
    and data_fattura is not null) then raise exception 'TEST: fattura riaperta';end if;
  -- Blocco esplicito, sospensione e conflitto fiscale restano bloccanti.
  d:=d||'{"targa":"TRC0002","numero":"TEST-RICONCILIA-2"}';
  update public.pratiche set blocco_operatore=true where id=p2;
  begin
    perform public.riconcilia_fattura_episodio_verificato(p2,d,v);
    raise exception 'TEST: blocco operatore ignorato';
  exception when others then if sqlerrm<>'Pratica o blocco operatore da verificare' then raise;end if;end;
  begin
    update public.pratiche set blocco_operatore=false,stato_commerciale='ordine_acquisito',stato_fatturazione='da_fatturare' where id=p2;
    perform public.gestisci_sospensione_fatturazione(p2,true,'Manutenzione autorizzata');
    perform public.riconcilia_fattura_episodio_verificato(p2,d,
      v||'{"stato_commerciale_atteso":"ordine_acquisito","stato_fatturazione_atteso":"da_fatturare"}'::jsonb);
    raise exception 'TEST: sospensione operatore ignorata';
  exception when others then if sqlerrm<>'Pratica o blocco operatore da verificare' then raise;end if;end;
  -- Un errore della registrazione interna, dopo la promozione commerciale,
  -- deve annullare anche promozione, cliente, documento e apertura evasione.
  update public.pratiche set blocco_operatore=false,dati_raw='{}' where id=p2;
  select to_jsonb(x) into prima from public.pratiche x where id=p2;
  begin
    perform public.riconcilia_fattura_episodio_verificato(p2,d||'{"cliente":{}}'::jsonb,v);
    raise exception 'TEST: destinatario incompleto accettato';
  exception when others then if sqlerrm like 'TEST:%' then raise;end if;end;
  if (select to_jsonb(x) from public.pratiche x where id=p2) is distinct from prima
    or exists(select 1 from public.evasioni_pratiche where pratica_id=p2)
    or exists(select 1 from public.azioni_operatore where pratica_id=p2 and azione='fattura_episodio_riconciliata') then
    raise exception 'TEST: errore interno non atomico';end if;
  update public.pratiche set blocco_operatore=false,dati_raw='{"anagrafica_estratta":{"codice_fiscale":"TSTFSC83A01F952A"}}' where id=p2;
  begin
    perform public.riconcilia_fattura_episodio_verificato(p2,d,v);
    raise exception 'TEST: discordanza fiscale ignorata';
  exception when others then if sqlerrm<>'Identificativi fiscali acquisiti discordanti dal documento' then raise;end if;end;
  if exists(select 1 from public.documenti_amministrativi where pratica_id=p2) then raise exception 'TEST: documento parziale';end if;
end;
$test$;
rollback;

begin;
do $test$
declare p uuid; a uuid; c uuid; q uuid; b uuid; r jsonb; dati jsonb; t text; code text; i int:=0;
 d date:=(now() at time zone 'Europe/Rome')::date; check_at timestamptz:=now();
begin
 if has_table_privilege('anon','public.esiti_prese_gls','select') or has_table_privilege('authenticated','public.esiti_prese_gls','insert')
  or has_function_privilege('anon','public.registra_esito_presa_gls(jsonb,uuid,text)','execute') then raise exception 'Esiti GLS esposti'; end if;
 foreach t in array array['ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_programma_scambio','ritiro_altro_reso'] loop
  i:=i+1; code:='P3 977700000'||i; c:=null;
  insert into public.pratiche(targa,nome_cliente,stato_commerciale,stato_logistica)
   values('GLSTST'||i,'Mario Rossi','ordine_acquisito',case when t='ritiro_lavorazione' then 'ritiro_programmato'::public.stato_logistica else 'ritirato'::public.stato_logistica end) returning id into p;
  if t='ritiro_verifica_garanzia' then
   insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evidenza,stato,aperta_at) values(p,p,'Test garanzia','ritiro_prenotato',now()-interval '2 days') returning id into c;
  end if;
  insert into public.attivita_operatore(pratica_id,pratica_origine_id,assistenza_rientro_id,tipo,evidenza,richiesta_at,stato,riferimento_ritiro,data_ritiro_prevista)
   values(p,p,c,t,'Test esiti GLS',now()-interval '2 days','programmata',code,d+1) returning id into a;
  dati:=jsonb_build_object('fonte','api_gls','fonte_id','test:gls:prenotata:'||i,'contratto','6178','riferimento',replace(code,' ',''),
   'data_ritiro',d+1,'mittente','Rossi Mario - Via Prova','destinatario',case when t like '%scambio' or t='ritiro_altro_reso' then 'Italiana Ricambi - Oleggio' else 'ALB Meccatronica' end,
   'verificata_at',check_at-interval '1 hour','testo','Dettaglio GLS verificato','eventi',jsonb_build_array(jsonb_build_object('at',now()-interval '2 hours','stato','Ritiro preso in carico','luogo','Test','note','')));
  r:=public.registra_esito_presa_gls(dati);
  if r->>'esito'<>'abbinata' or r->>'stato'<>'prenotata' or (select stato from public.attivita_operatore where id=a)<>'programmata' then raise exception 'Presa in carico confusa con ritiro fisico: %',r; end if;
  r:=public.registra_esito_presa_gls(dati);
  if (select count(*) from public.azioni_operatore where pratica_id=p and azione='esito_presa_gls_registrato')<>1 then raise exception 'Retry duplicato'; end if;
  -- Data riprogrammata richiede verifica, non sovrascrive la prenotazione.
  r:=public.registra_esito_presa_gls(dati||jsonb_build_object('fonte_id','test:gls:cambio-data:'||i,'data_ritiro',d+2,'verificata_at',check_at-interval '50 minutes'));
  if r->>'esito'<>'data_da_verificare' or (select data_ritiro_prevista from public.attivita_operatore where id=a)<>d+1 then raise exception 'Cambio data non protetto'; end if;
  -- Rimette la data odierna con una nuova prenotazione manuale (tutti i canali).
  perform public.gestisci_ritiro_assistenza(p,a,c,'programma',p_riferimento=>code,p_data_ritiro=>d,p_operatore=>'Test operatore');
  if (select metadati ? 'gls' from public.attivita_operatore where id=a) then raise exception 'Nuova prenotazione eredita vecchio esito'; end if;
  dati:=dati||jsonb_build_object('fonte_id','test:gls:merce-assente:'||i,'data_ritiro',d,'verificata_at',check_at-interval '40 minutes',
   'eventi',jsonb_build_array(jsonb_build_object('at',now()-interval '45 minutes','stato','Merce non presente. In attesa di istruzioni dal Cliente per effettuare il ritiro.','luogo','Test','note','')));
  r:=public.registra_esito_presa_gls(dati);
  if r->>'stato'<>'non_effettuata' or (select stato from public.attivita_operatore where id=a)<>'programmata' then raise exception 'Mancato ritiro non gestito'; end if;
  -- Il controllo vecchio non può sovrascrivere un esito più recente.
  r:=public.registra_esito_presa_gls(dati||jsonb_build_object('fonte_id','test:gls:vecchio:'||i,'verificata_at',check_at-interval '2 hours',
   'eventi',jsonb_build_array(jsonb_build_object('at',now()-interval '3 hours','stato','Ritiro Inserito','luogo','Test','note',''))));
  if r->>'esito'<>'controllo_precedente' then raise exception 'Controllo vecchio applicato'; end if;
  dati:=dati||jsonb_build_object('fonte_id','test:gls:effettuata:'||i,'verificata_at',check_at,'numero_spedizione','MT 260099991',
   'eventi',jsonb_build_array(jsonb_build_object('at',now()-interval '15 minutes','stato','Spedizione creata','luogo','Test','note',''),
    jsonb_build_object('at',now()-interval '20 minutes','stato','Ritiro Effettuato','luogo','Test','note','')));
  r:=public.registra_esito_presa_gls(dati);
  if r->>'stato'<>'effettuata' or (select stato from public.attivita_operatore where id=a)<>'completata' then raise exception 'Ritiro fisico non avanzato'; end if;
  if (select stato_commerciale from public.pratiche where id=p)<>'ordine_acquisito' then raise exception 'Stato commerciale alterato'; end if;
  if c is not null and not exists(select 1 from public.assistenze_rientri where id=c and stato='ritiro_prenotato' and chiusa_at is null) then raise exception 'Garanzia ricevuta/chiusa dal ritiro'; end if;
  r:=public.registra_esito_presa_gls(dati||jsonb_build_object('fonte_id','test:gls:regressione:'||i,'verificata_at',check_at,
   'eventi',jsonb_build_array(jsonb_build_object('at',now()-interval '30 minutes','stato','Ritiro Annullato','luogo','Test','note',''))));
  if r->>'esito'<>'ritiro_chiuso_operatore' or (select stato from public.attivita_operatore where id=a)<>'completata' then raise exception 'Ritiro completato regredito'; end if;
 end loop;
 -- Codice nuovo: il laboratorio non è sufficiente per scegliere una pratica.
 dati:=dati||jsonb_build_object('fonte_id','test:gls:senza-codice','riferimento','P3 9777000099');
 r:=public.registra_esito_presa_gls(dati);
 if r->>'esito'<>'da_abbinare' then raise exception 'Codice senza pratica scelto arbitrariamente'; end if;
 -- Una presa passata senza esito, la creazione spedizione e gli stati sconosciuti richiedono verifica.
 foreach t in array array['Ritiro Inserito','Spedizione creata','Ritiro stato non riconosciuto'] loop
  r:=public.registra_esito_presa_gls(dati||jsonb_build_object('fonte_id','test:gls:ignoto:'||t,'data_ritiro',d-1,
   'eventi',jsonb_build_array(jsonb_build_object('at',now()-interval '2 days','stato',t,'luogo','Test','note',''))));
  if r->>'stato'<>'da_verificare' then raise exception 'Assenza di esito inventata'; end if;
 end loop;
 -- Codice duplicato e cliente incoerente si fermano nella coda.
 insert into public.pratiche(nome_cliente) values('Mario Rossi') returning id into p;
 insert into public.pratiche(nome_cliente) values('Mario Rossi') returning id into q;
 insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza,richiesta_at,riferimento_ritiro,data_ritiro_prevista)
  values(p,p,'ritiro_lavorazione','Test ambigua',now()-interval '1 day','P3 9777000088',d) returning id into a;
 insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza,richiesta_at,riferimento_ritiro,data_ritiro_prevista)
  values(q,q,'ritiro_lavorazione','Test ambigua',now()-interval '1 day','P3 9777000088',d) returning id into b;
 dati:=dati||jsonb_build_object('fonte_id','test:gls:ambigua','riferimento','P3 9777000088');
 r:=public.registra_esito_presa_gls(dati);
 if r->>'esito'<>'abbinamento_ambiguo' then raise exception 'Codice ambiguo applicato'; end if;
 r:=public.registra_esito_presa_gls(dati,a,'Operatore test');
 if r->>'esito'<>'abbinata' or (select stato from public.attivita_operatore where id=b)='completata' then raise exception 'Abbinamento manuale non isolato'; end if;
 begin perform public.registra_esito_presa_gls(dati,b,'Operatore test'); raise exception 'Riutilizzo consentito'; exception when others then if sqlerrm='Riutilizzo consentito' then raise; end if; end;
 dati:=dati||jsonb_build_object('fonte_id','test:gls:cliente-diverso','mittente','Cliente diverso');
 update public.attivita_operatore set riferimento_ritiro='P3 9777000089' where id=b;
 r:=public.registra_esito_presa_gls(dati||jsonb_build_object('riferimento','P3 9777000089'));
 if r->>'esito'<>'mittente_da_verificare' then raise exception 'Cliente incoerente applicato'; end if;
end $test$;
rollback;

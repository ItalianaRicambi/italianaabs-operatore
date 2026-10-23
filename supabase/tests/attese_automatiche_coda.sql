-- L'arretrato resta visibile senza trasformare ogni ingresso in una verifica manuale.
begin;
set local role service_role;
do $test$
declare p uuid; s uuid:=gen_random_uuid(); v bigint; r jsonb; q uuid;
begin
 if has_table_privilege('anon','public.keplero_lavori_pratiche_elenco','select')
  or has_function_privilege('authenticated','public.stato_esiti_commerciali_k()','execute') then
  raise exception 'Coda o conteggi esposti';
 end if;
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale,preventivo_inviato_at)
 values('ZZ801AA','Test attese rollback','commerciale','preventivo_inviato',now()-interval '1 hour') returning id into p;
 insert into public.keplero_esiti_fonti(fonte,chiave,pratica_id,data_fonte,impronta)
 values('live','test_attese_'||p,p,now(),repeat('a',64));
 perform private.aggiorna_lavoro_pratica_k(p);
 if not exists(select 1 from public.keplero_lavori_pratiche_elenco where pratica_id=p and attesa_automazione) then
  raise exception 'Ingresso non valutato presentato come verifica manuale';
 end if;
 -- L'anomalia valutata cambia subito la vista, senza cancellare alcun ingresso.
 update public.keplero_esiti_fonti set stato='da_verificare',codice='consenso_non_registrato' where pratica_id=p;
 if not exists(select 1 from public.keplero_lavori_pratiche_elenco where pratica_id=p and not attesa_automazione) then
  raise exception 'Conferma da verificare nascosta nelle attese';
 end if;
 update public.keplero_esiti_fonti set stato='ricevuto',codice='in_elaborazione' where pratica_id=p;
 -- Una ragione di lavoro futura e sconosciuta deve rimanere operativa.
 update public.keplero_lavori_pratiche set motivi=motivi||'{"nuova_azione_operatore":true}'::jsonb where pratica_id=p;
 if exists(select 1 from public.keplero_lavori_pratiche_elenco where pratica_id=p and attesa_automazione) then
  raise exception 'Motivo sconosciuto trattato come arretrato';
 end if;
 perform private.aggiorna_lavoro_pratica_k(p);
 update public.keplero_lavori_pratiche set priorita=0 where pratica_id=p;
 if exists(select 1 from public.keplero_lavori_pratiche_elenco where pratica_id=p and attesa_automazione) then
  raise exception 'Scheda prioritaria nascosta';
 end if;
 perform private.aggiorna_lavoro_pratica_k(p);
 select versione into v from public.keplero_lavori_pratiche where pratica_id=p;
 perform public.prendi_in_carico_lavoro_k('pratica:'||p,'Operatore 1',v);
 if exists(select 1 from public.keplero_lavori_pratiche_elenco where pratica_id=p and attesa_automazione) then
  raise exception 'Presa in carico non rende operativa la scheda';
 end if;
 -- Una richiesta commerciale resta subito lavorabile, anche senza diagnosi completa.
 insert into public.pratiche(targa,nome_cliente,tipo_flusso,stato_commerciale)
 values('ZZ802AA','Test richiesta rollback','commerciale','raccolta_dati') returning id into q;
 if not exists(select 1 from public.keplero_lavori_pratiche_elenco where pratica_id=q and not attesa_automazione and stato<>'risolta') then
  raise exception 'Richiesta da preventivare nascosta';
 end if;
 -- Lo stesso vale prima della creazione della pratica o dell'acquisizione della targa.
 r:=public.conserva_richiesta_senza_pratica_k('conversation:'||s,s,'{"ultimo_messaggio_cliente":"Richiedo preventivo senza targa"}');
 if not exists(select 1 from public.keplero_lavori_pratiche_elenco where chiave='chat:'||s and not attesa_automazione) then
  raise exception 'Richiesta senza targa nascosta';
 end if;
 -- Un originale non ancora interpretato resta consultabile nella vista delle attese.
 s:=gen_random_uuid();
 insert into public.keplero_esiti_fonti(fonte,chiave,sessione,data_fonte,impronta)
 values('originale',s||':test',s,now(),repeat('b',64));
 perform private.aggiorna_lavori_senza_pratica_k();
 if not exists(select 1 from public.keplero_lavori_pratiche_elenco where chiave='chat:'||s and attesa_automazione) then
  raise exception 'Originale in attesa perso';
 end if;
 update public.keplero_esiti_fonti set stato='in_attesa',codice='da_associare' where sessione=s;
 if not exists(select 1 from public.keplero_lavori_pratiche_elenco where chiave='chat:'||s and not attesa_automazione) then
  raise exception 'Associazione gia valutata non resa lavorabile';
 end if;
 r:=public.stato_esiti_commerciali_k();
 if (r->>'lavori_totali')::bigint <> (r->>'lavori_aperti')::bigint+(r->>'lavori_in_attesa_automazione')::bigint then
  raise exception 'Conteggi della coda incoerenti';
 end if;
end; $test$;
reset role;
rollback;
select 'ok: attese consultabili, anomalie, priorita, presa in carico, richieste incomplete e senza targa, nuovi motivi e conteggi' verifica;

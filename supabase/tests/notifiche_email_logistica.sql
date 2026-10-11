-- Dati sintetici e configurazione solo transazionale: nessuna email inviata.
begin;
do $test$
declare p uuid; a uuid; nid uuid; n jsonb; tipo text; r jsonb; cliente uuid; ticket text;
begin
 if has_function_privilege('anon','public.configurazione_email_logistica(boolean)','execute')
  or has_function_privilege('authenticated','public.salva_smtp_logistica(text,text,text)','execute')
  or has_function_privilege('anon','public.prendi_email_logistica(uuid)','execute')
  or has_table_privilege('authenticated','public.notifiche_email_logistica','select') then raise exception 'Accesso email non protetto'; end if;
 ticket:=gen_random_uuid()::text||gen_random_uuid()::text;
 insert into private.ticket_worker_email_logistica(impronta,scade_at) values(encode(sha256(convert_to(ticket,'UTF8')),'hex'),now()+interval '2 minutes');
 if not public.autorizza_worker_email_logistica(ticket) then raise exception 'Ticket worker rifiutato'; end if;
 if public.autorizza_worker_email_logistica(ticket) then raise exception 'Ticket worker riutilizzato'; end if;
 insert into private.ticket_worker_email_logistica(impronta,scade_at) values(encode(sha256(convert_to(ticket,'UTF8')),'hex'),now()-interval '1 minute');
 if public.autorizza_worker_email_logistica(ticket) then raise exception 'Ticket worker scaduto accettato'; end if;
 update private.config_email_logistica set abilitata=true,password_id=gen_random_uuid() where id;
 foreach tipo in array array['ritiro_lavorazione','ritiro_verifica_garanzia','ritiro_programma_scambio'] loop
  insert into public.pratiche(nome_cliente,email_cliente,targa) values('Test email logistica','logistica@test.invalid','TSTMAIL') returning id into p;
  insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza)
  values(p,p,tipo,'Collaudo interno notifiche') returning id into a;
  if exists(select 1 from public.notifiche_email_logistica where attivita_id=a) then raise exception 'Richiesta non confermata accodata'; end if;
  update public.attivita_operatore set stato='programmata',riferimento_ritiro='P3 9260993000',data_ritiro_prevista=current_date+2 where id=a;
  if exists(select 1 from public.notifiche_email_logistica where attivita_id=a) then raise exception 'Prenotazione non confermata accodata'; end if;
  update public.attivita_operatore set metadati=metadati||'{"prenotazione_confermata":true}'::jsonb where id=a;
  select id into nid from public.notifiche_email_logistica where attivita_id=a;
  update public.attivita_operatore set nota='Modifica senza nuova prenotazione',updated_at=now() where id=a;
  if (select count(*) from public.notifiche_email_logistica where attivita_id=a)<>1 then raise exception 'Duplicato su aggiornamento irrilevante'; end if;
  n:=public.prendi_email_logistica(nid);
  if n->>'destinatario'<>'logistica@test.invalid' or n->>'revisione'<>'1' then raise exception 'Claim incompleto %',n; end if;
  if public.prendi_email_logistica(nid) is not null then raise exception 'Due worker hanno preso lo stesso avviso'; end if;
  if public.esito_email_logistica(nid,gen_random_uuid(),'inviata') then raise exception 'Token sbagliato accettato'; end if;
  if not public.esito_email_logistica(nid,(n->>'token')::uuid,'inviata') then raise exception 'Esito non registrato'; end if;
  if public.prendi_email_logistica(nid) is not null then raise exception 'Email inviata ripresa'; end if;
  update public.attivita_operatore set data_ritiro_prevista=current_date+3 where id=a;
  select id into nid from public.notifiche_email_logistica where attivita_id=a and revisione=2;
  update public.attivita_operatore set data_ritiro_prevista=current_date+4 where id=a;
  if (select stato from public.notifiche_email_logistica where id=nid)<>'annullata' then raise exception 'Avviso vecchio non annullato'; end if;
  select id into nid from public.notifiche_email_logistica where attivita_id=a and revisione=3;
  update public.pratiche set email_cliente=null where id=p;
  n:=public.prendi_email_logistica(nid);
  if n is not null or (select stato from public.notifiche_email_logistica where id=nid)<>'da_verificare' then raise exception 'Email mancante inviata'; end if;
  update public.pratiche set email_cliente='logistica@test.invalid' where id=p;
  r:=public.rivaluta_email_logistica(nid,'Operatore test');
  if r->>'stato'<>'in_attesa' then raise exception 'Dati corretti non rimessi in coda'; end if;
  n:=public.prendi_email_logistica(nid);
  update public.notifiche_email_logistica set avviata_at=now()-interval '11 minutes' where id=nid;
  r:=public.prendi_email_logistica(nid);
  if r is not null or (select stato from public.notifiche_email_logistica where id=nid)<>'esito_incerto' then raise exception 'Crash ritentato automaticamente'; end if;
  begin
   perform public.rivaluta_email_logistica(nid,'Operatore test'); raise exception 'Esito incerto ripetuto';
  exception when others then if sqlerrm='Esito incerto ripetuto' then raise; end if; end;
  -- Esito tardivo col token giusto resta registrabile.
  if not public.esito_email_logistica(nid,(n->>'token')::uuid,'inviata') then raise exception 'Esito tardivo perso'; end if;
  update public.attivita_operatore set data_ritiro_prevista=current_date+5 where id=a;
  select id into nid from public.notifiche_email_logistica where attivita_id=a and revisione=4;
  update public.attivita_operatore set stato='annullata' where id=a;
  if (select stato from public.notifiche_email_logistica where id=nid)<>'annullata' then raise exception 'Ritiro annullato invia avviso'; end if;
 end loop;
 -- Una correzione non supera un esito incerto della stessa presa.
 update public.attivita_operatore set stato='programmata' where id=a;
 select id into nid from public.notifiche_email_logistica where attivita_id=a and revisione=5;
 n:=public.prendi_email_logistica(nid);
 perform public.esito_email_logistica(nid,(n->>'token')::uuid,'esito_incerto');
 update public.attivita_operatore set data_ritiro_prevista=current_date+6 where id=a;
 select id into cliente from public.notifiche_email_logistica where attivita_id=a and revisione=6;
 r:=public.prendi_email_logistica(cliente);
 if r is not null or (select stato from public.notifiche_email_logistica where id=cliente)<>'da_verificare' then raise exception 'Correzione supera esito incerto'; end if;
 perform public.risolvi_email_logistica(nid,'errore','Riscontro sintetico del servizio di posta: messaggio non accettato.','Operatore test');
 if public.esito_email_logistica(nid,(n->>'token')::uuid,'inviata') then raise exception 'Esito tardivo sovrascrive verifica operatore'; end if;
 r:=public.rivaluta_email_logistica(cliente,'Operatore test');
 if r->>'stato'<>'in_attesa' then raise exception 'Correzione bloccata dopo verifica'; end if;
 update public.attivita_operatore set stato='annullata' where id=a;
 -- Indirizzi discordanti, cliente duplicato e prenotazione trascorsa.
 insert into public.pratiche(nome_cliente,email_cliente,targa,stato_commerciale,stato_fatturazione) values('Test conflitto email','uno@test.invalid','TSTCON','ordine_acquisito','da_fatturare') returning id into p;
 perform public.crea_e_collega_cliente_pratica(p,'Test conflitto email','Via Test 1','Novara','28100',p_codice_fiscale=>'TSTFSC80A01F955A',p_email=>'due@test.invalid');
 select cliente_id into cliente from public.pratiche where id=p;
 update public.pratiche set email_cliente='uno@test.invalid' where id=p;
 update public.clienti set da_verificare=false,possibile_duplicato=false where id=cliente;
 insert into public.attivita_operatore(pratica_id,pratica_origine_id,tipo,evidenza,stato,riferimento_ritiro,data_ritiro_prevista,metadati)
 values(p,p,'ritiro_lavorazione','Test conflitto','programmata','P3 9260993010',current_date+2,'{"prenotazione_confermata":true}') returning id into a;
 select id into nid from public.notifiche_email_logistica where attivita_id=a;
 r:=public.prendi_email_logistica(nid);
 if r is not null or (select motivo from public.notifiche_email_logistica where id=nid) not like 'Email della pratica diversa%' then raise exception 'Conflitto indirizzi non bloccato'; end if;
 update public.pratiche set email_cliente='due@test.invalid' where id=p;
 update public.clienti set possibile_duplicato=true where id=cliente;
 if public.rivaluta_email_logistica(nid,'Operatore test')->>'stato'<>'da_verificare' then raise exception 'Cliente duplicato non bloccato'; end if;
 update public.attivita_operatore set data_ritiro_prevista=current_date-1 where id=a;
 select id into nid from public.notifiche_email_logistica where attivita_id=a and revisione=2;
 r:=public.prendi_email_logistica(nid);
 if r is not null or (select motivo from public.notifiche_email_logistica where id=nid)<>'Data ritiro trascorsa.' then raise exception 'Prenotazione vecchia inviata'; end if;
end; $test$;
rollback;

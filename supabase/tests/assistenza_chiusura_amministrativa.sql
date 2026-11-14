-- Fixture isolate, nessun dato cliente. Tutto annullato a fine test.
begin;
set local role service_role;
do $test$
declare
  p uuid; r uuid; a uuid; prima jsonb; chiusura timestamptz; n integer;
begin
  if has_function_privilege('anon','private.chiudi_richiesta_assistenza_non_avviata(uuid,timestamptz,text)','EXECUTE')
    or has_function_privilege('authenticated','public.applica_azione_operatore(uuid,text,text)','EXECUTE') then
    raise exception 'Permessi client troppo ampi';
  end if;
  insert into public.pratiche(nome_cliente,tipo_flusso,stato_assistenza)
    values('TEST CHIUSURA ROLLBACK','assistenza','in_gestione') returning id into p;
  insert into public.assistenze_rientri(pratica_id,evidenza,aperta_at,nota)
    values(p,'TEST',now()-interval '1 hour','Nota precedente da conservare') returning id into r;
  -- La richiamata indipendente resta aperta.
  insert into public.attivita_operatore(pratica_id,tipo,evidenza)
    values(p,'richiamata_post_vendita','TEST') returning id into a;
  select to_jsonb(x) into prima from public.attivita_operatore x where id=a;
  perform public.applica_azione_operatore(p,'assistenza_risolta','Soluzione concordata senza rientro');
  if not exists(select 1 from public.assistenze_rientri where id=r and stato='chiusa'
    and chiusa_at is not null and esito_tecnico is null and presa_in_carico_at is null
    and nota like 'Nota precedente da conservare%') then raise exception 'Chiusura amministrativa incoerente'; end if;
  if prima is distinct from (select to_jsonb(x) from public.attivita_operatore x where id=a) then
    raise exception 'Attività indipendente modificata'; end if;
  select assistenza_chiusa_at into chiusura from public.pratiche where id=p;
  perform public.applica_azione_operatore(p,'assistenza_risolta',null);
  select count(*) into n from public.azioni_operatore where pratica_id=p and azione='assistenza_chiusura_amministrativa';
  if n<>1 or chiusura is distinct from (select assistenza_chiusa_at from public.pratiche where id=p) then
    raise exception 'Replay non idempotente'; end if;
  -- Un episodio successivo non viene chiuso da un replay della vecchia risoluzione.
  insert into public.assistenze_rientri(pratica_id,evidenza,aperta_at)
    values(p,'TEST NUOVO EPISODIO',chiusura+interval '1 second') returning id into r;
  perform public.applica_azione_operatore(p,'assistenza_risolta',null);
  if (select chiusa_at from public.assistenze_rientri where id=r) is not null then
    raise exception 'Nuovo episodio chiuso impropriamente'; end if;
  -- Rientro avviato: errore atomico, senza modifiche parziali.
  update public.pratiche set stato_assistenza='in_gestione',assistenza_chiusa_at=null where id=p;
  update public.assistenze_rientri set aperta_at=now()-interval '1 minute',stato='in_lavorazione',presa_in_carico_at=now() where id=r;
  select to_jsonb(x) into prima from public.pratiche x where id=p;
  begin
    perform public.applica_azione_operatore(p,'assistenza_risolta',null);
    raise exception using errcode='ZX001',message='Rientro avviato chiuso senza esito';
  exception when sqlstate 'P0001' then
    if sqlerrm not like 'Assistenza già avviata:%' then raise; end if;
  end;
  if prima is distinct from (select to_jsonb(x) from public.pratiche x where id=p) then
    raise exception 'Modifica parziale dopo blocco tecnico'; end if;
  -- Anche il ritiro collegato pendente impedisce la chiusura amministrativa.
  update public.assistenze_rientri set stato='da_prendere_in_carico',presa_in_carico_at=null where id=r;
  update public.attivita_operatore set assistenza_rientro_id=r,tipo='ritiro_verifica_garanzia' where id=a;
  begin
    perform public.applica_azione_operatore(p,'assistenza_risolta',null);
    raise exception using errcode='ZX001',message='Ritiro pendente chiuso impropriamente';
  exception when sqlstate 'P0001' then
    if sqlerrm not like 'Attività collegata ancora aperta:%' then raise; end if;
  end;
  if (select chiusa_at from public.assistenze_rientri where id=r) is not null then raise exception 'Rientro modificato dopo blocco ritiro'; end if;
  update public.attivita_operatore set stato='annullata',nota='TEST annullamento motivato' where id=a;
  perform public.applica_azione_operatore(p,'assistenza_risolta',null);
  if (select chiusa_at from public.assistenze_rientri where id=r) is null then raise exception 'Richiesta non chiusa dopo annullamento ritiro'; end if;
  -- Senza episodio collegato il pulsante mantiene il comportamento normale.
  update public.pratiche set stato_assistenza='in_gestione',assistenza_chiusa_at=null where id=p;
  perform public.applica_azione_operatore(p,'assistenza_risolta',null);
  if (select stato_assistenza::text from public.pratiche where id=p)<>'risolta' then raise exception 'Risoluzione semplice fallita'; end if;
end;
$test$;
rollback;

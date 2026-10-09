CREATE OR REPLACE FUNCTION public.gestisci_ritiro_assistenza(p_pratica_id uuid, p_attivita_id uuid DEFAULT NULL::uuid, p_assistenza_id uuid DEFAULT NULL::uuid, p_azione text DEFAULT NULL::text, p_tipo text DEFAULT NULL::text, p_nota text DEFAULT NULL::text, p_riferimento text DEFAULT NULL::text, p_data_ritiro date DEFAULT NULL::date, p_operatore text DEFAULT NULL::text, p_origine_numero bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare a public.attivita_operatore%rowtype; c public.assistenze_rientri%rowtype; v_prima jsonb; v_origine uuid;
begin
 if nullif(trim(p_operatore),'') is null then raise exception 'Operatore richiesto'; end if;
 perform 1 from public.pratiche where id=p_pratica_id for update;
 if not found then raise exception 'Pratica non trovata'; end if;
 if p_attivita_id is not null then
  select * into a from public.attivita_operatore where id=p_attivita_id and pratica_id=p_pratica_id for update;
  if not found or a.tipo not like 'ritiro_%' or a.stato in ('annullata','completata') then raise exception 'Ritiro non attivo o estraneo alla pratica'; end if;
  v_prima:=to_jsonb(a); p_assistenza_id:=coalesce(p_assistenza_id,a.assistenza_rientro_id);
 end if;
 if p_assistenza_id is not null then
  select * into c from public.assistenze_rientri where id=p_assistenza_id and pratica_id=p_pratica_id for update;
  if not found or c.chiusa_at is not null then raise exception 'Assistenza non attiva o estranea alla pratica'; end if;
  v_prima:=coalesce(v_prima,to_jsonb(c));
 end if;
 if a.id is null and c.id is null then raise exception 'Selezionare ritiro o assistenza'; end if;
 if p_origine_numero is not null then
  if (a.id is null and c.id is null) or nullif(trim(p_nota),'') is null then raise exception 'Assistenza o ritiro e motivazione del collegamento richiesti'; end if;
  select x.id into v_origine from public.pratiche x join public.pratiche y on y.id=p_pratica_id
  where x.numero_pratica=p_origine_numero and (x.stato_commerciale::text='ordine_acquisito' or x.stato_fatturazione::text='fatturato')
   and (nullif(y.targa,'') is null or upper(x.targa)=upper(y.targa));
  if v_origine is null then raise exception 'Ordine non trovato o targa incompatibile'; end if;
  update public.attivita_operatore set pratica_origine_id=v_origine,stato=case when stato='da_collegare' then 'da_gestire' else stato end where id=a.id;
  a.pratica_origine_id:=v_origine;
  update public.assistenze_rientri set pratica_origine_id=v_origine where id=c.id;
 end if;
 if p_azione='collega_origine' then
  if p_origine_numero is null then raise exception 'Numero ordine di origine richiesto'; end if;
 elsif p_azione='prendi_in_carico' then
  update public.attivita_operatore set presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,updated_at=now() where id=a.id;
  update public.assistenze_rientri set presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,
   stato=case when stato='da_prendere_in_carico' then case when a.id is null then 'verifica_tecnica' else 'ritiro_da_prenotare' end else stato end,updated_at=now() where id=c.id;
 elsif p_azione='classifica' then
  if a.id is null or p_tipo not in ('ritiro_lavorazione','ritiro_programma_scambio','ritiro_verifica_garanzia','ritiro_da_classificare','ritiro_altro_reso') or nullif(trim(p_nota),'') is null then raise exception 'Tipo e motivazione richiesti'; end if;
  if p_tipo='ritiro_verifica_garanzia' and c.id is null then
   insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evidenza,aperta_at,operatore,presa_in_carico_at,stato)
   values(p_pratica_id,a.pratica_origine_id,p_nota,a.richiesta_at,p_operatore,now(),'ritiro_da_prenotare') returning * into c;
  end if;
  update public.attivita_operatore set tipo=p_tipo,blocco_classificazione=true,nota=p_nota,operatore=p_operatore,
   priorita=case when p_tipo='ritiro_verifica_garanzia' then 'urgente' else priorita end,assistenza_rientro_id=coalesce(assistenza_rientro_id,c.id),updated_at=now() where id=a.id;
 elsif p_azione='verifica_prenotazione' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Registrare la verifica effettuata'; end if;
  update public.attivita_operatore set metadati=metadati||jsonb_build_object('ritiro_gia_effettuato_segnalato',false,'verifica_prenotazione',p_nota,'evento_prenotazione_verificato',coalesce((metadati->>'evento_ritiro_effettuato')::bigint,0)),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
 elsif p_azione='programma' then
  if a.metadati->>'ritiro_gia_effettuato_segnalato'='true' then raise exception 'Il cliente segnala un ritiro già effettuato: verificarlo prima di prenotare nuovamente'; end if;
  if a.id is null or a.pratica_origine_id is null or a.tipo='ritiro_da_classificare' then raise exception 'Classificare e collegare prima il ritiro'; end if;
  if nullif(trim(p_riferimento),'') is null or p_data_ritiro is null then raise exception 'Riferimento prenotazione e data richiesti'; end if;
  update public.attivita_operatore set stato='programmata',programmata_at=coalesce(programmata_at,now()),
   riferimento_ritiro=p_riferimento,data_ritiro_prevista=p_data_ritiro,presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,nota=p_nota,updated_at=now() where id=a.id;
  update public.assistenze_rientri set stato='ritiro_prenotato',presa_in_carico_at=coalesce(presa_in_carico_at,now()),operatore=p_operatore,updated_at=now() where id=c.id;
 elsif p_azione='completa' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Registrare la prova del ritiro effettuato'; end if;
  update public.attivita_operatore set stato='completata',completata_at=now(),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
  -- Ritiro effettuato non equivale a ricezione in laboratorio o risoluzione del guasto.
 elsif p_azione='annulla' then
  if a.id is null or nullif(trim(p_nota),'') is null then raise exception 'Motivazione richiesta'; end if;
  update public.attivita_operatore set stato='annullata',annullata_at=now(),nota=p_nota,operatore=p_operatore,updated_at=now() where id=a.id;
 elsif p_azione in ('verifica_tecnica','ritiro_da_prenotare','ricevuto','in_lavorazione','esito_comunicato','chiudi') then
  if c.id is null or c.presa_in_carico_at is null then raise exception 'Prendere prima in carico l’assistenza'; end if;
  if p_azione='chiudi' and exists(select 1 from public.attivita_operatore where assistenza_rientro_id=c.id and stato in ('da_gestire','da_collegare','programmata')) then raise exception 'Completare o annullare prima il ritiro ancora aperto'; end if;
  if p_azione='chiudi' and (c.stato<>'esito_comunicato' or nullif(trim(p_nota),'') is null) then raise exception 'Comunicare e registrare prima l’esito tecnico'; end if;
  if p_azione='esito_comunicato' and nullif(trim(p_nota),'') is null then raise exception 'Esito tecnico obbligatorio'; end if;
  update public.assistenze_rientri set stato=case when p_azione='chiudi' then 'chiusa' else p_azione end,
   nota=coalesce(nullif(trim(p_nota),''),nota),esito_tecnico=case when p_azione='esito_comunicato' then p_nota else esito_tecnico end,
   chiusa_at=case when p_azione='chiudi' then now() else null end,operatore=p_operatore,updated_at=now() where id=c.id;
 else raise exception 'Azione non riconosciuta'; end if;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p_pratica_id,'ritiro_assistenza_'||p_azione,p_nota,v_prima,
  jsonb_build_object('attivita',(select to_jsonb(x) from public.attivita_operatore x where id=a.id),
   'assistenza',(select to_jsonb(x) from public.assistenze_rientri x where id=c.id)),p_operatore);
 return jsonb_build_object('ok',true,'azione',p_azione);
end; $function$
;

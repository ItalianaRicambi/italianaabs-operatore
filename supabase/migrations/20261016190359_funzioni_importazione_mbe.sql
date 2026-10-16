create function public.inizia_sincronizzazione_mbe()
returns uuid language plpgsql security invoker set search_path='' as $$
declare t uuid:=gen_random_uuid();
begin
 update public.mbe_collegamento set lease=t,lease_scade_at=now()+interval '3 minutes',ultimo_tentativo_at=now()
 where id and (lease_scade_at is null or lease_scade_at<now());
 if not found then return null; end if;
 return t;
end; $$;

create function public.termina_sincronizzazione_mbe(p_lease uuid,p_spedizioni jsonb,p_tracking jsonb,p_errore text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare s jsonb; t jsonb; ref text; parti text[]; pratica uuid; esito text; motivo text; impronta text; precedente public.mbe_spedizioni%rowtype; n integer:=0; dati jsonb;
begin
 perform 1 from public.mbe_collegamento where id and lease=p_lease and lease_scade_at>now() for update;
 if not found then raise exception 'Sincronizzazione scaduta o non autorizzata'; end if;
 if p_errore is not null then
  update public.mbe_collegamento set ultimo_errore=left(p_errore,500),lease=null,lease_scade_at=null where id;
  return jsonb_build_object('esito','errore');
 end if;
 if jsonb_typeof(p_spedizioni)<>'array' or jsonb_typeof(p_tracking)<>'array' or jsonb_array_length(p_spedizioni)>1000 or jsonb_array_length(p_tracking)>1000 then raise exception 'Dati MBE non validi'; end if;
 if exists(select 1 from jsonb_array_elements(p_spedizioni) x group by x->>'tracking_mbe' having count(*)>1)
 or exists(select 1 from jsonb_array_elements(p_tracking) x group by x->>'tracking_mbe' having count(*)>1) then raise exception 'Codici MBE duplicati'; end if;
 for s in select value from jsonb_array_elements(p_spedizioni) loop
  if not (s->>'tracking_mbe' ~ '^[A-Za-z0-9-]{1,20}$') or length(s->>'riferimento')>500 then raise exception 'Identità MBE non valida'; end if;
  ref:=s->>'riferimento';pratica:=null;esito:='da_abbinare';motivo:='Riferimento pratica assente o non riconosciuto. Verifica manuale.';
  -- Formato esplicito: ABS-000123 oppure ABS-000123 — XX000XX.
  -- Nomi, telefoni, indirizzi e sola targa non vengono usati per scegliere una pratica.
  parti:=regexp_match(upper(btrim(ref)), '^ABS-0*([1-9][0-9]{0,10})([[:space:]]*[-–—/|][[:space:]]*([A-Z]{2}[0-9]{3}[A-Z]{2}))?$');
  if parti is not null then
   select case when count(*)=1 then (array_agg(p.id))[1] end into pratica from public.pratiche p where p.numero_pratica=parti[1]::bigint;
   if pratica is not null then
    if parti[3] is not null and not exists(select 1 from public.pratiche p where p.id=pratica and regexp_replace(upper(coalesce(p.targa,'')),'[^A-Z0-9]','','g')=parti[3]) then
     pratica:=null;esito:='da_verificare';motivo:='Numero pratica e targa non corrispondono.';
    else esito:='abbinata';motivo:='Riferimento pratica esatto.';end if;
   else motivo:='Numero pratica inesistente o non univoco.';end if;
  end if;
  select * into precedente from public.mbe_spedizioni where tracking_mbe=s->>'tracking_mbe' for update;
  if found and (precedente.riferimento is distinct from ref or (precedente.pratica_id is not null and precedente.pratica_id is distinct from pratica)) then
   pratica:=precedente.pratica_id;esito:='da_verificare';motivo:='Riferimento MBE modificato: collegamento precedente conservato, verificare.';
  end if;
  impronta:=encode(sha256(convert_to(s::text,'UTF8')),'hex');
  insert into public.mbe_spedizioni(tracking_mbe,riferimento,data_spedizione,corriere,tracking_corriere,colli_mbe,colli_corriere,mittente,destinatario,bozza,pratica_id,abbinamento,motivo,impronta)
  values(s->>'tracking_mbe',ref,(s->>'data_spedizione')::date,s->>'corriere',s->>'tracking_corriere',s->'colli_mbe',s->'colli_corriere',s->'mittente',s->'destinatario',(s->>'bozza')::boolean,pratica,esito,motivo,impronta)
  on conflict(tracking_mbe) do update set riferimento=excluded.riferimento,data_spedizione=excluded.data_spedizione,corriere=excluded.corriere,
   tracking_corriere=case when excluded.tracking_corriere<>'' then excluded.tracking_corriere else public.mbe_spedizioni.tracking_corriere end,
   colli_mbe=excluded.colli_mbe,colli_corriere=excluded.colli_corriere,mittente=excluded.mittente,destinatario=excluded.destinatario,bozza=excluded.bozza,
   pratica_id=excluded.pratica_id,abbinamento=excluded.abbinamento,motivo=excluded.motivo,impronta=excluded.impronta,ultima_lettura_at=now();
  if precedente.tracking_mbe is null or precedente.impronta<>impronta then
   insert into public.mbe_osservazioni(tracking_mbe,contenuto,impronta) values(s->>'tracking_mbe',jsonb_build_object('spedizione',s),impronta);
  end if;
  n:=n+1;
 end loop;
 for t in select value from jsonb_array_elements(p_tracking) loop
  select * into precedente from public.mbe_spedizioni where tracking_mbe=t->>'tracking_mbe' for update;
  if not found then raise exception 'Tracking senza spedizione';end if;
  if (t->>'stato') is null or (t->>'stato') not in ('DELIVERED','PARTIALLY_DELIVERED','WAITING_DELIVERY','NOT_AVAILABLE','EXCEPTION') then raise exception 'Stato MBE sconosciuto';end if;
  if precedente.stato is distinct from t->>'stato' or precedente.data_consegna is distinct from (t->>'data_consegna')::date or precedente.descrizione is distinct from t->>'descrizione' or ((t->>'tracking_corriere')<>'' and precedente.tracking_corriere is distinct from t->>'tracking_corriere') then
   dati:=jsonb_build_object('tracking',t);impronta:=encode(sha256(convert_to(dati::text,'UTF8')),'hex');
   insert into public.mbe_osservazioni(tracking_mbe,contenuto,impronta) values(t->>'tracking_mbe',dati,impronta);
  end if;
  update public.mbe_spedizioni set stato=t->>'stato',data_consegna=(t->>'data_consegna')::date,descrizione=t->>'descrizione',
   tracking_corriere=case when t->>'tracking_corriere'<>'' then t->>'tracking_corriere' else tracking_corriere end,ultima_lettura_at=now()
  where tracking_mbe=t->>'tracking_mbe';
 end loop;
 update public.mbe_collegamento set ultimo_successo_at=now(),ultimo_errore=null,importate=n,controllate=jsonb_array_length(p_tracking),lease=null,lease_scade_at=null where id;
 return jsonb_build_object('esito','ok','importate',n,'controllate',jsonb_array_length(p_tracking));
end; $$;

create function public.configura_automatico_mbe(p_attivo boolean)
returns void language plpgsql security invoker set search_path='' as $$
begin
 if p_attivo and not exists(select 1 from public.mbe_collegamento where ultimo_successo_at>now()-interval '1 day' and ultimo_errore is null) then raise exception 'Collaudo MBE necessario';end if;
 update public.mbe_collegamento set automatico=p_attivo where id;
end; $$;
create function public.classifica_spedizione_mbe(p_tracking text,p_tipo text,p_operatore text)
returns void language plpgsql security invoker set search_path='' as $$
begin
 if p_tipo not in ('cliente','laboratorio','rientro','da_classificare') or p_tipo is null or p_operatore is null or p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') then raise exception 'Classificazione non valida';end if;
 update public.mbe_spedizioni set tipo_destinazione=p_tipo,classificata_da=p_operatore,classificata_at=now() where tracking_mbe=p_tracking;
 if not found then raise exception 'Spedizione non trovata';end if;
end; $$;

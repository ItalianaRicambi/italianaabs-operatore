-- L'invio dichiarato dall'operatore non comporta l'invenzione di PDF o prezzi.
-- Il preventivo mancante viene creato solo quando l'operatore registra alternative esplicite.
create function public.registra_alternative_offerta_operatore(
 p_pratica_id uuid,p_preventivo_id uuid,p_contenuto jsonb,p_operatore text
) returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare p public.pratiche%rowtype; q public.preventivi%rowtype; r jsonb;
 v_opzioni jsonb:=p_contenuto->'opzioni'; v_creato boolean:=false;
 v_external text:='operatore:alternative:'||p_pratica_id::text;
begin
 if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') or p_operatore is null then
  raise exception 'Operatore non valido';
 end if;
 if jsonb_typeof(v_opzioni) is distinct from 'array' then raise exception 'Alternative non valide'; end if;
 if jsonb_array_length(v_opzioni) not between 1 and 8 or nullif(p_contenuto->>'errore','') is not null then
  raise exception 'Alternative e prezzi da verificare nel documento';
 end if;
 if coalesce(p_contenuto->>'impronta','') !~ '^[0-9a-f]{64}$' then raise exception 'Impronta non valida'; end if;
 if exists(select 1 from jsonb_array_elements(v_opzioni) x where
  coalesce(x->>'servizio','') not in ('RI','RE','PS','PSMI') or
  coalesce(x->>'numero','') !~ '^[1-8]$' or
  coalesce(x->>'importo','') !~ '^[0-9]+([.][0-9]{1,2})?$' or
  coalesce(x->>'valuta','EUR')<>'EUR' or
  coalesce(jsonb_typeof(x->'iva_inclusa'),'null') not in ('boolean','null')) then
  raise exception 'Alternative non valide';
 end if;
 if exists(select 1 from jsonb_array_elements(v_opzioni) x where (x->>'importo')::numeric<=0 or (x->>'importo')::numeric>100000)
  or exists(select 1 from jsonb_array_elements(v_opzioni) x group by x->>'numero' having count(*)>1) then
  raise exception 'Importi o numeri delle alternative non validi';
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_external,0));
 -- Quote prima della pratica, come registra_opzioni_offerta: evita inversioni dei lock.
 if p_preventivo_id is not null then
  select * into q from public.preventivi where id=p_preventivo_id for update;
  if not found or q.pratica_id<>p_pratica_id then raise exception 'Preventivo estraneo alla pratica'; end if;
 else
  select * into q from public.preventivi where external_id=v_external for update;
 end if;
 select * into p from public.pratiche where id=p_pratica_id for update;
 if not found then raise exception 'Pratica non trovata'; end if;
 if p.tipo_flusso<>'commerciale' then raise exception 'Registrazione disponibile per le pratiche commerciali'; end if;
 if q.id is null then
  if exists(select 1 from public.preventivi where pratica_id=p.id) then
   raise exception 'Un preventivo è già presente: ricarica la pratica e selezionalo';
  end if;
  if p.preventivo_inviato_at is null or p.stato_commerciale not in ('preventivo_inviato','attesa_cliente','ordine_acquisito') then
   raise exception 'Registra prima l’invio del preventivo nella sezione commerciale';
  end if;
  insert into public.preventivi(pratica_id,external_id,stato,creato_at,inviato_at,note)
  values(p.id,v_external,'inviato',p.preventivo_inviato_at,p.preventivo_inviato_at,
   'Invio dichiarato dall’operatore; alternative inserite da '||p_operatore||'. PDF non collegato.') returning * into q;
  v_creato:=true;
 end if;
 r:=public.registra_opzioni_offerta(q.id,v_opzioni,p_contenuto->>'impronta',p_contenuto->>'testo',null,
  'operatore:'||p_operatore,(p_contenuto->>'validita_giorni')::integer,null);
 return r||jsonb_build_object('preventivo_id',q.id,'preventivo_creato',v_creato);
end; $fn$;
revoke all on function public.registra_alternative_offerta_operatore(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.registra_alternative_offerta_operatore(uuid,uuid,jsonb,text) to service_role;

CREATE OR REPLACE FUNCTION public.registra_opzioni_offerta(p_preventivo_id uuid, p_opzioni jsonb, p_impronta text, p_testo text DEFAULT NULL::text, p_errore text DEFAULT NULL::text, p_fonte text DEFAULT 'pdf'::text, p_validita_giorni integer DEFAULT NULL::integer, p_inviato_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare q public.preventivi%rowtype; p public.pratiche%rowtype; v_id uuid; v_num integer; o jsonb; e record; v_data_invio timestamptz;
begin
 select * into q from public.preventivi where id=p_preventivo_id for update;
 if not found then raise exception 'Preventivo non trovato'; end if;
 select * into p from public.pratiche where id=q.pratica_id for update;
 if length(coalesce(p_impronta,'')) not between 8 and 160 then raise exception 'Impronta documento non valida'; end if;
 if jsonb_typeof(p_opzioni)<>'array' or jsonb_array_length(p_opzioni)>8 then raise exception 'Alternative non valide'; end if;
 if p_errore is null and jsonb_array_length(p_opzioni)=0 then raise exception 'Alternative assenti'; end if;
 if p_validita_giorni is not null and p_validita_giorni not between 1 and 365 then raise exception 'Validità non valida'; end if;
 if exists(select 1 from jsonb_array_elements(p_opzioni) x group by (x->>'numero')::integer having count(*)>1) then raise exception 'Alternative duplicate'; end if;
 select id into v_id from public.offerte_versioni where preventivo_id=q.id and impronta=p_impronta;
 if v_id is not null then return jsonb_build_object('ok',true,'offerta_id',v_id,'duplicato',true); end if;
 select coalesce(max(versione),0)+1 into v_num from public.offerte_versioni where preventivo_id=q.id;
 -- La prima lettura non rinnova la data di invio del preventivo già registrato.
 v_data_invio:=case when v_num=1 then coalesce(q.inviato_at,q.creato_at,p_inviato_at) else coalesce(p_inviato_at,q.inviato_at,q.creato_at) end;
 insert into public.offerte_versioni(pratica_id,preventivo_id,versione,impronta,targa,file_url,inviato_at,stato,errore,testo_documento,fonte,validita_giorni)
 values(p.id,q.id,v_num,p_impronta,coalesce(p.targa,''),q.file_url,v_data_invio,
  case when p_errore is null then 'letta' else 'da_verificare' end,p_errore,left(p_testo,200000),p_fonte,p_validita_giorni) returning id into v_id;
 if p_errore is null then
  for o in select * from jsonb_array_elements(p_opzioni) loop
   insert into public.offerta_opzioni(offerta_id,numero,numero_esplicito,servizio,descrizione,importo,iva_inclusa,valuta,condizioni,reso_vecchio)
   values(v_id,(o->>'numero')::integer,coalesce((o->>'numero_esplicito')::boolean,true),o->>'servizio',
    coalesce(o->>'descrizione',o->>'servizio'),(o->>'importo')::numeric,(o->>'iva_inclusa')::boolean,
    coalesce(o->>'valuta','EUR'),left(o->>'condizioni',6000),(o->>'reso_vecchio')::boolean);
  end loop;
 end if;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'registro_offerta_versione','Versione '||v_num||' - '||coalesce(p_errore,'alternative registrate'),
  '{}'::jsonb,jsonb_build_object('offerta_id',v_id,'numero_opzioni',jsonb_array_length(p_opzioni)),p_fonte);
 -- Consensi arrivati prima della lettura del PDF vengono rielaborati con la loro data originale.
 for e in select id from public.keplero_live_events where pratica_id=p.id
  and created_at>=v_data_invio order by id loop
  perform private.rileva_scelta_cliente_evento(e.id);
 end loop;
 return jsonb_build_object('ok',true,'offerta_id',v_id,'versione',v_num,'stato',case when p_errore is null then 'letta' else 'da_verificare' end);
end; $function$
;

do $repair$
declare d record; e record;
begin
 for d in select o.id,o.pratica_id,o.inviato_at as precedente,q.inviato_at as originale
  from public.offerte_versioni o join public.preventivi q on q.id=o.preventivo_id
  where o.versione=1 and o.fonte='pdf' and o.registrata_at>='2026-10-09T21:40:00Z'
   and o.inviato_at>q.inviato_at
 loop
  update public.offerte_versioni set inviato_at=d.originale where id=d.id;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
   values(d.pratica_id,'riallineamento_data_offerta','Prima lettura PDF: preservata la data di invio già registrata',
    jsonb_build_object('offerta_id',d.id,'inviato_at',d.precedente),
    jsonb_build_object('offerta_id',d.id,'inviato_at',d.originale),'routine_controllo_k');
  for e in select id from public.keplero_live_events where pratica_id=d.pratica_id and created_at>=d.originale order by id loop
   perform private.rileva_scelta_cliente_evento(e.id);
  end loop;
 end loop;
end; $repair$;

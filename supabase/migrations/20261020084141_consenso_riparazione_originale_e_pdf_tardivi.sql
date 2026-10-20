-- Una direttiva sul pezzo del cliente richiede una scelta verificata RI/RE/RC.
create or replace function private.scelta_dispositivo_originale(p_testo text)
returns boolean language sql immutable security invoker set search_path='' as $$
 select coalesce(lower(btrim(p_testo)) ~
 '^(?:(?:ok|va bene|bene|allora|buongiorno|buonasera)[,!. ]*)?(ripariamo|riparate|revisioniamo|revisionate)[[:space:]]+(il[[:space:]]+(mio|nostro)([[:space:]]+(abs|modulo|dispositivo))?|la[[:space:]]+(mia|nostra)([[:space:]]+(centralina|pompa|unita|unità))?)[.! ]*$',false);
$$;
revoke all on function private.scelta_dispositivo_originale(text) from public,anon,authenticated;
grant execute on function private.scelta_dispositivo_originale(text) to service_role;

do $patch$
declare d text; a text; b text;
begin
 d:=pg_get_functiondef('private.conferma_letterale_offerta(text)'::regprocedure);
 a:=' private.scelta_conclusa_cliente(p_testo) or';
 if position(a in d)=0 then raise exception 'Regola conferma inattesa'; end if;
 execute replace(d,a,' private.scelta_dispositivo_originale(p_testo) or'||chr(10)||a);

 d:=pg_get_functiondef('private.scelta_lavorazione_cliente(text)'::regprocedure);
 a:='   private.scelta_conclusa_cliente(p_testo) or';
 if position(a in d)=0 then raise exception 'Regola lavorazione inattesa'; end if;
 execute replace(d,a,'   private.scelta_dispositivo_originale(p_testo) or'||chr(10)||a);

 d:=pg_get_functiondef('private.rileva_scelta_cliente_evento(bigint)'::regprocedure);
 a:='  if not v_risposta_breve and t!~';
 if position(a in d)=0 then raise exception 'Regola scelta breve inattesa'; end if;
 d:=replace(d,a,'  v_risposta_breve:=v_risposta_breve or private.scelta_dispositivo_originale(t);'||chr(10)||a);
 a:='  v_num:=(regexp_match(v_riferimento,';
 if position(a in d)=0 then raise exception 'Regola alternative inattesa'; end if;
 b:='  if private.scelta_dispositivo_originale(t) then'||chr(10)||
    '   v_ha_riferimento:=true;'||chr(10)||
    '   select array_agg(id) into v_ids from public.offerta_opzioni where offerta_id=q.id and id=any(v_ids) and servizio in (''RI'',''RE'',''RC'');'||chr(10)||
    '  end if;'||chr(10);
 execute replace(d,a,b||a);

 d:=pg_get_functiondef('public.conferma_ordine_da_keplero(uuid,text,text)'::regprocedure);
 a:='  -- I controlli terminali vengono eseguiti prima dei prerequisiti per';
 if position(a in d)=0 then raise exception 'Protezione ordine inattesa'; end if;
 b:='  if private.scelta_dispositivo_originale(p_messaggio_cliente) and not exists('||chr(10)||
    '    select 1 from public.scelte_cliente s join public.offerta_opzioni o on o.id=s.opzione_id'||chr(10)||
    '    where s.pratica_id=p_pratica_id and s.stato=''confermata'' and o.servizio in (''RI'',''RE'',''RC'')) then'||chr(10)||
    '    return jsonb_build_object(''aggiornato'',false,''motivo'',''lavorazione_originale_da_chiarire'',''pratica_id'',p_pratica_id);'||chr(10)||
    '  end if;'||chr(10)||chr(10);
 execute replace(d,a,b||a);
end $patch$;

-- Un documento recente già pendente può precedere la registrazione della pratica.
CREATE OR REPLACE FUNCTION private.abbina_documento_preventivo(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare d public.documenti_preventivo_auto%rowtype; candidati uuid[];
begin
 select * into d from public.documenti_preventivo_auto where id=p_id for update;
 if d.id is null then raise exception 'Documento assente'; end if;
 if d.stato='inviato' then return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito','inviato','pratica_id',d.pratica_id); end if;
 -- Una targa condivisa da più episodi non permette di scegliere arbitrariamente.
 select array_agg(p.id) into candidati from public.pratiche p
 where upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g'))=d.targa
 and p.tipo_flusso='commerciale' and p.stato_commerciale in ('nuova','raccolta_dati','da_preventivare','preventivo_pronto','preventivo_inviato','attesa_cliente','richiesta_verifica')
 and p.stato_fatturazione='non_applicabile'
 and (p.created_at<=d.data_offerta+interval '5 minutes'
  or (d.ricevuto_at<=p.created_at
   and d.ricevuto_at>=private.inizio_finestra_controllo_keplero(p.created_at,48)
   and d.data_offerta>=private.inizio_finestra_controllo_keplero(d.ricevuto_at,24)))
 and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
 and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
 update public.documenti_preventivo_auto set ultimo_tentativo_at=now(),
 pratica_id=case when cardinality(candidati)=1 then candidati[1] end,
 stato=case when coalesce(cardinality(candidati),0)<>1 then 'da_abbinare'
   when prova_invio is not null or nullif(contenuto->>'errore','') is not null then 'da_verificare' else 'pronto' end,
 motivo=case when coalesce(cardinality(candidati),0)=0 then 'Nessuna pratica compatibile con targa e data del documento.'
   when cardinality(candidati)>1 then 'Più pratiche compatibili: verificare l’abbinamento.'
   when prova_invio is not null then 'Invio rilevato: aggiornamento della pratica da verificare.'
   when nullif(contenuto->>'errore','') is not null then left(contenuto->>'errore',500)
   else 'PDF acquisito. Invio al cliente non ancora verificato.' end
 where id=d.id returning * into d;
 -- Nessuna modifica a classificazione, completezza o stato della pratica.
 return jsonb_build_object('acquisito',true,'documento_id',d.id,'esito',d.stato,'pratica_id',d.pratica_id);
end; $function$;


-- Le schede consolidate e chiuse conservano il riferimento alla pratica canonica.
-- Un link storico non deve interrompere la continuità dopo il consolidamento.
do $patch$
declare v_def text; v_old text; v_new text;
begin
 v_def:=pg_get_functiondef('public.prepara_instradamento_keplero(text,text,text,text,text,text,jsonb)'::regprocedure);
 v_old:=$old$where l.external_key=p_external_key and a.id<>v_candidato_id
      and (a.blocco_operatore$old$;
 v_new:=$new$where l.external_key=p_external_key and a.id<>v_candidato_id
      and not (coalesce(a.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true'
        and a.dati_raw#>>'{pratica_duplicata,pratica_canonica_id}'=v_candidato_id::text)
      and (a.blocco_operatore$new$;
 if strpos(v_def,v_old)=0 then raise exception 'Instradamento canonico inatteso'; end if;
 execute replace(v_def,v_old,v_new);
end; $patch$;

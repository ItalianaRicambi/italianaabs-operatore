do $patch$
declare d text; old text:=$old$a.dati_raw#>>'{pratica_duplicata,pratica_canonica_id}'=v_candidato_id::text$old$;
begin
 d:=pg_get_functiondef('public.prepara_instradamento_keplero(text,text,text,text,text,text,jsonb)'::regprocedure);
 if strpos(d,old)=0 then raise exception 'Guardia consolidamento inattesa'; end if;
 execute replace(d,old,$new$coalesce(a.dati_raw#>>'{pratica_duplicata,pratica_canonica_id}','')=v_candidato_id::text$new$);
end; $patch$;
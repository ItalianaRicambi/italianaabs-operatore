-- Un altro worker può acquisire l'ordine tra selezione e lock.
-- In quel caso la verifica restituisce un oggetto vuoto: non sovrascrivere
-- la prova già registrata con un contesto NULL.
do $patch$
declare v_def text; v_old text; v_new text;
begin
 v_def:=pg_get_functiondef('private.recupera_ordini_contestuali_keplero()'::regprocedure);
 v_old:=$old$if v_result#>>'{contesto,confermato}'<>'true' then continue; end if;$old$;
 v_new:=$new$if coalesce(v_result#>>'{contesto,confermato}','false')<>'true' then continue; end if;$new$;
 if strpos(v_def,v_old)=0 then raise exception 'Guardia recupero inattesa'; end if;
 execute replace(v_def,v_old,v_new);
end;
$patch$;

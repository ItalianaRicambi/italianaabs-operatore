-- Il messaggio letterale prevale anche su un flag AI erroneamente positivo.
do $patch$
declare d text; a text;
begin
 d:=pg_get_functiondef('public.conferma_ordine_da_keplero(uuid,text,text)'::regprocedure);
 a:='  if private.preferenza_senza_conferma(p_messaggio_cliente)';
 if position(a in d)=0 or position('scelta_riferita_non_conclusa' in d)>0 then raise exception 'Conferma ordine inattesa';end if;
 execute replace(d,a,$new$  if lower(coalesce(p_messaggio_cliente,'')) ~ '\mnon\M.{0,50}\m(scelt[oa]|decis[oa])\M'
    or (lower(coalesce(p_messaggio_cliente,'')) ~ '\m(cliente|proprietario|officina)[[:space:]]+ha[[:space:]]+scelto\M'
       and not private.scelta_conclusa_cliente(p_messaggio_cliente)) then
    return jsonb_build_object('aggiornato',false,'motivo','scelta_riferita_non_conclusa','pratica_id',p_pratica_id);
  end if;

$new$||a);
end $patch$;

-- La decisione conclusa riferita da K non è una preferenza. Le condizioni,
-- le domande e le verifiche preliminari continuano a impedire l'acquisizione.
create or replace function private.scelta_conclusa_cliente(p_testo text)
returns boolean language sql immutable security invoker set search_path='' as $function$
 select coalesce(
  lower(p_testo) ~ '\m(il[[:space:]]+)?(cliente|proprietario|officina)[[:space:]]+ha[[:space:]]+scelto[[:space:]]+(per[[:space:]]+)?(il[[:space:]]+|la[[:space:]]+|l[''’])?(programma[[:space:]]+scambio|riparazione|revisione|lavorazione|opzione|proposta|offerta)\M'
  and lower(p_testo) !~ '\m(se|qualora|altrimenti|forse|eventualmente)\M'
  and lower(p_testo) !~ '\mnon\M.{0,50}\m(scelt[oa]|decis[oa])\M'
  and lower(p_testo) !~ 'ha[[:space:]]+scelto[^.!]*[?]'
  and not private.domanda_su_accettazione(p_testo)
  and not private.rinvio_conferma_per_verifiche(p_testo)
  and not private.preferenza_senza_conferma(p_testo),false);
$function$;
revoke all on function private.scelta_conclusa_cliente(text) from public,anon,authenticated;
grant execute on function private.scelta_conclusa_cliente(text) to service_role;

-- Un'unica regola per recupero SQL, registrazione scelta e webhook HTTP.
do $patch$
declare d text; a text;
begin
 d:=pg_get_functiondef('private.conferma_letterale_offerta(text)'::regprocedure);
 a:='select ('||chr(10);
 if position(a in d)=0 or position('private.scelta_conclusa_cliente' in d)>0 then raise exception 'Riconoscimento conferma inatteso';end if;
 execute replace(d,a,a||' private.scelta_conclusa_cliente(p_testo) or'||chr(10));
 d:=pg_get_functiondef('private.scelta_lavorazione_cliente(text)'::regprocedure);
 a:='   lower(trim(p_testo)) ~';
 if position(a in d)=0 or position('private.scelta_conclusa_cliente' in d)>0 then raise exception 'Riconoscimento scelta inatteso';end if;
 execute replace(d,a,'   private.scelta_conclusa_cliente(p_testo) or'||chr(10)||a);
end $patch$;
notify pgrst,'reload schema';

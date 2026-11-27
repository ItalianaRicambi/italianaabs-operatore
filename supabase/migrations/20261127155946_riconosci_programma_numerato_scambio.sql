-- Eccezione circoscritta alla scelta conclusa del programma numerato di scambio.
-- Il numero è accettato solo se l'alternativa numerata del PDF è esplicita e PS/PSMI.
create or replace function private.programma_numerato_scambio_concluso(p_testo text)
returns integer language sql immutable security invoker set search_path='' as $$
 select (regexp_match(lower(regexp_replace(btrim(translate(coalesce(p_testo,''),'’','''')),
   '[[:space:]]+',' ','g')),
   '^(?:(?:buon pomeriggio|buongiorno|buonasera)[,!. ]*)?per noi andrebbe bene anche il programma ([1-8]) quindi lo scambio della parte[.! ]*$'))[1]::integer;
$$;
revoke all on function private.programma_numerato_scambio_concluso(text) from public,anon,authenticated;
grant execute on function private.programma_numerato_scambio_concluso(text) to service_role;

do $patch$
declare d text; a text;
begin
 d:=pg_get_functiondef('private.conferma_letterale_offerta(text)'::regprocedure);
 a:=' private.scelta_conclusa_cliente(p_testo) or';
 if length(d)-length(replace(d,a,''))<>length(a) then raise exception 'Regola conferma inattesa'; end if;
 execute replace(d,a,' private.programma_numerato_scambio_concluso(p_testo) is not null or'||chr(10)||a);

 d:=pg_get_functiondef('private.rileva_scelta_cliente_evento(bigint)'::regprocedure);
 a:='if not v_risposta_breve and t!~';
 if length(d)-length(replace(d,a,''))<>length(a) then raise exception 'Primo filtro scelta inatteso'; end if;
 d:=replace(d,a,'if not v_risposta_breve and private.programma_numerato_scambio_concluso(t) is null and t!~');
 a:='and not v_risposta_breve and not private.richiesta_procedere_ordine(t) then';
 if length(d)-length(replace(d,a,''))<>length(a) then raise exception 'Secondo filtro scelta inatteso'; end if;
 d:=replace(d,a,'and not v_risposta_breve and not private.richiesta_procedere_ordine(t) and private.programma_numerato_scambio_concluso(t) is null then');
 a:='  if v_num is null then';
 if length(d)-length(replace(d,a,''))<>length(a) then raise exception 'Numero scelta inatteso'; end if;
 d:=replace(d,a,'  v_num:=coalesce(v_num,private.programma_numerato_scambio_concluso(t));'||chr(10)||a);
 a:='and numero=v_num and numero_esplicito;';
 if length(d)-length(replace(d,a,''))<>length(a) then raise exception 'Confronto opzione inatteso'; end if;
 d:=replace(d,a,'and numero=v_num and numero_esplicito and (private.programma_numerato_scambio_concluso(t) is null or servizio in (''PS'',''PSMI''));');
 execute d;
end $patch$;

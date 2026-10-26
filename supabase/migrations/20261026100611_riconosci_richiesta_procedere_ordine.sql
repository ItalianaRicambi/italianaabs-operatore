-- Consenso circoscritto: nessuna domanda, condizione o testo libero finale.
-- Le alternative e le prove di invio restano verificate dai chiamanti.
create or replace function private.richiesta_procedere_ordine(p_testo text)
returns boolean language sql immutable security invoker set search_path='' as $$
 select coalesce(lower(regexp_replace(btrim(translate(p_testo,'’','''')),'[[:space:]]+',' ','g')) ~
 '^(?:(?:ok|bene|allora|buongiorno|buonasera)[,!. ]*)?possiamo procedere (?:per fare l''ordine|con (?:l''ordine|il preventivo|l''offerta|l''opzione [1-8]|opzione [1-8]|ri|re|rc|ps|psmi|il programma scambio(?: made in italy)?))[.! ]*(?:grazie[.! ]*)?$',false);
$$;
revoke all on function private.richiesta_procedere_ordine(text) from public,anon,authenticated;
grant execute on function private.richiesta_procedere_ordine(text) to service_role;

do $patch$
declare d text; a text;
begin
 d:=pg_get_functiondef('private.conferma_letterale_offerta(text)'::regprocedure);
 a:=' private.scelta_dispositivo_originale(p_testo) or';
 if position(a in d)=0 then raise exception 'Regola conferma inattesa'; end if;
 execute replace(d,a,' private.richiesta_procedere_ordine(p_testo) or'||chr(10)||a);

 d:=pg_get_functiondef('private.rileva_scelta_cliente_evento(bigint)'::regprocedure);
 a:='and not v_risposta_breve then return ''{}''::jsonb; end if;';
 if position(a in d)=0 then raise exception 'Regola scelta inattesa'; end if;
 -- La richiesta entra nel registro: se ci sono più opzioni resta da chiarire.
 execute replace(d,a,'and not v_risposta_breve and not private.richiesta_procedere_ordine(t) then return ''{}''::jsonb; end if;');

 d:=pg_get_functiondef('private.valuta_originale_k(uuid,text)'::regprocedure);
 a:='or private.scelta_dispositivo_originale(t))';
 if position(a in d)=0 then raise exception 'Regola originale inattesa'; end if;
 execute replace(d,a,'or private.scelta_dispositivo_originale(t) or private.richiesta_procedere_ordine(t))');
end $patch$;

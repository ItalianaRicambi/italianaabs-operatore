begin;
do $$
declare dati jsonb:=jsonb_build_object('mailbox','info@italianaabs.com','sender','collaudo@example.com','subject','TEST EMAIL','content','Collaudo interno',
 'conversation_id','b3be5f5b-ece5-4c5e-90be-e39d856fe12f','fingerprint',repeat('a',64));
 primo jsonb; secondo jsonb; terzo jsonb; ok boolean;
begin
 if has_table_privilege('anon','public.richieste_email','select') or has_table_privilege('authenticated','public.richieste_email','select') then raise exception 'Registro esposto'; end if;
 if has_function_privilege('anon','public.registra_richiesta_email(jsonb)','execute') then raise exception 'RPC esposta'; end if;
 primo:=public.registra_richiesta_email(dati);
 if primo->>'token' is null then raise exception 'Claim iniziale mancante'; end if;
 secondo:=public.registra_richiesta_email(dati);
 if secondo->>'id'<>primo->>'id' or secondo->>'token' is not null then raise exception 'Retry concorrente duplicato'; end if;
 ok:=public.esito_richiesta_email((primo->>'id')::uuid,gen_random_uuid(),'esclusa',null,'TEST',false);
 if ok then raise exception 'Token errato accettato'; end if;
 ok:=public.esito_richiesta_email((primo->>'id')::uuid,(primo->>'token')::uuid,'errore',null,'TEST',false);
 if not ok then raise exception 'Esito non salvato'; end if;
 terzo:=public.registra_richiesta_email(dati);
 if terzo->>'id'<>primo->>'id' or terzo->>'token' is null or terzo->>'token'=primo->>'token' then raise exception 'Retry fallito'; end if;
 perform public.esito_richiesta_email((terzo->>'id')::uuid,(terzo->>'token')::uuid,'esclusa',null,'TEST',false);
 if (public.registra_richiesta_email(dati))->>'token' is not null then raise exception 'Esclusa riaperta'; end if;
 if exists(select 1 from public.pratiche where keplero_conversation_id='b3be5f5b-ece5-4c5e-90be-e39d856fe12f') then raise exception 'Pratica test creata'; end if;
end $$;
rollback;

begin;
set local role service_role;
do $$
declare
 e jsonb; r jsonb; r2 jsonb; row_id uuid; lease uuid; n integer;
begin
 e:=jsonb_build_object('mailbox','ordini@italianaabs.com','sender','collaudo@example.invalid',
   'subject','TEST EMAIL ORDINI — collaudo','content','Prova interna: ordine e pagamento non attestati.',
   'conversation_id',gen_random_uuid(),'fingerprint',repeat('f',32)||replace(gen_random_uuid()::text,'-',''));
 r:=public.registra_richiesta_email(e); row_id:=(r->>'id')::uuid; lease:=(r->>'token')::uuid;
 if lease is null or r->>'mailbox'<>'ordini@italianaabs.com' then raise exception 'Registrazione ordini fallita'; end if;
 r2:=public.registra_richiesta_email(e);
 if r2->>'id'<>r->>'id' or r2->>'token' is not null then raise exception 'Retry concorrente duplicato'; end if;
 if not public.esito_richiesta_email(row_id,lease,'da_classificare',null,'Verificare ordine Shopify',false) then raise exception 'Esito non salvato'; end if;
 r2:=public.registra_richiesta_email(e);
 if r2->>'id'<>r->>'id' or r2->>'token' is not null or r2->>'stato'<>'da_classificare' or r2->>'pratica_id' is not null then raise exception 'Retry dopo esito non idempotente'; end if;
 select count(*) into n from public.richieste_email where fingerprint=e->>'fingerprint';
 if n<>1 then raise exception 'Email duplicata'; end if;
 e:=e||jsonb_build_object('mailbox','info@italianaabs.com','fingerprint',repeat('e',32)||replace(gen_random_uuid()::text,'-',''));
 r:=public.registra_richiesta_email(e);
 if r->>'token' is null then raise exception 'Regressione casella info'; end if;
 begin
  perform public.registra_richiesta_email(e||jsonb_build_object('mailbox','altro@example.invalid'));
  raise exception 'Casella non autorizzata accettata';
 exception when others then
  if sqlerrm<>'Dati email non validi' then raise; end if;
 end;
 if has_function_privilege('anon','public.registra_richiesta_email(jsonb)','execute') or has_function_privilege('authenticated','public.registra_richiesta_email(jsonb)','execute') then raise exception 'Funzione esposta'; end if;
end $$;
rollback;

begin;
do $$
declare r public.ordini_shopify; j jsonb; p uuid; ev public.evasioni_pratiche; n integer;
begin
 -- Frasi singolari/plurali, falsi positivi e scelta isolata.
 if not private.possibile_ordine_letterale('Accettiamo il preventivo')
 or not private.possibile_ordine_letterale('Confermiamo la lavorazione')
 or not private.possibile_ordine_letterale('Approviamo questa offerta')
 or not private.possibile_ordine_letterale('Ordine fatto')
 or private.possibile_ordine_letterale('Non confermo il preventivo')
 or private.possibile_ordine_letterale('Se confermo il preventivo spedite?')
 or private.possibile_ordine_letterale('Programma scambio')
 or private.possibile_ordine_letterale('Bonifico effettuato')
 or private.possibile_ordine_letterale('Confermo il ritiro del pacco')
 then raise exception 'Test frasi fallito';end if;
 select * into r from public.ordini_shopify where attivo and dati->>'stato_evasione'='da_evadere' limit 1;
 if r.id is null then raise exception 'Fixture ordine reale assente';end if;
 j:=public.registra_ordine_shopify(r.dati,r.valutazione);
 if j->>'esito'<>'duplicato' then raise exception 'Idempotenza fallita';end if;
 j:=public.registra_ordine_shopify(r.dati-'stato_evasione',r.valutazione);
 if j->>'esito'<>'duplicato_pre_arricchimento' then raise exception 'Retry vecchio adattatore fallito';end if;
 j:=public.registra_ordine_shopify(r.dati||jsonb_build_object('aggiornato_shopify_at',r.aggiornato_shopify_at-interval '1 second','stato_evasione','evaso'),r.valutazione);
 if j->>'esito'<>'evento_superato' then raise exception 'Evento vecchio fallito';end if;
 -- Stato noto discordante alla stessa revisione: deve restare in verifica.
 j:=public.registra_ordine_shopify(r.dati||'{"stato_evasione":"evaso"}'::jsonb,r.valutazione);
 if j->>'esito'<>'conflitto_da_verificare' then raise exception 'Conflitto evasione fallito';end if;
 if (select dati->>'stato_evasione' from public.ordini_shopify where id=r.id)<>'da_evadere'
 then raise exception 'Conflitto ha sovrascritto stato';end if;
 select * into ev from public.evasioni_pratiche where stato='da_evadere' limit 1;
 perform public.aggiorna_evasione_pratica(ev.pratica_id,ev.revisione,'evaso','TEST rollback: prova evasione non reale','Operatore 1');
 begin
  perform public.aggiorna_evasione_pratica(ev.pratica_id,ev.revisione,'da_evadere','TEST revisione obsoleta','Operatore 1');
  raise exception 'Concorrenza non protetta';
 exception when raise_exception then
  if sqlerrm='Concorrenza non protetta' then raise;end if;
 end;
 if has_table_privilege('anon','public.evasioni_pratiche','SELECT')
 or has_function_privilege('authenticated','public.aggiorna_evasione_pratica(uuid,integer,text,text,text)','EXECUTE')
 then raise exception 'Permessi pubblici non consentiti';end if;
end $$;
select 'OK: frasi, idempotenza, retry precedente, eventi fuori ordine, conflitti, revisioni e permessi; rollback' as esito;
rollback;

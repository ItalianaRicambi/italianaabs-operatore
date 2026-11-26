begin;
do $$
declare
 oggi date:=(now() at time zone 'Europe/Rome')::date;
 r public.resi_scambio; primo uuid; secondo uuid;
begin
 if public.resi_lunedi_pasqua(2027)<>date '2027-03-29'
 or public.resi_aggiungi_lavorativi('2026-12-04',1)<>date '2026-12-09'
 or public.resi_aggiungi_lavorativi('2026-11-06',3)<>date '2026-11-11'
 or public.resi_aggiungi_lavorativi('2026-10-28',20)<>date '2026-11-25'
 then raise exception 'Calendario errato'; end if;
 insert into public.resi_scambio(fattura,data_fattura,cliente,veicolo,componente,sigla,spedizione,fonte)
 values('TEST-RESI',oggi-40,'TEST','TEST','ABS','MBMI',oggi-37,'test') returning * into r;
 perform public.evento_reso_scambio(r.id,1,'attiva','start','Routine resi','{"nota":"fonti verificate"}');
 perform public.evento_reso_scambio(r.id,2,'montaggio','risposta','Routine resi',jsonb_build_object('data',oggi+3,'nota','montaggio concordato'));
 if (select prossima from public.resi_scambio where id=r.id)<>public.resi_aggiungi_lavorativi(oggi+3,3) then raise exception 'Rinvio errato'; end if;
 perform public.evento_reso_scambio(r.id,3,'presa','booking','Routine resi','{"nota":"confermata","presa":"TEST"}');
 begin
  perform public.evento_reso_scambio(r.id,4,'tentativo','claim','Routine resi','{}');
  raise exception 'Test fallito';
 exception when others then if sqlerrm='Test fallito' then raise; end if; end;
 update public.resi_scambio set stato='attesa',prossima=oggi-1,spedizione=(oggi-interval '6 months')::date where id=r.id;
 if not (select riesame from public.v_resi_scambio where id=r.id) then raise exception 'Riesame mancante'; end if;
 begin
  perform public.evento_reso_scambio(r.id,4,'decaduta','sistema','Routine resi','{"nota":"test","clausola":"test"}');
  raise exception 'Test fallito';
 exception when others then if sqlerrm='Test fallito' then raise; end if; end;
 primo:=public.evento_reso_scambio(r.id,4,'decaduta','decisione','Operatore 1','{"nota":"test","clausola":"test"}');
 secondo:=public.evento_reso_scambio(r.id,4,'decaduta','decisione','Operatore 1','{"nota":"test","clausola":"test"}');
 if primo<>secondo or (select comunicazione is not null from public.resi_scambio where id=r.id) then raise exception 'Duplicato o comunicazione prematura'; end if;
 perform public.evento_reso_scambio(r.id,5,'comunicata','prova','Operatore 1',jsonb_build_object('data',oggi,'canale','Email','testo','test','prova','test'));
 if (select comunicazione->>'prova' from public.resi_scambio where id=r.id)<>'test' then raise exception 'Comunicazione mancante'; end if;
end $$;
rollback;

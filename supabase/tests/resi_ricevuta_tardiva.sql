begin;
-- Esercita la fase tra acquisizione e risposta anche se la suite gira in un festivo.
do $$
declare
 oggi date:=(now() at time zone 'Europe/Rome')::date;
 r public.resi_scambio; token uuid:=gen_random_uuid(); data_montaggio date:=oggi+10;
begin
 insert into public.resi_scambio(fattura,data_fattura,cliente,veicolo,componente,sigla,spedizione,fonte,
  stato,prossima,revisione,unico_tentativo)
 values('TEST-RICEVUTA',oggi-30,'TEST','TEST','ABS','ARMI',oggi-30,'test','attesa',oggi,2,token) returning * into r;
 insert into public.resi_scambio_eventi(id,reso_id,chiave,tipo,autore,dettagli)
 values(token,r.id,'tentativo','tentativo','Routine resi','{"revisione_invio":2}');
 perform public.evento_reso_scambio(r.id,2,'montaggio','risposta','Routine resi',jsonb_build_object('data',data_montaggio,'nota','nuovo appuntamento'));
 perform public.evento_reso_scambio(r.id,3,'inviato','ricevuta','Routine resi',jsonb_build_object('data',oggi,'prova','test','token',token));
 select * into r from public.resi_scambio where id=r.id;
 if r.stato<>'montaggio' or r.prossima<>public.resi_aggiungi_lavorativi(data_montaggio,3)
  or r.ultimo_invio<>oggi or r.unico_tentativo is not null then raise exception 'Ricevuta sovrascrive accordo'; end if;
end $$;
rollback;

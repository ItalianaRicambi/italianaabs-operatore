-- Prova della continuità della pratica tramite un PDF già inviato da K.
begin;
set local role service_role;
do $test$
declare v_origine uuid; v_nuova uuid; v_raw jsonb;
begin
  insert into public.pratiche(targa,nome_cliente,tipo_componente,tipo_flusso,stato_commerciale,created_at,dati_raw)
  values('TSTP001','Cliente test rollback','ABS','commerciale','preventivo_inviato',now()-interval '1 day',
    '{"dtc_estratti":["00301"],"messaggi_keplero":[{"sender":"assistant","operator":"keplero","message":"attachment:https://example.com/TSTP001.pdf"}]}')
  returning id into v_origine;
  insert into public.preventivi(pratica_id,external_id,stato,file_url,creato_at,inviato_at)
  values(v_origine,'test:preventivi:origine','inviato','https://example.com/TSTP001.pdf',now()-interval '12 hours',now()-interval '12 hours');
  v_raw:='{"dtc_estratti":["00301 - Pompa"],"allegati_keplero":[{"url":"https://example.com/TSTP001.pdf"}]}';
  insert into public.pratiche(targa,nome_cliente,tipo_componente,tipo_flusso,stato_commerciale,created_at,dati_raw)
  values('TSTP001','Cliente test diverso','ABS','commerciale','da_preventivare',now(),v_raw)
  returning id into v_nuova;
  if private.riconosci_preventivo_gia_inviato(v_nuova) then raise exception 'Clienti diversi abbinati'; end if;
  update public.pratiche set nome_cliente='Cliente test rollback',
    dati_raw='{"dtc_estratti":["01276"],"allegati_keplero":[{"url":"https://example.com/TSTP001.pdf"}]}' where id=v_nuova;
  if private.riconosci_preventivo_gia_inviato(v_nuova) then raise exception 'Guasti differenti abbinati'; end if;
  update public.pratiche set dati_raw='{"dtc_estratti":["00301"],"allegati_keplero":[{"url":"https://example.com/altro-TSTP001.pdf"}]}' where id=v_nuova;
  if private.riconosci_preventivo_gia_inviato(v_nuova) then raise exception 'Allegati differenti abbinati'; end if;
  update public.pratiche set dati_raw=v_raw,blocco_classificazione_operatore=true where id=v_nuova;
  if private.riconosci_preventivo_gia_inviato(v_nuova) then raise exception 'Blocco operatore ignorato'; end if;
  update public.pratiche set blocco_classificazione_operatore=false where id=v_nuova;
  if not private.riconosci_preventivo_gia_inviato(v_nuova) then raise exception 'Identico PDF inviato non riconosciuto'; end if;
  if not exists(select 1 from public.pratiche where id=v_nuova and stato_commerciale='preventivo_inviato' and pratica_origine_id=v_origine)
    or (select count(*) from public.preventivi where external_id='test:preventivi:origine')<>1
  then raise exception 'Collegamento origine errato o documento duplicato'; end if;
  if private.riconosci_preventivo_gia_inviato(v_nuova) then raise exception 'Recupero ripetuto'; end if;
end;
$test$;
reset role;
rollback;

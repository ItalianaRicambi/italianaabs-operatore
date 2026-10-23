CREATE OR REPLACE FUNCTION public.registra_originali_k(p_lease uuid, p_sessione uuid, p_messaggi jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare x jsonb; v_id text; m record;
begin
 perform 1 from public.keplero_recupero_originali where lease=p_lease and scade_at>now() for update;
 if not found or not exists(select 1 from public.keplero_sessioni_originali where sessione=p_sessione and lease=p_lease) then raise exception 'Lettura scaduta';end if;
 if jsonb_typeof(p_messaggi)<>'array' or jsonb_array_length(p_messaggi)>5000 then raise exception 'Snapshot non valido';end if;
 if exists(select 1 from jsonb_array_elements(p_messaggi) a group by a->>'id' having count(*)>1) then raise exception 'ID duplicati';end if;
 for x in select value from jsonb_array_elements(p_messaggi) loop
  v_id:=x->>'id';
  if v_id is null or v_id!~'^[A-Za-z0-9_-]{1,100}$' or x->>'impronta'!~'^[a-f0-9]{64}$' or length(x->>'testo')>30000 or (x->>'data')::timestamptz>now()+interval '5 minutes' then raise exception 'Originale non valido';end if;
  if exists(select 1 from public.keplero_originali where sessione=p_sessione and messaggio_id=v_id and impronta<>x->>'impronta' and coalesce(revisione->>'impronta','')<>x->>'impronta') then
   update public.keplero_verifiche_originali set esito='da_verificare',operatore=null,verificata_at=null,updated_at=now() where sessione=p_sessione and messaggio_id=v_id;
  end if;
  insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,targa_pdf,sha256_pdf,originale,consegna)
  values(p_sessione,v_id,(x->>'data')::timestamptz,x->>'data_originale',x->>'direzione',x->>'tipo',x->>'testo',x->>'impronta',(x->>'candidato')::boolean,(x->>'revoca')::boolean,x->>'targa_pdf',x->>'sha256_pdf',x->'originale',jsonb_build_object('whatsapp_message',x->'originale'->'whatsapp_message','metadata',x->'originale'->'metadata'))
  on conflict(sessione,messaggio_id) do update set
   consegna=excluded.consegna,
   modificato=public.keplero_originali.modificato or public.keplero_originali.impronta<>excluded.impronta,
   revisione=case when public.keplero_originali.impronta<>excluded.impronta then x else public.keplero_originali.revisione end,
   candidato=public.keplero_originali.candidato or excluded.candidato or public.keplero_originali.impronta<>excluded.impronta,
   sha256_pdf=case when public.keplero_originali.impronta=excluded.impronta then coalesce(public.keplero_originali.sha256_pdf,excluded.sha256_pdf) else public.keplero_originali.sha256_pdf end;
 end loop;
 for m in select messaggio_id from public.keplero_originali where sessione=p_sessione and candidato and data_messaggio>now()-interval '30 days' order by data_messaggio desc,messaggio_id desc loop
  begin
   perform private.valuta_originale_k(p_sessione,m.messaggio_id);
  exception when others then
   insert into public.keplero_verifiche_originali(sessione,messaggio_id,esito,motivo)
   values(p_sessione,m.messaggio_id,'da_verificare','Errore nella regola: originale conservato, verifica operatore richiesta.')
   on conflict(sessione,messaggio_id) do update set esito='da_verificare',motivo=excluded.motivo,updated_at=now();
  end;
 end loop;
 update public.keplero_sessioni_originali set ultimo_successo_at=now(),errore=null,messaggi=jsonb_array_length(p_messaggi) where sessione=p_sessione;
 return jsonb_build_object('esito','completato','messaggi',jsonb_array_length(p_messaggi));
end; $function$


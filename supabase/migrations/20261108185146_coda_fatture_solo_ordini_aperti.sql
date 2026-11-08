create or replace function public.fic_documenti_chat_da_controllare()
returns jsonb language plpgsql security invoker set search_path='' as $$
declare ids jsonb; risultato jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('sessione',m.sessione,'id',m.messaggio_id)),'[]') into ids from (
  select k.sessione,k.messaggio_id from public.keplero_originali k
  left join public.fic_controlli_pdf_chat c using(sessione,messaggio_id)
  where k.direzione='uscita' and k.tipo='file' and not k.modificato and k.testo~*'\.pdf$'
   and k.data_messaggio>now()-interval '30 days'
   and exists(select 1 from public.pratiche p where p.tipo_flusso='commerciale'
     and p.stato_commerciale='ordine_acquisito' and p.stato_fatturazione='da_fatturare'
     and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
     and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
     and private.pratica_nella_conversazione_k(p.id,k.sessione))
   and (c.sessione is null or (c.esito='pendente' and c.ultimo_tentativo_at<now()-interval '30 minutes'))
  order by c.ultimo_tentativo_at nulls first,k.data_messaggio desc,k.sessione,k.messaggio_id limit 2
 ) m;
 insert into public.fic_controlli_pdf_chat(sessione,messaggio_id)
 select (x->>'sessione')::uuid,x->>'id' from jsonb_array_elements(ids) x
 on conflict(sessione,messaggio_id) do update set ultimo_tentativo_at=now();
 select coalesce(jsonb_agg(jsonb_build_object('sessione',k.sessione,'id',k.messaggio_id,'data',k.data_messaggio,
  'direzione',k.direzione,'tipo',k.tipo,'testo',k.testo,'originale',k.originale,'sha256_pdf',k.sha256_pdf)),'[]') into risultato
 from public.keplero_originali k join jsonb_array_elements(ids) x on k.sessione=(x->>'sessione')::uuid and k.messaggio_id=x->>'id';
 return risultato;
end; $$;


-- Un PDF gia registrato su un'altra conversazione resta una verifica di
-- collegamento. Non riprovare l'applicazione come se fosse lo stesso episodio.
create or replace function private.riprova_pdf_originale_letto_k(p_sessione uuid,p_messaggio text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare m public.keplero_originali%rowtype; d public.documenti_preventivo_auto%rowtype;
begin
 select * into m from public.keplero_originali where sessione=p_sessione and messaggio_id=p_messaggio;
 if m.modificato or m.direzione<>'uscita' or m.targa_pdf is null or m.sha256_pdf is null then
  return jsonb_build_object('esito','prova_non_verificata');end if;
 if (select count(distinct impronta) from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf)<>1 then
  return jsonb_build_object('esito','documento_assente_o_ambiguo');end if;
 select * into d from public.documenti_preventivo_auto where sha256_pdf=m.sha256_pdf and targa=m.targa_pdf
  order by (stato='inviato') desc,ricevuto_at,id limit 1;
 if d.stato='inviato' and not private.pratica_nella_conversazione_k(d.pratica_id,m.sessione) then
  return jsonb_build_object('esito','conversazione_da_verificare');
 end if;
 return public.conferma_invio_documento_preventivo(d.id,jsonb_build_object('fonte','keplero_originale_verificato',
  'fonte_id','keplero:'||m.sessione||':'||m.messaggio_id,'direzione','uscita','esito','inviato',
  'impronta_documento',d.impronta,'messaggio_id',m.messaggio_id,'conversazione_id',m.sessione,
  'verificata_originale',true,'inviato_at',m.data_messaggio));
end; $$;
revoke all on function private.riprova_pdf_originale_letto_k(uuid,text) from public,anon,authenticated;
grant execute on function private.riprova_pdf_originale_letto_k(uuid,text) to service_role;

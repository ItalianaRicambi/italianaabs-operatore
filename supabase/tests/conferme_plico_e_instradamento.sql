-- Collaudo in transazione: nessuna pratica di prova viene conservata.
begin;
do $test$
declare p uuid; other_p uuid; v_event_id bigint; quote_id uuid; offer_id uuid;
 payload jsonb; result jsonb; v_at timestamptz:=now()-interval '2 hours';
begin
 insert into public.pratiche(targa,telefono,nome_cliente,marca_veicolo,tipo_componente,tipo_flusso,
   stato_commerciale,preventivo_inviato_at)
 values('TSTP900','390000009900','Test rollback','Suzuki','ABS','commerciale','preventivo_inviato',v_at)
 returning id into p;
 insert into public.preventivi(pratica_id,stato,inviato_at,creato_at) values(p,'inviato',v_at,v_at) returning id into quote_id;
 insert into public.offerte_versioni(pratica_id,preventivo_id,versione,targa,inviato_at,fonte,stato,impronta,testo_documento)
 values(p,quote_id,1,'TSTP900',v_at,'pdf','letta','test:plico:rollback','Suzuki ABS 56110-TEST9') returning id into offer_id;
 insert into public.offerta_opzioni(offerta_id,numero,servizio,importo,numero_esplicito,iva_inclusa,reso_vecchio,descrizione,condizioni) values(offer_id,1,'RI',447,false,true,false,'Riparazione idraulica','Test rollback');
 payload:=jsonb_build_object('targa','TSTP900','telefono','390000009900','marca_veicolo','Suzuki',
   'tipo_flusso','commerciale','codici_identificativi',jsonb_build_array('56110-TEST9'),
   'ordine_confermato_rilevato',false);
 if private.preventivo_univoco_per_payload('390000009900','TSTP900','Suzuki',payload) is distinct from p then
   raise exception 'Preventivo univoco non riconosciuto'; end if;
 if private.preventivo_univoco_per_payload('390000009901','TSTP900','Suzuki',payload) is not null
 or private.preventivo_univoco_per_payload('390000009900','TSTP901','Suzuki',payload) is not null
 or private.preventivo_univoco_per_payload('390000009900','TSTP900','Fiat',payload) is not null
 or private.preventivo_univoco_per_payload('390000009900','TSTP900','Suzuki',payload||'{"codici_identificativi":["56110-TEST8"]}') is not null
 then raise exception 'Identità o codici differenti abbinati'; end if;
 insert into public.pratiche(targa,telefono,nome_cliente,marca_veicolo,tipo_flusso,stato_commerciale)
 values('TSTP900','390000009900','Test rollback','Suzuki','commerciale','raccolta_dati') returning id into other_p;
 insert into public.keplero_live_links(external_key,pratica_id) values('test:plico:canonico',p),('test:plico:route',other_p);
 result:=public.prepara_instradamento_keplero('test:plico:route',null,'390000009900','TSTP900','Suzuki','Vitara',payload);
 if result->>'pratica_id' is distinct from p::text or result->>'external_key' is distinct from 'test:plico:canonico' then raise exception 'Instradamento non recuperato: %',result; end if;
 -- La chiave storica resta associata alla scheda originaria.
 update public.pratiche set blocco_operatore=true where id=other_p;
 perform public.prepara_instradamento_keplero('test:plico:route',null,'390000009900','TSTP900','Suzuki','Vitara',payload);
 if (select pratica_id from public.keplero_live_links where external_key='test:plico:route')<>other_p then
   raise exception 'Blocco operatore ignorato'; end if;
 -- Un flag di archivio senza destinazione non autorizza a ignorare un blocco.
 update public.pratiche set dati_raw='{"pratica_duplicata":{"archiviata":true}}' where id=other_p;
 result:=public.prepara_instradamento_keplero('test:plico:route',null,'390000009900','TSTP900','Suzuki','Vitara',payload);
 if result->>'pratica_id' is distinct from other_p::text then raise exception 'Consolidamento senza destinazione ignora blocco'; end if;
 perform set_config('app.allow_archived_record_update','1',true);
 update public.pratiche set dati_raw='{}'::jsonb,blocco_operatore=false where id=other_p;
 perform set_config('app.allow_archived_record_update','0',true);
 update public.pratiche set stato_commerciale='chiuso',blocco_operatore=true,
   dati_raw=jsonb_build_object('pratica_duplicata',jsonb_build_object('archiviata',true,'pratica_canonica_id',p))
   where id=other_p;
 result:=public.prepara_instradamento_keplero('test:plico:route',null,'390000009900','TSTP900','Suzuki','Vitara',payload);
 if result->>'pratica_id' is distinct from p::text or result->>'external_key' is distinct from 'test:plico:canonico' then
   raise exception 'Scheda consolidata interrompe continuità: %',result; end if;
 perform public.prepara_instradamento_keplero('test:plico:route',null,'390000009900','TSTP900','Suzuki','Vitara',payload);
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:plico:canonico',p,payload||jsonb_build_object('ultimo_messaggio_cliente','Plico effettuato.'));
 if (select stato_commerciale from public.pratiche where id=p)<>'preventivo_inviato' then
   raise exception 'Solo plico ha confermato ordine'; end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:plico:canonico',p,payload||jsonb_build_object('ultimo_messaggio_cliente','CF MRNGBR65B02B354V. Email: test@example.invalid.',
   'descrizione_guasto','Il cliente sta valutando l’offerta.')) returning id into v_event_id;
 if (select stato_commerciale from public.pratiche where id=p)<>'preventivo_inviato' then
   raise exception 'Valutazione ha confermato ordine'; end if;
 insert into public.offerta_opzioni(offerta_id,numero,servizio,importo,numero_esplicito,iva_inclusa,reso_vecchio,descrizione,condizioni) values(offer_id,2,'PS',597,false,true,true,'Programma scambio','Test rollback');
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:plico:canonico',p,payload||jsonb_build_object('ultimo_messaggio_cliente','CF MRNGBR65B02B354V. Email: test@example.invalid.',
   'descrizione_guasto','Accettazione di un’offerta per la revisione della centralina ABS.')) returning id into v_event_id;
 if (select stato_commerciale from public.pratiche where id=p)<>'preventivo_inviato' then
   raise exception 'Alternative ambigue hanno confermato ordine'; end if;
 delete from public.offerta_opzioni where offerta_id=offer_id and numero=2;
 update public.offerte_versioni set validita_giorni=1,inviato_at=now()-interval '2 days' where id=offer_id;
 update public.pratiche set preventivo_inviato_at=now()-interval '2 days' where id=p;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:plico:canonico',p,payload||jsonb_build_object('ultimo_messaggio_cliente','CF MRNGBR65B02B354V. Email: test@example.invalid.',
   'descrizione_guasto','Accettazione di un’offerta per la revisione della centralina ABS.'));
 if (select stato_commerciale from public.pratiche where id=p)<>'preventivo_inviato' then
   raise exception 'Offerta scaduta confermata'; end if;
 update public.offerte_versioni set validita_giorni=null,inviato_at=v_at where id=offer_id;
 update public.pratiche set preventivo_inviato_at=v_at where id=p;
 update public.pratiche set blocco_operatore=true where id=p;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:plico:canonico',p,payload||jsonb_build_object('ultimo_messaggio_cliente','CF MRNGBR65B02B354V. Email: test@example.invalid.',
   'descrizione_guasto','Accettazione di un’offerta per la revisione della centralina ABS.')) returning id into v_event_id;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:plico:canonico',p,payload||jsonb_build_object('ultimo_messaggio_cliente','Non procedo.'));
 update public.pratiche set blocco_operatore=false where id=p;
 if private.ordine_da_plico_e_fiscali(v_event_id)->>'confermato'='true' then
   raise exception 'Revoca successiva ignorata'; end if;
 -- Rimuove esclusivamente il messaggio sintetico per proseguire il caso positivo.
 delete from public.keplero_live_events ev where ev.pratica_id=p and ev.payload->>'ultimo_messaggio_cliente'='Non procedo.';
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('test:plico:canonico',p,payload||jsonb_build_object('ultimo_messaggio_cliente','CF MRNGBR65B02B354V. Email: test@example.invalid.',
   'descrizione_guasto','Accettazione di un’offerta per la revisione della centralina ABS.')) returning id into v_event_id;
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare') then
   raise exception 'Plico + fiscali + offerta unica non acquisiti: %',(select decisione from private.keplero_event_processing where event_id=v_event_id); end if;
 result:=public.esito_ordine_contestuale_keplero(p,'test:plico:canonico');
 if result#>>'{contesto,regola}' is distinct from 'plico_pronto_fiscali_offerta_unica_v1' then
   raise exception 'Prova non disponibile al bot: %',result; end if;
 if public.conferma_ordine_da_keplero(p,'test:plico:canonico','CF MRNGBR65B02B354V.')->>'motivo'<>'ordine_gia_acquisito' then
   raise exception 'Conferma non idempotente'; end if;
end; $test$;
rollback;

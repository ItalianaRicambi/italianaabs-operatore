-- Dati sintetici e nessun invio esterno. Eseguire dopo stabilizza_pratiche_keplero.
begin;
create temporary table risultati_affidabilita(caso text primary key);
grant all on risultati_affidabilita to service_role;
create function pg_temp.caso_k(t text,s uuid default gen_random_uuid(),secondario boolean default false,storico boolean default false,alternative integer default 1)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p uuid; d uuid; impronta text:=encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex');
 sha text:=encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex'); dt timestamptz; contenuto jsonb;
begin
 dt:=case when storico then now()-interval '35 days' else now()-interval '1 hour' end;
 insert into public.pratiche(keplero_conversation_id,targa,telefono,nome_cliente,tipo_flusso,stato_commerciale,stato_completezza,descrizione_guasto,dati_raw)
 values(case when secondario then null else s::text end,t,'390000000000','Collaudo sintetico rollback','commerciale','raccolta_dati','dati_mancanti','Guasto descritto da verificare',
  jsonb_build_object('origine','test_affidabilita','codici_identificativi_estratti',jsonb_build_array(jsonb_build_object('codice','TEST-ABS')),
   'payload_live',jsonb_build_object('decisione_sistema',jsonb_build_object('completezza',jsonb_build_object('datiMancanti',jsonb_build_array('dtc_con_spie_accese')))))) returning id into p;
 insert into public.keplero_live_links(external_key,pratica_id) values('conversation:'||s||case when secondario then ':veicolo:'||lower(t) else '' end,p);
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,targa_pdf,sha256_pdf)
 values(s,'pdf-'||t,dt,dt::text,'uscita','file','attachment:https://v2.api.keplero.ai/v2/session-attachments/test-'||t||'.pdf',repeat('a',64),true,false,t,sha);
 contenuto:=jsonb_build_object('impronta',impronta,'testo','Preventivo sintetico '||t,'opzioni',jsonb_build_array(jsonb_build_object('numero',1,'numero_esplicito',true,'servizio','RI','importo',447,'valuta','EUR')));
 if alternative=2 then contenuto:=jsonb_set(contenuto,'{opzioni}',(contenuto->'opzioni')||jsonb_build_array(jsonb_build_object('numero',2,'numero_esplicito',true,'servizio','PS','importo',597,'valuta','EUR')));end if;
 insert into public.documenti_preventivo_auto(external_id,impronta,sha256_pdf,nome_file,targa,file_url,data_offerta,contenuto,stato)
 values('test-affidabilita:'||s||':'||t,impronta,sha,t||'.pdf',''||t,'https://v2.api.keplero.ai/v2/session-attachments/test-'||t||'.pdf',dt,contenuto,'da_abbinare') returning id into d;
 return jsonb_build_object('pratica',p,'documento',d,'sessione',s,'messaggio','pdf-'||t,'data',dt,'impronta',impronta,'sha',sha);
end; $$;

create function pg_temp.messaggio_k(s uuid,id text,testo text,candidato boolean default true,revoca boolean default false)
returns void language plpgsql security invoker set search_path='' as $$
begin
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca)
 values(s,id,now()-interval '10 minutes',(now()-interval '10 minutes')::text,'entrata','text',testo,encode(sha256(convert_to(testo,'UTF8')),'hex'),candidato,revoca);
end; $$;

set local role service_role;
do $test$
declare x jsonb; y jsonb; r jsonb; p uuid; d uuid; s uuid; q uuid; v_chiave text; imp text; n integer; msg text; i integer;
begin
 if has_table_privilege('anon','public.keplero_esiti_fonti','select')
  or has_table_privilege('authenticated','public.keplero_lavori_pratiche','update')
  or has_function_privilege('anon','public.riconcilia_esiti_commerciali_k(integer,boolean)','execute')
  or has_function_privilege('authenticated','public.esito_registrazione_commerciale_k(uuid,text)','execute')
  or has_function_privilege('anon','private.leggi_esito_elaborazione_k(bigint)','execute')
  or has_table_privilege('service_role','private.keplero_event_processing','select')
  or has_table_privilege('service_role','private.keplero_event_processing','update') then raise exception 'Permessi pubblici non consentiti';end if;
 insert into risultati_affidabilita values('RLS e funzioni riservate al backend');

 -- BMW: l'assenza dei DTC mantiene un lavoro visibile, senza inventare la diagnosi.
 x:=pg_temp.caso_k('ZZ101AA');p:=(x->>'pratica')::uuid;d:=(x->>'documento')::uuid;s:=(x->>'sessione')::uuid;
 perform private.aggiorna_lavoro_pratica_k(p);
 if not exists(select 1 from public.keplero_lavori_pratiche_elenco where pratica_id=p and verifica_tecnica_necessaria)
  or not exists(select 1 from public.pratiche where id=p and stato_completezza='dati_mancanti' and diagnosi_presente is null) then raise exception 'Richiesta tecnica persa o diagnosi inventata';end if;
 insert into risultati_affidabilita values('DTC mancanti: richiesta visibile e completezza preservata');

 -- Un PDF generato non equivale a inviato: il solo hash non basta senza originale.
 update public.keplero_originali set sha256_pdf=null where sessione=s and messaggio_id=x->>'messaggio';
 r:=private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 if r->>'esito'<>'prova_non_verificata' or exists(select 1 from public.preventivi where pratica_id=p) then raise exception 'Emissione scambiata per invio';end if;
 update public.keplero_originali set sha256_pdf=x->>'sha' where sessione=s and messaggio_id=x->>'messaggio';
 r:=private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 if r->>'ok' is distinct from 'true' or r->>'pratica_id'<>p::text then raise exception 'PDF originale non collegato: %',r;end if;
 q:=(r->>'preventivo_id')::uuid;
 if (select inviato_at from public.preventivi where id=q) is distinct from (x->>'data')::timestamptz then raise exception 'Data invio non originale';end if;
 insert into risultati_affidabilita values('Emissione distinta dall’invio; prova e data originale verificate');

 -- Replay e copie identiche non creano preventivi ulteriori.
 for i in 1..3 loop perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');end loop;
 insert into public.documenti_preventivo_auto(external_id,impronta,sha256_pdf,nome_file,targa,file_url,data_offerta,contenuto,pratica_id,stato)
 select external_id||':copia',impronta,sha256_pdf,nome_file,targa,file_url,data_offerta,contenuto,pratica_id,'pronto' from public.documenti_preventivo_auto where id=d;
 perform pg_temp.messaggio_k(s,'consenso','Accetto preventivo');
 perform private.valuta_originale_k(s,'consenso');
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and stato_fatturazione='da_fatturare' and stato_amministrativo='dati_mancanti')
  or (select count(*) from public.preventivi where pratica_id=p)<>1 then raise exception 'Replay/copia/ordine non corretti';end if;
 if (select accettato_at from public.preventivi where id=q)<>(select data_messaggio from public.keplero_originali where sessione=s and messaggio_id='consenso') then raise exception 'Data consenso non originale';end if;
 perform private.valuta_originale_k(s,'consenso');
 if (select count(*) from public.scelte_cliente where pratica_id=p)<>1 then raise exception 'Scelta duplicata';end if;
 insert into risultati_affidabilita values('Consenso unico con copia PDF, replay, date e anagrafica incompleta');
 r:=public.esito_registrazione_commerciale_k(p,'conversation:'||s);
 if r->>'ordine_registrato'<>'true' then raise exception 'Ricevuta non conferma ordine salvato';end if;
 insert into risultati_affidabilita values('Ricevuta restituisce lo stato effettivamente salvato');

 -- Milione: fonte storica nella stessa chat, pratica nata dopo settimane.
 x:=pg_temp.caso_k('ZZ102AA',gen_random_uuid(),false,true);p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 r:=private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 if r->>'ok' is distinct from 'true' then raise exception 'Offerta storica non collegata: %',r;end if;
 perform pg_temp.messaggio_k(s,'consenso','Accetto preventivo');perform private.valuta_originale_k(s,'consenso');
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Consenso su offerta storica perso';end if;
 insert into risultati_affidabilita values('Preventivo storico e consenso successivo senza scadenza inventata');

 -- Toyota: una chat con più episodi, collegamento secondario e targa esplicita.
 s:=gen_random_uuid();x:=pg_temp.caso_k('ZZ103AA',s);y:=pg_temp.caso_k('ZZ104AA',s,true);
 perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 r:=private.riprova_pdf_originale_letto_k(s,y->>'messaggio');
 if r->>'ok' is distinct from 'true' or r->>'pratica_id'<>y->>'pratica' then raise exception 'Episodio secondario non riconosciuto: %',r;end if;
 perform pg_temp.messaggio_k(s,'generico','Accetto preventivo');perform private.valuta_originale_k(s,'generico');
 if exists(select 1 from public.pratiche where id in ((x->>'pratica')::uuid,(y->>'pratica')::uuid) and stato_commerciale='ordine_acquisito') then raise exception 'Ultimo veicolo scelto arbitrariamente';end if;
 perform private.valuta_fonte_commerciale_k('originale',s||':generico');
 perform private.aggiorna_lavori_senza_pratica_k();
 if not exists(select 1 from public.keplero_lavori_pratiche where chiave='chat:'||s and stato<>'risolta') then raise exception 'Consenso ambiguo senza lavoro persistente';end if;
 perform pg_temp.messaggio_k(s,'esplicito','Accetto preventivo ZZ104AA');perform private.valuta_originale_k(s,'esplicito');
 if not exists(select 1 from public.pratiche where id=(y->>'pratica')::uuid and stato_commerciale='ordine_acquisito')
  or exists(select 1 from public.pratiche where id=(x->>'pratica')::uuid and stato_commerciale='ordine_acquisito') then raise exception 'Consenso sul veicolo esplicito errato';end if;
 insert into risultati_affidabilita values('Chat multiveicolo: PDF secondario, consenso ambiguo e consenso con targa');

 -- Un'origine diversa con medesima targa non autorizza l'aggancio.
 x:=pg_temp.caso_k('ZZ105AA');s:=gen_random_uuid();
 if private.pratica_nella_conversazione_k((x->>'pratica')::uuid,s) then raise exception 'Conversazione estranea accettata';end if;
 insert into risultati_affidabilita values('Conversazioni estranee restano separate');

 -- Lo stesso PDF gia inviato, copiato in un'altra chat, non viene riassegnato
 -- e non genera un errore tecnico ripetuto nel recupero generale.
 x:=pg_temp.caso_k('ZZ140AA');p:=(x->>'pratica')::uuid;
 perform private.riprova_pdf_originale_letto_k((x->>'sessione')::uuid,x->>'messaggio');
 s:=gen_random_uuid();
 insert into public.keplero_originali(sessione,messaggio_id,data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,targa_pdf,sha256_pdf)
 select s,'copia-chat-distinta',data_messaggio,data_originale,direzione,tipo,testo,impronta,candidato,revoca,targa_pdf,sha256_pdf
 from public.keplero_originali where sessione=(x->>'sessione')::uuid and messaggio_id=x->>'messaggio';
 for i in 1..2 loop
  r:=private.riprova_pdf_originale_letto_k(s,'copia-chat-distinta');
  if r->>'esito' is distinct from 'conversazione_da_verificare' then raise exception 'Copia in altra chat non trattenuta: %',r;end if;
  perform private.valuta_fonte_commerciale_k('originale',s||':copia-chat-distinta');
 end loop;
 if not exists(select 1 from public.keplero_esiti_fonti where fonte='originale' and chiave=s||':copia-chat-distinta'
  and stato='da_verificare' and codice='pdf_inviato_non_collegato' and errore is null)
  or not exists(select 1 from public.documenti_preventivo_auto where id=(x->>'documento')::uuid and pratica_id=p and stato='inviato')
  or (select count(*) from public.preventivi where pratica_id=p)<>1
  or private.pratica_nella_conversazione_k(p,s) then raise exception 'Copia in altra chat: prova, collegamento o stato alterati';end if;
 insert into risultati_affidabilita values('PDF copiato in altra chat: verifica visibile, nessuna riassegnazione o errore al replay');

 -- Scelta di alternativa, condizioni, revoca, numeri economici.
 for i in 1..7 loop
  x:=pg_temp.caso_k('ZZ'||(110+i)::text||'AA',gen_random_uuid(),false,false,2);p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
  perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
  msg:=(array['Accetto preventivo','Confermo RI se disponibile','Non confermo RI','Confermo il mio indirizzo','Confermo idraulica e programma scambio','Accetto per 300 euro','Confermo RI'])[i];
  perform pg_temp.messaggio_k(s,'risposta',msg,true,i=3);perform private.valuta_originale_k(s,'risposta');
  if i=7 then
   if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Opzione esplicita non acquisita';end if;
  elsif exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Consenso ambiguo acquisito: %',msg;end if;
 end loop;
 insert into risultati_affidabilita values('Alternative, condizioni, negazioni, indirizzi e importi discordanti');

 -- Messaggi logistici successivi non cancellano un consenso precedente.
 x:=pg_temp.caso_k('ZZ120AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 perform pg_temp.messaggio_k(s,'ordine','Accetto preventivo');
 perform pg_temp.messaggio_k(s,'indirizzo','Confermo indirizzo di spedizione');
 update public.keplero_originali set data_messaggio=now()-interval '5 minutes' where sessione=s and messaggio_id='indirizzo';
 perform private.valuta_originale_k(s,'ordine');
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Logistica ha cancellato consenso';end if;
 insert into risultati_affidabilita values('Logistica successiva non invalida l’accettazione');

 -- Un testo non classificato da K non viene ignorato dopo il preventivo.
 x:=pg_temp.caso_k('ZZ121AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 perform pg_temp.messaggio_k(s,'ignoto','Benissimo, facciamo andare avanti questa cosa',false);
 perform private.valuta_fonte_commerciale_k('originale',s||':ignoto');
 if not exists(select 1 from public.keplero_esiti_fonti where fonte='originale' and chiave=s||':ignoto' and stato='da_verificare' and codice='risposta_cliente_da_valutare') then raise exception 'Variante sconosciuta persa';end if;
 select impronta into imp from public.keplero_esiti_fonti where fonte='originale' and chiave=s||':ignoto';
 perform public.verifica_esito_fonte_k('originale',s||':ignoto',imp,'Verificata la richiesta e completata la gestione nella pratica.','Manutenzione autorizzata');
 perform private.valuta_fonte_commerciale_k('originale',s||':ignoto');
 if not exists(select 1 from public.keplero_esiti_fonti where chiave=s||':ignoto' and verificata_operatore and codice='verifica_operatore') then raise exception 'Verifica umana non preservata';end if;
 -- Un nuovo messaggio riapre, anche se l'assistente risponde.
 perform pg_temp.messaggio_k(s,'nuovo','Aspettate, devo cambiare la lavorazione',false,true);
 perform private.valuta_fonte_commerciale_k('originale',s||':nuovo');
 if not exists(select 1 from public.keplero_lavori_pratiche where pratica_id=p and stato<>'risolta') then raise exception 'Nuovo lavoro non riaperto';end if;
 insert into risultati_affidabilita values('Varianti sconosciute, verifica motivata e riapertura per nuovo messaggio');

 -- Presa in carico non significa risoluzione e richiede la versione corrente.
 select chiave,versione into v_chiave,n from public.keplero_lavori_pratiche where pratica_id=p;
 perform public.prendi_in_carico_lavoro_k(v_chiave,'Manutenzione autorizzata',n);
 begin
  perform public.prendi_in_carico_lavoro_k(v_chiave,'Manutenzione autorizzata',n);
  raise exception 'Versione obsoleta accettata';
 exception when raise_exception then if sqlerrm='Versione obsoleta accettata' then raise;end if;end;
 if not exists(select 1 from public.keplero_lavori_pratiche l where l.chiave=v_chiave and stato='in_carico') then raise exception 'Presa in carico non persistita';end if;
 insert into risultati_affidabilita values('Responsabile, versione e lavoro ancora aperto dopo presa in carico');

 -- Nessuna targa: lavoro persistente prima della creazione della pratica.
 s:=gen_random_uuid();r:=public.conserva_richiesta_senza_pratica_k('conversation:'||s,s,'{"ultimo_messaggio_cliente":"Un altro veicolo, devo chiedere preventivo"}');
 if r->>'ricevuta' is distinct from 'true' or not exists(select 1 from public.keplero_lavori_pratiche where chiave='chat:'||s and stato='aperta') then raise exception 'Richiesta senza targa persa';end if;
 if not exists(select 1 from public.keplero_esiti_fonti where fonte='richiesta' and chiave=r->>'riferimento' and contenuto_richiesta->>'ultimo_messaggio_cliente'='Un altro veicolo, devo chiedere preventivo') then raise exception 'Contenuto richiesta senza targa non conservato';end if;
 insert into risultati_affidabilita values('Nuovo episodio senza targa conservato senza sovrascrivere altri veicoli');
 -- Il flag AI non sostituisce offerta letta e scelta, nemmeno con stato inviato manuale.
 x:=pg_temp.caso_k('ZZ130AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 update public.pratiche set stato_commerciale='preventivo_inviato',preventivo_inviato_at=now()-interval '1 hour' where id=p;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('conversation:'||s,p,jsonb_build_object('targa','ZZ130AA','ultimo_messaggio_cliente','Come si effettua il bonifico?','ordine_confermato_rilevato',true)) returning id into n;
 perform private.valuta_fonte_commerciale_k('live',n::text);
 if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito')
  or not exists(select 1 from public.keplero_esiti_fonti where fonte='live' and chiave=n::text and codice='consenso_non_registrato' and stato='da_verificare') then raise exception 'Flag AI: stato=%, registro=%, elaborazione=%',
  (select stato_commerciale from public.pratiche where id=p),
  (select jsonb_build_object('stato',stato,'codice',codice,'errore',errore) from public.keplero_esiti_fonti where fonte='live' and chiave=n::text),
  private.leggi_esito_elaborazione_k(n);end if;
 insert into risultati_affidabilita values('Flag AI positivo senza prova: ordine trattenuto ed eccezione visibile');

 -- Doppio messaggio: consenso generico e poi scelta breve, con replay.
 x:=pg_temp.caso_k('ZZ131AA',gen_random_uuid(),false,false,2);p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('conversation:'||s,p,jsonb_build_object('targa','ZZ131AA','ultimo_messaggio_cliente','Accetto il preventivo','ordine_confermato_rilevato',true),now()-interval '2 minutes');
 if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Scelta ambigua acquisita prima del chiarimento';end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 values('conversation:'||s,p,jsonb_build_object('targa','ZZ131AA','ultimo_messaggio_cliente','RI'),now()-interval '1 minute') returning id into n;
 set local role postgres;
 perform private.riprocessa_evento_keplero(n);
 set local role service_role;
 if not exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito' and ordine_acquisito_at=now()-interval '1 minute')
  or not exists(select 1 from public.scelte_cliente where pratica_id=p and stato='confermata') then raise exception 'Chiarimento breve o replay non corretti';end if;
 insert into public.keplero_live_events(external_key,pratica_id,payload,created_at)
 select external_key,pratica_id,payload,created_at from public.keplero_live_events where id=n;
 if not exists(select 1 from public.scelte_cliente where pratica_id=p and stato='confermata') then raise exception 'Risposta breve duplicata ha modificato la scelta';end if;
 insert into risultati_affidabilita values('Consenso e scelta su due messaggi: ordine e data preservati al replay');

 -- Scadenza esplicita, documento illeggibile e correzioni operatore.
 x:=pg_temp.caso_k('ZZ132AA',gen_random_uuid(),false,true);p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 update public.documenti_preventivo_auto set contenuto=contenuto||'{"validita_giorni":15}' where id=(x->>'documento')::uuid;
 perform private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 perform pg_temp.messaggio_k(s,'scaduto','Accetto preventivo');perform private.valuta_originale_k(s,'scaduto');
 if exists(select 1 from public.pratiche where id=p and stato_commerciale='ordine_acquisito') then raise exception 'Offerta scaduta acquisita';end if;
 x:=pg_temp.caso_k('ZZ133AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 update public.documenti_preventivo_auto set contenuto=contenuto||'{"errore":"Lettura da verificare"}' where id=(x->>'documento')::uuid;
 r:=private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 if r->>'esito' is distinct from 'lettura_da_verificare' or exists(select 1 from public.preventivi where pratica_id=p) then raise exception 'PDF illeggibile trattato come offerta letta: %',r;end if;
 x:=pg_temp.caso_k('ZZ134AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 update public.pratiche set blocco_operatore=true where id=p;
 r:=private.riprova_pdf_originale_letto_k(s,x->>'messaggio');
 if r->>'esito' is distinct from 'blocco_operatore' or exists(select 1 from public.preventivi where pratica_id=p)
  or not exists(select 1 from public.documenti_preventivo_auto where id=(x->>'documento')::uuid and prova_invio is not null) then raise exception 'Blocco o conservazione prova non corretti';end if;
 insert into risultati_affidabilita values('Scadenza esplicita, PDF illeggibile e blocco operatore non aggirati');

 -- L'assenza dell'esito o un errore del motore non possono diventare successo.
 x:=pg_temp.caso_k('ZZ135AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('conversation:'||s,p,jsonb_build_object('targa','ZZ135AA','ultimo_messaggio_cliente','Dati componente allegati')) returning id into n;
 set local role postgres;
 delete from private.keplero_event_processing where event_id=n;
 set local role service_role;
 perform private.valuta_fonte_commerciale_k('live',n::text);
 if not exists(select 1 from public.keplero_esiti_fonti where fonte='live' and chiave=n::text and codice='elaborazione_non_verificata' and stato='in_attesa') then raise exception 'Esito assente scambiato per successo';end if;
 set local role postgres;
 perform private.elabora_evento_keplero(n);
 update private.keplero_event_processing set stato='da_verificare' where event_id=n;
 set local role service_role;
 perform private.valuta_fonte_commerciale_k('live',n::text);
 if not exists(select 1 from public.keplero_esiti_fonti where fonte='live' and chiave=n::text and codice='ingresso_da_verificare' and stato='da_verificare') then raise exception 'Allegato da verificare scambiato per successo';end if;
 set local role postgres;
 update private.keplero_event_processing set stato='errore',errore='Errore sintetico' where event_id=n;
 set local role service_role;
 perform private.valuta_fonte_commerciale_k('live',n::text);
 if not exists(select 1 from public.keplero_esiti_fonti where fonte='live' and chiave=n::text and codice='errore_elaborazione' and stato='da_verificare') then raise exception 'Errore scambiato per successo';end if;
 insert into risultati_affidabilita values('Esito mancante, allegati da verificare ed errore restano visibili');
 -- Anche la chiamata backend del riconciliatore usa i privilegi previsti,
 -- senza allargare l’accesso diretto del servizio al registro interno.
 x:=pg_temp.caso_k('ZZ136AA');p:=(x->>'pratica')::uuid;s:=(x->>'sessione')::uuid;
 insert into public.keplero_live_events(external_key,pratica_id,payload)
 values('conversation:'||s,p,jsonb_build_object('targa','ZZ136AA','ultimo_messaggio_cliente','Dati del componente ricevuti')) returning id into n;
 update public.keplero_esiti_fonti set prossimo_tentativo_at=now()+interval '1 day' where fonte<>'live' or chiave<>n::text;
 r:=public.riconcilia_esiti_commerciali_k(1,true);
 if r->>'esito' is distinct from 'completato' or r->>'esiti_elaborati' is distinct from '1'
  or not exists(select 1 from public.keplero_esiti_fonti where fonte='live' and chiave=n::text and stato='applicato' and errore is null)
 then raise exception 'Riconciliazione backend non completa: %',r;end if;
 r:=public.stato_esiti_commerciali_k();
 if jsonb_typeof(r->'controllo') is distinct from 'object' then raise exception 'Stato controllo non leggibile dal backend';end if;
 insert into risultati_affidabilita values('Permessi reali: riconciliazione e stato backend senza accesso diretto al registro');
 if public.riconcilia_esiti_commerciali_k()->>'esito'<>'sospeso' then raise exception 'Attivazione prematura';end if;
 insert into risultati_affidabilita values('Riconciliatore predisposto ma non attivo prima del collaudo');
end; $test$;
select caso from risultati_affidabilita order by caso;
rollback;

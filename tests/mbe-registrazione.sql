-- Nessuna chiamata esterna. Tutte le scritture di prova sono annullate.
begin isolation level repeatable read;
insert into public.mbe_ticket_worker(impronta,scade_at) values(encode(sha256(convert_to(repeat('a',72),'UTF8')),'hex'),now()+interval '1 minute');
set local role service_role;
do $$
declare p public.pratiche%rowtype; prima jsonb; dopo jsonb; lease uuid; dati jsonb; tracking jsonb; r jsonb; osservazioni bigint; bloccato boolean:=false;
begin
 select * into p from public.pratiche where numero_pratica>0 and upper(targa) ~ '^[A-Z]{2}[0-9]{3}[A-Z]{2}$' order by numero_pratica desc limit 1;
 if p.id is null then raise exception 'Pratica con targa necessaria al collaudo';end if;
 if not public.autorizza_worker_mbe(repeat('a',72)) or public.autorizza_worker_mbe(repeat('a',72)) or public.autorizza_worker_mbe(repeat('b',72)) then raise exception 'Ticket non monouso';end if;
 select to_jsonb(x) into prima from public.pratiche x where id=p.id;
 begin perform public.configura_automatico_mbe(true);exception when others then bloccato:=true;end;
 if not bloccato then raise exception 'Attivazione senza collaudo consentita';end if;
 lease:=public.inizia_sincronizzazione_mbe();
 if lease is null or public.inizia_sincronizzazione_mbe() is not null then raise exception 'Lease concorrenti';end if;
 dati:=jsonb_build_array(jsonb_build_object('tracking_mbe','TEST-MBE-001','riferimento','ABS-'||lpad(p.numero_pratica::text,6,'0')||' — '||upper(p.targa),'data_spedizione','2026-10-15','corriere','UPS','tracking_corriere','001234','colli_mbe','[]'::jsonb,'colli_corriere','[]'::jsonb,'mittente',jsonb_build_object('nome','Mittente fittizio','citta','Novara','paese','IT'),'destinatario',jsonb_build_object('nome','Cliente fittizio','citta','Roma','paese','IT'),'bozza',false));
 dati:=dati||jsonb_build_array((dati->0)||jsonb_build_object('tracking_mbe','TEST-MBE-002','riferimento',upper(p.targa)),(dati->0)||jsonb_build_object('tracking_mbe','TEST-MBE-003','riferimento','ABS-'||p.numero_pratica||' — '||case when upper(p.targa)='ZZ999ZZ' then 'AA000AA' else 'ZZ999ZZ' end),(dati->0)||jsonb_build_object('tracking_mbe','TEST-MBE-004','riferimento','ABS-000001 / ABS-000002'));
 tracking:=jsonb_build_array(jsonb_build_object('tracking_mbe','TEST-MBE-001','stato','WAITING_DELIVERY','data_consegna',null,'descrizione','Attesa MBE','tracking_corriere','009876'));
 r:=public.termina_sincronizzazione_mbe(lease,dati,tracking);
 if r->>'esito'<>'ok' then raise exception 'Importazione fallita';end if;
 if not exists(select 1 from public.mbe_spedizioni where tracking_mbe='TEST-MBE-001' and pratica_id=p.id and abbinamento='abbinata' and stato='WAITING_DELIVERY' and tracking_corriere='001234' and tracking_corriere_stato='009876' and tipo_destinazione='da_classificare') then raise exception 'Abbinamento esatto o codici corriere errati';end if;
 if exists(select 1 from public.mbe_spedizioni where tracking_mbe in ('TEST-MBE-002','TEST-MBE-003','TEST-MBE-004') and pratica_id is not null) then raise exception 'Abbinamento non autorizzato';end if;
 if not exists(select 1 from public.mbe_spedizioni where tracking_mbe='TEST-MBE-003' and abbinamento='da_verificare') then raise exception 'Targa discordante non trattenuta';end if;
 perform public.classifica_spedizione_mbe('TEST-MBE-001','laboratorio','Operatore 3');
 select count(*) into osservazioni from public.mbe_osservazioni;
 lease:=public.inizia_sincronizzazione_mbe();perform public.termina_sincronizzazione_mbe(lease,dati,tracking);
 if (select count(*) from public.mbe_osservazioni)<>osservazioni then raise exception 'Osservazioni duplicate';end if;
 if not exists(select 1 from public.mbe_spedizioni where tracking_mbe='TEST-MBE-001' and tipo_destinazione='laboratorio' and classificata_da='Operatore 3') then raise exception 'Classificazione operatore persa';end if;
 -- Un riferimento cambiato non sposta la spedizione fuori dalla pratica precedente.
 dati:=jsonb_set(dati,'{0,riferimento}','"ABS-99999999999"');
 lease:=public.inizia_sincronizzazione_mbe();perform public.termina_sincronizzazione_mbe(lease,dati,tracking);
 if not exists(select 1 from public.mbe_spedizioni where tracking_mbe='TEST-MBE-001' and pratica_id=p.id and abbinamento='da_verificare') then raise exception 'Riferimento modificato non protetto';end if;
 -- Un errore non importa righe e conserva l'ultimo successo completo.
 select count(*) into osservazioni from public.mbe_osservazioni;
 lease:=public.inizia_sincronizzazione_mbe();perform public.termina_sincronizzazione_mbe(lease,'[]','[]','Errore di collaudo fittizio');
 if (select count(*) from public.mbe_osservazioni)<>osservazioni then raise exception 'Errore ha importato dati';end if;
 if not exists(select 1 from public.mbe_collegamento c where c.ultimo_successo_at is not null and c.ultimo_errore='Errore di collaudo fittizio' and c.lease is null) then raise exception 'Esito errore perso';end if;
 -- Stato di consegna parziale e data di consegna: nessuna transizione della pratica.
 tracking:=jsonb_set(tracking,'{0,stato}','"PARTIALLY_DELIVERED"');
 lease:=public.inizia_sincronizzazione_mbe();perform public.termina_sincronizzazione_mbe(lease,'[]',tracking);
 perform public.configura_automatico_mbe(true);perform public.configura_automatico_mbe(false);
 lease:=public.inizia_sincronizzazione_mbe();
 update public.mbe_collegamento set lease_scade_at=now()-interval '1 second' where id;
 bloccato:=false;
 begin perform public.termina_sincronizzazione_mbe(lease,'[]','[]');exception when others then bloccato:=true;end;
 if not bloccato then raise exception 'Lease scaduta accettata';end if;
 lease:=public.inizia_sincronizzazione_mbe();perform public.termina_sincronizzazione_mbe(lease,'[]','[]');
 select to_jsonb(x) into dopo from public.pratiche x where id=p.id;
 if prima<>dopo then raise exception 'Pratica modificata dal tracking';end if;
 if has_function_privilege('anon','public.termina_sincronizzazione_mbe(uuid,jsonb,jsonb,text)','execute') or has_function_privilege('authenticated','public.inizia_sincronizzazione_mbe()','execute') or has_table_privilege('anon','public.mbe_spedizioni','select') then raise exception 'Accesso pubblico non autorizzato';end if;
end $$;
rollback;
select 'ok: abbinamenti, idempotenza, classificazione, lease, errori, stati pratica e ACL; rollback completo' as verifica;

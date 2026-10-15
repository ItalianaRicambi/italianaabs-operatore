-- Stessa elaborazione per trigger e recupero: nessuna modifica al messaggio originale.
create or replace function private.elabora_evento_keplero(p_event_id bigint)
returns void language plpgsql security invoker set search_path = '' as $outer$
declare v_evento public.keplero_live_events%rowtype;
begin
 select * into v_evento from public.keplero_live_events where id=p_event_id;
 if not found then raise exception 'Evento non trovato'; end if;
 declare
  v_decisione jsonb := coalesce(v_evento.payload -> 'decisione_sistema', '{}'::jsonb);
  v_versione text := coalesce(
    nullif(v_decisione ->> 'versione_regole', ''),
    'legacy-non-strutturato'
  );
  v_ordine boolean := coalesce(
    (v_decisione #>> '{ordine,confermato}')::boolean,
    (v_evento.payload ->> 'ordine_confermato_rilevato')::boolean,
    false
  );
  v_contesto_ordine jsonb := '{}'::jsonb;
  v_allegati jsonb := '[]'::jsonb;
  v_esito_ordine jsonb := '{}'::jsonb;
  v_esito_allegati jsonb := '{}'::jsonb;
  v_stato text := 'elaborato';
begin
  if v_evento.pratica_id is null then
    v_stato := 'da_verificare';
  end if;

  if v_evento.pratica_id is not null then
    v_contesto_ordine := private.ordine_da_conferma_letterale(v_evento.id);
    if not v_ordine and coalesce(v_contesto_ordine->>'confermato','false')<>'true' then
      v_contesto_ordine := private.ordine_da_scelta_e_fiscali(v_evento.id);
    end if;
    v_ordine := v_ordine or coalesce((v_contesto_ordine->>'confermato')::boolean,false);
  end if;

  if v_evento.pratica_id is not null and v_ordine then
    if coalesce(v_contesto_ordine->>'confermato','false')='true' then
      v_esito_ordine := private.conferma_ordine_evento_verificato(v_evento.id)->'avanzamento';
    else
    v_esito_ordine := public.conferma_ordine_da_keplero(
      v_evento.pratica_id,
      v_evento.external_key,
      coalesce(
        v_evento.payload ->> 'ultimo_messaggio_cliente',
        v_evento.payload ->> 'messaggio_cliente',
        v_evento.payload ->> 'messaggio'
      )
    );

    end if;

    if coalesce(v_esito_ordine ->> 'motivo', '') in (
      'preventivo_non_registrato',
      'collegamento_keplero_non_valido',
      'stato_non_abilitato',
      'dati_non_completi'
    ) then
      v_stato := 'da_verificare';
    end if;
  end if;

  with sorgenti as (
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'allegati') = 'array'
          then v_evento.payload -> 'allegati'
        when jsonb_typeof(v_evento.payload -> 'allegati') = 'string'
          then jsonb_build_array(v_evento.payload -> 'allegati')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'attachments') = 'array'
          then v_evento.payload -> 'attachments'
        when jsonb_typeof(v_evento.payload -> 'attachments') = 'string'
          then jsonb_build_array(v_evento.payload -> 'attachments')
        else '[]'::jsonb
      end
    ) elemento
    union all
    select elemento
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_evento.payload -> 'attachment_urls') = 'array'
          then v_evento.payload -> 'attachment_urls'
        when jsonb_typeof(v_evento.payload -> 'attachment_urls') = 'string'
          then jsonb_build_array(v_evento.payload -> 'attachment_urls')
        else '[]'::jsonb
      end
    ) elemento
  ), valori as (
    select case
      when jsonb_typeof(elemento) = 'object' then elemento ->> 'url'
      when jsonb_typeof(elemento) = 'string' then elemento #>> '{}'
      else null
    end valore
    from sorgenti
  ), url as (
    select distinct (regexp_match(valore, 'https?://[^[:space:]<>"]+'))[1] valore
    from valori
    where valore ~ 'https?://'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'url', valore,
    'tipo', case when lower(valore) ~ '[.]pdf([?]|$)' then 'PDF' else 'Allegato' end
  )), '[]'::jsonb)
  into v_allegati
  from url
  where valore is not null;

  if v_evento.pratica_id is not null and jsonb_array_length(v_allegati) > 0 then
    v_esito_allegati := public.sincronizza_allegati_keplero(
      v_evento.pratica_id,
      v_allegati
    );
  elsif v_evento.pratica_id is not null and (
    coalesce(v_evento.payload ->> 'stato_lettura_immagini', '') = 'file_non_trasmessi_da_keplero'
    or coalesce(v_evento.payload ->> 'allegati_descritti_ma_non_trasmessi', 'false') = 'true'
  ) then
    v_stato := 'da_verificare';
  end if;

  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore,
    tentativi, elaborato_at, updated_at
  ) values (
    v_evento.id, v_evento.pratica_id, v_versione, v_stato,
    jsonb_build_object(
      'decisione_ricevuta', v_decisione,
      'esito_ordine', v_esito_ordine,
      'contesto_ordine', v_contesto_ordine,
      'esito_allegati', v_esito_allegati,
      'numero_allegati_url', jsonb_array_length(v_allegati)
    ),
    null, 1, now(), now()
  )
  on conflict (event_id) do update set
    pratica_id = excluded.pratica_id,
    versione_regole = excluded.versione_regole,
    stato = excluded.stato,
    decisione = excluded.decisione,
    errore = null,
    tentativi = private.keplero_event_processing.tentativi + 1,
    elaborato_at = now(),
    updated_at = now();

  return;
exception when others then
  insert into private.keplero_event_processing (
    event_id, pratica_id, versione_regole, stato, decisione, errore
  ) values (
    v_evento.id, v_evento.pratica_id, v_versione, 'errore', v_decisione, sqlerrm
  )
  on conflict (event_id) do update set
    stato = 'errore',
    errore = excluded.errore,
    tentativi = private.keplero_event_processing.tentativi + 1,
    updated_at = now();

  return;
end;

end;
$outer$;
revoke all on function private.elabora_evento_keplero(bigint) from public,anon,authenticated;

create or replace function private.processa_evento_keplero()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 perform private.elabora_evento_keplero(new.id);
 return new;
end; $$;

-- Comprende la richiesta indiretta di contatto da parte del tecnico.
CREATE OR REPLACE FUNCTION private.richiesta_richiamata_esplicita(p_testo text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_testo text := lower(coalesce(p_testo, ''));
  v_callback boolean;
  v_diretta boolean;
begin
  -- Rimuove soltanto le formulazioni negate, senza escludere altre frasi.
  v_testo := regexp_replace(v_testo,
    'non[[:space:]]+(mi[[:space:]]+)?(potete|puo|può|puoi|potreste|potrebbe)[[:space:]]+(farmi[[:space:]]+)?(contattarmi|ricontattarmi|richiamarmi|telefonarmi|chiamarmi|contattare|ricontattare|richiamare|telefonare|chiamare)',
    '', 'g');
  v_diretta := v_testo ~ (
    '((potete|puo|può|puoi|potreste|potrebbe)[[:space:]]+(contattarmi|ricontattarmi|richiamarmi|telefonarmi|chiamarmi)|' ||
    'mi[[:space:]]+(potete|puo|può|puoi|potreste|potrebbe)[[:space:]]+(contattare|ricontattare|richiamare|telefonare|chiamare))'
  );
  v_callback := v_testo ~ (
    '(richiamatemi|mi (potete|puo|può) richiamare|essere (ricontattat|contattat)|' ||
    '(potrei|posso|e possibile|è possibile) parlare con|possiamo sentirci|' ||
    'riusciamo a sentirci|sentirci telefonicamente|parlare telefonicamente|' ||
    'parlare con (qualcuno|un operatore)|a voce|verr[oò] contattat|' ||
    '(aspetto|attendo) (una )?(chiamata|telefonata))'
  );

  if v_testo ~ '(domani|piu tardi|più tardi)?[[:space:]]*(vi|la|le)[[:space:]]+richiam'
     and v_testo !~ '(richiamatemi|mi (potete|puo|può) richiamare|essere (ricontattat|contattat))'
  then
    v_callback := false;
  end if;

  return v_callback or v_diretta or v_testo ~ '(potete|potreste|puo|può)[[:space:]]+farmi[[:space:]]+(ri)?contattare';
end;
$function$;


-- Nuove richieste tecniche post vendita: un episodio separato conserva la
-- chiusura precedente dell'operatore e non riapre la vendita/fatturazione.
create or replace function private.rileva_assistenza_tecnica_evento(p_event_id bigint)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype;
 c public.assistenze_rientri%rowtype; t text; v_richiesta boolean; v_origine uuid; v_num integer;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id for update;
 if not found or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then return '{}'::jsonb; end if;
 if nullif(e.payload->>'targa','') is not null and
  upper(regexp_replace(e.payload->>'targa','[^A-Za-z0-9]','','g'))<>
  upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g')) then return '{}'::jsonb; end if;
 t:=lower(translate(coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio',''),'àèéìòù’','aeeiou'''));
 v_richiesta:=
  (t~'((ho|abbiamo)[[:space:]]+(acquistato|ricevuto)|ricevuto da voi|fornito da voi|vostr[oa] (riparazione|intervento))'
   and t~'(problem|non.{0,25}(funzion|riesc)|difett|codific)')
  or (p.tipo_flusso='assistenza' and p.tipo_assistenza::text in ('montaggio_codifica','post_riparazione','post_scambio','garanzia')
   and private.richiesta_richiamata_esplicita(t) and t~'(tecnico|codific|configur|programmaz)');
 if not coalesce(v_richiesta,false) or t~'(non (ho|abbiamo) (acquistato|ricevuto)|problema risolto|tutto risolto|funziona correttamente)' then return '{}'::jsonb; end if;
 -- Nessun replay può riaprire episodi risolti successivamente al messaggio.
 if p.assistenza_chiusa_at>=e.created_at or exists(select 1 from public.assistenze_rientri
  where pratica_id=p.id and chiusa_at>=e.created_at) then return jsonb_build_object('esito','episodio_gia_chiuso'); end if;
 select * into c from public.assistenze_rientri where pratica_id=p.id and chiusa_at is null;
 if found then return jsonb_build_object('esito','gia_registrata','assistenza_id',c.id); end if;
 v_origine:=p.pratica_origine_id;
 if p.stato_commerciale='ordine_acquisito' or p.stato_fatturazione='fatturato' then v_origine:=p.id; end if;
 if v_origine is null and nullif(p.targa,'') is not null then
  select count(*),min(x.id::text)::uuid into v_num,v_origine from public.pratiche x
  where x.id<>p.id and upper(regexp_replace(coalesce(x.targa,''),'[^A-Za-z0-9]','','g'))=upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))
   and (x.stato_commerciale='ordine_acquisito' or x.stato_fatturazione='fatturato')
   and (x.cliente_id=p.cliente_id or (nullif(p.telefono,'') is not null and regexp_replace(x.telefono,'[^0-9]','','g')=regexp_replace(p.telefono,'[^0-9]','','g')))
   and coalesce(x.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
   and coalesce(x.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true';
  if v_num<>1 then v_origine:=null; end if;
 end if;
 insert into public.assistenze_rientri(pratica_id,pratica_origine_id,evento_id,evidenza,aperta_at,priorita,nota)
 values(p.id,v_origine,e.id,coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio'),e.created_at,
  case when t~'(urgente|urgenza|prima possibile|mezzo fermo)' then 'urgente' else 'alta' end,
  'Richiesta di assistenza tecnica post vendita. Verificare il problema e l’ordine di origine; non equivale ad accettazione della garanzia o richiesta di ritiro.') returning * into c;
 insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo,operatore)
 values(p.id,'apertura_assistenza_tecnica','Nuova richiesta tecnica ricevuta: evento '||e.id,'{}',to_jsonb(c),'routine_controllo_k');
 return jsonb_build_object('esito','aperta','assistenza_id',c.id);
end; $$;
revoke all on function private.rileva_assistenza_tecnica_evento(bigint) from public,anon,authenticated;

-- Il recupero richiama le stesse regole dei trigger senza riscrivere i payload.
create or replace function private.riprocessa_evento_keplero(p_event_id bigint)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_stato text; v_errore text;
begin
 perform private.elabora_evento_keplero(p_event_id);
 select stato,errore into v_stato,v_errore from private.keplero_event_processing where event_id=p_event_id;
 if v_stato='errore' then raise exception '%',v_errore; end if;
 perform private.rileva_attivita_operativa_evento(p_event_id);
 perform private.rileva_scelta_cliente_evento(p_event_id);
 perform private.rileva_rientro_evento(p_event_id);
 perform private.rileva_assistenza_tecnica_evento(p_event_id);
 perform private.precompila_presa_evento(p_event_id);
 update private.keplero_event_processing set errore=null,
  decisione=decisione||jsonb_build_object('recupero_completo_at',now()),updated_at=now() where event_id=p_event_id;
 return jsonb_build_object('esito',v_stato);
exception when others then
 update private.keplero_event_processing set stato='errore',errore=sqlerrm,
  tentativi=tentativi+1,updated_at=now() where event_id=p_event_id;
 return jsonb_build_object('esito','errore','errore',sqlerrm);
end; $$;
revoke all on function private.riprocessa_evento_keplero(bigint) from public,anon,authenticated;

create or replace function private.recupera_eventi_keplero_falliti()
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare r record; v_esito jsonb; v_ok integer:=0; v_errori integer:=0;
begin
 for r in select event_id,pratica_id from private.keplero_event_processing where stato='errore'
  order by updated_at,event_id limit 100 loop
  -- Come l'intake live: pratica prima del registro di elaborazione.
  if r.pratica_id is not null then
   perform 1 from public.pratiche where id=r.pratica_id for update skip locked;
   if not found then continue; end if;
  end if;
  perform 1 from private.keplero_event_processing where event_id=r.event_id and stato='errore' for update skip locked;
  if not found then continue; end if;
  v_esito:=private.riprocessa_evento_keplero(r.event_id);
  if v_esito->>'esito'='errore' then v_errori:=v_errori+1; else v_ok:=v_ok+1; end if;
 end loop;
 return jsonb_build_object('recuperati',v_ok,'errori',v_errori);
end; $$;
revoke all on function private.recupera_eventi_keplero_falliti() from public,anon,authenticated;

create table private.keplero_manutenzione_esecuzioni (
 finestra timestamptz primary key, iniziata_at timestamptz not null default now(),
 completata_at timestamptz, risultati jsonb not null default '{}'
);
alter table private.keplero_manutenzione_esecuzioni enable row level security;
revoke all on private.keplero_manutenzione_esecuzioni from public,anon,authenticated;

create or replace function private.esegui_manutenzione_keplero()
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_finestra timestamptz:=date_bin(interval '5 minutes',now(),'2000-01-01'::timestamptz);
 v_fase text; v_risultati jsonb:='{}'; v_esito jsonb;
begin
 if not pg_catalog.pg_try_advisory_xact_lock(20261015,94749) then
  return jsonb_build_object('esito','gia_in_esecuzione'); end if;
 if exists(select 1 from private.keplero_manutenzione_esecuzioni where finestra=v_finestra and completata_at is not null) then
  return jsonb_build_object('esito','finestra_gia_elaborata'); end if;
 insert into private.keplero_manutenzione_esecuzioni(finestra) values(v_finestra)
 on conflict(finestra) do update set iniziata_at=now();
 -- Un solo ordine di esecuzione per tutti i job che scrivono sulle pratiche.
 foreach v_fase in array array['gestisci_code_automatiche','ritenta_preventivi_non_abbinati',
  'recupera_preventivi_gia_inviati','ritenta_letture_offerte','recupera_ordini_contestuali_keplero',
  'recupera_flussi_offerta_rientro','recupera_eventi_keplero_falliti','riprova_prenotazioni_prese','controlla_coerenza_keplero'] loop
  begin
   execute format('select to_jsonb(private.%I())',v_fase) into v_esito;
   v_risultati:=v_risultati||jsonb_build_object(v_fase,jsonb_build_object('ok',true,'risultato',v_esito));
  exception when others then
   v_risultati:=v_risultati||jsonb_build_object(v_fase,jsonb_build_object('ok',false,'errore',sqlerrm));
  end;
 end loop;
 update private.keplero_manutenzione_esecuzioni set completata_at=clock_timestamp(),risultati=v_risultati where finestra=v_finestra;
 return v_risultati;
end; $$;
revoke all on function private.esegui_manutenzione_keplero() from public,anon,authenticated;

-- I job restano attivi: il coordinatore esegue tutte le fasi una volta per finestra.
-- I trigger live e il recupero periodico applicano anche la regola tecnica.
do $patch$
declare d text; a text;
begin
 d:=pg_get_functiondef('private.trg_flussi_offerta_rientro()'::regprocedure);
 a:='perform private.rileva_rientro_evento(new.id);';
 if strpos(d,a)=0 then raise exception 'Trigger flussi inatteso'; end if;
 execute replace(d,a,a||E'\n perform private.rileva_assistenza_tecnica_evento(new.id);');
 d:=pg_get_functiondef('private.recupera_flussi_offerta_rientro()'::regprocedure);
 a:='perform private.rileva_rientro_evento(e.id);';
 if strpos(d,a)=0 then raise exception 'Recupero flussi inatteso'; end if;
 execute replace(d,a,a||E'\n   perform private.rileva_assistenza_tecnica_evento(e.id);');
 -- Non rigenera richiamate da vecchi episodi già gestiti dall'operatore.
 d:=pg_get_functiondef('private.rileva_attivita_operativa_evento(bigint)'::regprocedure);
 a:='  if v_callback then';
 if strpos(d,a)=0 then raise exception 'Rilevatore richiamate inatteso'; end if;
 execute replace(d,a,$new$
  if v_callback and (v_pratica.assistenza_chiusa_at>=v_evento.created_at or exists(
   select 1 from public.attivita_operatore a where a.pratica_id=v_pratica.id and a.tipo like 'richiamata_%'
    and coalesce(a.completata_at,a.annullata_at)>=v_evento.created_at)) then v_callback:=false; end if;
  if v_callback then$new$);
 -- Espone tutti gli errori, anche se il messaggio è uscito dalla finestra 48h.
 d:=pg_get_functiondef('private.candidati_errori_flussi()'::regprocedure);
 a:=$old$ep.stato='errore' and (ep.versione_regole='offerte-rientri-v2' or ep.errore like 'offerte-rientri-v2:%')$old$;
 if strpos(d,a)=0 then raise exception 'Monitor errori inatteso'; end if;
 d:=replace(d,a,$new$ep.stato='errore'$new$);
 d:=replace(d,'Elaborazione offerta/ritiro non completata: verifica tecnica richiesta.','Elaborazione evento K non completata: recupero automatico in coda, verifica tecnica richiesta.');
 execute d;
end;
$patch$;

-- I job restano attivi: il coordinatore esegue tutte le fasi una volta per finestra.
do $$ declare r record; begin
 for r in select jobid from cron.job where jobname in ('gestisci-code-keplero-ogni-5-minuti',
 'recupera-offerte-ritiri-assistenza','ritenta-letture-offerte','controllo-coerenza-keplero',
 'ritenta-preventivi-non-abbinati','recupera-ordini-contestuali-keplero','riprova-prenotazioni-prese') loop
 perform cron.alter_job(r.jobid,command:='select private.esegui_manutenzione_keplero();');
 end loop;
end; $$;

create or replace function private.candidati_richieste_keplero()
returns table(chiave text,pratica_id uuid,event_id bigint,regola text,descrizione text,evidenza text)
language sql stable security invoker set search_path = '' as $$
 with ultimi as (
  select distinct on(pratica_id) pratica_id,id,payload,created_at from public.keplero_live_events
  where pratica_id is not null order by pratica_id,id desc
 )
 select 'offerta_non_ricevuta:'||e.id,p.id,e.id,'offerta_non_ricevuta',
  'Il cliente non ha ricevuto il preventivo: verificare destinatario e prova di invio, senza considerarlo accettato.',
  left(e.payload->>'ultimo_messaggio_cliente',600)
 from ultimi e join public.pratiche p on p.id=e.pratica_id
 where p.tipo_flusso='commerciale' and p.stato_commerciale in ('preventivo_inviato','attesa_cliente')
  and e.created_at>coalesce(p.preventivo_inviato_at,p.created_at)
  and lower(coalesce(e.payload->>'ultimo_messaggio_cliente',''))~'(non ho ricevuto|non abbiamo ricevuto|non e arrivat|non è arrivat).{0,40}(offerta|preventivo)'
  and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
 union all
 select 'assistenza_nuova:'||c.id,p.id,c.evento_id,'nuova_assistenza_su_pratica_chiusa',
  'Nuova richiesta tecnica successiva alla chiusura: episodio aperto da prendere in carico.',left(c.evidenza,600)
 from public.assistenze_rientri c join public.pratiche p on p.id=c.pratica_id
 where c.chiusa_at is null and p.stato_assistenza in ('chiusa','risolta') and c.aperta_at>p.assistenza_chiusa_at
 union all
 select 'manutenzione:'||f.key,null::uuid,null::bigint,'errore_manutenzione_keplero',
  'Recupero automatico K non completato: '||f.key,left(f.value->>'errore',600)
 from (select risultati from private.keplero_manutenzione_esecuzioni order by finestra desc limit 1)m,
  lateral jsonb_each(m.risultati) f where f.value->>'ok'='false';
$$;
revoke all on function private.candidati_richieste_keplero() from public,anon,authenticated;
do $patch$ declare d text; a text; begin
 d:=pg_get_functiondef('private.candidati_coerenza_keplero()'::regprocedure);
 a:='union all select * from private.candidati_errori_flussi()';
 if strpos(d,a)=0 then raise exception 'Candidati controllo inattesi'; end if;
 execute replace(d,a,a||E'\nunion all select * from private.candidati_richieste_keplero()');
end; $patch$;


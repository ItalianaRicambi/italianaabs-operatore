
-- Un unico preventivo effettivo, stesso telefono/targa/marca e codice del dispositivo.
-- Non basta il nome del PDF e non si usa il solo telefono.
create or replace function private.preventivo_univoco_per_payload(p_telefono text,p_targa text,p_marca text,p_payload jsonb)
returns uuid language sql stable set search_path='' as $function$
with candidati as (
 select distinct p.id
 from public.pratiche p join public.preventivi pv on pv.pratica_id=p.id
 join public.offerte_versioni q on q.preventivo_id=pv.id and q.pratica_id=p.id
 where nullif(regexp_replace(coalesce(p_telefono,''),'[^0-9]','','g'),'') is not null
 and public.normalizza_telefono_cliente(p.telefono)=public.normalizza_telefono_cliente(p_telefono)
 and nullif(regexp_replace(coalesce(p_targa,''),'[^A-Za-z0-9]','','g'),'') is not null
 and upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))=upper(regexp_replace(p_targa,'[^A-Za-z0-9]','','g'))
 and nullif(btrim(coalesce(p_marca,'')),'') is not null
 and lower(btrim(p.marca_veicolo))=lower(btrim(p_marca))
 and p.tipo_flusso='commerciale'
 and p.stato_commerciale in ('preventivo_inviato','attesa_cliente','ordine_acquisito')
 and p.stato_fatturazione<>'fatturato' and not p.blocco_operatore
 and pv.stato in ('inviato','accettato') and q.stato='letta'
 and not exists(select 1 from public.offerte_versioni newer where newer.pratica_id=p.id and newer.inviato_at>q.inviato_at)
 and coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')<>'true'
 and coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')<>'true'
 and coalesce(p_payload->>'nuova_pratica_richiesta','false')<>'true'
 and not exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
   and c.telefono_normalizzato=regexp_replace(coalesce(p_telefono,''),'[^0-9]','','g'))
 and exists(
  select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_payload->'codici_identificativi')='array'
    then p_payload->'codici_identificativi' else '[]'::jsonb end) c(code)
  where length(regexp_replace(c.code,'[^A-Za-z0-9]','','g'))>=6
  and exists(select 1 from regexp_split_to_table(upper(coalesce(q.testo_documento,'')),'[^A-Z0-9-]+') t(token)
   where regexp_replace(t.token,'[^A-Z0-9]','','g')=upper(regexp_replace(c.code,'[^A-Za-z0-9]','','g')))
 )
)
select case when count(*)=1 then min(id::text)::uuid else null end from candidati;
$function$;
revoke all on function private.preventivo_univoco_per_payload(text,text,text,jsonb) from public,anon,authenticated;
grant execute on function private.preventivo_univoco_per_payload(text,text,text,jsonb) to service_role;

-- Fiscali reali + plico pronto nella stessa conversazione + riepilogo di accettazione.
-- Le sole foto o la sola preparazione del pacco non confermano un ordine.
create or replace function private.ordine_da_plico_e_fiscali(p_event_id bigint)
returns jsonb language plpgsql stable set search_path='' as $function$
declare e public.keplero_live_events%rowtype; p public.pratiche%rowtype;
 q public.offerte_versioni%rowtype; v_msg text; v_summary text; v_pack bigint;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 select * into p from public.pratiche where id=e.pratica_id;
 if p.tipo_flusso<>'commerciale' or p.stato_commerciale not in ('preventivo_inviato','attesa_cliente')
  or p.stato_fatturazione in ('da_fatturare','fatturato') or p.blocco_operatore
  or coalesce(p.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
  or coalesce(p.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true'
 then return '{}'::jsonb; end if;
 if not exists(select 1 from public.keplero_live_links l where l.external_key=e.external_key and l.pratica_id=p.id)
  or upper(regexp_replace(coalesce(e.payload->>'targa',''),'[^A-Za-z0-9]','','g'))<>
     upper(regexp_replace(coalesce(p.targa,''),'[^A-Za-z0-9]','','g'))
  or exists(select 1 from public.contatti_operativi c where c.attivo and c.blocca_automazioni_commerciali
    and c.telefono_normalizzato=regexp_replace(coalesce(p.telefono,''),'[^0-9]','','g'))
 then return '{}'::jsonb; end if;
 select * into q from public.offerte_versioni where pratica_id=p.id order by inviato_at desc,versione desc limit 1;
 if q.id is null or q.stato<>'letta' or q.inviato_at>e.created_at
  or q.inviato_at is distinct from p.preventivo_inviato_at
  or (q.validita_giorni is not null and e.created_at>q.inviato_at+make_interval(days=>q.validita_giorni))
  or (select count(*) from public.offerta_opzioni where offerta_id=q.id)<>1
  or not exists(select 1 from public.preventivi pv where pv.id=q.preventivo_id and pv.stato='inviato')
 then return '{}'::jsonb; end if;
 if exists(select 1 from public.scelte_cliente s where s.pratica_id=p.id
  and (s.protetta_operatore or s.stato in ('revocata','condizionata','modifica_da_verificare','preferenza')))
 then return '{}'::jsonb; end if;
 v_msg:=coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio','');
 v_summary:=coalesce(e.payload->>'riepilogo_operativo',e.payload->>'descrizione_guasto','');
 if not private.dati_fiscali_cliente(v_msg)
  or lower(v_summary)!~ '\m(accettazione|accettato|accetta|confermato|conferma)\M.{0,45}\m(offerta|preventivo|lavorazione|revisione|riparazione)\M'
  or lower(v_msg||' '||v_summary)~ '(\m(se|forse|eventualmente|qualora)\M|valut|prima di|confront|in attesa|vorrebbe|non.{0,25}(accett|conferm|proced))'
  or private.revoca_scelta_cliente(v_msg) or private.domanda_su_accettazione(v_msg)
 then return '{}'::jsonb; end if;
 select r.id into v_pack from public.keplero_live_events r where r.pratica_id=p.id and r.external_key=e.external_key
  and r.id<=e.id and r.created_at>=greatest(q.inviato_at,private.inizio_finestra_controllo_keplero(e.created_at,48))
  and upper(regexp_replace(coalesce(r.payload->>'targa',''),'[^A-Za-z0-9]','','g'))=upper(regexp_replace(p.targa,'[^A-Za-z0-9]','','g'))
  and lower(coalesce(r.payload->>'ultimo_messaggio_cliente',''))~
    '\m(plico|pacco|imballo)\M[[:space:]]+(e[[:space:]]+|è[[:space:]]+)?(effettuato|pronto|preparato|imballato)\M'
  and not private.revoca_scelta_cliente(r.payload->>'ultimo_messaggio_cliente')
  and not private.domanda_su_accettazione(r.payload->>'ultimo_messaggio_cliente')
  and lower(coalesce(r.payload->>'ultimo_messaggio_cliente',''))!~ '\m(non|se|forse|eventualmente|quando|sarà)\M|[?]'
 order by r.id desc limit 1;
 if v_pack is null or exists(select 1 from public.keplero_live_events r where r.pratica_id=p.id
   and r.id>=v_pack and private.revoca_scelta_cliente(coalesce(r.payload->>'ultimo_messaggio_cliente','')))
 then return '{}'::jsonb; end if;
 return jsonb_build_object('confermato',true,'regola','plico_pronto_fiscali_offerta_unica_v1',
   'evento_conferma',e.id,'evento_plico',v_pack,'evento_dati_fiscali',e.id,'offerta_id',q.id);
end; $function$;
revoke all on function private.ordine_da_plico_e_fiscali(bigint) from public,anon,authenticated;
grant execute on function private.ordine_da_plico_e_fiscali(bigint) to service_role;

CREATE OR REPLACE FUNCTION public.prepara_instradamento_keplero(p_external_key text, p_conversation_id text DEFAULT NULL::text, p_telefono text DEFAULT NULL::text, p_targa text DEFAULT NULL::text, p_marca_veicolo text DEFAULT NULL::text, p_modello_veicolo text DEFAULT NULL::text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_pratica public.pratiche%rowtype;
  v_conversation_uuid uuid;
  v_targa text;
  v_targa_attuale text;
  v_telefono text;
  v_marca text;
  v_marca_attuale text;
  v_modello text;
  v_modello_attuale text;
  v_nuova_pratica_esplicita boolean := false;
  v_ordine_confermato boolean := false;
  v_identita_diversa boolean := false;
  v_external_key_effettiva text;
  v_candidato_id uuid;
  v_numero_candidati integer := 0;
  v_targhe_allegati integer := 0;
  v_event_id bigint;
begin
  if nullif(btrim(coalesce(p_external_key, '')), '') is null then
    raise exception 'external_key mancante';
  end if;

  v_targa := nullif(upper(regexp_replace(btrim(coalesce(p_targa, '')), '[^A-Za-z0-9]', '', 'g')), '');
  v_telefono := nullif(regexp_replace(coalesce(p_telefono, ''), '[^0-9]', '', 'g'), '');
  v_marca := nullif(lower(regexp_replace(btrim(coalesce(p_marca_veicolo, '')), '\s+', ' ', 'g')), '');
  v_modello := nullif(lower(regexp_replace(btrim(coalesce(p_modello_veicolo, '')), '\s+', ' ', 'g')), '');
  v_nuova_pratica_esplicita := lower(coalesce(p_payload ->> 'nuova_pratica_richiesta', 'false'))
    in ('1','true','vero','si','sì','yes');
  v_ordine_confermato := lower(coalesce(p_payload ->> 'ordine_confermato_rilevato', 'false'))
    in ('1','true','vero','si','sì','yes');

  -- Recupera la pratica del preventivo anche quando K non marca la conferma.
  -- Conserva i blocchi e non sposta una conversazione già in gestione avanzata.
  v_candidato_id:=private.preventivo_univoco_per_payload(p_telefono,p_targa,p_marca_veicolo,p_payload);
  if v_candidato_id is not null and not v_nuova_pratica_esplicita
    and not exists(select 1 from public.keplero_live_links l join public.pratiche a on a.id=l.pratica_id
      where l.external_key=p_external_key and a.id<>v_candidato_id
      and (a.blocco_operatore
        or a.stato_commerciale::text in ('ordine_acquisito','rifiutato','chiuso')
        or a.stato_fatturazione<>'non_applicabile'))
  then
    insert into public.keplero_live_links(external_key,pratica_id)
    values(p_external_key,v_candidato_id)
    on conflict(external_key) do update set pratica_id=excluded.pratica_id,updated_at=now();
  end if;

  select p.* into v_pratica
  from public.keplero_live_links l
  join public.pratiche p on p.id = l.pratica_id
  where l.external_key = p_external_key
  limit 1;

  if v_pratica.id is null then
    begin
      if nullif(btrim(coalesce(p_conversation_id, '')), '') is not null then
        v_conversation_uuid := btrim(p_conversation_id)::uuid;
      end if;
    exception when others then
      v_conversation_uuid := null;
    end;

    if v_conversation_uuid is not null then
      select p.* into v_pratica
      from public.pratiche p
      where p.keplero_conversation_id = v_conversation_uuid::text
      order by p.updated_at desc, p.created_at desc
      limit 1;
    end if;
  end if;

  -- Se la targa non è strutturata, prova a ricavarla solo da un PDF il cui
  -- nome coincide esattamente con una targa già presente. Nessuna OCR o
  -- interpretazione libera: occorre una sola corrispondenza univoca.
  if v_ordine_confermato and v_targa is null then
    with allegati as (
      select upper(regexp_replace(regexp_replace(x, '^.*[/\\]', ''), '\.pdf$', '', 'i')) as nome
      from jsonb_array_elements_text(coalesce(p_payload -> 'allegati', '[]'::jsonb)) x
      where x ~* '\.pdf$'
    ), corrispondenze as (
      select distinct upper(regexp_replace(coalesce(p.targa, ''), '[^A-Za-z0-9]', '', 'g')) as targa
      from allegati a
      join public.pratiche p
        on upper(regexp_replace(a.nome, '[^A-Za-z0-9]', '', 'g'))
         = upper(regexp_replace(coalesce(p.targa, ''), '[^A-Za-z0-9]', '', 'g'))
      where coalesce(p.targa, '') <> ''
    )
    select count(*), min(targa)
    into v_targhe_allegati, v_targa
    from corrispondenze;

    if v_targhe_allegati <> 1 then
      v_targa := null;
    end if;
  end if;

  -- Una conferma esplicita può provenire da un numero diverso dell'officina.
  -- Prima usa la targa esatta (anche ricavata dal nome PDF), poi il telefono.
  -- Il collegamento avviene solo se esiste un unico preventivo aperto.
  if v_ordine_confermato then
    if v_targa is not null then
      select count(*), min(c.id::text)::uuid
      into v_numero_candidati, v_candidato_id
      from (
        select p.id
        from public.pratiche p
        where upper(regexp_replace(coalesce(p.targa, ''), '[^A-Za-z0-9]', '', 'g')) = v_targa
          and p.stato_commerciale in ('preventivo_inviato','attesa_cliente','ordine_acquisito')
          and p.stato_fatturazione <> 'fatturato'
          and (
            p.preventivo_inviato_at is not null
            or exists (
              select 1 from public.preventivi pv
              where pv.pratica_id = p.id and pv.stato in ('inviato','accettato')
            )
          )
          and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
          and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
        limit 2
      ) c;
    end if;

    if v_numero_candidati <> 1 and length(coalesce(v_telefono, '')) >= 8 then
      v_candidato_id := null;
      select count(*), min(c.id::text)::uuid
      into v_numero_candidati, v_candidato_id
      from (
        select p.id
        from public.pratiche p
        where p.tipo_flusso = 'commerciale'::public.tipo_flusso
          and p.stato_commerciale in ('preventivo_inviato','attesa_cliente','ordine_acquisito')
          and p.stato_fatturazione <> 'fatturato'
          and regexp_replace(coalesce(p.telefono, ''), '[^0-9]', '', 'g') = v_telefono
          and (
            p.preventivo_inviato_at is not null
            or exists (
              select 1 from public.preventivi pv
              where pv.pratica_id = p.id and pv.stato in ('inviato','accettato')
            )
          )
          and coalesce(p.dati_raw #>> '{archiviazione_test,archiviata}', 'false') <> 'true'
          and coalesce(p.dati_raw #>> '{pratica_duplicata,archiviata}', 'false') <> 'true'
        limit 2
      ) c;
    end if;

    if v_numero_candidati = 1 and v_candidato_id is not null
       and (
         v_pratica.id is null
         or v_pratica.id = v_candidato_id
         or (
           v_pratica.stato_commerciale not in ('preventivo_inviato','attesa_cliente','ordine_acquisito')
           and v_pratica.stato_fatturazione <> 'fatturato'
         )
       ) then
      select * into v_pratica from public.pratiche where id = v_candidato_id;

      insert into public.keplero_live_links(external_key, pratica_id, created_at, updated_at)
      values (p_external_key, v_pratica.id, now(), now())
      on conflict (external_key) do update
      set pratica_id = excluded.pratica_id, updated_at = now();
    end if;
  end if;

  if v_pratica.id is null then
    return jsonb_build_object('ok', true, 'external_key', p_external_key,
      'nuova_pratica', false, 'richiedi_targa', false, 'usa_conversation_id', true,
      'motivo', 'prima_pratica_conversazione');
  end if;

  v_targa_attuale := nullif(upper(regexp_replace(btrim(coalesce(v_pratica.targa, '')), '[^A-Za-z0-9]', '', 'g')), '');
  v_marca_attuale := nullif(lower(regexp_replace(btrim(coalesce(v_pratica.marca_veicolo, '')), '\s+', ' ', 'g')), '');
  v_modello_attuale := nullif(lower(regexp_replace(btrim(coalesce(v_pratica.modello_veicolo, '')), '\s+', ' ', 'g')), '');

  v_identita_diversa :=
    (v_marca is not null and v_marca_attuale is not null and v_marca <> v_marca_attuale)
    or (v_modello is not null and v_modello_attuale is not null and v_modello <> v_modello_attuale);

  if not v_ordine_confermato and v_targa is null
     and (v_nuova_pratica_esplicita or v_identita_diversa) then
    -- Conserva la ricezione senza attribuire il nuovo veicolo alla vecchia pratica.
    insert into public.keplero_live_events(external_key, pratica_id, payload)
    values (p_external_key, null, coalesce(p_payload, '{}'::jsonb) ||
      jsonb_build_object('instradamento_sospeso', true,
        'motivo_sospensione', 'nuovo_veicolo_senza_targa',
        'pratica_precedente_id', v_pratica.id,
        'marca_veicolo', p_marca_veicolo, 'modello_veicolo', p_modello_veicolo))
    returning id into v_event_id;
    return jsonb_build_object('ok', true, 'external_key', p_external_key,
      'nuova_pratica', false, 'richiedi_targa', true, 'usa_conversation_id', false,
      'evento_ricevuto_id', v_event_id, 'ricezione_registrata', true,
      'pratica_precedente_id', v_pratica.id, 'pratica_precedente_targa', v_targa_attuale,
      'motivo', case when v_nuova_pratica_esplicita then 'nuovo_veicolo_senza_targa'
                     else 'identita_veicolo_diversa_senza_targa' end);
  end if;

  if not v_ordine_confermato and v_targa is not null
     and ((v_targa_attuale is not null and v_targa <> v_targa_attuale)
       or (v_targa_attuale is null and (v_nuova_pratica_esplicita or v_identita_diversa))) then
    v_external_key_effettiva := concat(p_external_key, ':veicolo:', lower(v_targa));
    return jsonb_build_object('ok', true, 'external_key', v_external_key_effettiva,
      'external_key_conversazione', p_external_key, 'nuova_pratica', true,
      'richiedi_targa', false, 'usa_conversation_id', false,
      'pratica_precedente_id', v_pratica.id, 'pratica_precedente_targa', v_targa_attuale,
      'nuova_targa', v_targa, 'motivo', 'targa_diversa');
  end if;

  return jsonb_build_object('ok', true, 'external_key', p_external_key,
    'nuova_pratica', false, 'richiedi_targa', false, 'usa_conversation_id', false,
    'pratica_id', v_pratica.id,
    'motivo', case when v_ordine_confermato then 'conferma_ordine_collegata_al_preventivo'
                   else 'continua_pratica_attiva' end);
end;
$function$;

CREATE OR REPLACE FUNCTION private.ordine_da_scelta_e_fiscali(p_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
 v_evento public.keplero_live_events%rowtype;
 v_pratica public.pratiche%rowtype;
 v_scelta public.keplero_live_events%rowtype;
 v_preventivo_at timestamptz;
 v_testo text;
begin
 select * into v_evento from public.keplero_live_events where id=p_event_id;
 if not found or v_evento.pratica_id is null then return '{}'::jsonb; end if;
 select * into v_pratica from public.pratiche where id=v_evento.pratica_id;
 if not found or v_pratica.tipo_flusso::text <> 'commerciale'
    or v_pratica.stato_commerciale::text not in ('preventivo_inviato','attesa_cliente')
    or v_pratica.stato_fatturazione::text in ('da_fatturare','fatturato')
    or v_pratica.blocco_operatore
    or coalesce(v_pratica.dati_raw #>> '{archiviazione_test,archiviata}','false')='true'
    or coalesce(v_pratica.dati_raw #>> '{pratica_duplicata,archiviata}','false')='true'
 then return '{}'::jsonb; end if;
 if not exists(select 1 from public.keplero_live_links l
   where l.pratica_id=v_pratica.id and l.external_key=v_evento.external_key)
 then return '{}'::jsonb; end if;
 -- Il recupero retroattivo non deve riesumare una conferma poi revocata.
 if exists(select 1 from public.keplero_live_events e
   where e.pratica_id=v_pratica.id and e.id>v_evento.id
     and private.revoca_scelta_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
       e.payload->>'messaggio_cliente',e.payload->>'messaggio','')))
 then return '{}'::jsonb; end if;
 if exists (select 1 from public.contatti_operativi c where c.attivo
    and c.blocca_automazioni_commerciali and c.telefono_normalizzato=
      regexp_replace(coalesce(v_pratica.telefono,''),'[^0-9]','','g'))
 then return '{}'::jsonb; end if;

 -- Preferire l'ultimo preventivo: una scelta precedente a una nuova offerta
 -- non autorizza automaticamente l'accettazione della nuova proposta.
 select greatest(v_pratica.preventivo_inviato_at,max(pv.inviato_at))
 into v_preventivo_at from public.preventivi pv
 where pv.pratica_id=v_pratica.id and pv.stato in ('inviato','accettato');
 if v_preventivo_at is null or v_evento.created_at < v_preventivo_at
 then return '{}'::jsonb; end if;
 v_testo := coalesce(v_evento.payload->>'ultimo_messaggio_cliente',
                    v_evento.payload->>'messaggio_cliente',v_evento.payload->>'messaggio','');
 if not private.dati_fiscali_cliente(v_testo)
    or nullif(v_pratica.targa,'') is null
    or upper(regexp_replace(coalesce(v_evento.payload->>'targa',''),'[^A-Za-z0-9]','','g')) <>
       upper(regexp_replace(v_pratica.targa,'[^A-Za-z0-9]','','g'))
 then return '{}'::jsonb; end if;

 select e.* into v_scelta from public.keplero_live_events e
 where e.pratica_id=v_pratica.id and e.external_key=v_evento.external_key
   and e.id<v_evento.id and e.created_at<=v_evento.created_at
   and e.created_at>=v_preventivo_at
   and e.created_at>=private.inizio_finestra_controllo_keplero(v_evento.created_at,48)
   and upper(regexp_replace(coalesce(e.payload->>'targa',''),'[^A-Za-z0-9]','','g')) =
       upper(regexp_replace(v_pratica.targa,'[^A-Za-z0-9]','','g'))
   and private.scelta_lavorazione_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
         e.payload->>'messaggio_cliente',e.payload->>'messaggio',''))
 order by e.created_at desc,e.id desc limit 1;
 if not found then
   if private.intenzione_offerta_con_fiscali(v_testo,coalesce(
        v_evento.payload->>'riepilogo_operativo',
        v_evento.payload->>'descrizione_guasto',
        v_evento.payload->>'richiesta',''))
      and not exists (select 1 from public.keplero_live_events e
        where e.pratica_id=v_pratica.id and e.created_at>=v_preventivo_at
          and e.id<=v_evento.id
          and private.revoca_scelta_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
            e.payload->>'messaggio_cliente',e.payload->>'messaggio','')))
   then
     return jsonb_build_object('confermato',true,
       'regola','intenzione_offerta_e_dati_fiscali_v1','evento_dati_fiscali',v_evento.id);
   end if;
   return private.ordine_da_plico_e_fiscali(p_event_id);
 end if;
 if exists (select 1 from public.keplero_live_events e
   where e.pratica_id=v_pratica.id and e.id>v_scelta.id
     and e.created_at>=v_scelta.created_at
     and e.created_at<=v_evento.created_at and e.id<=v_evento.id
     and private.revoca_scelta_cliente(coalesce(e.payload->>'ultimo_messaggio_cliente',
       e.payload->>'messaggio_cliente',e.payload->>'messaggio','')))
 then return '{}'::jsonb; end if;
 return jsonb_build_object('confermato',true,'regola','scelta_lavorazione_e_dati_fiscali_v1',
   'evento_scelta',v_scelta.id,'evento_dati_fiscali',v_evento.id);
end;
$function$;

CREATE OR REPLACE FUNCTION private.conferma_ordine_evento_verificato(p_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare e public.keplero_live_events%rowtype; v_contesto jsonb; v_esito jsonb;
 v_prima jsonb; v_sorgente public.keplero_live_events%rowtype;
begin
 select * into e from public.keplero_live_events where id=p_event_id;
 if not found or e.pratica_id is null then return '{}'::jsonb; end if;
 perform 1 from public.pratiche where id=e.pratica_id for update;
 v_contesto:=private.ordine_da_conferma_letterale(e.id);
 if coalesce(v_contesto->>'confermato','false')<>'true' then
  v_contesto:=private.ordine_da_scelta_e_fiscali(e.id);
 end if;
 if coalesce(v_contesto->>'confermato','false')<>'true' then return '{}'::jsonb; end if;
 -- Registra la sola alternativa verificata con la prova del contesto.
 if v_contesto->>'regola'='plico_pronto_fiscali_offerta_unica_v1' then
  insert into public.scelte_cliente(pratica_id,offerta_id,opzione_id,stato,evento_id,evidenza,richiesta_at,fonte)
  select e.pratica_id,o.offerta_id,o.id,'confermata',e.id,
   'Offerta unica; plico pronto e dati fiscali comunicati nella stessa conversazione.',
   e.created_at,'keplero_live' from public.offerta_opzioni o
   where o.offerta_id=(v_contesto->>'offerta_id')::uuid
  on conflict(pratica_id) do update set offerta_id=excluded.offerta_id,opzione_id=excluded.opzione_id,
   stato=excluded.stato,evento_id=excluded.evento_id,evidenza=excluded.evidenza,richiesta_at=excluded.richiesta_at,updated_at=now()
   where not public.scelte_cliente.protetta_operatore;
 end if;
 select to_jsonb(p) into v_prima from public.pratiche p where p.id=e.pratica_id;
 v_esito:=public.conferma_ordine_da_keplero(e.pratica_id,e.external_key,
  coalesce(e.payload->>'ultimo_messaggio_cliente',e.payload->>'messaggio_cliente',e.payload->>'messaggio'));
 if v_esito->>'aggiornato'='true' then
  select * into v_sorgente from public.keplero_live_events
   where id=coalesce((v_contesto->>'evento_conferma')::bigint,
     (v_contesto->>'evento_scelta')::bigint,e.id) and pratica_id=e.pratica_id;
  update public.pratiche set ordine_acquisito_at=v_sorgente.created_at,
   dati_raw=coalesce(dati_raw,'{}'::jsonb)||jsonb_build_object('conferma_ordine_verificata',
    v_contesto||jsonb_build_object('event_id',v_sorgente.id,'external_key',e.external_key,
      'confermata_at',v_sorgente.created_at,'registrata_at',now(),
      'messaggio',coalesce(v_sorgente.payload->>'ultimo_messaggio_cliente',
       v_sorgente.payload->>'messaggio_cliente',v_sorgente.payload->>'messaggio')))
   where id=e.pratica_id;
  update public.preventivi set accettato_at=v_sorgente.created_at
   where pratica_id=e.pratica_id and stato='accettato' and accettato_at=now();
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo)
   select e.pratica_id,'conferma_ordine_evento_verificato',
    'Conferma verificata nell’evento '||v_sorgente.id||' del '||v_sorgente.created_at||': '||
    left(coalesce(v_sorgente.payload->>'ultimo_messaggio_cliente',v_sorgente.payload->>'messaggio_cliente',v_sorgente.payload->>'messaggio',''),1000),
    v_prima,to_jsonb(p) from public.pratiche p where p.id=e.pratica_id;
 end if;
 return jsonb_build_object('contesto',v_contesto,'avanzamento',v_esito);
end;
$function$;

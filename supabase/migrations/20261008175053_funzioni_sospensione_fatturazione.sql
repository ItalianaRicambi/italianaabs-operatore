create or replace function private.domanda_su_accettazione(p_testo text)
returns boolean language sql immutable set search_path = '' as $function$
  select lower(btrim(coalesce(p_testo,''))) ~
    '^(?:(?:buongiorno|buonasera|ciao|ok|scusi|scusa)[,!. ]*)?(?:come|in che modo|cosa devo fare|che devo fare)\M.{0,65}\m(?:accett|conferm|approv|proced)';
$function$;

create or replace function private.valida_dati_fatturazione()
returns trigger language plpgsql set search_path = '' as $function$
declare
  esito jsonb;
  sospesa boolean;
begin
  -- I payload e le rivalutazioni automatiche non possono cancellare la scelta
  -- dell'operatore. Solo la RPC autorizzata può modificarla.
  if tg_op='UPDATE' and coalesce(current_setting('app.gestisci_sospensione_fatturazione',true),'')<>'true' then
    if old.dati_raw ? 'sospensione_fatturazione_operatore' then
      new.dati_raw:=coalesce(new.dati_raw,'{}'::jsonb)||jsonb_build_object(
        'sospensione_fatturazione_operatore',old.dati_raw->'sospensione_fatturazione_operatore');
    else
      new.dati_raw:=coalesce(new.dati_raw,'{}'::jsonb)-'sospensione_fatturazione_operatore';
    end if;
  elsif tg_op='INSERT' and coalesce(current_setting('app.gestisci_sospensione_fatturazione',true),'')<>'true' then
    new.dati_raw:=coalesce(new.dati_raw,'{}'::jsonb)-'sospensione_fatturazione_operatore';
  end if;
  sospesa:=coalesce(new.dati_raw#>>'{sospensione_fatturazione_operatore,attiva}','false')='true';
  if new.stato_fatturazione='fatturato' then
    -- Le fatture storiche restano documenti effettivamente emessi.
    if tg_op='INSERT' or old.stato_fatturazione is distinct from 'fatturato'::public.stato_fatturazione then
      esito:=private.verifica_dati_cliente_fatturazione(new.cliente_id);
      if sospesa or esito->>'completi'<>'true' then
        raise exception 'Fatturazione bloccata: completare e confermare i dati del cliente nella sezione Cliente fiscale.';
      end if;
    end if;
    return new;
  end if;
  if new.stato_fatturazione<>'da_fatturare' then return new; end if;
  esito:=private.verifica_dati_cliente_fatturazione(new.cliente_id);
  if not sospesa and new.stato_commerciale='ordine_acquisito' and esito->>'completi'='true' then
    new.stato_amministrativo:='pronto_fatturazione';
  else
    if new.stato_amministrativo<>'corrispondenza_ambigua' then
      new.stato_amministrativo:='dati_mancanti';
    end if;
    new.nota_amministrativa:=case when sospesa
      then 'Fatturazione sospesa dall''operatore: completare/verificare l''anagrafica e confermare manualmente per riabilitarla.'
      when new.cliente_id is null then 'Cliente fiscale non collegato: collegare o creare l''anagrafica completa prima della fatturazione.'
      else 'Dati cliente mancanti o da verificare: '||array_to_string(array(select jsonb_array_elements_text(esito->'campi')),', ') end;
  end if;
  if tg_op='INSERT' or new.stato_amministrativo is distinct from old.stato_amministrativo then
    new.stato_amministrativo_at:=now();
  end if;
  return new;
end;
$function$;



create or replace function public.gestisci_sospensione_fatturazione(
  p_pratica_id uuid, p_sospendi boolean, p_operatore text)
returns jsonb language plpgsql set search_path = '' as $function$
declare
  prima public.pratiche%rowtype;
  dopo public.pratiche%rowtype;
  verifica jsonb;
  impostazione_precedente text:=coalesce(current_setting('app.gestisci_sospensione_fatturazione',true),'');
begin
  if p_operatore not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4','Manutenzione autorizzata')
     or p_operatore is null or p_sospendi is null then raise exception 'Operatore o comando non valido'; end if;
  select * into prima from public.pratiche where id=p_pratica_id for update;
  if not found then raise exception 'Pratica non trovata'; end if;
  if prima.stato_commerciale<>'ordine_acquisito' or prima.stato_fatturazione<>'da_fatturare' then
    raise exception 'La sospensione riguarda soltanto ordini acquisiti non ancora fatturati';
  end if;
  if coalesce(prima.dati_raw#>>'{archiviazione_test,archiviata}','false')='true'
    or coalesce(prima.dati_raw#>>'{pratica_duplicata,archiviata}','false')='true' then
    raise exception 'Pratica archiviata';
  end if;
  if not p_sospendi then
    verifica:=private.verifica_dati_cliente_fatturazione(prima.cliente_id);
    if verifica->>'completi'<>'true' then raise exception 'Dati cliente incompleti o da verificare: non è possibile abilitare la fatturazione'; end if;
  end if;
  perform set_config('app.gestisci_sospensione_fatturazione','true',true);
  update public.pratiche set dati_raw=coalesce(dati_raw,'{}'::jsonb)||jsonb_build_object(
    'sospensione_fatturazione_operatore',jsonb_build_object('attiva',p_sospendi,'operatore',p_operatore,'at',now())),
    stato_amministrativo=case when p_sospendi then 'dati_mancanti'::public.stato_amministrativo
      else 'pronto_fatturazione'::public.stato_amministrativo end,
    nota_amministrativa=case when p_sospendi then 'Fatturazione sospesa: dati cliente mancanti o da verificare.'
      else 'Anagrafica fiscale completa confermata dall''operatore.' end
    where id=p_pratica_id;
  perform set_config('app.gestisci_sospensione_fatturazione',impostazione_precedente,true);
  perform public.prepara_richiesta_dati_amministrativi(p_pratica_id);
  select * into dopo from public.pratiche where id=p_pratica_id;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo)
    values(p_pratica_id,case when p_sospendi then 'fatturazione_sospesa_dati_cliente' else 'fatturazione_abilitata_dati_cliente' end,
      p_operatore||': '||case when p_sospendi then 'Fatturazione sospesa senza annullare l''ordine acquisito.'
        else 'Dati fiscali verificati e fatturazione abilitata.' end,to_jsonb(prima),to_jsonb(dopo));
  return jsonb_build_object('pratica_id',p_pratica_id,'sospesa',p_sospendi,'stato_amministrativo',dopo.stato_amministrativo);
end;
$function$;

create or replace function private.rivalida_pratiche_cliente_fiscale()
returns trigger language plpgsql set search_path = '' as $function$
declare p uuid;
begin
  for p in select id from public.pratiche where cliente_id=new.id and stato_fatturazione='da_fatturare' loop
    update public.pratiche set stato_amministrativo=stato_amministrativo where id=p;
    perform public.prepara_richiesta_dati_amministrativi(p);
  end loop;
  return new;
end;
$function$;



revoke all on function private.verifica_dati_cliente_fatturazione(uuid),private.domanda_su_accettazione(text),
  private.valida_dati_fatturazione(),private.rivalida_pratiche_cliente_fiscale(),
  public.gestisci_sospensione_fatturazione(uuid,boolean,text) from public,anon,authenticated;
grant execute on function private.verifica_dati_cliente_fatturazione(uuid),private.domanda_su_accettazione(text),
  private.valida_dati_fatturazione(),private.rivalida_pratiche_cliente_fiscale(),
  public.gestisci_sospensione_fatturazione(uuid,boolean,text) to service_role;

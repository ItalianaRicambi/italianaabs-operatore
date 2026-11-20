-- Risolta = conclusione della richiesta, non prova di riparazione/sostituzione/rimborso.
-- Nessun automatismo modifica ritiri, esiti tecnici o dati amministrativi.
create or replace function private.chiudi_richiesta_assistenza_non_avviata(
  p_pratica_id uuid, p_chiusa_at timestamptz, p_nota text default null
) returns uuid
language plpgsql security invoker set search_path = ''
as $function$
declare
  r public.assistenze_rientri%rowtype;
  dopo public.assistenze_rientri%rowtype;
  nota_chiusura text := 'Chiusura amministrativa della richiesta per assistenza segnata come risolta dall’operatore. Non attesta riparazione, sostituzione o rimborso.';
begin
  if p_chiusa_at is null or p_chiusa_at > now() then
    raise exception 'Data di chiusura assistenza non valida';
  end if;
  -- Stesso ordine di lock dei flussi di apertura e gestione dei rientri.
  perform 1 from public.pratiche where id=p_pratica_id and tipo_flusso='assistenza' for update;
  if not found then raise exception 'Pratica assistenza non trovata'; end if;
  select * into r from public.assistenze_rientri
    where pratica_id=p_pratica_id and chiusa_at is null and aperta_at<=p_chiusa_at for update;
  if not found then return null; end if;

  if r.stato<>'da_prendere_in_carico' or r.presa_in_carico_at is not null or r.esito_tecnico is not null then
    raise exception 'Assistenza già avviata: completare il percorso del rientro e registrarne l’esito prima di segnare la pratica come risolta';
  end if;
  perform 1 from public.attivita_operatore
    where assistenza_rientro_id=r.id and stato not in ('annullata','completata') for update;
  if found then
    raise exception 'Attività collegata ancora aperta: completarla o annullarla con motivazione prima di chiudere la richiesta';
  end if;
  if nullif(btrim(p_nota),'') is not null then nota_chiusura:=nota_chiusura||' Nota: '||btrim(p_nota); end if;
  update public.assistenze_rientri set stato='chiusa',chiusa_at=p_chiusa_at,updated_at=now(),
    nota=concat_ws(E'\n',nullif(nota,''),nota_chiusura)
    where id=r.id returning * into dopo;
  insert into public.azioni_operatore(pratica_id,azione,nota,stato_prima,stato_dopo)
    values(p_pratica_id,'assistenza_chiusura_amministrativa',nota_chiusura,to_jsonb(r),to_jsonb(dopo));
  return r.id;
end;
$function$;
revoke all on function private.chiudi_richiesta_assistenza_non_avviata(uuid,timestamptz,text) from public,anon,authenticated;
grant execute on function private.chiudi_richiesta_assistenza_non_avviata(uuid,timestamptz,text) to service_role;

-- Patch stretta della sola azione assistenza_risolta: preserva tutti gli altri rami e gli ACL.
do $patch$
declare
  definizione text := replace(pg_get_functiondef('public.applica_azione_operatore(uuid,text,text)'::regprocedure),E'\r\n',E'\n');
  prima text := $prima$    update public.pratiche
    set
      stato_assistenza = 'risolta'::public.stato_assistenza,
      assistenza_chiusa_at = now()
    where id = p_pratica_id;$prima$;
  dopo text := $dopo$    -- Replay di una risoluzione: conserva la data, senza chiudere episodi successivi.
    perform private.chiudi_richiesta_assistenza_non_avviata(
      p_pratica_id,
      case when v_prima.stato_assistenza in ('risolta','chiusa')
        then v_prima.assistenza_chiusa_at else now() end,
      p_nota
    );
    update public.pratiche
    set
      stato_assistenza = 'risolta'::public.stato_assistenza,
      assistenza_chiusa_at = case when v_prima.stato_assistenza in ('risolta','chiusa')
        then v_prima.assistenza_chiusa_at else now() end
    where id = p_pratica_id;$dopo$;
begin
  if (length(definizione)-length(replace(definizione,prima,'')))/length(prima)<>1 then
    raise exception 'Funzione operatore cambiata: patch non applicata';
  end if;
  execute replace(definizione,prima,dopo);
end;
$patch$;

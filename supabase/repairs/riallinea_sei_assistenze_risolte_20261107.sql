-- Esecuzione una tantum autorizzata da Norberto. Solo sei risoluzioni confermate.
-- Ripetibile: le richieste già riallineate vengono saltate senza nuovo audit.
begin;
do $repair$
declare
  x record; p public.pratiche%rowtype; r public.assistenze_rientri%rowtype;
  prima jsonb; attivita_prima jsonb; chiuso uuid;
begin
  for x in select * from (values
    (97,   '2026-11-07 15:45:39.2225+00'::timestamptz),
    (923,  '2026-11-07 15:47:09.194129+00'::timestamptz),
    (1086, '2026-11-07 15:49:08.96345+00'::timestamptz),
    (1134, '2026-11-07 15:38:20.89478+00'::timestamptz),
    (1309, '2026-11-07 15:47:37.102736+00'::timestamptz),
    (2488, '2026-11-07 15:51:35.794506+00'::timestamptz)
  ) as t(numero,chiusa_at) order by numero loop
    select * into strict p from public.pratiche where numero_pratica=x.numero for update;
    if p.tipo_flusso<>'assistenza' or p.stato_assistenza<>'risolta'
      or p.assistenza_chiusa_at is distinct from x.chiusa_at then
      raise exception 'Pratica % cambiata dopo la verifica: riallineamento sospeso',x.numero;
    end if;
    if not exists(select 1 from public.azioni_operatore
      where pratica_id=p.id and azione='assistenza_risolta' and created_at=x.chiusa_at) then
      raise exception 'Risoluzione operatore non riscontrata: %',x.numero;
    end if;
    if exists(select 1 from public.keplero_live_events where pratica_id=p.id and created_at>x.chiusa_at) then
      raise exception 'Nuovi eventi da verificare per la pratica %',x.numero;
    end if;
    select * into r from public.assistenze_rientri where pratica_id=p.id and chiusa_at is null for update;
    if not found then continue; end if;
    if r.aperta_at>x.chiusa_at then raise exception 'Nuovo episodio da preservare: %',x.numero; end if;
    prima:=to_jsonb(p)-'updated_at'-'ultima_azione_operatore_at';
    select coalesce(jsonb_agg(to_jsonb(a) order by a.id),'[]') into attivita_prima
      from public.attivita_operatore a where pratica_id=p.id;
    chiuso:=private.chiudi_richiesta_assistenza_non_avviata(p.id,x.chiusa_at,
      'Riallineamento autorizzato da Norberto alla risoluzione operatore già registrata; nessun esito tecnico o finanziario aggiunto.');
    if chiuso is distinct from r.id then raise exception 'Episodio non riallineato: %',x.numero; end if;
    if prima is distinct from (select to_jsonb(v)-'updated_at'-'ultima_azione_operatore_at' from public.pratiche v where id=p.id) then
      raise exception 'Modifica inattesa alla pratica %',x.numero;
    end if;
    if attivita_prima is distinct from (select coalesce(jsonb_agg(to_jsonb(a) order by a.id),'[]') from public.attivita_operatore a where pratica_id=p.id) then
      raise exception 'Modifica inattesa alle attività della pratica %',x.numero;
    end if;
  end loop;
end;
$repair$;
commit;

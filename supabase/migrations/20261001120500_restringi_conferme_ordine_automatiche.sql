-- Evita che domande logistiche o richieste di istruzioni vengano promosse
-- automaticamente a conferme d'ordine.

create or replace function private.testo_conferma_ordine_inequivoca(
  p_messaggio text,
  p_riepilogo text default null
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_messaggio text := lower(trim(coalesce(p_messaggio, '')));
  v_riepilogo text := lower(trim(coalesce(p_riepilogo, '')));
  v_accettazione_letterale boolean := false;
  v_direttiva_specifica boolean := false;
  v_riepilogo_esplicito boolean := false;
begin
  if v_messaggio ~ '(non.{0,25}(accett|conferm|approv|proced)|rifiut|troppo caro|ci penso|devo valutare|dobbiamo valutare|vi faccio sapere|se (accetto|confermo|procedo)|non vorrei procedere)' then
    return false;
  end if;

  v_accettazione_letterale :=
    v_messaggio ~ '(accetto|confermo|approvo).{0,45}(preventivo|offerta|ordine|lavorazione|riparazione|programma scambio)'
    or v_messaggio ~ '(preventivo|offerta|ordine|lavorazione|riparazione|programma scambio).{0,45}(accettat|confermat|approvat)';

  v_direttiva_specifica :=
    (
      v_messaggio ~ '(potete procedere|procedete pure|date pure corso|dare seguito|diamo seguito|vorrei proseguire)'
      and v_messaggio ~ '(preventivo|offerta|lavorazione|riparazione|programma scambio)'
    );

  -- Una domanda su procedura, ritiro o spedizione non e una conferma.
  if not v_accettazione_letterale
     and not v_direttiva_specifica
     and (
       v_messaggio ~ '(come|quando|dove|quale|cosa).{0,55}(proced|ritir|sped)'
       or v_messaggio ~ '(proced|ritir|sped).{0,55}(come|quando|dove|quale|cosa)'
       or (v_messaggio ~ '[?]' and v_messaggio ~ '(proced|ritir|sped)')
     )
  then
    return false;
  end if;

  -- Il riepilogo puo recuperare una conferma precedente solo con formule
  -- inequivoche; parole isolate come pagamento, ritiro o spedizione non bastano.
  v_riepilogo_esplicito :=
    v_riepilogo ~ '(accettat|confermat|approvat).{0,55}(lavorazione|riparazione|preventivo|offerta|ordine)'
    or v_riepilogo ~ '(lavorazione|riparazione|preventivo|offerta|ordine).{0,55}(accettat|confermat|approvat)'
    or v_riepilogo ~ 'scelt[oa].{0,55}(lavorazione|riparazione|programma scambio)';

  return v_accettazione_letterale
    or v_direttiva_specifica
    or v_riepilogo_esplicito;
end;
$$;

revoke all on function private.testo_conferma_ordine_inequivoca(text, text)
  from public, anon, authenticated;

create or replace function private.recupera_conferma_ordine_evento_keplero()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_messaggio text := trim(coalesce(
    new.payload ->> 'ultimo_messaggio_cliente',
    new.payload ->> 'messaggio_cliente',
    new.payload ->> 'messaggio',
    ''
  ));
  v_riepilogo text := trim(coalesce(
    new.payload ->> 'riepilogo_operativo',
    new.payload ->> 'descrizione_guasto',
    new.payload ->> 'richiesta',
    ''
  ));
begin
  if private.testo_conferma_ordine_inequivoca(v_messaggio, v_riepilogo) then
    perform public.conferma_ordine_da_keplero(
      new.pratica_id,
      new.external_key,
      coalesce(nullif(v_messaggio, ''), nullif(v_riepilogo, ''))
    );
  end if;

  return new;
end;
$$;

revoke all on function private.recupera_conferma_ordine_evento_keplero()
  from public, anon, authenticated;

comment on function private.testo_conferma_ordine_inequivoca(text, text) is
  'Riconosce soltanto accettazioni esplicite della specifica offerta o lavorazione; esclude domande logistiche, pagamenti e richieste di istruzioni.';

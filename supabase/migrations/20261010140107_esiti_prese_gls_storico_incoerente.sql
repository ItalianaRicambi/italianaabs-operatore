-- Esiti contraddittori: un mancato ritiro/annullamento seguito da transito o
-- consegna non prova quando sia avvenuta la presa. Richiede verifica operatore.
do $migration$
declare
 definizione text := pg_get_functiondef('public.registra_esito_presa_gls(jsonb,uuid,text)'::regprocedure);
 punto text := E' v_nome:=private.gls_normalizza(p_dati->>''destinatario'');';
 controllo text := $patch$
 if v_ritirato is null and v_evento is not null and exists (
  select 1 from jsonb_array_elements(p_dati->'eventi') e
  where (e->>'at')::timestamptz>v_evento
   and private.gls_normalizza(e->>'stato')~'^(spedizione creata|partita dalla sede|in transito|arrivata|consegnata)'
 ) then
  v_stato:='da_verificare';
  v_motivo:='Storico GLS incoerente: '||v_motivo||' Risultano eventi di spedizione successivi senza conferma del ritiro.';
 end if;
$patch$;
begin
 if position(punto in definizione)=0 or position('Storico GLS incoerente:' in definizione)>0 then
  raise exception 'Definizione registra_esito_presa_gls inattesa: verificare prima di applicare';
 end if;
 execute replace(definizione,punto,controllo||punto);
end $migration$;

notify pgrst,'reload schema';

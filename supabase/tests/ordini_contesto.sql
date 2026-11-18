-- No persistent changes, no client communications. All fixtures are synthetic.
begin;
do $$
declare base jsonb; d jsonb; m jsonb; n integer:=0;
begin
 base := '[
 {"id":"1","data":"2026-10-01T10:00:00Z","direzione":"entrata","testo":"Vorrei dare seguito alla vostra proposta. Il preventivo resta confermato?"},
 {"id":"2","data":"2026-10-01T10:01:00Z","direzione":"entrata","testo":"Dovrei inviare il mio dispositivo"},
 {"id":"3","data":"2026-10-01T10:02:00Z","direzione":"uscita","testo":"Per procedere ci occorrono i dati fiscali per apertura della pratica"},
 {"id":"4","data":"2026-10-01T10:03:00Z","direzione":"entrata","testo":"Mario Rossi, codice fiscale RSSMRA80A01H501U, Via Roma 1, 00100 Roma, mario@example.com"}
 ]'::jsonb;
 d:=private.classifica_sequenza_ordine(base);
 assert d->>'decisione'='conferma' and d->>'scelta'='ORIGINALE', 'Complete fiscal sequence'; n:=n+1;
 m:='{"id":"5","data":"2026-10-20T10:00:00Z","direzione":"entrata","testo":"Per lunedì il meccanico non riuscirebbe a smontare il pezzo per tempo"}';
 assert private.classifica_sequenza_ordine(base||jsonb_build_array(m))->>'decisione'='conferma', 'Logistics postponement must retain order'; n:=n+1;
 m:=jsonb_set(m,'{testo}','"Annullate l’ordine, non voglio procedere"');
 assert private.classifica_sequenza_ordine(base||jsonb_build_array(m))->>'decisione'='verifica', 'Withdrawal must block confirmation'; n:=n+1;
 m:=jsonb_set(m,'{testo}','"Prima di confermare devo sentire il cliente"');
 assert private.classifica_sequenza_ordine(base||jsonb_build_array(m))->>'decisione'='verifica', 'Commercial postponement'; n:=n+1;
 assert private.classifica_sequenza_ordine(base-0)->>'decisione'='verifica', 'Fiscal details alone are not unconditional acceptance'; n:=n+1;
 assert private.classifica_sequenza_ordine(base-2)->>'decisione'='verifica', 'Unrequested fiscal details'; n:=n+1;
 assert private.classifica_sequenza_ordine(base-3)->>'decisione'<>'conferma', 'Missing fiscal response'; n:=n+1;
 assert private.classifica_sequenza_ordine(jsonb_set(base,'{0,testo}','"Non confermo il preventivo"'))->>'decisione'<>'conferma', 'Negated acceptance'; n:=n+1;
 assert private.classifica_sequenza_ordine(jsonb_set(base,'{0,testo}','"Vorrei sapere se posso accettare il preventivo"'))->>'decisione'<>'conferma', 'Question is not acceptance'; n:=n+1;
 assert private.classifica_sequenza_ordine(jsonb_set(base,'{3,modificato}','true'))->>'decisione'<>'conferma', 'Edited fiscal message'; n:=n+1;
 assert private.classifica_sequenza_ordine(jsonb_set(base,'{3,revoca}','true'))->>'decisione'<>'conferma', 'Deleted fiscal message'; n:=n+1;
 assert private.classifica_sequenza_ordine(jsonb_set(base,'{2,testo}','"Invii i dati fiscali per preparare il preventivo"'))->>'decisione'<>'conferma', 'Fiscal request for estimate'; n:=n+1;
 m:=jsonb_set(base,'{3,testo}','"Mario Rossi, codice fiscale RSSMRA80A01H501U"');
 m:=m||jsonb_build_array('{"id":"5","data":"2026-10-01T10:04:00Z","direzione":"entrata","testo":"Via Roma 1, 00100 Roma, mario@example.com"}'::jsonb);
 assert private.classifica_sequenza_ordine(m)->>'decisione'='conferma', 'Fiscal reply split across messages'; n:=n+1;
 m:='{"id":"5","data":"2026-10-20T10:00:00Z","direzione":"entrata","testo":"Confermo solo se il prezzo rimane quello"}';
 assert private.classifica_sequenza_ordine(base||jsonb_build_array(m))->>'decisione'='verifica', 'Conditional acceptance needs review'; n:=n+1;
 m:=jsonb_set(m,'{testo}','"Non sono sicuro di voler procedere"');
 assert private.classifica_sequenza_ordine(base||jsonb_build_array(m))->>'decisione'='verifica', 'Uncertainty after acceptance'; n:=n+1;
 raise notice '% classifier cases passed',n;
end $$;
rollback;

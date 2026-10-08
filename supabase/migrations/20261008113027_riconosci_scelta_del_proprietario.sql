-- Un'officina può riportare la scelta del proprietario in terza persona.
-- Manteniamo i controlli contro rinvii, dubbi e verifiche preliminari.
create or replace function private.scelta_lavorazione_cliente(p_testo text)
returns boolean language sql immutable security invoker set search_path=''
as $fn$
select coalesce(
 (
   lower(trim(p_testo)) ~ '^(sarei interessat[oa] a (fare )?(revisionare|riparare)|vorrei procedere con|procediamo con|scelgo|ho scelto|preferisco)[[:space:]]'
   or lower(trim(p_testo)) ~ '\m(il[[:space:]]+)?(proprietario|cliente)[[:space:]]+ha[[:space:]]+deciso[[:space:]]+(per|di[[:space:]]+procedere[[:space:]]+con)\M'
 )
 and lower(p_testo) ~ '\m(revision|ripar|lavoraz|programma scambio)'
 and lower(p_testo) !~ '(non.{0,30}(revision|ripar|proced|scel|deciso)|ci penso|forse|valut|quanto|se.{0,30}(riparabile|possibile|costa))'
 and not private.rinvio_conferma_per_verifiche(p_testo),false);
$fn$;

create or replace function private.evidenza_accettazione_controllo(p_testo text)
returns boolean language sql immutable security invoker set search_path=''
as $fn$
select (
 lower(coalesce(p_testo,'')) ~ '\m(accetto|accettiamo|confermo|confermiamo|approvo|approviamo)\M.{0,45}\m(preventivo|offerta|ordine|lavorazione|riparazione)\M'
 or private.scelta_lavorazione_cliente(p_testo)
)
 and lower(coalesce(p_testo,'')) !~ '(non.{0,25}(accett|conferm|approv)|\mse\M.{0,30}(accett|conferm|approv)|rifiut|ci penso|valutare|forse|eventualmente)';
$fn$;

revoke all on function private.scelta_lavorazione_cliente(text),
 private.evidenza_accettazione_controllo(text) from public,anon,authenticated;

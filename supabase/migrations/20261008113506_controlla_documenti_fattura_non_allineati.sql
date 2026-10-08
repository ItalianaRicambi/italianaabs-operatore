-- Un PDF con nome "Fattura" va verificato se la pratica non è fatturata.
-- Il nome del file genera una segnalazione: non basta per cambiare lo stato.
-- Preserviamo tutte le regole esistenti, inclusi limite 48h e sospensione weekend.
do $patch$
declare v_def text; v_fin text:=E'\n;\n$function$'; v_aggiunta text;
begin
 v_def:=regexp_replace(pg_get_functiondef('private.candidati_coerenza_keplero()'::regprocedure),'[[:space:]]+$','');
 if right(v_def,length(v_fin))<>v_fin then raise exception 'Definizione controllo inattesa'; end if;
 v_aggiunta:=$addition$
union all
select distinct on (p.id) 'fattura_documento:'||p.id,p.id,e.id,
 'fattura_documento_non_allineato',
 'Documento denominato Fattura ricevuto, ma pratica non fatturata. Verificare contenuto, targa e data del PDF prima di allineare.',
 left(e.testo,400)||' | '||coalesce(e.payload->'allegati','[]'::jsonb)::text
from pratiche p join eventi e on e.pratica_id=p.id
where p.tipo_flusso::text='commerciale' and p.stato_fatturazione::text<>'fatturato'
 and exists(
   select 1 from jsonb_array_elements(case when jsonb_typeof(e.payload->'allegati')='array'
     then e.payload->'allegati' else '[]'::jsonb end) a
   where coalesce(a->>'url',a->>'file_url',a#>>'{}','') ~* '(fattura[-_]|fattura%20)'
 )
$addition$;
 execute left(v_def,length(v_def)-length(v_fin))||v_aggiunta||v_fin;
end;
$patch$;

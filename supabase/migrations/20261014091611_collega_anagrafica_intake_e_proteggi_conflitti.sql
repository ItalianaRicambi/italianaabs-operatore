
do $patch$
declare d text; a text; b text;
begin
 select pg_get_functiondef('public.valuta_collegamento_cliente(uuid)'::regprocedure) into d;
 a:=$anchor$  update public.pratiche
  set
    cliente_id = null,
    fonte_collegamento_cliente = 'nessuna',
    cliente_collegato_at = null,
    stato_amministrativo = 'dati_mancanti',$anchor$;
 if position(a in d)=0 or position('v_anagrafica_acquisita' in d)>0 then raise exception 'Definizione inattesa';end if;
 d:=replace(d,'  v_codice_fiscale text;','  v_codice_fiscale text;'||chr(10)||'  v_anagrafica_acquisita jsonb;');
 b:=$new$  v_anagrafica_acquisita:=private.crea_cliente_fiscale_intake(p_pratica_id);
  if v_anagrafica_acquisita is not null then return v_anagrafica_acquisita;end if;

$new$||a;
 execute replace(d,a,b);
 select pg_get_functiondef('private.valida_dati_fatturazione()'::regprocedure) into d;
 a:='  if new.stato_fatturazione<>''da_fatturare'' then return new; end if;';
 if position(a in d)=0 then raise exception 'Validatore inatteso';end if;
 b:=a||$new$
  if new.fonte_collegamento_cliente is distinct from 'operatore'
    and jsonb_array_length(coalesce(new.dati_raw#>'{anagrafica_estratta,_conflitti}','[]'::jsonb))>0 then
    new.stato_amministrativo:='corrispondenza_ambigua';
    new.nota_amministrativa:='Dati fiscali discordanti nella conversazione: verifica dell’operatore richiesta.';
    return new;
  end if;
$new$;
 execute replace(d,a,b);
end $patch$;


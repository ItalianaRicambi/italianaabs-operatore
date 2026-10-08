-- L'ordine acquisito resta tale anche quando manca l'anagrafica fiscale.
-- La coda fatturazione richiede dati canonici completi e nessuna sospensione.
create or replace function private.verifica_dati_cliente_fatturazione(p_cliente_id uuid)
returns jsonb language plpgsql set search_path = '' as $function$
declare
  c public.clienti%rowtype;
  mancanti text[] := '{}'::text[];
begin
  select * into c from public.clienti where id = p_cliente_id;
  if not found then
    return jsonb_build_object('completi',false,'motivo','cliente_non_collegato',
      'campi',jsonb_build_array('denominazione','indirizzo_fatturazione','cap','comune','partita_iva_o_codice_fiscale'));
  end if;
  if nullif(btrim(c.denominazione),'') is null then mancanti:=array_append(mancanti,'denominazione'); end if;
  if nullif(btrim(c.indirizzo_fatturazione),'') is null then mancanti:=array_append(mancanti,'indirizzo_fatturazione'); end if;
  if nullif(btrim(c.cap),'') is null then mancanti:=array_append(mancanti,'cap'); end if;
  if nullif(btrim(c.comune),'') is null then mancanti:=array_append(mancanti,'comune'); end if;
  if nullif(btrim(c.partita_iva),'') is null and nullif(btrim(c.codice_fiscale),'') is null then
    mancanti:=array_append(mancanti,'partita_iva_o_codice_fiscale');
  end if;
  select coalesce(array_agg(distinct campo order by campo),'{}'::text[]) into mancanti
    from unnest(mancanti || coalesce(c.campi_amministrativi_mancanti,'{}'::text[])) campo;
  if cardinality(mancanti)=0 and (not coalesce(c.dati_fiscali_completi,false)
      or coalesce(c.da_verificare,false) or coalesce(c.possibile_duplicato,false)) then
    mancanti:=array['verifica_anagrafica'];
  end if;
  return jsonb_build_object('completi',cardinality(mancanti)=0,'campi',to_jsonb(mancanti),
    'motivo',case when cardinality(mancanti)=0 then 'cliente_completo' else 'dati_cliente_da_completare_o_verificare' end);
end;
$function$;

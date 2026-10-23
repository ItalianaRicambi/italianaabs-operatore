"""Assembla migrazione e test obbligatori per l'esecuzione manuale atomica."""
import argparse
import hashlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MIGRAZIONE = "20261023093042_stabilizza_pratiche_keplero.sql"
FUNZIONI = {
    "private.abbina_documento_preventivo": "uuid",
    "public.conferma_invio_documento_preventivo": "uuid,jsonb",
    "public.registra_pdf_originale_k": "uuid,uuid,text,jsonb,text",
    "private.valuta_originale_k": "uuid,text",
    "public.conferma_ordine_da_keplero": "uuid,text,text",
    "private.elabora_evento_keplero": "bigint",
    "private.rileva_scelta_cliente_evento": "bigint",
}
SUITE = [
    "affidabilita_pratiche", "conferme_ordine_letterali",
    "conferme_plico_e_instradamento", "consenso_originale_e_pdf_tardivi",
    "offerte_guardie", "offerte_ingresso_pdf", "offerte_scelte_ritiri",
    "ordine_intenzione_fiscali", "preventivi_documenti_e_prove_invio",
    "preventivo_storico_gia_inviato", "recupero_originali_keplero",
    "scelta_conclusa_e_prefissi_fiscali",
]


def prepara(revisione: str) -> str:
    if not re.fullmatch(r"[a-f0-9]{40}", revisione):
        raise ValueError("Revisione Git completa richiesta")
    ripristino = (ROOT / "supabase/rollback/stabilizza_pratiche_keplero.sql").read_text()
    controlli = []
    for nome, argomenti in FUNZIONI.items():
        pattern = r"CREATE OR REPLACE FUNCTION " + re.escape(nome) + r"\(.*?AS \$function\$(.*?)\$function\$"
        trovato = re.search(pattern, ripristino, re.S)
        if trovato is None:
            raise ValueError("Definizione precedente assente: " + nome)
        impronta = hashlib.sha256(trovato.group(1).encode()).hexdigest()
        controlli.append(f"('{nome}({argomenti})','{impronta}')")
    sql = """-- INSTALLAZIONE CONTROLLATA — VERSIONE 2 — 23 OTTOBRE 2026
-- Permessi reali; 19 gruppi di prove e 11 regressioni; controllo ancora sospeso.
begin;
set local statement_timeout='100s';
set local lock_timeout='10s';
do $preflight$
declare x record; attuale text;
begin
 for x in select * from (values
""" + ",\n".join(controlli) + """
 ) v(funzione,impronta) loop
  select encode(sha256(convert_to(prosrc,'UTF8')),'hex') into attuale
   from pg_proc where oid=to_regprocedure(x.funzione);
  if attuale is distinct from x.impronta then
   raise exception 'Il motore è cambiato dopo il collaudo: aggiornare la migrazione (%)',x.funzione;
  end if;
 end loop;
end; $preflight$;
"""
    sql += (ROOT / "supabase/migrations" / MIGRAZIONE).read_text()
    for nome in SUITE:
        prova = (ROOT / "supabase/tests" / (nome + ".sql")).read_text()
        prova, numero = re.subn(r"^begin;[ \t]*$", "", prova, count=1, flags=re.M)
        if numero != 1 or "rollback;" not in prova:
            raise ValueError("Suite senza transazione annullabile: " + nome)
        prima, dopo = prova.rsplit("rollback;", 1)
        sql += "\n\nsavepoint prova;\n" + prima
        sql += "\nreset role;\nrollback to savepoint prova;\nrelease savepoint prova;\n" + dopo
    sql += f"""
reset role;
insert into supabase_migrations.schema_migrations(version,name,statements)
values('20261023093042','stabilizza_pratiche_keplero',array['Source: ItalianaRicambi/italianaabs-operatore commit {revisione}, supabase/migrations/{MIGRAZIONE}; 19 gruppi e 11 regressioni prima del commit.']);
commit;
select 'INSTALLAZIONE V2 E COLLAUDI RIUSCITI — RICONCILIATORE SOSPESO, DISTRIBUZIONE APP DA COMPLETARE' as esito,
 (select attivo from public.keplero_stato_riconciliazione where id) as riconciliatore_attivo;
"""
    return sql


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    contenuto = prepara(args.revision)
    args.output.write_text(contenuto, encoding="utf-8")
    print(f"Creato {args.output}: {len(contenuto.splitlines())} righe, {len(contenuto.encode())} byte")

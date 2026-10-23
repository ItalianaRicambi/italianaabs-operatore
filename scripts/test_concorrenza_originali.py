"""Prova i lock della funzione reale su PostgreSQL nativo, senza dati o servizi esterni.

Richiede psql e un database locale vuoto il cui nome inizi con keplero_lock_test.
Le fixture isolano registrazione e lease; le regole commerciali hanno suite separate.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import time
from urllib.parse import urlparse
import uuid

ROOT = Path(__file__).resolve().parents[1]
URL = os.environ["TEST_DATABASE_URL"]
parsed = urlparse(URL)
if parsed.hostname not in ("localhost", "127.0.0.1") or not parsed.path.startswith("/keplero_lock_test"):
    raise SystemExit("Usare soltanto un database locale di collaudo dedicato")
CMD = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", URL]
LEASE = str(uuid.uuid4())
SESSIONS = [str(uuid.uuid4()) for _ in range(9)]


def run(sql, error=None):
    r = subprocess.run(CMD, input="\\set VERBOSITY verbose\n" + sql, text=True,
                       capture_output=True, timeout=15)
    if error:
        assert r.returncode != 0 and error in r.stderr, r.stdout + r.stderr
    else:
        assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout.strip()


def original_function():
    src = (ROOT / "supabase/migrations/20261021135041_controllo_risposte_keplero.sql").read_text()
    start = src.index("create or replace function public.registra_originali_k(")
    end = src.index("end; $$;", start) + len("end; $$;")
    return src[start:end]


def registration(session, messages=None, lease=LEASE):
    if messages is None:
        messages = [{"id": "messaggio", "data": "2026-01-01T00:00:00Z", "data_originale": "2026-01-01T00:00:00Z",
                     "direzione": "entrata", "tipo": "text", "testo": "Test di sola registrazione",
                     "impronta": "a" * 64, "candidato": False, "revoca": False, "originale": {}}]
    payload = json.dumps(messages).replace("'", "''")
    return f"select public.registra_originali_k('{lease}','{session}','{payload}'::jsonb);"


def transaction(sql):
    return "begin; set local role service_role; set local lock_timeout='300ms'; " + sql + "rollback;"


def hold_registration(session):
    p = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, bufsize=1)
    p.stdin.write("begin; set local role service_role; set local statement_timeout='3s'; "
                  + registration(session) + "\n\\echo PRONTO\n")
    p.stdin.flush()
    deadline = time.monotonic() + 8
    output = ""
    # Lettura binaria non bufferizzata: un marker già letto insieme alla risposta
    # non deve dipendere da un secondo evento select sul descrittore.
    while "PRONTO" not in output and time.monotonic() < deadline:
        if select.select([p.stdout], [], [], 0.2)[0]:
            data = os.read(p.stdout.fileno(), 65536).decode()
            if not data:
                break
            output += data
    if "PRONTO" not in output:
        p.kill()
        _, error = p.communicate(timeout=3)
        raise AssertionError(output + error)
    return p


def release(process):
    process.stdin.write("rollback;\n\\q\n")
    process.stdin.flush()
    _, error = process.communicate(timeout=8)
    assert process.returncode == 0, error


def main():
    assert run("select count(*) from pg_tables where schemaname='public';") == "0", "Database non vuoto"
    run("""
      create role service_role nologin bypassrls;
      create schema private;
      create table public.keplero_recupero_originali(id boolean primary key,lease uuid,scade_at timestamptz);
      create table public.keplero_sessioni_originali(sessione uuid primary key,lease uuid,
        ultimo_successo_at timestamptz,errore text,messaggi integer);
      create table public.keplero_originali(sessione uuid,messaggio_id text,data_messaggio timestamptz,
        data_originale text,direzione text,tipo text,testo text,impronta text,candidato boolean,revoca boolean,
        targa_pdf text,sha256_pdf text,originale jsonb,consegna jsonb,modificato boolean default false,
        revisione jsonb,primary key(sessione,messaggio_id));
      create table public.keplero_verifiche_originali(sessione uuid,messaggio_id text,esito text,motivo text,
        operatore text,verificata_at timestamptz,updated_at timestamptz,primary key(sessione,messaggio_id));
      grant usage on schema public,private to service_role;
      grant all on all tables in schema public to service_role;
    """)
    run(original_function())
    run(f"insert into public.keplero_recupero_originali values(true,'{LEASE}',now()+interval '10 minutes');"
        + "insert into public.keplero_sessioni_originali(sessione,lease) values"
        + ",".join(f"('{s}','{LEASE}')" for s in SESSIONS) + ";")

    first = hold_registration(SESSIONS[0])
    try:
        run(transaction(registration(SESSIONS[1])), error="55P03")
    finally:
        release(first)
    print("OK: la versione precedente riproduce il blocco tra chat diverse")

    run((ROOT / "supabase/migrations/20261023144505_parallelizza_registro_originali.sql").read_text())
    held = []
    try:
        for session in SESSIONS[:8]:
            held.append(hold_registration(session))
        print("OK: otto registrazioni distinte completate mentre le transazioni restano tutte aperte")
        run(transaction(registration(SESSIONS[0])), error="55P03")
        print("OK: una seconda registrazione della stessa chat resta esclusa")
        run("begin; set local lock_timeout='300ms'; update public.keplero_recupero_originali "
            "set lease=null where id; rollback;", error="55P03")
        print("OK: cambio o chiusura del lotto attendono le registrazioni in corso")
    finally:
        for process in reversed(held):
            release(process)

    run(transaction(registration(SESSIONS[8], lease=str(uuid.uuid4()))), error="P0001")
    run(f"update public.keplero_sessioni_originali set lease=null where sessione='{SESSIONS[8]}';")
    run(transaction(registration(SESSIONS[8])), error="P0001")
    run(f"update public.keplero_sessioni_originali set lease='{LEASE}' where sessione='{SESSIONS[8]}';")
    print("OK: lease globale e appartenenza della chat entrambi verificati")
    run("begin; set local role service_role; " + registration(SESSIONS[8]) * 2 + "commit;")
    assert run(f"select count(*) from public.keplero_originali where sessione='{SESSIONS[8]}';") == "1"
    run(transaction(registration(SESSIONS[8], messages=[{"id": "doppio"}, {"id": "doppio"}])), error="ID duplicati")
    run("update public.keplero_recupero_originali set lease=null where id;")
    print("OK: replay senza duplicati, snapshot errato rifiutato, lock rilasciati")
    print("COLLAUDO CONCORRENZA COMPLETATO SU POSTGRESQL NATIVO")


if __name__ == "__main__":
    main()

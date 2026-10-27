"""Collaudo delle funzioni reali su PostgreSQL locale, con dipendenze fittizie.

Verifica esclusione reciproca, rilascio dei lock, recupero dei documenti e
telemetria delle fasi. Non accede a servizi o dati di produzione.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
URL = os.environ['TEST_DATABASE_URL']
parsed = urlparse(URL)
if parsed.hostname not in ('localhost', '127.0.0.1') or not parsed.path.startswith('/keplero_lock_test'):
    raise SystemExit('Usare soltanto un database locale di collaudo dedicato')
CMD = ['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', URL]
MIGRATION = ROOT / 'supabase/migrations/20261027180812_serializza_documenti_e_misura_manutenzione.sql'
PHASES = ['gestisci_code_automatiche', 'ritenta_preventivi_non_abbinati',
          'recupera_preventivi_gia_inviati', 'ritenta_letture_offerte',
          'recupera_ordini_contestuali_keplero', 'recupera_flussi_offerta_rientro',
          'recupera_eventi_keplero_falliti', 'riprova_prenotazioni_prese', 'controlla_coerenza_keplero']
MAINT = 'select private.esegui_manutenzione_keplero();'
RETRY = 'select private.ritenta_documenti_preventivo();'


def run(sql):
    r = subprocess.run(CMD, input=sql, text=True, capture_output=True, timeout=10)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout.strip()


def trial(sql):
    return run("begin; set local lock_timeout='200ms'; set local statement_timeout='2s'; " + sql + 'rollback;')


def hold(sql):
    p = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, bufsize=1)
    p.stdin.write("begin; set local statement_timeout='2s'; " + sql + '\n\\echo PRONTO\n')
    p.stdin.flush()
    output = ''
    deadline = time.monotonic() + 5
    while 'PRONTO' not in output and time.monotonic() < deadline:
        if select.select([p.stdout], [], [], 0.1)[0]:
            data = os.read(p.stdout.fileno(), 65536).decode()
            if not data:
                break
            output += data
    if 'PRONTO' not in output:
        p.kill()
        _, err = p.communicate(timeout=2)
        raise AssertionError(output + err)
    return p


def release(p):
    p.stdin.write('rollback;\n\\q\n')
    p.stdin.flush()
    _, err = p.communicate(timeout=3)
    assert p.returncode == 0, err


def source_function(path, name):
    src = (ROOT / 'supabase/migrations' / path).read_text()
    start = src.index(name)
    start = src.rfind('create ', 0, start)
    end = src.index('end; $$;', start) + len('end; $$;')
    return src[start:end]


def main():
    assert run("select count(*) from pg_tables where schemaname='public';") == '0', 'Database non vuoto'
    run("""
    create role anon; create role authenticated; create role service_role;
    create schema private; create schema cron;
    create table private.keplero_manutenzione_esecuzioni(finestra timestamptz primary key,
      iniziata_at timestamptz default now(), completata_at timestamptz, risultati jsonb);
    create table public.documenti_preventivo_auto(id uuid primary key, prova_invio jsonb,
      stato text, ultimo_tentativo_at timestamptz);
    create table public.chiamate(tipo text, documento uuid);
    create table cron.job(jobid bigint,jobname text,command text,schedule text);
    insert into cron.job values(72,'ritenta-documenti-preventivo',
      'select private.ritenta_documenti_preventivo();','*/5 * * * *');
    create function cron.alter_job(job_id bigint,schedule text) returns void language sql as $$
      update cron.job set schedule=$2 where jobid=$1;
    $$;
    create function private.abbina_documento_preventivo(p_id uuid) returns void language sql as $$
      insert into public.chiamate values('abbina',p_id);
      update public.documenti_preventivo_auto set ultimo_tentativo_at=now() where id=p_id;
    $$;
    create function public.conferma_invio_documento_preventivo(p_id uuid,prova jsonb)
    returns void language sql as $$ insert into public.chiamate values('conferma',p_id); $$;
    insert into public.documenti_preventivo_auto values
      ('00000000-0000-0000-0000-000000000001','{}','pendente',null),
      ('00000000-0000-0000-0000-000000000002','{}','inviato',null),
      ('00000000-0000-0000-0000-000000000003','{}','pendente',now());
    """)
    for phase in PHASES:
        run(f"create function private.{phase}() returns integer language sql as $$ select 1; $$;")
    run(source_function('20261015094749_recupero_richieste_keplero_serializzato.sql',
                        'private.esegui_manutenzione_keplero()'))
    run(source_function('20261016174052_preventivi_documenti_e_prove_invio.sql',
                        'private.ritenta_documenti_preventivo()'))
    held = hold(MAINT)
    try:
        assert trial(RETRY) == '1'
        print('OK: la versione precedente accede ai documenti durante la manutenzione')
    finally:
        release(held)

    run(MIGRATION.read_text())
    assert run('select schedule from cron.job;') == '3-59/5 * * * *'
    held = hold(MAINT)
    try:
        assert trial(RETRY) == '0'
        assert run('select count(*) from public.chiamate;') == '0'
        print('OK: manutenzione attiva esclude subito il recupero PDF, senza scritture')
    finally:
        release(held)
    held = hold(RETRY)
    try:
        assert json.loads(trial(MAINT)) == {'esito': 'gia_in_esecuzione'}
        assert trial(RETRY) == '0'
        print('OK: recupero PDF esclude manutenzione e secondo recupero PDF')
    finally:
        release(held)
    assert run(RETRY) == '1'
    assert run("select string_agg(tipo,',' order by tipo) from public.chiamate;") == 'abbina,conferma'
    assert run(RETRY) == '0'
    print('OK: dopo il rilascio il documento pendente viene abbinato e confermato una sola volta')

    run("create or replace function private.ritenta_letture_offerte() returns integer language plpgsql "
        "as $$ begin raise exception 'errore simulato'; end; $$;")
    result = json.loads(run(MAINT))
    assert set(result) == set(PHASES)
    for phase, value in result.items():
        assert value['durata_ms'] >= 0
        assert value['ok'] == (phase != 'ritenta_letture_offerte')
    assert result['ritenta_letture_offerte']['sqlstate'] == 'P0001'
    assert json.loads(run('select risultati from private.keplero_manutenzione_esecuzioni;')) == result
    assert json.loads(run(MAINT)) == {'esito': 'finestra_gia_elaborata'}
    print('OK: durate e SQLSTATE persistiti, fasi successive eseguite, finestra non ripetuta')
    assert run("select has_function_privilege('anon','private.ritenta_documenti_preventivo()','execute');") == 'f'
    assert run("select has_function_privilege('authenticated','private.esegui_manutenzione_keplero()','execute');") == 'f'
    print('COLLAUDO MANUTENZIONE COMPLETATO SU POSTGRESQL NATIVO')


if __name__ == '__main__':
    main()

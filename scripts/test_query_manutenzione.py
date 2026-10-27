"""Confronta query precedente e ottimizzata su PostgreSQL locale isolato.

Le fixture non contengono dati cliente. Le funzioni di classificazione esterne
sono stub condivisi: si verifica che l'ottimizzazione conservi le stesse righe,
compresi duplicati e valori nulli, senza ridefinire le regole commerciali.
"""
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
URL = os.environ['TEST_DATABASE_URL']
p = urlparse(URL)
if p.hostname not in ('localhost', '127.0.0.1') or not p.path.startswith('/keplero_lock_test'):
    raise SystemExit('Usare soltanto un database locale di collaudo dedicato')
CMD = ['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', URL]
MIGRATIONS = list((ROOT / 'supabase/migrations').glob('*_riduci_durata_manutenzione_keplero.sql'))
assert len(MIGRATIONS) == 1
MIGRATION = MIGRATIONS[0].read_text()


def run(sql):
    r = subprocess.run(CMD, input=sql, text=True, capture_output=True, timeout=30)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout.strip()


def compare(label):
    result = json.loads(run('''
      with prima as materialized(select * from private.candidati_coerenza_keplero_reference()),
      dopo as materialized(select * from private.candidati_coerenza_keplero())
      select json_build_object('righe',(select count(*) from prima),'differenze',
       (select count(*) from ((select * from prima except all select * from dopo)
          union all (select * from dopo except all select * from prima)) d));
    '''))
    assert result['differenze'] == 0, result
    print('OK:', label, result)
    return result['righe']


def main():
    assert run("select count(*) from pg_tables where schemaname='public';") == '0'
    run('''
      create role anon; create role authenticated;
      create schema private;
      create table public.pratiche(id uuid primary key,targa text,dati_raw jsonb,telefono text,
        tipo_flusso text,stato_commerciale text,stato_fatturazione text,preventivo_inviato_at timestamptz,
        descrizione_guasto text,spie_accese boolean);
      create table public.keplero_live_events(id bigint primary key,pratica_id uuid,external_key text,
        payload jsonb,created_at timestamptz);
      create table public.preventivi(pratica_id uuid,stato text,inviato_at timestamptz,creato_at timestamptz);
      create table public.contatti_operativi(attivo boolean,blocca_automazioni_commerciali boolean,telefono_normalizzato text);
      create table public.codici_identificativi(pratica_id uuid,codice text);
      create table public.allegati(pratica_id uuid,url text,created_at timestamptz);
      create table public.dtc(pratica_id uuid);
      create table private.keplero_event_processing(event_id bigint,stato text,errore text);
      create table public.preventivi_emessi_ricevuti(external_id text,pratica_id uuid,esito text,nome_file text,
        targa text,data_offerta timestamptz,file_url text,risolto_at timestamptz,ricevuto_at timestamptz);
      create table public.keplero_controllo_segnalazioni(chiave text primary key,pratica_id uuid,event_id bigint,
        regola text,descrizione text,evidenza text,rilevata_at timestamptz default now(),
        verificata_at timestamptz default now(),risolta_at timestamptz);
      create table public.keplero_controllo_stato(id integer primary key,ultima_esecuzione_at timestamptz,
        eventi_esaminati integer,segnalazioni_aperte integer,risposte_k_disponibili boolean,errore text);
      insert into public.keplero_controllo_stato(id) values(1);
      create function private.inizio_finestra_controllo_keplero(timestamptz,integer)
        returns timestamptz language sql stable as $$ select $1-make_interval(hours=>$2); $$;
      create function private.ordine_da_scelta_e_fiscali(bigint) returns jsonb language sql stable
        as $$ select case when $1%4=0 then '{"confermato":true}'::jsonb else '{}'::jsonb end; $$;
    ''')
    for name, pattern in {
        'evidenza_accettazione_controllo': 'accetto', 'rinvio_conferma_per_verifiche': 'verificare prima',
        'revoca_scelta_cliente': 'annullo', 'domanda_su_accettazione': 'domanda',
        'dati_fiscali_cliente': 'partita iva'
    }.items():
        run(f"create function private.{name}(text) returns boolean language sql immutable "
            f"as $$ select $1 ~ '{pattern}'; $$;")
    for name in ['candidati_flussi_offerta_rientro', 'candidati_errori_flussi', 'candidati_richieste_keplero']:
        run(f'''create function private.{name}() returns table(chiave text,pratica_id uuid,event_id bigint,
          regola text,descrizione text,evidenza text) language sql stable as $$
          select '{name}',null::uuid,null::bigint,'fixture','descrizione','evidenza'; $$;''')
    old = (ROOT / 'supabase/tests/fixtures/candidati_coerenza_prima_ottimizzazione.sql').read_text()
    run(old.replace('private.candidati_coerenza_keplero()', 'private.candidati_coerenza_keplero_reference()', 1))
    run('begin; ' + MIGRATION + 'commit;')
    assert compare('assenza di eventi, conservate le tre sorgenti supplementari') == 3
    run('''
      insert into public.pratiche
      select md5(i::text)::uuid,case when i=1 then 'aa-123 bb' else 'T'||i end,
        case when i%13=0 then '{"pratica_duplicata":{"archiviata":true}}'::jsonb else '{}'::jsonb end,
        '123'||i,'commerciale',case when i%7=0 then 'raccolta_dati' else 'preventivo_inviato' end,
        case when i%11=0 then 'fatturato' else 'non_applicabile' end,
        now()-interval '24 hours','descrizione fixture',false
      from generate_series(1,40) i;
      insert into public.preventivi select id,'inviato',preventivo_inviato_at,preventivo_inviato_at from public.pratiche;
      insert into public.keplero_live_events
      select i,case when i%17=0 then null else md5(((i%40)+1)::text)::uuid end,'fixture:'||i,
        jsonb_build_object('ultimo_messaggio_cliente',case i%8
          when 0 then 'partita iva 00000000000' when 1 then 'bonifico fatto'
          when 2 then 'non ho pagato' when 3 then 'accetto il preventivo'
          when 4 then 'annullo la scelta' when 5 then null
          when 6 then 'se domani faccio il bonifico' else 'grazie' end),
        now()-interval '1 hour'-i*interval '1 minute'
      from generate_series(1,120) i;
      insert into public.preventivi_emessi_ricevuti(external_id,esito,nome_file,targa,data_offerta,ricevuto_at)
      values('fixture-pdf','da_abbinare','AA123BB.pdf','AA123BB',now(),now()-interval '20 minutes');
    ''')
    assert compare('pagamenti, negazioni, fiscali, revoche, eventi senza pratica e archiviati') > 3
    run("update public.pratiche set stato_fatturazione='fatturato';")
    compare('pratiche fatturate')
    run("update public.keplero_live_events set created_at=now()-interval '60 hours';")
    assert compare('eventi fuori finestra, PDF e sorgenti supplementari conservati') == 4

    # Verifica dell'indice reale: il piano deve usarlo con un insieme selettivo.
    run("insert into public.pratiche(id,targa) select md5(('indice:'||i)::text)::uuid,'ZZ'||i from generate_series(1,10000)i; analyze public.pratiche;")
    plan = json.loads(run("explain (analyze,format json) select id from public.pratiche "
                         "where upper(regexp_replace(coalesce(targa,''),'[^A-Za-z0-9]','','g'))='AA123BB';"))
    assert 'idx_pratiche_targa_normalizzata' in json.dumps(plan), plan
    assert plan[0]['Plan']['Actual Rows'] == 1
    print('OK: targa con spazi/trattino trova la stessa riga usando il nuovo indice')

    # Una funzione strumentata rende visibile quante volte viene calcolato
    # l'insieme di candidati dal controllore reale, non da una sua imitazione.
    run('''
      create sequence public.conta_candidati;
      create table public.candidati_fixture(chiave text,pratica_id uuid,event_id bigint,
        regola text,descrizione text,evidenza text);
      insert into public.candidati_fixture values('attiva',null,1,'fixture','nuova','test'),
        ('riaperta',null,2,'fixture','riaperta','test');
      create or replace function private.candidati_coerenza_keplero()
      returns table(chiave text,pratica_id uuid,event_id bigint,regola text,descrizione text,evidenza text)
      language plpgsql volatile as $$ begin
       perform nextval('public.conta_candidati');
       return query select * from public.candidati_fixture;
      end; $$;
      insert into public.keplero_controllo_segnalazioni(chiave,descrizione,risolta_at) values
       ('attiva','vecchia',null),('riaperta','vecchia',now()-interval '1 day'),('risolta','vecchia',null);
    ''')
    result = json.loads(run('select private.controlla_coerenza_keplero();'))
    assert result['esito'] == 'completato' and result['segnalazioni_aperte'] == 2, result
    assert run('select last_value from public.conta_candidati;') == '1'
    assert run("select count(*) from public.keplero_controllo_segnalazioni where chiave in ('attiva','riaperta') and risolta_at is null;") == '2'
    assert run("select risolta_at is not null from public.keplero_controllo_segnalazioni where chiave='risolta';") == 't'
    run('delete from public.candidati_fixture;')
    assert json.loads(run('select private.controlla_coerenza_keplero();'))['segnalazioni_aperte'] == 0
    assert run('select last_value from public.conta_candidati;') == '2'
    print('OK: un solo calcolo per ciclo, apertura/aggiornamento/risoluzione coerenti anche con insieme vuoto')
    run("create or replace function private.candidati_coerenza_keplero() returns table(chiave text,pratica_id uuid,event_id bigint,regola text,descrizione text,evidenza text) language plpgsql as $$ begin raise exception 'guasto simulato'; end; $$;")
    result = json.loads(run('select private.controlla_coerenza_keplero();'))
    assert result['esito'] == 'errore' and result['errore'] == 'guasto simulato'
    assert run("select errore from public.keplero_controllo_stato where id=1;") == 'guasto simulato'
    print('OK: errore registrato senza mascherarlo come controllo riuscito')
    print('COLLAUDO QUERY MANUTENZIONE COMPLETATO')


if __name__ == '__main__':
    main()

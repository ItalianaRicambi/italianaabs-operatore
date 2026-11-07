import test from 'node:test';
import assert from 'node:assert/strict';
import { creaClientFic, validaRicercaFic, ErroreFic, type RicercaFic } from './fattureInCloud.ts';

const config = { token: 'token-solo-test', companyId: '29153', partitaIva: '02439670031' };
const filtro: RicercaFic = { tipo: 'invoice', dal: '2026-11-01', al: '2026-11-07', cerca: '' };
const aziende = () => Response.json({ data: { companies: [{ id: 29153, name: 'Azienda di prova', vat_number: '02439670031', access_token: 'segreto-da-non-restituire' }] } });
const doc = (id = 1) => ({ id, type: 'invoice', date: '2026-11-03', number: 34, numeration: '/A', entity: { name: 'Officina prova', vat_number: 'IT12345678901', tax_code: '12345678901' },
  currency: { id: 'EUR' }, subject: 'Targa ZZ123ZZ', visible_subject: '', notes: '', amount_gross: 497,
  items_list: [{ code: '10.0206-0410.4', name: 'ABS', description: 'AV41-2C405-AA' }], payments_list: [{ amount: 497, due_date: '2026-11-10', status: 'not_paid' }] });
const pagina = (rows: unknown[], current = 1, last = 1, total = rows.length) => Response.json({ data: rows, current_page: current, last_page: last, total });
const errore = (codice: string) => (e: unknown) => e instanceof ErroreFic && e.codice === codice && !e.message.includes(config.token);

test('solo GET sul dominio ufficiale, no redirect/cache; dati sensibili remoti non propagati', async () => {
  const calls: string[] = [];
  const client = creaClientFic(config, async (url, init) => {
    calls.push(String(url)); assert.equal(new URL(String(url)).origin, 'https://api-v2.fattureincloud.it');
    assert.equal(init?.method, 'GET'); assert.equal(init?.redirect, 'error'); assert.equal(init?.cache, 'no-store');
    assert.equal(new Headers(init?.headers).get('authorization'), `Bearer ${config.token}`);
    return calls.length === 1 ? aziende() : pagina([{ ...doc(), access_token: 'non-restituire', url: 'https://non-seguire.test', entity: { ...doc().entity, email: 'non-necessaria' } }]);
  });
  const r = await client.cerca({ ...filtro, cerca: '10020604104' });
  assert.equal(r.documenti.length, 1); assert.equal(r.completo, true);
  assert.equal(r.documenti[0].pagamenti[0].stato, 'not_paid');
  assert.doesNotMatch(JSON.stringify(r), /access_token|non-restituire|non-necessaria|non-seguire/);
  const q = new URL(calls[1]).searchParams;
  assert.equal(q.get('q'), "date >= '2026-11-01' and date <= '2026-11-07'");
  assert.equal(q.get('fieldset'), 'detailed');
});

test('cerca targa, codice, cliente e proforma senza trasformarlo in fattura', async () => {
  for (const cerca of ['zz 123 zz', 'AV412C405AA', 'OFFICINA PROVA']) {
    const client = creaClientFic(config, async url => String(url).endsWith('/user/companies') ? aziende() : pagina([{ ...doc(), type: 'proforma', payments_list: null }]));
    const r = await client.cerca({ ...filtro, tipo: 'proforma', cerca });
    assert.equal(r.documenti[0].tipo, 'proforma'); assert.deepEqual(r.documenti[0].pagamenti, []);
  }
});

test('paginazione completa e filtro su tutte le pagine, ignora URL remoti', async () => {
  let count = 0;
  const r = await creaClientFic(config, async url => {
    if (String(url).endsWith('/user/companies')) return aziende();
    count++; const page = Number(new URL(String(url)).searchParams.get('page'));
    return pagina([{ ...doc(page), notes: page === 2 ? 'RICERCATA' : '' }], page, 2, 2);
  }).cerca({ ...filtro, cerca: 'RICERCATA' });
  assert.equal(count, 2); assert.equal(r.esaminati, 2); assert.equal(r.documenti[0].id, 2); assert.equal(r.completo, true);
});

test('risultati parziali espliciti dopo dieci pagine, nessun falso completo', async () => {
  const r = await creaClientFic(config, async url => String(url).endsWith('/user/companies') ? aziende() :
    pagina([doc(Number(new URL(String(url)).searchParams.get('page')))], Number(new URL(String(url)).searchParams.get('page')), 11, 11)).cerca(filtro);
  assert.equal(r.completo, false); assert.equal(r.esaminati, 10); assert.equal(r.totale, 11);
});

test('azienda errata blocca prima della lettura di documenti', async () => {
  let count = 0;
  await assert.rejects(creaClientFic(config, async () => { count++; return Response.json({ data: { companies: [{ id: 29153, vat_number: '99999999999' }] } }); }).cerca(filtro), errore('azienda'));
  assert.equal(count, 1);
});

test('validazione prima di qualsiasi chiamata: date, intervallo, tipi e identificativi', async () => {
  for (const v of [{ tipo: 'credit_note' }, { tipo: '__proto__' }, { dal: '2026-02-30' }, { dal: '2026-09-01' }, { al: '2026-10-30' }, { cerca: ['non valido'] }, { cerca: 'x'.repeat(101) }]) {
    assert.throws(() => validaRicercaFic({ ...filtro, ...v }), errore('parametri'));
  }
  for (const v of [{ token: '' }, { token: 'a\nb' }, { companyId: '../other' }]) assert.throws(() => creaClientFic({ ...config, ...v }), errore('configurazione'));
  let count = 0;
  await assert.rejects(creaClientFic(config, async () => { count++; return aziende(); }).cerca({ ...filtro, tipo: 'other' } as unknown as RicercaFic), errore('parametri'));
  assert.equal(count, 0);
});

test('errori e quote non espongono corpo remoto né segreti; nessun retry su 429', async () => {
  for (const status of [401, 403, 429, 500]) {
    let count = 0;
    await assert.rejects(creaClientFic(config, async () => { count++; return new Response(config.token, { status }); }).cerca(filtro), errore(status === 429 ? 'quota' : status < 500 ? 'autorizzazione' : 'rete'));
    assert.equal(count, 1);
  }
  await assert.rejects(creaClientFic(config, async () => { throw new Error(config.token); }).cerca(filtro), errore('rete'));
});

test('risposte malformate, duplicate o totali variati non diventano risultati vuoti', async () => {
  for (const risposta of [() => pagina([{ ...doc(), type: 'quote' }]), () => pagina([{ ...doc(), date: '2026-10-01' }]), () => pagina([{ ...doc(), items_list: undefined }]),
    () => pagina([doc(), doc()]), () => pagina([doc()], 1, 1, 2), () => new Response('non json'), () => new Response('x'.repeat(4_000_001))]) {
    await assert.rejects(creaClientFic(config, async url => String(url).endsWith('/user/companies') ? aziende() : risposta()).cerca(filtro), errore('risposta'));
  }
  await assert.rejects(creaClientFic(config, async url => {
    if (String(url).endsWith('/user/companies')) return aziende();
    const page = Number(new URL(String(url)).searchParams.get('page'));
    return pagina([doc(page)], page, 2, page === 1 ? 2 : 3);
  }).cerca(filtro), errore('risposta'));
});

test('verifica restituisce solo identità aziendale e lista vuota valida è completa', async () => {
  const c = creaClientFic(config, async url => String(url).endsWith('/user/companies') ? aziende() : pagina([]));
  assert.deepEqual(await c.verifica(), { id: '29153', nome: 'Azienda di prova', partitaIva: '02439670031' });
  const r = await c.cerca(filtro); assert.equal(r.completo, true); assert.equal(r.totale, 0);
});

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {renderApprovedTemplate} from './templates.ts';
test('approved prequote body uses practice and only the current missing fields',()=>{
 assert.equal(renderApprovedTemplate('preventivo',['ABS-999999','targa del veicolo']),
 'Buongiorno, la contattiamo da ItalianaABS per la richiesta di preventivo relativa alla pratica ABS-999999. Per completare la valutazione ci mancano ancora: targa del veicolo. Può inviarci queste informazioni rispondendo qui? Se ha già risolto o non desidera proseguire, ce lo comunichi e chiuderemo la richiesta. Grazie.');
});
test('approved fiscal body preserves literal variable content and collapses whitespace',()=>{
 const text=renderApprovedTemplate('fatturazione',['ABS-999999','CAP\n comune $& $1']);
 assert.ok(text.includes('pratica ABS-999999, relativa al preventivo da lei accettato.'));
 assert.ok(text.includes('mancano ancora: CAP comune $& $1.'));
 assert.ok(!text.includes('{{'));
});

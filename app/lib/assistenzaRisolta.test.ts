import assert from 'node:assert/strict';
import test from 'node:test';
import { filtraOggi, prossimaAzione, type PraticaOggi } from './oggi.ts';

const giorno='2026-11-07';
const risolta: PraticaOggi={id:'test',tipo_flusso:'assistenza',stato_assistenza:'risolta',priorita_assistenza:'urgente'};
test('richiesta chiusa amministrativamente: sparisce da urgenti e da lavorare, resta in concluse',()=>{
  const p={...risolta,assistenze_rientro:[{stato:'chiusa',priorita:'urgente',chiusa_at:'2026-11-07T15:00:00Z'}]};
  assert.equal(prossimaAzione(p,giorno).urgente,false);
  assert.equal(filtraOggi([p],'oggi_urgenti',giorno).length,0);
  assert.equal(filtraOggi([p],'oggi',giorno).length,0);
  assert.equal(filtraOggi([p],'oggi_concluse',giorno).length,1);
});
test('nuovo episodio aperto mantiene l’urgenza anche sulla pratica precedentemente risolta',()=>{
  const p={...risolta,assistenze_rientro:[{stato:'da_prendere_in_carico',priorita:'urgente',chiusa_at:null}]};
  assert.equal(prossimaAzione(p,giorno).urgente,true);
  assert.equal(filtraOggi([p],'oggi_urgenti',giorno).length,1);
});
test('ritiro residuo dopo sostituzione resta visibile senza riaprire artificialmente l’assistenza',()=>{
  const p={...risolta,attivita_operative:[{tipo:'ritiro_altro_reso',stato:'da_gestire',priorita:'normale'}]};
  assert.equal(prossimaAzione(p,giorno).stato,'da_lavorare');
  assert.equal(prossimaAzione(p,giorno).area,'logistica');
  assert.equal(prossimaAzione(p,giorno).urgente,false);
});

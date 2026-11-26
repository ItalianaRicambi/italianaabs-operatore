import assert from 'node:assert/strict';
import test from 'node:test';
import { risolviTracking, selezionaPratica, type OrdineTracking, type PraticaTracking } from './trackingWhatsApp.ts';
const p:PraticaTracking={targa:'ZZ001ZZ',telefono:'+390000000001',ordine_id:'42',numero_ordine:'#42',mbe:[]};
const url='https://www.poste.it/cerca/index.html#/risultati-spedizioni/TEST123';
const ordine:OrdineTracking={id:'gid://shopify/Order/42',name:'#42',test:false,cancelledAt:null,shippingAddress:{phone:p.telefono},fulfillments:[{status:'SUCCESS',trackingInfo:[{number:'TEST123',url}]}]};
test('richiesta del destinatario e verifica dei riferimenti nella sola sessione',()=>{
 assert.equal(risolviTracking(p,ordine,false).stato_tracking,'trovato');
 assert.equal(selezionaPratica([p,p],'',''),null);
 assert.equal(selezionaPratica([p],'','#43'),null);
 assert.equal(selezionaPratica([p],'ZZ001ZZ',''),p);
});
test('nessun link per telefono, ordine, URL o spedizioni incerti',()=>{
 for(const x of [{...ordine,shippingAddress:{phone:'+390000000002'}},{...ordine,test:true},
   {...ordine,cancelledAt:'2026-01-01'},{...ordine,id:'gid://shopify/Order/43'},
   {...ordine,fulfillments:[{status:'SUCCESS',trackingInfo:[{number:'TEST123',url:'https://tracking.example.org'}]}]},
   {...ordine,fulfillments:[...ordine.fulfillments,{status:'SUCCESS',trackingInfo:[{number:'TEST124',url}]}]}]){
   assert.doesNotMatch(risolviTracking(p,x,false).message,/https:/);
 }
});
test('spedizione MBE univoca e deduplicazione del medesimo collo Shopify',()=>{
 const mbe=[{master:'IT0000-0B-0000000001',corriere:'TEST123',corriere_stato:'',colli:[]}];
 assert.match(risolviTracking({...p,ordine_id:null,mbe},null,false).message,/www\.mbe\.it/);
 assert.match(risolviTracking({...p,mbe},ordine,false).message,/www\.poste\.it/);
 assert.doesNotMatch(risolviTracking({...p,mbe:[{...mbe[0],corriere:'ALTRO'}]},ordine,true).message,/https:/);
});

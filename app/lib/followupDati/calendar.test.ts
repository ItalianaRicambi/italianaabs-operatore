import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fourthBusinessDayOpening,isOpen,nextOpening,type Calendar} from './policy.ts';

// Conferma Norberto 11/11/2026. Stesso dataset della migrazione dedicata.
const calendar:Calendar={confirmedThrough:'2026-12-31',closures:[
 {from:'2026-12-07',through:'2026-12-08'},
 {from:'2026-12-24',through:'2026-12-26'},
 {from:'2026-12-31',through:'2026-12-31'},
]};
const instant=(value:string)=>Date.parse(value);
test('ponte Immacolata: da venerdì dopo chiusura a mercoledì 9 alle 09 Roma',()=>{
 assert.equal(nextOpening(instant('2026-12-04T12:30:00Z'),calendar),instant('2026-12-09T08:00:00Z'));
 for(const day of ['05','06','07','08'])assert.equal(isOpen(instant(`2026-12-${day}T10:00:00Z`),calendar),false);
});
test('Natale: 24-26 e domenica 27 esclusi, prima apertura lunedì 28',()=>{
 for(const day of ['24','25','26','27']){
  assert.equal(isOpen(instant(`2026-12-${day}T10:00:00Z`),calendar),false);
  assert.equal(nextOpening(instant(`2026-12-${day}T10:00:00Z`),calendar),instant('2026-12-28T08:00:00Z'));
 }
});
test('31 dicembre escluso; nessun invio 2027 senza nuova copertura confermata',()=>{
 assert.equal(isOpen(instant('2026-12-31T10:00:00Z'),calendar),false);
 assert.equal(nextOpening(instant('2026-12-30T17:30:00Z'),calendar),null);
 assert.equal(isOpen(instant('2027-01-04T10:00:00Z'),calendar),false);
});
test('giorni non dichiarati chiusi restano lavorativi con pausa pranzo e venerdì breve',()=>{
 assert.equal(isOpen(instant('2026-12-23T13:00:00Z'),calendar),true);
 assert.equal(isOpen(instant('2026-12-28T11:30:00Z'),calendar),false);
 assert.equal(isOpen(instant('2026-12-30T17:29:59Z'),calendar),true);
 assert.equal(isOpen(instant('2026-12-11T12:30:00Z'),calendar),false);
});

test('an undated reply resumes on the fourth subsequent working day in Rome',()=>{
 assert.equal(fourthBusinessDayOpening(instant('2026-11-13T10:00:00Z'),calendar),instant('2026-11-19T08:00:00Z'));
 assert.equal(fourthBusinessDayOpening(instant('2026-12-04T10:00:00Z'),calendar),instant('2026-12-14T08:00:00Z'));
 assert.equal(fourthBusinessDayOpening(instant('2026-12-29T10:00:00Z'),calendar),null);
 assert.equal(fourthBusinessDayOpening(instant('2026-07-10T10:00:00Z'),calendar),instant('2026-07-16T07:00:00Z'));
});

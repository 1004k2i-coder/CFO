import test from 'node:test';
import assert from 'node:assert/strict';
import {buildCfoAdvice} from '../public/assets/js/cfo-advice.js';
const today='2026-11-13';
const base={accounts:[{company_id:'c',current_balance:1000,required_reserve:200,balance_as_of:today}],products:[],schedules:[]};
test('예정자료가 없으면 투자 판단을 보류한다',()=>{const r=buildCfoAdvice(base,'c',today);assert.ok(r.issues.length);assert.match(r.recommendation,/보류/);});
test('미래 확정 일정만 사용하고 입금확률 0을 그대로 적용한다',()=>{const schedules=[{company_id:'c',direction:'receipt',amount:1000,probability:0,due_date:'2026-11-14',status:'planned'},{company_id:'c',direction:'payment',amount:1200,due_date:'2026-11-15',status:'planned'},{company_id:'c',direction:'payment',amount:9000,due_date:'2026-11-14',status:'matched'}];const r=buildCfoAdvice({...base,schedules},'c',today);assert.equal(r.receipts,0);assert.equal(r.payments,1200);assert.equal(r.min,-200);assert.equal(r.shortage,400);assert.equal(r.firstShortage,'2026-11-15');assert.match(r.recommendation,/투자 집행을 보류/);assert.equal(r.weeks.length,13);});
test('법인별 판단에서 다른 법인 거래를 제외한다',()=>{const r=buildCfoAdvice({...base,accounts:[...base.accounts,{company_id:'other',current_balance:100000}]},'c',today);assert.equal(r.cash,1000);});

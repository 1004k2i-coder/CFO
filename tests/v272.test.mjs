import test from 'node:test';
import assert from 'node:assert/strict';
import {calculateDashboard,buildReportSnapshot} from '../public/assets/js/finance.js';
test('총 보유자금은 선택 법인 통장과 활성 비대출 상품의 현재 잔액을 합산',()=>{
 const data={companies:[{id:'a'},{id:'b'}],accounts:[{company_id:'a',current_balance:1000},{company_id:'b',current_balance:200},{company_id:'a',current_balance:999,active:false}],products:[{company_id:'a',product_type:'deposit',current_value:500,principal:900,manual_balance:true},{company_id:'a',product_type:'mmf',current_value:300,pledged:true},{company_id:'a',product_type:'deposit',current_value:0,principal:100},{company_id:'a',product_type:'fx',current_value:2,currency:'USD',exchange_rate:1300},{company_id:'a',product_type:'loan',current_value:99999},{company_id:'a',product_type:'deposit',current_value:999,active:false},{company_id:'b',product_type:'deposit',current_value:50}]};
 const d=calculateDashboard(data,'a');
 assert.equal(d.currentCash,1000);assert.equal(d.depositBalance,3400);assert.equal(d.cashIncludingDeposits,4400);assert.equal(d.projected,1000);
 assert.equal(calculateDashboard(data).cashIncludingDeposits,4650);
 assert.equal(buildReportSnapshot(data,'a').kpis.cash_including_deposits,4400);
 assert.equal(calculateDashboard({}).cashIncludingDeposits,0);
});

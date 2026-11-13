import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFinanceFile } from '../public/assets/js/excel.js';

test('기존 HTML JSON 백업을 신규 이관 구조로 변환한다',async()=>{
  const legacy={
    corpNames:['창진에스씨'],
    corps:[{cash:{bankBalance:1000,requiredReserve:200},monthly:[{income:500,expenses:{salary:100,creditPayment:50,interest:10,otherExpense:5}}],assets:{cashAsset:{amount:1000,target:50}}}],
    schedules:[{corpIndex:0,type:'receipt',date:'2026-10-20',counterparty:'가온전자',amount:300,probability:90,priority:'높음',memo:'테스트'}],
    shortInvestments:[{corpIndex:0,bank:'A은행',productName:'정기예금',principal:1000,currentValue:1010,rate:3.2,redeemable:'가능',pledged:'없음'}],
    fxDeposits:[{corpIndex:0,bank:'B은행',currency:'USD',foreignAmount:100,manualRate:1380,depositType:'외화보통예금'}],
  };
  const file=new File([JSON.stringify(legacy)],'legacy.json',{type:'application/json'});
  const parsed=await parseFinanceFile(file);
  assert.equal(parsed.kind,'legacy');
  assert.equal(parsed.rows.cash[0].current_balance,1000);
  assert.equal(parsed.rows.monthly[0].trade_payables,50);
  assert.equal(parsed.rows.schedules[0].direction,'receipt');
  assert.equal(parsed.rows.products.length,2);
  assert.equal(parsed.rows.products[1].exchange_rate,1380);
});

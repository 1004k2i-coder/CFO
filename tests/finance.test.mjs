import test from 'node:test';
import assert from 'node:assert/strict';
import { calculateDashboard, buildReportSnapshot, productKrwValue } from '../public/assets/js/finance.js';

const companies=[{id:'c1',name:'창진에스씨'},{id:'c2',name:'삼코'}];
const accounts=[
  {company_id:'c1',current_balance:100_000_000,required_reserve:30_000_000,active:true},
  {company_id:'c2',current_balance:50_000_000,required_reserve:10_000_000,active:true},
];
const today=new Date();
const date=n=>{const d=new Date(today);d.setDate(d.getDate()+n);return d.toISOString().slice(0,10)};
const schedules=[
  {company_id:'c1',direction:'receipt',due_date:date(2),amount:20_000_000,probability:50,status:'planned'},
  {company_id:'c1',direction:'payment',due_date:date(3),amount:90_000_000,probability:100,status:'planned'},
  {company_id:'c1',direction:'transfer',due_date:date(4),amount:5_000_000,probability:100,status:'planned'},
  {company_id:'c2',direction:'receipt',due_date:date(5),amount:10_000_000,probability:100,status:'planned'},
];
const products=[{company_id:'c1',product_type:'deposit',current_value:40_000_000,principal:40_000_000,redeemable:true,active:true}];
const monthlyPlans=[{company_id:'c1',plan_year:today.getFullYear(),plan_month:1,income:10_000_000,salary:3_000_000,trade_payables:2_000_000,interest_expense:1_000_000,other_expense:500_000}];
const reports=[{company_id:'c1',status:'submitted'}];

test('30일 입금은 확률을 반영하고 계좌이체는 비용에서 제외한다',()=>{
  const d=calculateDashboard({companies,accounts,schedules,products,monthlyPlans,reports},'c1');
  assert.equal(d.receipts,10_000_000);
  assert.equal(d.payments,90_000_000);
  assert.equal(d.transfers,5_000_000);
  assert.equal(d.projected,20_000_000);
  assert.equal(d.requiredCash,10_000_000);
  assert.equal(d.pendingApprovals,1);
});

test('전체 법인 합산과 법인별 부족액을 계산한다',()=>{
  const d=calculateDashboard({companies,accounts,schedules,products,monthlyPlans,reports},'all');
  assert.equal(d.currentCash,150_000_000);
  assert.equal(d.entityRows.length,2);
  const c1=d.entityRows.find(x=>x.company_id==='c1');
  assert.equal(c1.shortage,10_000_000);
  const c2=d.entityRows.find(x=>x.company_id==='c2');
  assert.equal(c2.shortage,0);
});

test('보고서 스냅샷은 결재 시점 KPI와 일정을 고정한다',()=>{
  const snap=buildReportSnapshot({companies,accounts,schedules,products,monthlyPlans,reports},'c1');
  assert.equal(snap.company_id,'c1');
  assert.equal(snap.kpis.current_cash,100_000_000);
  assert.ok(Array.isArray(snap.timeline));
  assert.ok(snap.generated_at);
});


test('외화 금융상품은 환율로 원화환산한다',()=>{
  assert.equal(productKrwValue({currency:'USD',current_value:1000,exchange_rate:1380}),1_380_000);
  assert.equal(productKrwValue({currency:'KRW',current_value:1_000_000,exchange_rate:0}),1_000_000);
});

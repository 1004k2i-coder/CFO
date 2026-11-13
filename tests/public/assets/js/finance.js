import {buildCfoAdvice} from './cfo-advice.js';
import { addDays, isoDate, toNumber } from './utils.js';

export function productKrwValue(product={}) {
  const amount=product.current_value==null?toNumber(product.principal):toNumber(product.current_value);
  const currency=String(product.currency||'KRW').toUpperCase();
  return currency==='KRW' ? amount : amount*toNumber(product.exchange_rate);
}

export function calculateDashboard({companies=[],accounts=[],schedules=[],products=[],monthlyPlans=[],reports=[]}, companyId='all') {
  const companyIds = companyId==='all' ? companies.map(c=>c.id) : [companyId];
  const companyMap=new Map(companies.map(c=>[c.id,c]));
  const selectedAccounts=accounts.filter(a=>companyIds.includes(a.company_id)&&a.active!==false);
  const selectedSchedules=schedules.filter(s=>companyIds.includes(s.company_id)&&!['cancelled','completed','matched'].includes(s.status));
  const selectedProducts=products.filter(p=>companyIds.includes(p.company_id)&&p.active!==false);
  const selectedPlans=monthlyPlans.filter(p=>companyIds.includes(p.company_id));
  const today=isoDate(); const in30=addDays(today,30);
  const upcoming=selectedSchedules.filter(s=>s.due_date>=today&&s.due_date<=in30);
  const overdue=selectedSchedules.filter(s=>s.due_date<today&&!['matched','completed','cancelled'].includes(s.status));
  const currentCash=selectedAccounts.reduce((sum,a)=>sum+toNumber(a.current_balance),0);
  const requiredReserve=selectedAccounts.reduce((sum,a)=>sum+toNumber(a.required_reserve),0);
  const receipts=upcoming.filter(s=>s.direction==='receipt').reduce((sum,s)=>sum+toNumber(s.amount)*toNumber(s.probability??100)/100,0);
  const payments=upcoming.filter(s=>s.direction==='payment').reduce((sum,s)=>sum+toNumber(s.amount),0);
  const transfers=upcoming.filter(s=>s.direction==='transfer').reduce((sum,s)=>sum+toNumber(s.amount),0);
  const liquidProducts=selectedProducts.filter(p=>p.product_type!=='loan'&&!p.pledged&&(p.redeemable||(p.maturity_date&&p.maturity_date<=in30)));
  const immediateLiquidity=liquidProducts.reduce((sum,p)=>sum+productKrwValue(p),0);
  const loans=selectedProducts.filter(p=>p.product_type==='loan').reduce((sum,p)=>sum+productKrwValue(p),0);
  const projected=currentCash+receipts-payments;
  const shortage=Math.max(requiredReserve-projected,0);
  const investable=Math.max(projected+immediateLiquidity-requiredReserve,0);
  const pendingApprovals=reports.filter(r=>['submitted','in_review'].includes(r.status)).length;

  const timeline=upcoming.slice().sort((a,b)=>a.due_date.localeCompare(b.due_date)).map(s=>({
    ...s, company_name:companyMap.get(s.company_id)?.name||'', weighted_amount:s.direction==='receipt'?toNumber(s.amount)*toNumber(s.probability??100)/100:toNumber(s.amount)
  }));
  let running=currentCash,minBalance=currentCash,minDate='';
  for(const item of timeline){
    if(item.direction==='receipt')running+=item.weighted_amount;
    else if(item.direction==='payment')running-=item.weighted_amount;
    if(running<minBalance){minBalance=running;minDate=item.due_date}
  }
  const requiredCash=Math.max(-minBalance,requiredReserve-minBalance,0);

  const entityRows=companyIds.map(id=>{
    const c=companyMap.get(id);
    const acc=accounts.filter(a=>a.company_id===id&&a.active!==false);
    const sch=upcoming.filter(s=>s.company_id===id);
    const cash=acc.reduce((s,a)=>s+toNumber(a.current_balance),0);
    const reserve=acc.reduce((s,a)=>s+toNumber(a.required_reserve),0);
    const inc=sch.filter(s=>s.direction==='receipt').reduce((s,x)=>s+toNumber(x.amount)*toNumber(x.probability??100)/100,0);
    const out=sch.filter(s=>s.direction==='payment').reduce((s,x)=>s+toNumber(x.amount),0);
    const end=cash+inc-out;
    return {company_id:id,company_name:c?.name||'',cash,reserve,receipt:inc,payment:out,ending:end,shortage:Math.max(reserve-end,0),surplus:Math.max(end-reserve,0)};
  });

  const year=new Date().getFullYear();
  const monthly=Array.from({length:12},(_,i)=>{
    const rows=selectedPlans.filter(p=>p.plan_year===year&&p.plan_month===i+1);
    const income=rows.reduce((s,r)=>s+toNumber(r.income),0);
    const expense=rows.reduce((s,r)=>s+toNumber(r.salary)+toNumber(r.trade_payables)+toNumber(r.interest_expense)+toNumber(r.other_expense),0);
    return {month:`${i+1}월`,income,expense,net:income-expense};
  });
  return {currentCash,requiredReserve,receipts,payments,transfers,immediateLiquidity,loans,projected,shortage,investable,pendingApprovals,overdueCount:overdue.length,minBalance,minDate,requiredCash,timeline,entityRows,monthly};
}

export function buildReportSnapshot(data, companyId='all') {
  const d=calculateDashboard(data,companyId);
  return {
    generated_at:new Date().toISOString(),
    cfo_advice:buildCfoAdvice(data,companyId),
    company_id:companyId,
    kpis:{
      current_cash:d.currentCash,required_reserve:d.requiredReserve,receipts_30d:d.receipts,payments_30d:d.payments,
      projected_balance:d.projected,min_balance:d.minBalance,required_cash:d.requiredCash,immediate_liquidity:d.immediateLiquidity,
      investable:d.investable,loan_balance:d.loans,overdue_count:d.overdueCount
    },
    entity_rows:d.entityRows,
    timeline:d.timeline,
    monthly:d.monthly,
  };
}

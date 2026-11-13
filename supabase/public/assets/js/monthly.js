import {toNumber} from './utils.js';
export const MONTHLY_FIELDS=['income','salary','trade_payables','interest_expense','other_expense'];
export const MONTHLY_LABELS={salary:'급여',trade_payables:'외상대금',interest_expense:'이자비용',other_expense:'기타비용'};
export function scheduleExpenseField(row){
  const override=row.recurring_rule?.monthly_category;
  if(Object.hasOwn(MONTHLY_LABELS,override))return override;
  const text=String(row.description||row.counterparty||'').normalize('NFKC').replace(/\s/g,'');
  if(/이자/.test(text))return 'interest_expense';
  if(/급여|인건비|용역대금|외주급여|퇴직금|외부인력/.test(text))return 'salary';
  if(/외상대|매입대금|업체대금|협력회사/.test(text))return 'trade_payables';
  return 'other_expense';
}
export function effectiveMonthlyPlans(manual=[],schedules=[],year=new Date().getFullYear()){
  const groups=new Map();
  for(const row of schedules){
    if(!row.company_id||!String(row.due_date).startsWith(year+'-'))continue;
    const month=Number(row.due_date.slice(5,7));if(month<1||month>12)continue;
    const key=row.company_id+':'+month;
    if(!groups.has(key))groups.set(key,{company_id:row.company_id,plan_year:Number(year),plan_month:month,...Object.fromEntries(MONTHLY_FIELDS.map(k=>[k,0])),aggregation_source:'schedules',schedule_count:0});
    const group=groups.get(key);
    if(row.status==='cancelled'||row.direction==='transfer')continue;
    const field=row.direction==='receipt'?'income':row.direction==='payment'?scheduleExpenseField(row):null;
    if(field){group[field]+=toNumber(row.amount);group.schedule_count++;}
  }
  // 법인·월별로 일정 집계가 있으면 수동 계획과 더하지 않고 집계만 사용합니다.
  for(const row of manual){const key=row.company_id+':'+row.plan_month;if(Number(row.plan_year)===Number(year)&&!groups.has(key))groups.set(key,{...row,aggregation_source:'manual'});}
  return [...groups.values()];
}
export function sumMonthlyPlans(plans,month){
  const rows=plans.filter(p=>Number(p.plan_month)===month);
  return {...Object.fromEntries(MONTHLY_FIELDS.map(k=>[k,rows.reduce((sum,r)=>sum+toNumber(r[k]),0)])),aggregation_source:rows.some(r=>r.aggregation_source==='schedules')?(rows.some(r=>r.aggregation_source==='manual')?'mixed':'schedules'):'manual'};
}

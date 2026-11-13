import {toNumber} from './utils.js';
export function expenseAnalysis(transactions,categories,plans=[]){
 const cats=new Map(categories.map(c=>[c.id,c])),groups=new Map(),monthly=new Map();let reviewed=0,unreviewed=0,income=0,expense=0,internal=0,unclassified=0;
 for(const t of transactions){
  if(t.classification_status!=='reviewed'){unreviewed++;continue;}reviewed++;
  const c=cats.get(t.category_id);if(!c){unclassified++;continue;}
  if(c.direction==='transfer'){internal++;continue;}
  income+=toNumber(t.inflow);expense+=toNumber(t.outflow);
  const name=c.name||'분류 없음';groups.set(name,(groups.get(name)||0)+toNumber(t.outflow));
  const month=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit'}).format(new Date(t.transaction_at));
  const row=monthly.get(month)||{month,income:0,expense:0};row.income+=toNumber(t.inflow);row.expense+=toNumber(t.outflow);monthly.set(month,row);
 }
 const planExpense=plans.reduce((s,p)=>s+toNumber(p.salary)+toNumber(p.trade_payables)+toNumber(p.interest_expense)+toNumber(p.other_expense),0);
 return {reviewed,unreviewed,unclassified,income,expense,internal,planExpense,variance:expense-planExpense,groups:[...groups].filter(([,v])=>v!==0).sort((a,b)=>b[1]-a[1]),monthly:[...monthly.values()].sort((a,b)=>a.month.localeCompare(b.month))};
}
export function productValue(product,adjustment=0){return toNumber(product.current_value)+toNumber(adjustment);}

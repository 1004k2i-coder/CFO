import {isoDate,addDays,toNumber,esc,money} from './utils.js';
import {productKrwValue} from './finance.js';

export function buildCfoAdvice(data,companyId='all',today=isoDate()){
  const selected=row=>companyId==='all'||row.company_id===companyId;
  const accounts=(data.accounts||[]).filter(a=>selected(a)&&a.active!==false);
  const products=(data.products||[]).filter(p=>selected(p)&&p.active!==false);
  const end=addDays(today,90);
  const schedules=(data.schedules||[]).filter(s=>selected(s)&&!['cancelled','completed','matched'].includes(s.status));
  const upcoming=schedules.filter(s=>s.due_date>=today&&s.due_date<=end);
  const cash=accounts.reduce((n,a)=>n+toNumber(a.current_balance),0);
  const reserve=accounts.reduce((n,a)=>n+toNumber(a.required_reserve),0);
  const receipts=upcoming.filter(s=>s.direction==='receipt').reduce((n,s)=>n+toNumber(s.amount)*toNumber(s.probability??100)/100,0);
  const payments=upcoming.filter(s=>s.direction==='payment').reduce((n,s)=>n+toNumber(s.amount),0);
  const loans=products.filter(p=>p.product_type==='loan');
  const dueLoans=loans.filter(p=>p.maturity_date&&p.maturity_date>=today&&p.maturity_date<=end);
  const loanMaturity=dueLoans.reduce((n,p)=>n+productKrwValue(p),0);
  const stale=accounts.filter(a=>!a.balance_as_of||a.balance_as_of.slice(0,10)<addDays(today,-7)).length;
  let running=cash,min=cash,firstShortage=cash<reserve?today:null;
  const weeks=[];
  for(let offset=0;offset<=90;offset++){
    const day=addDays(today,offset);
    for(const s of upcoming.filter(s=>s.due_date===day)){
      if(s.direction==='receipt')running+=toNumber(s.amount)*toNumber(s.probability??100)/100;
      if(s.direction==='payment')running-=toNumber(s.amount);
    }
    min=Math.min(min,running);
    if(!firstShortage&&running<reserve)firstShortage=day;
    if(offset%7===6||offset===90)weeks.push({date:day,balance:running});
  }
  const issues=[];
  if(!upcoming.some(s=>s.direction==='payment'))issues.push('향후 13주 지급계획이 없습니다. 급여·매입대금·세금·대출 상환일정을 입력하세요.');
  if(!upcoming.some(s=>s.direction==='receipt'))issues.push('향후 13주 입금계획이 없습니다. 회수 예정일과 입금확률을 확인하세요.');
  if(stale)issues.push('잔액 기준일이 7일 초과 또는 미등록인 계좌 '+stale+'개를 대조하세요.');
  if(reserve<=0)issues.push('필수보유현금 기준이 0원입니다. 운영자금 기준을 설정하세요.');
  if(loans.some(p=>!p.maturity_date))issues.push('만기일이 없는 대출이 있습니다. 상환·차환 일정을 확인하세요.');
  const shortage=Math.max(0,reserve-min);
  let recommendation='입금 지연 상황을 점검한 뒤 단기 운용 가능액을 검토하세요. 아래 금액은 입력된 계획 범위의 계산값입니다.';
  if(issues.length)recommendation='자료 보완 전 신규 장기투자 판단을 보류하고 계좌잔액·향후 입출금·필수보유현금을 먼저 확정하세요.';
  else if(shortage>0)recommendation='신규 투자 집행을 보류하고 부족일 이전 매출채권 회수, 비필수 지출 조정, 확정된 금융한도 활용을 검토하세요.';
  const stressEnding=cash+receipts*0.8-payments;
  if(!issues.length&&shortage===0&&stressEnding<reserve)recommendation='입금액이 예상보다 20% 줄면 보유현금 기준을 하회합니다. 신규투자를 줄이고 유동성 여유를 확보하세요.';
  return {cash,reserve,receipts,payments,min,firstShortage,shortage,stressEnding,loanMaturity,issues,recommendation,weeks,loans:loans.reduce((n,p)=>n+productKrwValue(p),0),overdue:schedules.filter(s=>s.due_date<today).length};
}
export function cfoAdviceHtml(advice){
  return `<section class="panel"><h2>CFO 자금 점검·의사결정 참고</h2><p>${esc(advice.recommendation)}</p><ul>${advice.issues.map(x=>`<li>${esc(x)}</li>`).join('')}</ul><table><tbody><tr><th>13주 최저 은행잔액</th><td>${money(advice.min)}</td><th>필수현금 미달 최초일</th><td>${advice.firstShortage||'입력된 일정에서 없음'}</td></tr><tr><th>기준 대비 최대 부족액</th><td>${money(advice.shortage)}</td><th>입금액 20% 감소 시 기말잔액</th><td>${money(advice.stressEnding)}</td></tr><tr><th>등록 대출잔액</th><td>${money(advice.loans)}</td><th>13주 내 만기 대출잔액</th><td>${money(advice.loanMaturity)}</td></tr><tr><th>기한 경과 미완료 일정</th><td>${advice.overdue}건</td><th>판단 자료</th><td>${advice.issues.length?'보완 필요':'입력 계획 기준'}</td></tr></tbody></table><p>예금·투자상품의 환매대금은 입금 예정으로 등록한 경우에 반영합니다. 만기 대출잔액은 별도 점검값이며, 지급 예정과의 중복을 피하기 위해 전망에서 자동 차감하지 않습니다. 대출 상환은 지급 예정에 등록하세요. 입금 20% 감소는 비교용 가정입니다.</p><table><thead><tr><th>주간 기준일</th><th>예상 은행잔액</th></tr></thead><tbody>${advice.weeks.map(w=>`<tr><td>${w.date}</td><td>${money(w.balance)}</td></tr>`).join('')}</tbody></table><p class="small muted">현금흐름 예측 참고 · <a href="https://www.bdc.ca/en/articles-tools/money-finance/manage-finances/making-projection-coming-year" target="_blank" rel="noopener">BDC 자금계획 안내</a></p></section>`;
}

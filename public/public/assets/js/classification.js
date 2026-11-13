const norm=value=>String(value??'').normalize('NFKC').replace(/\s+/g,'').toLowerCase();
const extraKeywords={
  '이자수익':['결산이자','예금이자','이자입금','결산'],
  '차입금 수령':['대출','차입','융자'],
  '대출이자':['대출금이자','대출이자','이자비용'],
  '통신·공공요금':['한국전력','전기요금','통신요금','수도요금'],
  '4대보험':['4대보험','국민연금','건강보험','고용보험','산재보험'],
};

export function suggestCategory(transaction,categories=[],history=[]){
  const direction=Number(transaction.inflow)>0?'receipt':'payment';
  const available=categories.filter(c=>c.active!==false&&(!c.company_id||c.company_id===transaction.company_id));
  const eligible=available.filter(c=>['mixed','transfer',direction].includes(c.direction));
  const counterparty=norm(transaction.counterparty);
  const previous=history.filter(t=>t.id!==transaction.id&&t.classification_status==='reviewed'&&t.company_id===transaction.company_id&&counterparty&&norm(t.counterparty)===counterparty&&(Number(t.inflow)>0?'receipt':'payment')===direction&&eligible.some(c=>c.id===t.category_id));
  const choices=[...new Set(previous.map(t=>t.category_id))];
  if(choices.length===1)return {id:choices[0],reason:'같은 법인·거래처·입출금 방향의 확인완료 분류',confidence:'history'};
  const text=norm([transaction.bank_summary,transaction.counterparty,transaction.memo].join(' '));
  const scores=eligible.map(c=>{
    const keys=[...new Set([...(c.keywords||[]),...(extraKeywords[c.name]||[])].map(norm).filter(Boolean))];
    const matches=keys.filter(k=>text.includes(k));
    return {id:c.id,score:matches.reduce((s,k)=>s+k.length,0),matches};
  }).filter(c=>c.score>0).sort((a,b)=>b.score-a.score);
  if(scores.length&&(!scores[1]||scores[0].score>scores[1].score))return {id:scores[0].id,reason:`적요·거래처·메모 키워드: ${scores[0].matches.join(', ')}`,confidence:'keyword'};
  const fallback=eligible.find(c=>c.name==='기타'&&c.direction==='mixed');
  return {id:fallback?.id||null,reason:choices.length>1?'이전 분류가 서로 달라 담당자 확인 필요':scores.length?'분류 후보가 겹쳐 담당자 확인 필요':'분류 근거가 부족하여 담당자 확인 필요',confidence:'review'};
}

export function selectedCategory(transaction,categories,history=[]){
  // 사용자가 저장한 확정 분류는 자동 분석으로 덮어쓰지 않습니다.
  if(transaction.category_id)return {id:transaction.category_id,reason:'기존에 저장한 확정 분류',confidence:'saved'};
  return suggestCategory(transaction,categories,history);
}

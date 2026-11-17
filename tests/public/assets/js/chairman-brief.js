import {esc,money} from './utils.js';
export function chairmanBrief(advice){
 const status=advice.issues.length?'자료 확인 필요':advice.shortage>0?'자금 확보 필요':'입력된 계획상 지급 가능';
 return `<section class="panel"><h2>회장님 보고 요약</h2><p><strong>${status}</strong></p><table><tbody><tr><th>현재 통장에 있는 돈</th><td>${money(advice.cash)}</td></tr><tr><th>앞으로 13주에 들어올 돈</th><td>${money(advice.receipts)}</td></tr><tr><th>앞으로 13주에 지급할 돈</th><td>${money(advice.payments)}</td></tr><tr><th>가장 부족할 때 추가로 필요한 돈</th><td>${advice.issues.length?'예정자료 보완 후 확정':money(advice.shortage)}</td></tr></tbody></table><h3>이번에 결정할 사항</h3><p>${esc(advice.recommendation)}</p><p>예금·MMT 환매액은 실제 입금 예정으로 등록해야 전망에 포함됩니다. 통장 잔액과 상품 잔액의 기준일을 확인한 뒤 보고하세요.</p></section>`;
}

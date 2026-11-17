import {openModal,toast,esc} from './utils.js';
export function bindManualBalances(api,products,reload){
 document.querySelectorAll('[data-balance-product]').forEach(button=>button.onclick=()=>{
  const product=products.find(p=>p.id===button.dataset.balanceProduct);
  const now=new Date();now.setMinutes(now.getMinutes()-now.getTimezoneOffset());
  openModal({title:'현재 잔액 입력 · '+product.product_name,body:`<form id="manualBalanceForm"><div class="field"><label>실제 현재 잔액 (${esc(product.currency)})</label><input name="amount" type="number" min="0" step="any" required value="${product.current_value}"></div><div class="field"><label>잔액 확인일시</label><input name="at" type="datetime-local" required value="${now.toISOString().slice(0,16)}"></div><p>은행·증권사에서 조회한 잔액을 입력하세요. 저장한 금액으로 직접 관리합니다.</p></form>`,footer:'<button class="btn btn-secondary" data-modal-close>취소</button><button class="btn btn-primary" id="saveManualBalance">잔액 저장</button>',onOpen:(root,close)=>{
   root.querySelector('#saveManualBalance').onclick=async()=>{
    const form=root.querySelector('form');if(!form.reportValidity())return;
    const amount=Number(form.elements.amount.value),at=new Date(form.elements.at.value);
    if(!Number.isFinite(amount)||amount<0||!Number.isFinite(at.getTime()))return toast('금액과 확인일시를 확인하세요.','warn');
    const save=root.querySelector('#saveManualBalance');save.disabled=true;
    try{
     const {data:{user}}=await api.client.auth.getUser();
     const {error}=await api.client.from('financial_products').update({current_value:amount,balance_as_of:at.toISOString(),manual_balance:true,updated_by:user.id}).eq('id',product.id).select('id').single();
     if(error)throw error;close();await reload();toast('현재 잔액을 저장했습니다.');
    }catch(error){toast(error.message,'error');save.disabled=false;}
   };
  }});
 });
}

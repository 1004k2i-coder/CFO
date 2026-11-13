import {confirmDialog,toast,money,fmtDateTime} from './utils.js';

export async function applyBankBalance(api,accountId,{allowPrompt=true}={}) {
  let result=await api.rpc('reconcile_account',{p_id:accountId,p_force:false});
  if(result.status==='older'&&allowPrompt){
    const confirmed=await confirmDialog({title:'은행자료 잔액 반영',message:`이 계좌에 저장된 최신 은행 거래는 ${fmtDateTime(result.at)}이며 잔액은 ${money(result.balance)}입니다. 계좌 잔액과 기준일을 이 거래에 맞추시겠습니까?`,confirmText:'은행자료 잔액 적용'});
    if(confirmed)result=await api.rpc('reconcile_account',{p_id:accountId,p_force:true});
  }
  const messages={updated:'은행자료의 최신 잔액을 반영했습니다.',older:'거래는 저장되었습니다. 계좌 잔액은 잔액 반영 버튼에서 확인하세요.',no_data:'이 계좌에 잔액이 포함된 은행 거래가 없습니다.',ambiguous:'같은 최신 시각에 다른 잔액이 있습니다. 은행 원본을 확인하세요.'};
  toast(messages[result.status]||'잔액 반영 결과를 확인하세요.',result.status==='ambiguous'?'warn':'info');
  return result;
}

export function bindAccountActions(api,profile,reload){
  document.querySelectorAll('[data-account-balance]').forEach(button=>{
    button.onclick=async()=>{
      button.disabled=true;
      try{
        if(profile.role==='admin')await api.rpc('create_checkpoint',{p_label:'계좌잔액 반영 전'});
        await applyBankBalance(api,button.dataset.accountBalance);
        await reload();
      }catch(error){toast(error.message,'error');}finally{button.disabled=false;}
    };
  });
  document.querySelectorAll('[data-account-delete]').forEach(button=>{
    button.onclick=async()=>{
      if(!await confirmDialog({title:'계좌 삭제',message:'이 계좌를 계좌 현황과 자금 합계에서 제외합니다. 거래 이력은 보존합니다. 삭제하시겠습니까?',confirmText:'계좌 삭제',danger:true}))return;
      button.disabled=true;
      try{
        if(profile.role==='admin')await api.rpc('create_checkpoint',{p_label:'계좌 삭제 전'});
        const {error}=await api.client.from('cash_accounts').update({active:false}).eq('id',button.dataset.accountDelete).select('id').single();
        if(error)throw error;
        toast('계좌를 삭제 처리했습니다.');await reload();
      }catch(error){toast(error.message,'error');}finally{button.disabled=false;}
    };
  });
}

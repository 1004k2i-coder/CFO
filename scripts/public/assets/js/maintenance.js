import {openModal,confirmDialog,toast,money,fmtDateTime} from './utils.js';

export function installMaintenance(api, accounts, reload, isAdmin) {
  const heading=document.querySelector('#content .page-heading');
  if(!heading)return;
  const button=document.createElement('button');
  button.className='btn btn-secondary';
  button.id='maintenanceOpen';
  button.textContent='잔액 대조·계좌 삭제·작업 백업';
  heading.append(button);
  button.onclick=()=>openModal({title:'계좌 대조 및 작업 백업',width:'1000px',body:`<p>‘거래 잔액 반영’은 저장된 최신 은행 거래후 잔액으로 계좌 잔액과 기준일을 맞춥니다. 오래된 거래만 있는 계좌는 거래일을 확인하세요.</p><table><thead><tr><th>계좌</th><th>현재잔액</th><th>작업</th></tr></thead><tbody>${accounts.map(a=>`<tr><td>${escape(a.account_name)}</td><td>${money(a.current_balance)}</td><td><button data-reconcile="${a.id}" class="btn btn-secondary">거래 잔액 반영</button> <button data-archive="${a.id}" class="btn btn-danger">계좌 삭제</button></td></tr>`).join('')}</tbody></table>${isAdmin?'<hr><button id="checkpointCreate" class="btn btn-primary">현재 작업상태 백업</button> <button id="checkpointList" class="btn btn-secondary">이전 작업상태 목록</button> <button id="duplicateClean" class="btn btn-secondary">기존 중복 거래 정리</button><div id="checkpointRows"></div>':''}`,onOpen:(root,close)=>{
    root.querySelectorAll('[data-reconcile]').forEach(b=>b.onclick=async()=>{
      try{
        if(isAdmin)await api.rpc('create_checkpoint',{p_label:'계좌잔액 대조 전'});
        const result=await api.rpc('reconcile_account',{p_id:b.dataset.reconcile,p_force:false});
        if(result.status==='older'){
          if(!await confirmDialog({title:'과거 거래잔액 적용',message:`저장된 최신 거래는 ${fmtDateTime(result.at)}, 잔액은 ${money(result.balance)}입니다. 이 시점으로 계좌 잔액을 맞추시겠습니까?`,confirmText:'거래잔액 적용'}))return;
          if(isAdmin)await api.rpc('create_checkpoint',{p_label:'잔액 재반영 전'});
          const changed=await api.rpc('reconcile_account',{p_id:b.dataset.reconcile,p_force:true});
          toast(changed.status==='updated'?'거래잔액을 반영했습니다.':changed.message||'반영할 자료가 없습니다.');
        }else toast(result.status==='updated'?'거래잔액을 반영했습니다.':result.message||'은행 거래자료가 없습니다.');
        close();await reload();
      }catch(e){toast(e.message,'error');}
    });
    root.querySelectorAll('[data-archive]').forEach(b=>b.onclick=async()=>{
      if(!await confirmDialog({title:'계좌 삭제',message:'계좌를 목록과 자금 합계에서 제외하고 거래 이력은 보관합니다. 진행하시겠습니까?',confirmText:'삭제',danger:true}))return;
      try{
        if(isAdmin)await api.rpc('create_checkpoint',{p_label:'계좌 삭제 전'});
        const {error}=await api.client.from('cash_accounts').update({active:false}).eq('id',b.dataset.archive).select('id').single();
        if(error)throw error;
        close();await reload();toast('계좌를 삭제 처리했습니다.');
      }catch(e){toast(e.message,'error');}
    });
    if(!isAdmin)return;
    root.querySelector('#checkpointCreate').onclick=async()=>{try{await api.rpc('create_checkpoint',{p_label:'수동 작업 백업'});toast('현재 작업상태를 저장했습니다.');}catch(e){toast(e.message,'error');}};
    root.querySelector('#checkpointList').onclick=async()=>{
      try{
        const rows=await api.rpc('list_checkpoints');
        root.querySelector('#checkpointRows').innerHTML=rows.map(c=>`<p>${fmtDateTime(c.created_at)} ${escape(c.label)} <button class="btn btn-secondary" data-restore="${c.id}">이 상태로 복원</button></p>`).join('')||'<p>저장한 작업 백업이 없습니다.</p>';
        root.querySelectorAll('[data-restore]').forEach(b=>b.onclick=async()=>{
          if(!await confirmDialog({title:'업무자료 시점 복원',message:'선택한 백업 이후 추가·수정한 업무자료를 되돌립니다. 복원 직전 상태도 자동 보관합니다. 사용자 권한·기기 승인·원본 파일은 복원 범위에서 제외됩니다.',confirmText:'복원',danger:true}))return;
          try{await api.rpc('restore_checkpoint',{p_id:b.dataset.restore});location.reload();}catch(e){toast(e.message,'error');}
        });
      }catch(e){toast(e.message,'error');}
    };
    root.querySelector('#duplicateClean').onclick=async()=>{
      if(!await confirmDialog({title:'기존 중복 정리',message:'다른 업로드에서 같은 계좌·시각·금액·잔액·거래처·적요로 저장된 미확인 거래 중 연결이 없는 중복만 정리합니다. 정리 직전 백업을 저장합니다.',confirmText:'중복 정리'}))return;
      try{const count=await api.rpc('clean_duplicate_transactions');toast(count+'건의 중복 거래를 정리했습니다.');close();await reload();}catch(e){toast(e.message,'error');}
    };
  }});
}
function escape(value){return String(value||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}

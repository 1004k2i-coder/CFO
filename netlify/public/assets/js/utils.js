export const ROLE_LABELS = {
  admin: '시스템 관리자',
  finance_manager: '자금·재무 관리자',
  finance_staff: '재무 담당자',
  business_user: '현업 담당자',
  approver: '결재자',
  executive: '대표·임원',
  auditor: '감사·조회',
};

export const STATUS_LABELS = {
  draft:'작성중', submitted:'결재요청', in_review:'결재중', approved:'승인', rejected:'반려', archived:'보관',
  pending:'대기', cancelled:'취소', unreviewed:'미확인', reviewed:'확인완료', duplicate:'중복후보', excluded:'제외',
  planned:'예정', matched:'연결됨', completed:'완료', overdue:'기한경과'
};

export const money = value => `${Math.round(Number(value || 0)).toLocaleString('ko-KR')}원`;
export const shortMoney = value => {
  const n = Number(value || 0);
  const abs = Math.abs(n);
  if (abs >= 100000000) return `${(n / 100000000).toFixed(abs >= 1000000000 ? 1 : 2).replace(/\.0+$/,'')}억원`;
  if (abs >= 10000) return `${(n / 10000).toFixed(abs >= 10000000 ? 0 : 1).replace(/\.0$/,'')}만원`;
  return money(n);
};
export const pct = value => `${Number(value || 0).toFixed(1)}%`;
export const fmtDate = value => {
  if (!value) return '-';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : new Intl.DateTimeFormat('ko-KR',{year:'numeric',month:'2-digit',day:'2-digit'}).format(d);
};
export const fmtDateTime = value => {
  if (!value) return '-';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : new Intl.DateTimeFormat('ko-KR',{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}).format(d);
};
export const isoDate = (d = new Date()) => {
  const x = new Date(d);
  x.setMinutes(x.getMinutes() - x.getTimezoneOffset());
  return x.toISOString().slice(0,10);
};
export const firstDay = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-01`;
export const lastDay = (d = new Date()) => new Date(d.getFullYear(), d.getMonth()+1, 0).toISOString().slice(0,10);
export const addDays = (date, days) => { const d=new Date(`${date}T00:00:00`); d.setDate(d.getDate()+days); return isoDate(d); };
export const toNumber = value => {
  if (value === null || value === undefined || value === '') return 0;
  const n = Number(String(value).replace(/[₩원,\s]/g,''));
  return Number.isFinite(n) ? n : 0;
};
export const esc = value => String(value ?? '').replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));
export const clean = value => String(value ?? '').replace(/\s+/g,' ').trim();
export const uid = () => crypto.randomUUID ? crypto.randomUUID() : `id_${Date.now()}_${Math.random().toString(16).slice(2)}`;
export const sleep = ms => new Promise(r => setTimeout(r, ms));
export const chunk = (arr, size=500) => Array.from({length:Math.ceil(arr.length/size)},(_,i)=>arr.slice(i*size,(i+1)*size));

export function badge(status, label = STATUS_LABELS[status] || status || '-') {
  const green = ['approved','reviewed','completed','matched','active'].includes(status);
  const orange = ['submitted','in_review','pending','unreviewed','planned','overdue'].includes(status);
  const red = ['rejected','duplicate','excluded','cancelled','inactive'].includes(status);
  return `<span class="badge ${green?'green':orange?'orange':red?'red':'blue'}">${esc(label)}</span>`;
}

export function showLoading(text='처리 중입니다...') {
  const el = document.getElementById('loadingOverlay');
  if (!el) return;
  el.querySelector('[data-loading-text]').textContent = text;
  el.classList.remove('hidden');
}
export function hideLoading() { document.getElementById('loadingOverlay')?.classList.add('hidden'); }

export function toast(message, type='success', timeout=3600) {
  let wrap = document.getElementById('toastWrap');
  if (!wrap) { wrap=document.createElement('div'); wrap.id='toastWrap'; wrap.className='toast-wrap'; document.body.appendChild(wrap); }
  const el=document.createElement('div'); el.className=`toast ${type==='error'?'error':type==='warn'?'warn':''}`; el.textContent=message;
  wrap.appendChild(el); setTimeout(()=>el.remove(),timeout);
}

export function confirmDialog({title='확인', message='', confirmText='확인', danger=false}={}) {
  return new Promise(resolve => {
    const root=document.getElementById('modalRoot');
    root.innerHTML=`<div class="modal-backdrop"><div class="modal" style="max-width:480px"><div class="modal-header"><h3>${esc(title)}</h3><button class="btn btn-ghost" data-close>✕</button></div><div class="modal-body"><div style="line-height:1.7">${esc(message)}</div></div><div class="modal-footer"><button class="btn btn-secondary" data-close>취소</button><button class="btn ${danger?'btn-danger':'btn-primary'}" data-confirm>${esc(confirmText)}</button></div></div></div>`;
    const close = value => { root.innerHTML=''; resolve(value); };
    root.querySelectorAll('[data-close]').forEach(b=>b.onclick=()=>close(false));
    root.querySelector('[data-confirm]').onclick=()=>close(true);
  });
}

export function openModal({title, body, footer='', width='780px', onOpen}={}) {
  const root=document.getElementById('modalRoot');
  root.innerHTML=`<div class="modal-backdrop"><div class="modal" style="max-width:${width}"><div class="modal-header"><h3>${esc(title||'')}</h3><button class="btn btn-ghost" data-modal-close>✕</button></div><div class="modal-body">${body||''}</div>${footer?`<div class="modal-footer">${footer}</div>`:''}</div></div>`;
  const close=()=>{root.innerHTML=''};
  root.querySelectorAll('[data-modal-close]').forEach(b=>b.onclick=close);
  root.querySelector('.modal-backdrop').addEventListener('click',e=>{if(e.target===e.currentTarget)close()});
  onOpen?.(root,close);
  return close;
}

export function downloadBlob(name, content, type='application/octet-stream') {
  const blob = content instanceof Blob ? content : new Blob([content],{type});
  const url=URL.createObjectURL(blob); const a=document.createElement('a'); a.href=url; a.download=name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(()=>URL.revokeObjectURL(url),1000);
}

export async function sha256(input) {
  const data = input instanceof ArrayBuffer ? input : new TextEncoder().encode(String(input));
  const digest=await crypto.subtle.digest('SHA-256',data);
  return [...new Uint8Array(digest)].map(b=>b.toString(16).padStart(2,'0')).join('');
}

export function formDataObject(form) {
  const fd=new FormData(form); const out={};
  for(const [k,v] of fd.entries()) {
    if(Object.prototype.hasOwnProperty.call(out,k)) out[k]=Array.isArray(out[k])?[...out[k],v]:[out[k],v]; else out[k]=v;
  }
  return out;
}

export function debounce(fn, wait=250) { let t; return (...args)=>{clearTimeout(t);t=setTimeout(()=>fn(...args),wait)}; }

export function normalizeAccountNo(value='') {
  const digits=String(value).replace(/\D/g,'');
  if (!digits) return '';
  return digits.length<=4 ? `****${digits}` : `${digits.slice(0,3)}-****-${digits.slice(-4)}`;
}

export function fileSafe(value='file') { return String(value).replace(/[\\/:*?"<>|]/g,'_').replace(/\s+/g,'_'); }

export function loadScript(src, globalName, timeout=20000) {
  if (globalName && window[globalName]) return Promise.resolve(window[globalName]);
  const existing=[...document.scripts].find(x=>x.src===new URL(src,location.href).href);
  if(existing){return new Promise((resolve,reject)=>{const end=Date.now()+timeout;const timer=setInterval(()=>{if(!globalName||window[globalName]){clearInterval(timer);resolve(globalName?window[globalName]:true)}else if(Date.now()>end){clearInterval(timer);reject(new Error(`${globalName||src} 로딩 시간 초과`))}},100)});}
  return new Promise((resolve,reject)=>{const el=document.createElement('script');el.src=src;el.async=true;el.onload=()=>resolve(globalName?window[globalName]:true);el.onerror=()=>reject(new Error(`${src} 라이브러리를 불러오지 못했습니다.`));document.head.appendChild(el);setTimeout(()=>reject(new Error(`${globalName||src} 로딩 시간 초과`)),timeout)});
}

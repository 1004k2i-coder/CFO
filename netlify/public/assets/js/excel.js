import { clean, isoDate, loadScript, sha256, toNumber } from './utils.js';
import { findBankHeader, findPlanTitle, parseBankSheet, parsePlanSheet } from './import-parsers.js';

const LEGACY_ASSET_NAMES={cashAsset:'현금 및 현금성자산',shortFinancial:'단기금융상품',receivables:'매출채권 및 기타채권',inventory:'재고자산',investment:'투자자산',ppe:'유형자산',intangible:'무형자산',otherAsset:'기타자산'};

function sheetRows(workbook, name=workbook.SheetNames[0]) {
  const ws=workbook.Sheets[name];
  return ws?window.XLSX.utils.sheet_to_json(ws,{header:1,defval:'',raw:false,blankrows:true,range:0}):[];
}
function normalizedHeaders(row){
  const seen={};
  return row.map(h=>{
    let k=clean(h).replace(/\s+/g,'');
    seen[k]=(seen[k]||0)+1;
    return seen[k]>1?`${k}_${seen[k]}`:k;
  });
}
function rowsToObjects(rows){
  const headers=normalizedHeaders(rows[0]||[]);
  return rows.slice(1).map((row,index)=>({__row:index+2,...Object.fromEntries(headers.map((h,i)=>[h,row[i]??'']))}));
}
function excelDate(value){
  if(!value)return '';
  if(value instanceof Date)return isoDate(value);
  const s=String(value).trim();
  if(/^\d{4}[.\/-]\d{1,2}[.\/-]\d{1,2}/.test(s))return s.slice(0,10).replaceAll('.','-').replaceAll('/','-');
  const n=Number(s);
  if(Number.isFinite(n)&&n>20000&&n<80000){const d=new Date(Math.round((n-25569)*86400*1000));return d.toISOString().slice(0,10)}
  return s;
}

async function ensureXlsx(){if(!window.XLSX)await loadScript('https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js','XLSX');return window.XLSX}

export async function parseFinanceFile(file, {categories=[]}={}) {
  const lower=String(file.name||'').toLowerCase();
  if(lower.endsWith('.json')){
    const text=await file.text(); let parsed;
    try{parsed=JSON.parse(text)}catch{throw new Error('JSON 백업 파일을 읽을 수 없습니다.');}
    if(parsed?.corpNames&&parsed?.corps)return {kind:'legacy',fileHash:await sha256(text),...parseLegacyJson(parsed)};
    throw new Error('기존 재무현황표에서 저장한 JSON 백업 형식이 아닙니다.');
  }
  await ensureXlsx();
  const buffer=await file.arrayBuffer();
  const workbook=window.XLSX.read(buffer,{type:'array',cellDates:false});
  const fileHash=await sha256(buffer),candidates=[];
  for(const name of workbook.SheetNames){
    const rows=sheetRows(workbook,name);
    if(findPlanTitle(rows))candidates.push({kind:'cash_plan',name,rows});
    else if(findBankHeader(rows))candidates.push({kind:'bank',name,rows});
    else{
      const h=rows.findIndex(r=>r.map(clean).includes('자료구분')&&r.map(clean).includes('법인명'));
      if(h>=0)candidates.push({kind:'legacy',name,rows:rows.slice(h)});
    }
  }
  if(!candidates.length)throw new Error('지원하는 머리글을 찾지 못했습니다. 기업·경남·농협·신한 거래내역 또는 과거 자금계획서를 확인하세요.');
  if(candidates.length>1)throw new Error('가져올 수 있는 시트가 여러 개입니다. 필요한 시트 하나만 별도 파일로 저장해서 올려주세요.');
  const {kind,name,rows}=candidates[0];
  if(kind==='bank')return {kind,fileHash,...await parseBankSheet(rows,{categories,sheetName:name,date1904:!!workbook.Workbook?.WBProps?.date1904})};
  if(kind==='cash_plan')return {kind,fileHash,...parsePlanSheet(rows,{sheetName:name})};
  return {kind,fileHash,...parseLegacyRows(rows)};
}

function parseLegacyRows(rows){
  const objects=rowsToObjects(rows);
  const result={cash:[],monthly:[],schedules:[],assets:[],products:[]};
  for(const r of objects){
    const kind=clean(r['자료구분']),companyName=clean(r['법인명']); if(!kind||!companyName)continue;
    if(kind==='현금')result.cash.push({company_name:companyName,current_balance:toNumber(r['현재통장잔고']),required_reserve:toNumber(r['필수보유현금'])});
    else if(kind==='월별')result.monthly.push({company_name:companyName,plan_month:toNumber(r['월']),income:toNumber(r['수입']),salary:toNumber(r['급여']),trade_payables:toNumber(r['외상대금']),interest_expense:toNumber(r['이자비용']),other_expense:toNumber(r['기타비용'])});
    else if(kind==='예정')result.schedules.push({company_name:companyName,due_date:excelDate(r['예정일']),direction:String(r['구분']).includes('지급')?'payment':String(r['구분']).includes('이체')?'transfer':'receipt',counterparty:clean(r['거래처/내용']),description:clean(r['거래처/내용']),amount:toNumber(r['금액']),probability:toNumber(r['입금확률']||100),priority:String(r['우선순위']).includes('높')?'high':String(r['우선순위']).includes('낮')?'low':'normal',memo:clean(r['메모'])});
    else if(kind==='자산')result.assets.push({company_name:companyName,asset_type:clean(r['자산항목']),amount:toNumber(r['현재금액']),target_ratio:toNumber(r['목표비율'])});
    else if(kind==='단기투자')result.products.push({company_name:companyName,product_type:'deposit',bank_name:clean(r['금융기관']),product_name:clean(r['상품명'])||clean(r['상품구분'])||'단기투자',currency:'KRW',principal:toNumber(r['가입금액']),current_value:toNumber(r['현재평가금액']),interest_rate:toNumber(r['금리']),start_date:excelDate(r['가입일']),maturity_date:excelDate(r['만기일']),redeemable:String(r['중도해지']).includes('가능'),pledged:String(r['담보/질권']).includes('있음'),memo:clean(r['메모'])});
    else if(kind==='외화예금')result.products.push({company_name:companyName,product_type:'fx_deposit',bank_name:clean(r['금융기관']),product_name:clean(r['예금구분'])||'외화예금',currency:clean(r['통화'])||'USD',principal:toNumber(r['외화잔액']),current_value:toNumber(r['외화잔액']),exchange_rate:toNumber(r['수동환율']),interest_rate:0,start_date:excelDate(r['가입일']),maturity_date:excelDate(r['만기일']),redeemable:true,pledged:false,memo:clean(r['메모'])});
  }
  return {rows:result,preview:[...result.cash,...result.monthly,...result.schedules].slice(0,100),summary:Object.fromEntries(Object.entries(result).map(([k,v])=>[k,v.length]))};
}

function parseLegacyJson(state){
  const result={cash:[],monthly:[],schedules:[],assets:[],products:[]};
  const names=Array.isArray(state.corpNames)?state.corpNames:[];
  (state.corps||[]).forEach((corp,ci)=>{
    const company_name=clean(names[ci]||`법인 ${ci+1}`);
    result.cash.push({company_name,current_balance:toNumber(corp?.cash?.bankBalance),required_reserve:toNumber(corp?.cash?.requiredReserve)});
    (corp?.monthly||[]).forEach((m,mi)=>result.monthly.push({company_name,plan_month:mi+1,income:toNumber(m?.income),salary:toNumber(m?.expenses?.salary),trade_payables:toNumber(m?.expenses?.creditPayment),interest_expense:toNumber(m?.expenses?.interest),other_expense:toNumber(m?.expenses?.otherExpense)}));
    Object.entries(corp?.assets||{}).forEach(([key,a])=>result.assets.push({company_name,asset_type:LEGACY_ASSET_NAMES[key]||key,amount:toNumber(a?.amount),target_ratio:toNumber(a?.target)}));
  });
  (state.schedules||[]).forEach(x=>result.schedules.push({company_name:clean(names[toNumber(x.corpIndex)]||''),due_date:excelDate(x.date),direction:x.type==='payment'?'payment':x.type==='transfer'?'transfer':'receipt',counterparty:clean(x.counterparty),description:clean(x.counterparty),amount:toNumber(x.amount),probability:toNumber(x.probability||100),priority:x.priority==='높음'?'high':x.priority==='낮음'?'low':'normal',memo:clean(x.memo)}));
  (state.shortInvestments||[]).forEach(x=>result.products.push({company_name:clean(names[toNumber(x.corpIndex)]||''),product_type:'deposit',bank_name:clean(x.bank),product_name:clean(x.productName)||clean(x.productType)||'단기투자',currency:'KRW',principal:toNumber(x.principal),current_value:toNumber(x.currentValue)||toNumber(x.principal),exchange_rate:0,interest_rate:toNumber(x.rate),start_date:excelDate(x.startDate),maturity_date:excelDate(x.maturityDate),redeemable:String(x.redeemable).includes('가능'),pledged:String(x.pledged).includes('있음'),memo:clean(x.memo)}));
  (state.fxDeposits||[]).forEach(x=>result.products.push({company_name:clean(names[toNumber(x.corpIndex)]||''),product_type:'fx_deposit',bank_name:clean(x.bank),product_name:clean(x.depositType)||'외화예금',currency:clean(x.currency)||'USD',principal:toNumber(x.foreignAmount),current_value:toNumber(x.foreignAmount),exchange_rate:toNumber(x.manualRate),interest_rate:0,start_date:'',maturity_date:excelDate(x.maturityDate),redeemable:true,pledged:false,memo:clean(x.memo)}));
  return {rows:result,preview:[...result.cash,...result.monthly,...result.schedules,...result.products].slice(0,100),summary:Object.fromEntries(Object.entries(result).map(([k,v])=>[k,v.length]))};
}

export async function exportWorkbook(name,sheets){
  await ensureXlsx();
  const wb=window.XLSX.utils.book_new();
  for(const [sheetName,rows] of Object.entries(sheets)){
    const ws=window.XLSX.utils.json_to_sheet(rows);
    const keys=rows[0]?Object.keys(rows[0]):[];
    ws['!cols']=keys.map(k=>({wch:Math.min(40,Math.max(12,k.length+2,...rows.slice(0,100).map(r=>String(r[k]??'').length+2)))}));
    window.XLSX.utils.book_append_sheet(wb,ws,sheetName.slice(0,31));
  }
  window.XLSX.writeFile(wb,name);
}

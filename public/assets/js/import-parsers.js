import {clean,sha256} from './utils.js';
import {suggestCategory} from './classification.js';

const key=v=>clean(v).normalize('NFKC').replace(/\s+/g,'').replace(/\(원\)/g,'');
const aliases={
  date:['거래일시','거래일자','거래일','일시'],time:['거래시간'],
  inflow:['입금액','입금금액','입금','맡기신금액'],outflow:['출금액','출금금액','출금','찾으신금액','지급금액'],
  balance:['잔액','거래후잔액','거래후잔고','잔고'],
  summary:['적요','거래내용','거래종류','거래구분'],
  counterparty:['내용','거래기록사항','상대계좌예금주명','거래내용','적요'],
  branch:['거래점명','거래점','취급점','상대은행'],code:['입금인코드','CMS코드'],
};
const total=v=>/^(합계|총계|소계|총합계|입금합계|출금합계)$/.test(key(v));
const carry=v=>/^(전월이월|전일이월|이월금|이월잔액|차월이월|차기이월)/.test(key(v));
const blank=v=>v===null||v===undefined||clean(v)==='';
export function validDate(year,month,day){
  const d=new Date(Date.UTC(year,month-1,day));
  return year>=1900&&year<=2199&&d.getUTCFullYear()===year&&d.getUTCMonth()+1===month&&d.getUTCDate()===day;
}
export function bankDate(value,time='',date1904=false){
  let s=clean(value);
  if(/^\d{5}(?:\.\d+)?$/.test(s))value=Number(s);
  if(typeof value==='number'){
    if(value<1||value>110000)return null;
    const d=new Date(Date.UTC(1899,11,30)+(value+(date1904?1462:0))*86400000);
    s=d.toISOString().slice(0,19);
  }
  s=s.replace(/[./]/g,'-').replace(/\s+/g,' ');
  const match=s.match(/^(\d{4})-?(\d{2}|\d{1})-?(\d{2}|\d{1})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/);
  if(!match)return null;
  const [year,month,day]=match.slice(1,4).map(Number);
  if(!validDate(year,month,day))return null;
  let h=Number(match[4]||0),m=Number(match[5]||0),sec=Number(match[6]||0);
  if(!blank(time)){
    let t=clean(time);
    if(/^0\.\d+$/.test(t))time=Number(t);
    if(typeof time==='number'&&time>=0&&time<1){const seconds=Math.round(time*86400);t=`${Math.floor(seconds/3600)}:${String(Math.floor(seconds/60)%60).padStart(2,'0')}:${String(seconds%60).padStart(2,'0')}`;}
    const tm=t.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
    if(!tm)return null;[h,m,sec]=[Number(tm[1]),Number(tm[2]),Number(tm[3]||0)];
  }
  if(h>23||m>59||sec>59)return null;
  // 은행 원본의 시각은 한국 시각으로 해석하여 브라우저 시간대와 무관하게 저장합니다.
  return new Date(Date.UTC(year,month-1,day,h-9,m,sec)).toISOString();
}
export function amount(value,{empty=0}={}){
  if(blank(value)||clean(value)==='-')return empty;
  const s=clean(value).replace(/[,₩원\s]/g,'').replace(/^\((.+)\)$/,'-$1');
  if(!/^-?\d+(?:\.\d+)?$/.test(s))throw new Error(`숫자가 아닌 금액: ${clean(value)}`);
  const n=Number(s);if(!Number.isFinite(n)||Math.abs(n)>Number.MAX_SAFE_INTEGER)throw new Error('지원 범위를 초과한 금액입니다.');return n;
}
export function findBankHeader(rows){
  for(let index=0;index<rows.length;index++){
    const headers=(rows[index]||[]).map(key),map={};
    for(const [name,values] of Object.entries(aliases))map[name]=values.map(v=>headers.indexOf(v)).find(i=>i>=0)??-1;
    if(map.date>=0&&map.inflow>=0&&map.outflow>=0)return {index,map,headers};
  }
  return null;
}
export async function parseBankSheet(rows,{categories=[],sheetName='',date1904=false}={}){
  const header=findBankHeader(rows);if(!header)throw new Error('은행 거래내역의 날짜·입금·출금 머리글을 찾을 수 없습니다.');
  const {index,map,headers}=header,items=[],issues=[];let excluded=0;
  const get=(r,k)=>map[k]<0?'':r[map[k]];
  for(let i=index+1;i<rows.length;i++){
    const r=rows[i]||[];if(r.every(blank))continue;
    const dateValue=get(r,'date'),prefix=r.slice(0,map.date+1);
    if(prefix.some(total)||key(dateValue)===headers[map.date]){excluded++;continue;}
    // 날짜가 없는 설명행은 제외하되 금액이 있는 행은 누락시키지 않고 오류를 알립니다.
    if(blank(dateValue)&&blank(get(r,'inflow'))&&blank(get(r,'outflow'))){excluded++;continue;}
    try{
      const transaction_at=bankDate(dateValue,get(r,'time'),date1904);
      if(!transaction_at)throw new Error(`거래일시를 확인하세요: ${clean(dateValue)||'(비어 있음)'}`);
      const inflow=amount(get(r,'inflow')),outflow=amount(get(r,'outflow')),balance=amount(get(r,'balance'),{empty:null});
      if(inflow<0||outflow<0||(inflow>0&&outflow>0))throw new Error('입금·출금 방향 또는 음수 금액을 확인하세요.');
      if(!inflow&&!outflow){excluded++;continue;}
      const memo=r.filter((_,c)=>/메모/.test(headers[c]||'')).map(clean).filter(Boolean).join(' / ');
      const counterparty=aliases.counterparty.map(v=>headers.indexOf(v)).filter(c=>c>=0).map(c=>clean(r[c])).find(Boolean)||'';
      const bank_summary=clean(get(r,'summary')),branch_name=clean(get(r,'branch'));
      const item={transaction_at,inflow,outflow,balance,bank_summary,counterparty,memo,branch_name,bank_code:clean(get(r,'code')),depositor_code:clean(get(r,'code')),classification_status:'unreviewed'};
      // 기존 신한 업로드와 같은 주요 필드 순서를 유지합니다.
      const sourceText=[transaction_at,get(r,'summary'),inflow,outflow,headers.includes('내용')?r[headers.indexOf('내용')]:counterparty,get(r,'balance'),get(r,'branch')].join('|');
      item.source_hash=await sha256(sourceText);
      item.suggested_category_id=suggestCategory(item,categories).id;
      item.raw_data={__sheet:sheetName,__row:i+1,columns:headers,values:r};
      items.push(item);
    }catch(e){issues.push({sheet:sheetName,row:i+1,message:e.message});}
  }
  if(issues.length)throw new Error(`파일을 저장하지 않았습니다. ${issues.length}개 행을 확인하세요. ${issues.slice(0,8).map(x=>`${x.sheet} ${x.row}행: ${x.message}`).join(' / ')}`);
  if(!items.length)throw new Error('가져올 은행 거래가 없습니다. 제목·합계·빈 행을 제외한 실제 거래를 확인하세요.');
  return {rows:items,preview:items.slice(0,100),summary:{total:items.length,inflow:items.reduce((s,x)=>s+x.inflow,0),outflow:items.reduce((s,x)=>s+x.outflow,0),excluded,headerRows:index+1,sheet:sheetName}};
}

export function findPlanTitle(rows){
  for(let i=0;i<Math.min(rows.length,30);i++)for(const value of rows[i]||[]){
    const m=clean(value).match(/(20\d{2})년\s*(\d{1,2})월\s*조달\s*및\s*지출\s*계획/);
    if(m)return {index:i,year:Number(m[1]),month:Number(m[2])};
  }
  return null;
}
export function parsePlanSheet(rows,{sheetName=''}={}){
  const title=findPlanTitle(rows);if(!title||title.month<1||title.month>12)throw new Error('자금계획서 제목의 연도와 월을 확인하세요.');
  const header=rows.findIndex((r,i)=>i>title.index&&key(r[0])==='일자'&&key(r[1])==='수입내역'&&key(r[5])==='금액');
  if(header<0)throw new Error('자금계획서의 일자·수입내역·금액·지출금액 머리글을 찾을 수 없습니다.');
  let day=null;const schedules=[],warnings=[];let excluded=0;
  for(let i=header+1;i<rows.length;i++){
    const r=rows[i]||[];if(r.slice(0,8).every(blank))continue;
    if(total(r[0])||total(r[1])||total(r[4])){excluded++;continue;}
    if(key(r[0])==='일자'){excluded++;continue;}
    if(!blank(r[0])){
      const m=clean(r[0]).match(/^(\d{1,2})일?$/);day=m?Number(m[1]):null;
      if(!m||!validDate(title.year,title.month,day))throw new Error(`${sheetName} ${i+1}행: 일자가 올바르지 않습니다.`);
    }
    for(const [direction,descIndex,amountIndex,noteIndex] of [['receipt',1,2,3],['payment',4,5,6]]){
      const desc=clean(r[descIndex]);if(carry(desc)||total(desc)){excluded++;continue;}
      if(!desc&&blank(r[amountIndex]))continue;
      let value;try{value=amount(r[amountIndex]);}catch(e){throw new Error(`${sheetName} ${i+1}행: ${e.message}`);}
      if(value===0){excluded++;warnings.push(`${i+1}행 ${direction==='receipt'?'입금':'지급'}: 금액 없음 또는 0원으로 제외 (${desc||'내용 없음'})`);continue;}
      if(value<0)throw new Error(`${sheetName} ${i+1}행: 음수 예정금액을 확인하세요.`);
      if(!day)throw new Error(`${sheetName} ${i+1}행: 금액은 있지만 앞에 일자가 없습니다.`);
      const description=desc||`내용 미기재 (${sheetName} ${i+1}행)`;
      if(!desc)warnings.push(`${i+1}행: 금액은 있으나 내용이 없어 확인 필요로 가져옵니다.`);
      schedules.push({due_date:`${title.year}-${String(title.month).padStart(2,'0')}-${String(day).padStart(2,'0')}`,direction,counterparty:description,description,amount:value,probability:100,priority:'normal',memo:[clean(r[noteIndex]),clean(r[7]),`원본: ${sheetName} ${i+1}행`].filter(Boolean).join(' / '),source_row:i+1});
    }
  }
  if(!schedules.length)throw new Error('금액과 날짜가 있는 자금계획 항목이 없습니다.');
  return {rows:schedules,preview:schedules.slice(0,100),warnings,summary:{total:schedules.length,receipt:schedules.filter(x=>x.direction==='receipt').reduce((s,x)=>s+x.amount,0),payment:schedules.filter(x=>x.direction==='payment').reduce((s,x)=>s+x.amount,0),excluded,year:title.year,month:title.month,sheet:sheetName}};
}

export async function prepareScheduleImport(parsed,companyId,ownerId,targetMonth=''){
  if(targetMonth&&!/^20\d{2}-(0[1-9]|1[0-2])$/.test(targetMonth))throw new Error('적용할 연월을 확인하세요.');
  const result=[];
  for(const row of parsed.rows){
    const {source_row,...payload}=row;
    const due_date=targetMonth?`${targetMonth}-${row.due_date.slice(-2)}`:row.due_date;
    if(!validDate(...due_date.split('-').map(Number)))throw new Error(`${source_row}행: ${due_date}은 없는 날짜입니다. 적용 월이나 원본 일자를 수정하세요.`);
    // 같은 파일·법인·시트·행·방향·적용일의 재업로드는 동일한 식별자로 중복을 막습니다.
    const hash=await sha256([companyId,parsed.fileHash,parsed.summary.sheet,source_row,row.direction,due_date].join('|'));
    const id=`${hash.slice(0,8)}-${hash.slice(8,12)}-5${hash.slice(13,16)}-a${hash.slice(17,20)}-${hash.slice(20,32)}`;
    result.push({...payload,id,due_date,company_id:companyId,status:'planned',source:'cash_plan_import',owner_id:ownerId});
  }
  return result;
}

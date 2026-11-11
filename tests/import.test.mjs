import test from 'node:test';
import assert from 'node:assert/strict';
import {bankDate,parseBankSheet,parsePlanSheet,prepareScheduleImport} from '../public/assets/js/import-parsers.js';
import {suggestCategory,selectedCategory} from '../public/assets/js/classification.js';
import {FinanceAPI} from '../public/assets/js/api.js';
import {money} from '../public/assets/js/utils.js';
const headers=['번호','거래일시','출금금액','입금금액','거래후잔액','적요'];
const categories=[{id:'salary',name:'급여·인건비',direction:'payment',keywords:['급여']},{id:'interest',name:'대출이자',direction:'payment',keywords:['대출이자']},{id:'loan',name:'차입금 수령',direction:'receipt',keywords:['대출금']},{id:'other',name:'기타',direction:'mixed',keywords:[]}];
test('한국 시각·점/슬래시 구분 날짜·분리 시각을 정확하게 변환한다',()=>{
 assert.equal(bankDate('2026.01.30 16:05:46'),'2026-01-30T07:05:46.000Z');
 assert.equal(bankDate('2026/01/30','04:03:11'),'2026-01-29T19:03:11.000Z');
 assert.equal(bankDate('2026-1-2 14:26'),'2026-01-02T05:26:00.000Z');
 assert.equal(bankDate('합계'),null);assert.equal(bankDate('2026-02-30'),null);assert.equal(bankDate('2026-01-30 24:00'),null);
});
test('은행 제목·빈 행·합계·반복 머리글을 제외하고 원본 행 번호를 보존한다',async()=>{
 const result=await parseBankSheet([['통장 조회'],[],headers,['1','2026-01-30 10:00','100','','900','급여'],headers,['합계','','100','','','']],{sheetName:'거래',categories});
 assert.equal(result.rows.length,1);assert.equal(result.rows[0].raw_data.__row,4);assert.equal(result.rows[0].outflow,100);assert.equal(result.summary.excluded,2);assert.equal(result.rows[0].suggested_category_id,'salary');
});
test('날짜와 금액 오류는 저장 전에 행 번호로 거절한다',async()=>{
 await assert.rejects(parseBankSheet([headers,['1','2026-02-30','1','','0','']],{sheetName:'원본'}),/원본 2행/);
 await assert.rejects(parseBankSheet([headers,['1','2026-01-30','미정','','0','']]),/숫자가 아닌 금액/);
 await assert.rejects(parseBankSheet([headers,['1','','100','','0','']]),/거래일시/);
 await assert.rejects(parseBankSheet([headers,['1','2026-01-30','100','200','0','']]),/방향/);
});
test('잔액 0과 잔액 없음은 구분하며 적요의 합계 문구는 실제 거래를 제거하지 않는다',async()=>{
 const result=await parseBankSheet([headers,['1','2026-01-30','1','','0','합계'],['2','2026-01-29','2','','','']]);
 assert.equal(result.rows[0].balance,0);assert.equal(result.rows[1].balance,null);assert.equal(result.rows.length,2);
});
const plan=[['2025년 11월 조달 및 지출 계획'],[],['일자','수입내역','금액','','지출금액','금액','','비고'],['','전월이월',1000],['10','수금',2000,'협력회사','급여',500,'직원급여'],['','','','','카드',100],['30','미정','','','',''],['','','50'],['','합 계',2050]];
test('계획서 이월·합계·빈 금액 제외, 병합 일자 상속, 무명 금액 보존',()=>{
 const r=parsePlanSheet(plan,{sheetName:'계획'});assert.equal(r.rows.length,4);assert.equal(r.rows[2].due_date,'2025-11-10');assert.equal(r.summary.receipt,2050);assert.equal(r.summary.payment,600);assert.match(r.rows[3].description,/내용 미기재/);assert.equal(r.rows[0].memo,'협력회사 / 원본: 계획 5행');
});
test('계획 적용월 변경과 동일 업로드 식별자, 없는 일자 거절',async()=>{
 const parsed={...parsePlanSheet(plan,{sheetName:'계획'}),fileHash:'파일해시'};
 const a=await prepareScheduleImport(parsed,'company','user','2026-11'),b=await prepareScheduleImport(parsed,'company','user','2026-11');
 assert.deepEqual(a,b);assert.equal(a[0].due_date,'2026-11-10');assert.equal(a[0].source_row,undefined);assert.match(a[0].id,/^[a-f0-9-]{36}$/);
 assert.notEqual(a[0].id,(await prepareScheduleImport(parsed,'other-company','user','2026-11'))[0].id);
 await assert.rejects(prepareScheduleImport(parsed,'company','user','2026-02'),/없는 날짜/);
});
test('동일 법인·방향의 확정 내역으로 추천하고 기존 확정값은 유지한다',()=>{
 const t={id:'new',company_id:'c1',counterparty:'직원',inflow:0,outflow:100,bank_summary:'급여'};
 assert.equal(suggestCategory(t,categories).id,'salary');
 assert.equal(suggestCategory({...t,bank_summary:'대출금이자'},categories).id,'interest');
 assert.equal(suggestCategory({...t,bank_summary:'대출금이자',inflow:100,outflow:0},categories).id,'loan');
 assert.equal(suggestCategory({...t,bank_summary:''},categories,[{...t,id:'old',classification_status:'reviewed',category_id:'salary'}]).id,'salary');
 assert.equal(suggestCategory({...t,bank_summary:''},categories,[{...t,company_id:'c2',classification_status:'reviewed',category_id:'salary'}]).id,'other');
 assert.equal(selectedCategory({...t,category_id:'other'},categories).id,'other');
});
test('일정 저장 API는 알 수 없는 열 없이 중복 무시를 요청한다',async()=>{
 let saved;const api=Object.create(FinanceAPI.prototype);api.demo=false;
 api.client={auth:{getUser:async()=>({data:{user:{id:'user'}}})},from:table=>({upsert:(rows,options)=>{saved={table,rows,options};return {select:async()=>({data:rows.map(r=>({id:r.id}))})};}})};
 const rows=await prepareScheduleImport({...parsePlanSheet(plan),fileHash:'해시'},'company','user');
 assert.deepEqual(await api.importSchedules(rows),{inserted:4,duplicates:0});assert.equal(saved.table,'schedules');assert.deepEqual(saved.options,{onConflict:'id',ignoreDuplicates:true});assert.equal(saved.rows[0].source_row,undefined);
});
test('잔고는 원 단위를 유지하고 세 자리마다 쉼표로 표시한다',()=>{assert.equal(money(123456789),'123,456,789원');assert.equal(money(-1234567),'-1,234,567원');});

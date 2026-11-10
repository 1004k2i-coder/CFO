import { addDays, isoDate, uid } from './utils.js';

export function buildDemoData() {
  const today=isoDate();
  const companies=[
    {id:'11111111-1111-1111-1111-111111111111',code:'CHANGJIN',name:'창진에스씨'},
    {id:'22222222-2222-2222-2222-222222222222',code:'SAMCO',name:'삼코'},
    {id:'33333333-3333-3333-3333-333333333333',code:'SAMCHEON',name:'삼천산업'},
  ];
  const users=[
    {id:'demo-admin',email:'admin@demo.local',full_name:'관리자',department:'경영지원',job_title:'관리자',role:'admin',active:true},
    {id:'demo-finance',email:'finance@demo.local',full_name:'서다솜',department:'재무',job_title:'선임',role:'finance_manager',active:true},
    {id:'demo-approver',email:'ceo@demo.local',full_name:'대표이사',department:'경영',job_title:'대표',role:'executive',active:true},
  ];
  const memberships=users.flatMap(u=>companies.map(c=>({user_id:u.id,company_id:c.id,access_level:u.role==='admin'?'manage':u.role==='finance_manager'?'finance':'read',companies:c})));
  const categories=[
    ['cat1','거래처 수금','receipt',['매출','수금','가온전자','삼천산업']],
    ['cat2','매입대금','payment',['외상대','소재','업체대금']],
    ['cat3','내부이체','transfer',['자사 계좌','MMT','창진에스씨']],
    ['cat4','차입금 수령','receipt',['대출금','차입금']],
    ['cat5','급여·인건비','payment',['급여','용역','퇴직']],
    ['cat6','세금·공과금','payment',['세금','부가세','전기','통신']],
    ['cat7','대출이자','payment',['이자']],
    ['cat8','기타','mixed',[]],
  ].map(([id,name,direction,keywords],i)=>({id,name,direction,keywords,sort_order:(i+1)*10,active:true}));
  const accounts=companies.map((c,i)=>({id:`acc${i+1}`,company_id:c.id,bank_name:i===0?'기업은행':'경남은행',account_name:'운영계좌',account_number_masked:`123-****-${String(4567+i)}`,account_type:'operating',currency:'KRW',current_balance:[301000000,506000000,61000000][i],required_reserve:[300000000,200000000,3000000000][i],balance_as_of:new Date().toISOString(),active:true}));
  const transactions=[
    {id:'tx1',company_id:companies[0].id,account_id:'acc1',transaction_at:`${today}T09:10:00+09:00`,bank_summary:'타행PC',counterparty:'가온전자',inflow:50000000,outflow:0,balance:351000000,classification_status:'unreviewed',suggested_category_id:'cat1',category_id:null,owner_id:'demo-finance',source_hash:'demo1'},
    {id:'tx2',company_id:companies[0].id,account_id:'acc1',transaction_at:`${today}T11:20:00+09:00`,bank_summary:'인터넷',counterparty:'한빛소재',inflow:0,outflow:12000000,balance:339000000,classification_status:'unreviewed',suggested_category_id:'cat2',category_id:null,owner_id:'demo-finance',source_hash:'demo2'},
    {id:'tx3',company_id:companies[0].id,account_id:'acc1',transaction_at:`${today}T13:05:00+09:00`,bank_summary:'타행PC',counterparty:'자사 계좌 송금',inflow:0,outflow:30000000,balance:309000000,classification_status:'unreviewed',suggested_category_id:'cat3',category_id:null,owner_id:'demo-finance',source_hash:'demo3'},
    {id:'tx4',company_id:companies[0].id,account_id:'acc1',transaction_at:`${today}T14:40:00+09:00`,bank_summary:'대출금',counterparty:'기업은행',inflow:100000000,outflow:0,balance:409000000,classification_status:'unreviewed',suggested_category_id:'cat4',category_id:null,owner_id:'demo-finance',source_hash:'demo4'},
  ];
  const schedules=[
    {id:'sch1',company_id:companies[0].id,direction:'receipt',due_date:addDays(today,2),counterparty:'가온전자',description:'납품대금',amount:50000000,probability:80,priority:'high',status:'planned',owner_id:'demo-finance'},
    {id:'sch2',company_id:companies[0].id,direction:'payment',due_date:addDays(today,1),counterparty:'한빛소재',description:'매입대금',amount:20000000,probability:100,priority:'high',status:'planned',owner_id:'demo-finance'},
    {id:'sch3',company_id:companies[0].id,direction:'payment',due_date:addDays(today,-2),counterparty:'임차인',description:'임차료',amount:5000000,probability:100,priority:'normal',status:'overdue',owner_id:'demo-finance'},
  ];
  const products=[
    {id:'prd1',company_id:companies[0].id,product_type:'deposit',bank_name:'기업은행',product_name:'정기예금',currency:'KRW',principal:300000000,current_value:300000000,interest_rate:3.2,start_date:addDays(today,-60),maturity_date:addDays(today,1),available_date:addDays(today,1),redeemable:false,pledged:false,active:true},
    {id:'prd2',company_id:companies[0].id,product_type:'loan',bank_name:'기업은행',product_name:'운전자금대출',currency:'KRW',principal:4700000000,current_value:4700000000,interest_rate:4.5,start_date:addDays(today,-400),maturity_date:addDays(today,330),redeemable:false,pledged:false,active:true},
  ];
  const year=new Date().getFullYear();
  const monthlyPlans=Array.from({length:12},(_,i)=>({id:`mp${i+1}`,company_id:companies[0].id,plan_year:year,plan_month:i+1,income:650000000+(i%3)*40000000,salary:195000000,trade_payables:430000000,interest_expense:25000000,other_expense:130000000}));
  const reports=[{id:'rep1',company_id:companies[0].id,title:`${year}년 9월 자금현황 보고`,report_type:'monthly',period_start:`${year}-09-01`,period_end:`${year}-09-30`,status:'in_review',summary:'월말 지급 일정과 만기예금 회수 계획을 중심으로 검토 요청',snapshot:{currentCash:301000000,requiredReserve:300000000},current_version:1,created_by:'demo-finance',created_at:new Date().toISOString()}];
  const approvals=[{id:'ap1',report_id:'rep1',sequence_no:1,approver_id:'demo-approver',status:'pending',reports:reports[0]}];
  const audits=[];
  return {companies,users,memberships,categories,accounts,transactions,schedules,products,monthlyPlans,reports,approvals,audits,assetPositions:[],moduleAssignments:[]};
}

import { buildDemoData } from './demo-data.js';
import { callFunction } from './runtime.js';
import { chunk, isoDate, uid } from './utils.js';

const DEMO_KEY='changjin_finance_demo_v1';

function demoLoad(){
  const saved=localStorage.getItem(DEMO_KEY);
  if(saved){try{return JSON.parse(saved)}catch{}}
  const data=buildDemoData(); localStorage.setItem(DEMO_KEY,JSON.stringify(data)); return data;
}
function demoSave(data){localStorage.setItem(DEMO_KEY,JSON.stringify(data))}

export class FinanceAPI {
  constructor(runtime){this.runtime=runtime;this.client=runtime.client;this.demo=runtime.mode==='demo';this.demoData=this.demo?demoLoad():null;this.demoUser=this.demo?this.demoData.users[0]:null;}

  async deviceStatus(){const {data,error}=await this.client.rpc('device_status');if(error)throw error;return data;}
  async registerDevice(label){const {data,error}=await this.client.rpc('register_device',{p_label:label});if(error)throw error;return data;}
  async listDevices(){const {data,error}=await this.client.rpc('admin_devices');if(error)throw error;return data;}
  async setDevice(id,status){const {error}=await this.client.rpc('set_device_status',{p_id:id,p_status:status});if(error)throw error;}
  async getSession(){
    if(this.demo)return {user:{id:this.demoUser.id,email:this.demoUser.email},access_token:'demo'};
    const {data,error}=await this.client.auth.getSession(); if(error)throw error; return data.session;
  }
  async requestAccess({email,password,full_name,department}){
    const {data,error}=await this.client.auth.signUp({email,password,options:{emailRedirectTo:location.origin+'/',data:{full_name,department}}});
    if(error)throw error;return data;
  }
  async approveUser(payload){return callFunction(this.runtime,'admin-users',{body:{...payload,action:'approve'}});}
  async rejectUser(id){return callFunction(this.runtime,'admin-users',{body:{action:'reject',user_id:id}});}
  async signIn(email,password){
    if(this.demo){const user=this.demoData.users.find(u=>u.email===email)||this.demoData.users[0];this.demoUser=user;return {user};}
    const {data,error}=await this.client.auth.signInWithPassword({email,password});if(error)throw error;return data;
  }
  async signOut(){if(this.demo)return;const {error}=await this.client.auth.signOut();if(error)throw error;}
  async resetPassword(email){if(this.demo)return;const {error}=await this.client.auth.resetPasswordForEmail(email,{redirectTo:`${location.origin}/`});if(error)throw error;}

  async getProfile(userId){
    if(this.demo)return this.demoData.users.find(u=>u.id===userId)||this.demoUser;
    const {data,error}=await this.client.from('profiles').select('*').eq('id',userId).single();if(error)throw error;return data;
  }
  async getMemberships(userId){
    if(this.demo)return this.demoData.memberships.filter(m=>m.user_id===userId);
    const {data,error}=await this.client.from('company_memberships').select('*,companies(*)').eq('user_id',userId);if(error)throw error;return data||[];
  }
  async getModuleAssignments(userId){
    if(this.demo)return this.demoData.moduleAssignments.filter(a=>a.user_id===userId);
    const {data,error}=await this.client.from('module_assignments').select('*').eq('user_id',userId);if(error)throw error;return data||[];
  }
  async listCompanies(){
    if(this.demo)return this.demoData.companies;
    const {data,error}=await this.client.from('companies').select('*').eq('active',true).order('name');if(error)throw error;return data||[];
  }
  async listProfiles(){
    if(this.demo)return this.demoData.users;
    const {data,error}=await this.client.from('profiles').select('*').eq('active',true).order('full_name');if(error)throw error;return data||[];
  }
  async listCategories(companyId){
    if(this.demo)return this.demoData.categories;
    let q=this.client.from('finance_categories').select('*').eq('active',true).order('sort_order');
    if(companyId&&companyId!=='all')q=q.or(`company_id.is.null,company_id.eq.${companyId}`);else q=q.is('company_id',null);
    const {data,error}=await q;if(error)throw error;return data||[];
  }
  async saveCategory(row){
    if(this.demo){const i=this.demoData.categories.findIndex(x=>x.id===row.id);if(i>=0)this.demoData.categories[i]={...this.demoData.categories[i],...row};else this.demoData.categories.push({...row,id:row.id||uid()});demoSave(this.demoData);return row;}
    const {data,error}=await this.client.from('finance_categories').upsert(row).select().single();if(error)throw error;return data;
  }

  _companyFilter(query,companyId,field='company_id'){
    if(companyId&&companyId!=='all')return query.eq(field,companyId);
    return query;
  }

  async listAccounts(companyId){
    if(this.demo)return this.demoData.accounts.filter(a=>companyId==='all'||a.company_id===companyId);
    let q=this.client.from('cash_accounts').select('*').order('bank_name');q=this._companyFilter(q,companyId);const {data,error}=await q;if(error)throw error;return data||[];
  }
  async saveAccount(row){
    if(this.demo){const r={...row,id:row.id||uid(),active:row.active!==false};const i=this.demoData.accounts.findIndex(x=>x.id===r.id);if(i>=0)this.demoData.accounts[i]=r;else this.demoData.accounts.push(r);demoSave(this.demoData);return r;}
    const {data:{user}}=await this.client.auth.getUser();const payload={...row,updated_by:user?.id};if(!row.id)payload.created_by=user?.id;
    const {data,error}=await this.client.from('cash_accounts').upsert(payload).select().single();if(error)throw error;return data;
  }

  async listTransactions(companyId,{status,search,limit=300,fromDate,toDate}={}){
    if(this.demo){let rows=this.demoData.transactions.filter(x=>companyId==='all'||x.company_id===companyId);if(status)rows=rows.filter(x=>x.classification_status===status);if(search){const s=search.toLowerCase();rows=rows.filter(x=>`${x.counterparty} ${x.bank_summary} ${x.memo}`.toLowerCase().includes(s))}return rows.sort((a,b)=>String(b.transaction_at).localeCompare(String(a.transaction_at))).slice(0,limit);}
    let q=this.client.from('bank_transactions').select('*,finance_categories!bank_transactions_category_id_fkey(name),suggested:finance_categories!bank_transactions_suggested_category_id_fkey(name),cash_accounts(bank_name,account_name)').order('transaction_at',{ascending:false}).limit(limit);
    q=this._companyFilter(q,companyId);if(status)q=q.eq('classification_status',status);if(search)q=q.or(`counterparty.ilike.%${search}%,bank_summary.ilike.%${search}%,memo.ilike.%${search}%`);if(fromDate)q=q.gte('transaction_at',`${fromDate}T00:00:00`);if(toDate)q=q.lte('transaction_at',`${toDate}T23:59:59`);
    const {data,error}=await q;if(error)throw error;return data||[];
  }
  async countTransactions(companyId,status='unreviewed'){
    if(this.demo)return this.demoData.transactions.filter(x=>(companyId==='all'||x.company_id===companyId)&&x.classification_status===status).length;
    let q=this.client.from('bank_transactions').select('*',{count:'exact',head:true}).eq('classification_status',status);q=this._companyFilter(q,companyId);const {count,error}=await q;if(error)throw error;return count||0;
  }
  async updateTransaction(id,patch){
    if(this.demo){const i=this.demoData.transactions.findIndex(x=>x.id===id);this.demoData.transactions[i]={...this.demoData.transactions[i],...patch};demoSave(this.demoData);return this.demoData.transactions[i];}
    const {data:{user}}=await this.client.auth.getUser();const {data,error}=await this.client.from('bank_transactions').update({...patch,updated_by:user?.id}).eq('id',id).select().single();if(error)throw error;return data;
  }
  async bulkInsertTransactions(rows){
    if(this.demo){let inserted=0,duplicates=0;for(const row of rows){if(this.demoData.transactions.some(x=>x.company_id===row.company_id&&x.source_hash===row.source_hash)){duplicates++;continue}this.demoData.transactions.push({...row,id:uid(),created_at:new Date().toISOString()});inserted++;}demoSave(this.demoData);return {inserted,duplicates};}
    let inserted=0,duplicates=0;
    for(const part of chunk(rows,400)){
      const {data,error}=await this.client.from('bank_transactions').upsert(part,{onConflict:'company_id,source_hash',ignoreDuplicates:true}).select('id');
      if(error)throw error;inserted+=data?.length||0;duplicates+=part.length-(data?.length||0);
    }
    return {inserted,duplicates};
  }
  async createImportBatch(row){
    if(this.demo){const r={...row,id:uid(),imported_at:new Date().toISOString()};this.demoData.importBatches=this.demoData.importBatches||[];this.demoData.importBatches.push(r);demoSave(this.demoData);return r;}
    const {data:{user}}=await this.client.auth.getUser();const {data,error}=await this.client.from('import_batches').insert({...row,uploaded_by:user?.id}).select().single();if(error)throw error;return data;
  }
  async updateImportBatch(id,patch){if(this.demo)return;const {error}=await this.client.from('import_batches').update(patch).eq('id',id);if(error)throw error;}
  async uploadOriginalFile(companyId,file){
    if(this.demo)return `demo/${file.name}`;
    const {data:{user}}=await this.client.auth.getUser();const safe=file.name.replace(/[^a-zA-Z0-9가-힣._-]/g,'_');const path=`${companyId}/${user.id}/${Date.now()}_${safe}`;
    const {error}=await this.client.storage.from('finance-files').upload(path,file,{upsert:false,contentType:file.type||'application/octet-stream'});if(error)throw error;return path;
  }

  async listSchedules(companyId,{fromDate,toDate,status}={}){
    if(this.demo){let rows=this.demoData.schedules.filter(x=>companyId==='all'||x.company_id===companyId);if(fromDate)rows=rows.filter(x=>x.due_date>=fromDate);if(toDate)rows=rows.filter(x=>x.due_date<=toDate);if(status)rows=rows.filter(x=>x.status===status);return rows.sort((a,b)=>a.due_date.localeCompare(b.due_date));}
    let q=this.client.from('schedules').select('*,owner:profiles!schedules_owner_id_fkey(full_name),matched:bank_transactions!schedules_matched_transaction_id_fkey(id,counterparty,inflow,outflow,transaction_at)').order('due_date');q=this._companyFilter(q,companyId);if(fromDate)q=q.gte('due_date',fromDate);if(toDate)q=q.lte('due_date',toDate);if(status)q=q.eq('status',status);const {data,error}=await q;if(error)throw error;return data||[];
  }
  async countOverdue(companyId){const today=isoDate();if(this.demo)return this.demoData.schedules.filter(x=>(companyId==='all'||x.company_id===companyId)&&x.due_date<today&&!['matched','completed','cancelled'].includes(x.status)).length;let q=this.client.from('schedules').select('*',{count:'exact',head:true}).lt('due_date',today).not('status','in','("matched","completed","cancelled")');q=this._companyFilter(q,companyId);const {count,error}=await q;if(error)throw error;return count||0;}
  async saveSchedule(row){
    if(this.demo){const r={...row,id:row.id||uid(),status:row.status||'planned'};const i=this.demoData.schedules.findIndex(x=>x.id===r.id);if(i>=0)this.demoData.schedules[i]=r;else this.demoData.schedules.push(r);demoSave(this.demoData);return r;}
    const {data:{user}}=await this.client.auth.getUser();const payload={...row,updated_by:user?.id};if(!row.id)payload.created_by=user?.id;const {data,error}=await this.client.from('schedules').upsert(payload).select().single();if(error)throw error;return data;
  }
  async deleteSchedule(id){if(this.demo){this.demoData.schedules=this.demoData.schedules.filter(x=>x.id!==id);demoSave(this.demoData);return;}const {error}=await this.client.from('schedules').delete().eq('id',id);if(error)throw error;}

  async getExchangeRates(){if(this.demo)return {base:'KRW',updated_at:new Date().toISOString(),rates:{USD:1380,EUR:1490,JPY:9.2,CNY:190,THB:40}};return callFunction(this.runtime,'exchange-rates',{method:'GET'});}

  async listProducts(companyId){
    if(this.demo)return this.demoData.products.filter(x=>companyId==='all'||x.company_id===companyId);
    let q=this.client.from('financial_products').select('*').eq('active',true).order('maturity_date');q=this._companyFilter(q,companyId);const {data,error}=await q;if(error)throw error;return data||[];
  }
  async saveProduct(row){if(this.demo){const r={...row,id:row.id||uid(),active:row.active!==false};const i=this.demoData.products.findIndex(x=>x.id===r.id);if(i>=0)this.demoData.products[i]=r;else this.demoData.products.push(r);demoSave(this.demoData);return r;}const {data:{user}}=await this.client.auth.getUser();const payload={...row,updated_by:user?.id};if(!row.id)payload.created_by=user?.id;const {data,error}=await this.client.from('financial_products').upsert(payload).select().single();if(error)throw error;return data;}

  async listMonthlyPlans(companyId,year=new Date().getFullYear()){
    if(this.demo)return this.demoData.monthlyPlans.filter(x=>(companyId==='all'||x.company_id===companyId)&&x.plan_year===year);
    let q=this.client.from('monthly_plans').select('*').eq('plan_year',year).order('plan_month');q=this._companyFilter(q,companyId);const {data,error}=await q;if(error)throw error;return data||[];
  }
  async upsertMonthlyPlans(rows){if(this.demo){for(const r of rows){const i=this.demoData.monthlyPlans.findIndex(x=>x.company_id===r.company_id&&x.plan_year===r.plan_year&&x.plan_month===r.plan_month);if(i>=0)this.demoData.monthlyPlans[i]={...this.demoData.monthlyPlans[i],...r};else this.demoData.monthlyPlans.push({...r,id:uid()});}demoSave(this.demoData);return;}const {data:{user}}=await this.client.auth.getUser();const payload=rows.map(r=>({...r,updated_by:user?.id,created_by:r.created_by||user?.id}));const {error}=await this.client.from('monthly_plans').upsert(payload,{onConflict:'company_id,plan_year,plan_month'});if(error)throw error;}

  async listAssets(companyId){if(this.demo)return this.demoData.assetPositions.filter(x=>companyId==='all'||x.company_id===companyId);let q=this.client.from('asset_positions').select('*').order('as_of_date',{ascending:false});q=this._companyFilter(q,companyId);const {data,error}=await q;if(error)throw error;return data||[];}
  async upsertAssets(rows){if(this.demo){this.demoData.assetPositions.push(...rows.map(r=>({...r,id:uid()})));demoSave(this.demoData);return;}const {data:{user}}=await this.client.auth.getUser();const {error}=await this.client.from('asset_positions').upsert(rows.map(r=>({...r,updated_by:user?.id,created_by:r.created_by||user?.id})),{onConflict:'company_id,as_of_date,asset_type'});if(error)throw error;}

  async getDashboardData(companyId){const [companies,accounts,schedules,products,monthlyPlans,reports]=await Promise.all([this.listCompanies(),this.listAccounts(companyId),this.listSchedules(companyId),this.listProducts(companyId),this.listMonthlyPlans(companyId),this.listReports(companyId)]);return {companies,accounts,schedules,products,monthlyPlans,reports};}

  async listReports(companyId){
    if(this.demo)return this.demoData.reports.filter(x=>companyId==='all'||x.company_id===companyId).sort((a,b)=>String(b.created_at).localeCompare(String(a.created_at)));
    let q=this.client.from('reports').select('*,creator:profiles!reports_created_by_fkey(full_name),approval_steps(*,approver:profiles!approval_steps_approver_id_fkey(full_name,email))').order('created_at',{ascending:false});q=this._companyFilter(q,companyId);const {data,error}=await q;if(error)throw error;return data||[];
  }
  async getReport(id){if(this.demo){const r=this.demoData.reports.find(x=>x.id===id);return {...r,approval_steps:this.demoData.approvals.filter(a=>a.report_id===id)};}const {data,error}=await this.client.from('reports').select('*,creator:profiles!reports_created_by_fkey(full_name,email),approval_steps(*,approver:profiles!approval_steps_approver_id_fkey(full_name,email)),report_versions(*)').eq('id',id).single();if(error)throw error;return data;}
  async saveReport(row){if(this.demo){const r={...row,id:row.id||uid(),created_by:row.created_by||this.demoUser.id,created_at:row.created_at||new Date().toISOString(),status:row.status||'draft',current_version:row.current_version||0};const i=this.demoData.reports.findIndex(x=>x.id===r.id);if(i>=0)this.demoData.reports[i]=r;else this.demoData.reports.push(r);demoSave(this.demoData);return r;}const {data:{user}}=await this.client.auth.getUser();const payload={...row,created_by:row.created_by||user.id};const {data,error}=await this.client.from('reports').upsert(payload).select().single();if(error)throw error;return data;}
  async submitReport(reportId,approverIds){if(this.demo){const report=this.demoData.reports.find(r=>r.id===reportId);report.status='submitted';report.current_version=(report.current_version||0)+1;this.demoData.approvals=this.demoData.approvals.filter(a=>a.report_id!==reportId);approverIds.forEach((id,i)=>this.demoData.approvals.push({id:uid(),report_id:reportId,sequence_no:i+1,approver_id:id,status:'pending',reports:report}));demoSave(this.demoData);return report;}const {data,error}=await this.client.rpc('submit_report',{p_report_id:reportId,p_approver_ids:approverIds});if(error)throw error;return data;}
  async archiveReport(reportId){if(this.demo){const r=this.demoData.reports.find(x=>x.id===reportId);r.status='archived';demoSave(this.demoData);return r;}const {data,error}=await this.client.rpc('archive_report',{p_report_id:reportId});if(error)throw error;return data;}

  async listApprovals(){
    if(this.demo)return this.demoData.approvals.filter(a=>a.approver_id===this.demoUser.id&&a.status==='pending');
    const {data:{user}}=await this.client.auth.getUser();const {data,error}=await this.client.from('approval_steps').select('*,reports(*,creator:profiles!reports_created_by_fkey(full_name,email))').eq('approver_id',user.id).eq('status','pending').order('created_at');if(error)throw error;return data||[];
  }
  async actApproval(stepId,action,comment){if(this.demo){const step=this.demoData.approvals.find(a=>a.id===stepId);step.status=action==='approve'?'approved':'rejected';step.comment=comment;const r=this.demoData.reports.find(x=>x.id===step.report_id);r.status=action==='approve'?'approved':'rejected';demoSave(this.demoData);return r;}const {data,error}=await this.client.rpc('act_on_report',{p_step_id:stepId,p_action:action,p_comment:comment||null});if(error)throw error;return data;}
  async countApprovals(){return (await this.listApprovals()).length;}

  async listAudit(companyId,{tableName,recordId,limit=200}={}){
    if(this.demo)return this.demoData.audits.slice(-limit).reverse();
    let q=this.client.from('audit_logs').select('*,changer:profiles!audit_logs_changed_by_fkey(full_name,email)').order('changed_at',{ascending:false}).limit(limit);q=this._companyFilter(q,companyId);if(tableName)q=q.eq('table_name',tableName);if(recordId)q=q.eq('record_id',recordId);const {data,error}=await q;if(error)throw error;return data||[];
  }

  async adminListUsers(){if(this.demo)return {users:this.demoData.users.map(u=>({...u,memberships:this.demoData.memberships.filter(m=>m.user_id===u.id),module_assignments:[]}))};return callFunction(this.runtime,'admin-users',{method:'POST',body:{action:'list'}});}
  async adminCreateUser(payload){if(this.demo)throw new Error('데모 모드에서는 사용자 생성이 불가합니다.');return callFunction(this.runtime,'admin-users',{body:{action:'create',...payload}});}
  async adminUpdateUser(payload){if(this.demo)throw new Error('데모 모드에서는 사용자 수정이 불가합니다.');return callFunction(this.runtime,'admin-users',{body:{action:'update',...payload}});}
  async downloadBackup(){if(this.demo){return {format:'changjin-finance-backup-v1',exported_at:new Date().toISOString(),data:this.demoData};}return callFunction(this.runtime,'full-backup',{method:'GET'});}
  async restoreBackup(backup){if(this.demo){this.demoData=backup.data;demoSave(this.demoData);return {ok:true};}return callFunction(this.runtime,'restore-backup',{body:backup,headers:{'X-Confirm-Restore':'RESTORE'}});}

  async importLegacy(parsed,companies,currentYear=new Date().getFullYear()){
    const map=new Map(companies.map(c=>[c.name.replace(/\s/g,''),c.id]));
    if(parsed.kind==='cash_plan')throw new Error('자금계획서는 일정 가져오기 기능을 사용하세요.');
    const d=parsed.rows;
    for(const row of d.cash||[]){const id=map.get(row.company_name.replace(/\s/g,''));if(!id)continue;const accounts=await this.listAccounts(id);const account=accounts[0]||await this.saveAccount({company_id:id,bank_name:'미지정',account_name:'기존자료 이관',current_balance:0,required_reserve:0,active:true});await this.saveAccount({...account,current_balance:row.current_balance,required_reserve:row.required_reserve});}
    const monthly=(d.monthly||[]).map(r=>{const id=map.get(r.company_name.replace(/\s/g,''));return id?{company_id:id,plan_year:currentYear,plan_month:r.plan_month,income:r.income,salary:r.salary,trade_payables:r.trade_payables,interest_expense:r.interest_expense,other_expense:r.other_expense}:null}).filter(Boolean);if(monthly.length)await this.upsertMonthlyPlans(monthly);
    for(const row of d.schedules||[]){const id=map.get(row.company_name.replace(/\s/g,''));if(id)await this.saveSchedule({...row,company_id:id,status:'planned',source:'legacy_import'});}
    const assets=(d.assets||[]).map(r=>{const id=map.get(r.company_name.replace(/\s/g,''));return id?{company_id:id,as_of_date:isoDate(),asset_type:r.asset_type,amount:r.amount,target_ratio:r.target_ratio}:null}).filter(Boolean);if(assets.length)await this.upsertAssets(assets);
    for(const row of d.products||[]){const id=map.get(row.company_name.replace(/\s/g,''));if(id)await this.saveProduct({...row,company_id:id,active:true});}
    return {cash:d.cash?.length||0,monthly:monthly.length,schedules:d.schedules?.length||0,assets:assets.length,products:d.products?.length||0};
  }
}

begin;
create table if not exists public.work_checkpoints (
 id uuid primary key default gen_random_uuid(), label text not null,
 created_at timestamptz not null default now(), created_by uuid references public.profiles(id), payload jsonb not null
);
alter table public.work_checkpoints enable row level security;
revoke all on public.work_checkpoints from anon,authenticated;
create or replace function public.create_checkpoint(p_label text) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자만 작업 백업을 만들 수 있습니다.'; end if;
 lock table public.companies,public.finance_categories,public.cash_accounts,public.import_batches,public.schedules,public.bank_transactions,public.financial_products,public.monthly_plans,public.asset_positions,public.reports,public.report_versions,public.approval_steps,public.internal_transfers in share mode;
 insert into public.work_checkpoints(label,created_by,payload) values(left(coalesce(p_label,'작업 백업'),200),auth.uid(),public.export_finance_backup()) returning id into result;
 return result;
end $$;
create or replace function public.list_checkpoints() returns table(id uuid,label text,created_at timestamptz)
language plpgsql security definer set search_path='' as $$
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자가 필요합니다.'; end if;
 return query select c.id,c.label,c.created_at from public.work_checkpoints c order by c.created_at desc limit 100;
end $$;
-- 이전 병합 복원을 내부 함수로 보관합니다.
create or replace function public.merge_finance_backup_internal(p_backup jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t text; rows jsonb; cols text; updates text; links_s jsonb; links_t jsonb; r jsonb;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자 기기가 필요합니다.'; end if;
 if p_backup->>'format' is distinct from 'changjin-finance-backup-v2' or jsonb_typeof(p_backup->'data') is distinct from 'object' then raise exception '이 버전에서 생성한 업무 백업만 복원할 수 있습니다.'; end if;
 -- 보안 권한·감사로그·기기 승인은 복원으로 변경하지 않습니다.
 links_s:=coalesce(p_backup->'data'->'schedules','[]'); links_t:=coalesce(p_backup->'data'->'bank_transactions','[]');
 foreach t in array array['companies','finance_categories','cash_accounts','import_batches','schedules','bank_transactions','financial_products','monthly_plans','asset_positions','reports','report_versions','approval_steps','internal_transfers'] loop
  rows:=p_backup->'data'->t;if t='internal_transfers' and rows is null then rows:='[]'::jsonb;end if;
  if jsonb_typeof(rows) is distinct from 'array' then raise exception '백업에 필수 테이블 %가 없거나 형식이 잘못되었습니다.',t; end if;
  if t='schedules' then select coalesce(jsonb_agg(value||'{"matched_transaction_id":null}'::jsonb),'[]') into rows from jsonb_array_elements(rows); end if;
  if t='bank_transactions' then select coalesce(jsonb_agg(value||'{"matched_schedule_id":null}'::jsonb),'[]') into rows from jsonb_array_elements(rows); end if;
  select string_agg(format('%I',column_name),',' order by ordinal_position),string_agg(format('%I=excluded.%I',column_name,column_name),',' order by ordinal_position) filter(where column_name<>'id')
  into cols,updates from information_schema.columns where table_schema='public' and table_name=t;
  execute format('insert into public.%1$I(%2$s) select %2$s from jsonb_populate_recordset(null::public.%1$I,$1) on conflict(id) do update set %3$s',t,cols,updates) using rows;
 end loop;
 for r in select value from jsonb_array_elements(links_s) loop update public.schedules set matched_transaction_id=(r->>'matched_transaction_id')::uuid where id=(r->>'id')::uuid; end loop;
 for r in select value from jsonb_array_elements(links_t) loop update public.bank_transactions set matched_schedule_id=(r->>'matched_schedule_id')::uuid where id=(r->>'id')::uuid; end loop;
 insert into public.audit_logs(table_name,action,changed_by,new_data) values('backup','RESTORE',auth.uid(),jsonb_build_object('exported_at',p_backup->>'exported_at'));
 return jsonb_build_object('ok',true);
end $$;

create or replace function public.restore_finance_backup(p_backup jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t text; result jsonb; safety uuid;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자가 필요합니다.'; end if;
 if p_backup->>'format' is distinct from 'changjin-finance-backup-v2' then raise exception '지원하지 않는 백업입니다.'; end if;
 foreach t in array array['companies','finance_categories','cash_accounts','import_batches','schedules','bank_transactions','financial_products','monthly_plans','asset_positions','reports','report_versions','approval_steps'] loop
  if jsonb_typeof(p_backup->'data'->t) is distinct from 'array' then raise exception '필수 자료 %가 없습니다.',t; end if;
 end loop;
 lock table public.companies,public.finance_categories,public.cash_accounts,public.import_batches,public.schedules,public.bank_transactions,public.financial_products,public.monthly_plans,public.asset_positions,public.reports,public.report_versions,public.approval_steps,public.internal_transfers in exclusive mode;
 safety:=public.create_checkpoint('복원 직전 자동 백업');
 delete from public.internal_transfers;
 update public.schedules set matched_transaction_id=null where matched_transaction_id is not null;
 update public.bank_transactions set matched_schedule_id=null where matched_schedule_id is not null;
 delete from public.approval_steps;
 delete from public.report_versions;
 delete from public.reports;
 delete from public.bank_transactions;
 delete from public.schedules;
 delete from public.import_batches;
 delete from public.financial_products;
 delete from public.monthly_plans;
 delete from public.asset_positions;
 delete from public.cash_accounts;
 delete from public.finance_categories;
 -- 사용자 권한이 참조하는 법인은 보존하고 추가 법인은 비활성화합니다.
 update public.companies set active=false where id not in(select (v->>'id')::uuid from jsonb_array_elements(p_backup->'data'->'companies') v);
 perform set_config('app.restoring_finance','yes',true);
 result:=public.merge_finance_backup_internal(p_backup);
 perform set_config('app.restoring_finance','no',true);
 return result||jsonb_build_object('safety_checkpoint',safety);
end $$;
create or replace function public.restore_checkpoint(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare backup jsonb;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자가 필요합니다.'; end if;
 select payload into backup from public.work_checkpoints where id=p_id;
 if backup is null then raise exception '백업을 찾을 수 없습니다.'; end if;
 return public.restore_finance_backup(backup);
end $$;
create or replace function public.reconcile_account(p_id uuid,p_force boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.cash_accounts; latest public.bank_transactions; distinct_balances integer;
begin
 select * into a from public.cash_accounts where id=p_id for update;
 if a.id is null or not public.device_allowed() or not public.can_manage_finance(a.company_id) then raise exception '계좌 수정 권한이 필요합니다.'; end if;
 select * into latest from public.bank_transactions where account_id=p_id and balance is not null order by transaction_at desc,created_at desc,id desc limit 1;
 if latest.id is null then return jsonb_build_object('status','no_data'); end if;
 select count(distinct balance) into distinct_balances from public.bank_transactions where account_id=p_id and transaction_at=latest.transaction_at and balance is not null;
 if distinct_balances>1 then return jsonb_build_object('status','ambiguous','message','최신 시각의 잔액이 여러 개입니다. 은행 원본을 확인하세요.'); end if;
 if not p_force and a.balance_as_of>latest.transaction_at then return jsonb_build_object('status','older','balance',latest.balance,'at',latest.transaction_at); end if;
 update public.cash_accounts set current_balance=latest.balance,balance_as_of=latest.transaction_at,updated_by=auth.uid() where id=p_id;
 return jsonb_build_object('status','updated','balance',latest.balance,'at',latest.transaction_at);
end $$;
-- 다른 업로드의 같은 거래는 원본 식별값이 달라도 제외합니다.
create or replace function public.skip_reuploaded_transaction() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if current_setting('app.restoring_finance',true)='yes' then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended(new.account_id::text,250));
 if new.balance is not null and exists(select 1 from public.bank_transactions t where t.account_id=new.account_id
 and t.transaction_at=new.transaction_at and t.inflow=new.inflow and t.outflow=new.outflow
 and t.balance is not distinct from new.balance and coalesce(t.counterparty,'')=coalesce(new.counterparty,'')
 and coalesce(t.bank_summary,'')=coalesce(new.bank_summary,'')
 and t.import_batch_id is distinct from new.import_batch_id) then return null; end if;
 return new;
end $$;
drop trigger if exists skip_reuploaded_transaction on public.bank_transactions;
create trigger skip_reuploaded_transaction before insert on public.bank_transactions for each row execute function public.skip_reuploaded_transaction();
revoke all on function public.merge_finance_backup_internal(jsonb),public.skip_reuploaded_transaction() from public,anon,authenticated;
revoke all on function public.create_checkpoint(text),public.list_checkpoints(),public.restore_checkpoint(uuid),public.reconcile_account(uuid,boolean) from public,anon,authenticated;
grant execute on function public.create_checkpoint(text),public.list_checkpoints(),public.restore_checkpoint(uuid),public.reconcile_account(uuid,boolean) to authenticated;
create or replace function public.clean_duplicate_transactions() returns integer
language plpgsql security definer set search_path='' as $$
declare removed integer;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자가 필요합니다.'; end if;
 lock table public.bank_transactions,public.schedules,public.internal_transfers in exclusive mode;
 perform public.create_checkpoint('기존 중복 정리 전');
 with ranked as (
 select t.id,row_number() over(partition by account_id,transaction_at,inflow,outflow,balance,coalesce(counterparty,''),coalesce(bank_summary,'') order by created_at,id) rn
 from public.bank_transactions t
 ), candidates as (
 select t.id from public.bank_transactions t join ranked r on r.id=t.id where r.rn>1
 and t.balance is not null and t.classification_status='unreviewed' and t.matched_schedule_id is null
 and not exists(select 1 from public.schedules s where s.matched_transaction_id=t.id)
 and not exists(select 1 from public.internal_transfers x where x.bank_transaction_id=t.id or x.counterpart_transaction_id=t.id)
 and exists(select 1 from public.bank_transactions a join ranked ar on ar.id=a.id where ar.rn=1 and a.account_id=t.account_id and a.transaction_at=t.transaction_at and a.inflow=t.inflow and a.outflow=t.outflow and a.balance is not distinct from t.balance and coalesce(a.counterparty,'')=coalesce(t.counterparty,'') and coalesce(a.bank_summary,'')=coalesce(t.bank_summary,'') and a.import_batch_id is distinct from t.import_batch_id)
 ) delete from public.bank_transactions where id in(select id from candidates);
 get diagnostics removed=row_count;return removed;
end $$;
revoke all on function public.clean_duplicate_transactions() from public,anon,authenticated;
grant execute on function public.clean_duplicate_transactions() to authenticated;
commit;
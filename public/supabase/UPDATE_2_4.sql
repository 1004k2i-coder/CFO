begin;
alter table public.financial_products add column if not exists balance_as_of timestamptz default now();
alter table public.financial_products add column if not exists exchange_rate_at timestamptz;
alter table public.financial_products add column if not exists exchange_rate_fetched_at timestamptz;
create table if not exists public.internal_transfers(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id),
 bank_transaction_id uuid not null unique references public.bank_transactions(id) on delete restrict,
 counterpart_transaction_id uuid unique references public.bank_transactions(id) on delete restrict,
 target_account_id uuid references public.cash_accounts(id) on delete restrict,
 product_id uuid references public.financial_products(id) on delete restrict,
 amount numeric(20,2) not null check(amount>0),
 product_delta numeric(20,2) not null default 0,
 occurred_at timestamptz not null,
 status text not null check(status in ('pending','matched','product')),
 created_by uuid references public.profiles(id),created_at timestamptz not null default now(),
 check ((product_id is not null and target_account_id is null and counterpart_transaction_id is null and status='product') or (product_id is null and target_account_id is not null and ((counterpart_transaction_id is null and status='pending') or (counterpart_transaction_id is not null and status='matched'))))
);
alter table public.internal_transfers enable row level security;
drop policy if exists transfers_read on public.internal_transfers;
create policy transfers_read on public.internal_transfers for select to authenticated using(public.device_allowed() and public.has_company_access(company_id) and public.can_view_finance(company_id));
revoke all on public.internal_transfers from anon,authenticated;
grant select on public.internal_transfers to authenticated;

create or replace function public.check_internal_transfer() returns trigger language plpgsql security definer set search_path='' as $$
declare t public.bank_transactions; other public.bank_transactions; a public.cash_accounts; p public.financial_products; currency_code text;
begin
 perform pg_advisory_xact_lock(hashtext(new.company_id::text));
 select * into t from public.bank_transactions where id=new.bank_transaction_id;
 select currency into currency_code from public.cash_accounts where id=t.account_id;
 if t.company_id is distinct from new.company_id or t.account_id is null or currency_code is distinct from 'KRW' then raise exception '같은 법인의 원화 계좌 거래만 내부이체로 연결할 수 있습니다.'; end if;
 if not ((t.inflow>0 and t.outflow=0) or (t.outflow>0 and t.inflow=0)) or new.amount<>greatest(t.inflow,t.outflow) or new.occurred_at<>t.transaction_at then raise exception '내부이체 금액·일시 불일치'; end if;
 if exists(select 1 from public.internal_transfers x where x.id<>new.id and (x.bank_transaction_id=new.bank_transaction_id or x.counterpart_transaction_id=new.bank_transaction_id or (new.counterpart_transaction_id is not null and (x.bank_transaction_id=new.counterpart_transaction_id or x.counterpart_transaction_id=new.counterpart_transaction_id)))) then raise exception '이미 다른 내부이체에 연결된 거래입니다.'; end if;
 if new.product_id is not null then
  select * into p from public.financial_products where id=new.product_id;
  if p.company_id is distinct from new.company_id or p.currency<>'KRW' or p.product_type not in ('deposit','mmt','mmf','cma','other') then raise exception '같은 법인의 원화 예금·투자상품을 선택하세요.'; end if;
  if new.product_delta<>t.outflow-t.inflow then raise exception '상품 잔액 증감 불일치'; end if;
 else
  select * into a from public.cash_accounts where id=new.target_account_id;
  if a.company_id is distinct from new.company_id or a.id=t.account_id or a.currency<>'KRW' or new.product_delta<>0 then raise exception '다른 원화 계좌를 선택하세요.'; end if;
  if new.counterpart_transaction_id is not null then
   select * into other from public.bank_transactions where id=new.counterpart_transaction_id;
   if other.account_id is distinct from a.id or other.company_id is distinct from t.company_id or other.inflow<>t.outflow or other.outflow<>t.inflow or abs(extract(epoch from other.transaction_at-t.transaction_at))>604800 then raise exception '상대 거래의 계좌·입출금 방향·금액·일시가 맞지 않습니다.'; end if;
  end if;
 end if;
 return new;
end $$;
drop trigger if exists validate_internal_transfer on public.internal_transfers;
create trigger validate_internal_transfer before insert or update on public.internal_transfers for each row execute function public.check_internal_transfer();

create or replace function public.protect_linked_transaction() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.internal_transfers x where x.bank_transaction_id=old.id or x.counterpart_transaction_id=old.id) then
  if tg_op='DELETE' then raise exception '내부이체 연결을 먼저 해제하세요.'; end if;
  if new.account_id is distinct from old.account_id or new.company_id<>old.company_id or new.transaction_at<>old.transaction_at or new.inflow<>old.inflow or new.outflow<>old.outflow or new.classification_status<>'reviewed' or not exists(select 1 from public.finance_categories c where c.id=new.category_id and c.direction='transfer') then raise exception '연결된 내부이체는 먼저 연결 해제 후 수정하세요.'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;return new;
end $$;
drop trigger if exists protect_internal_transaction on public.bank_transactions;
create trigger protect_internal_transaction before update or delete on public.bank_transactions for each row execute function public.protect_linked_transaction();

create or replace function public.link_internal_transfer(p_transaction uuid,p_target_account uuid default null,p_product uuid default null,p_counterpart uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare t public.bank_transactions; p public.financial_products; transfer_id uuid; cat uuid; prior public.internal_transfers;
begin
 select * into t from public.bank_transactions where id=p_transaction;
 if t.id is null or not public.device_allowed() or not public.can_manage_finance(t.company_id) then raise exception '해당 법인의 재무관리 권한과 승인 기기가 필요합니다.'; end if;
 perform pg_advisory_xact_lock(hashtext(t.company_id::text));
 perform 1 from public.bank_transactions where id in (p_transaction,p_counterpart) order by id for update;
 select * into t from public.bank_transactions where id=p_transaction;
 if (p_target_account is null)=(p_product is null) then raise exception '은행 계좌 또는 금융상품 하나를 선택하세요.'; end if;
 select * into prior from public.internal_transfers where bank_transaction_id=p_transaction;
 if prior.id is not null and prior.target_account_id is not distinct from p_target_account and prior.product_id is not distinct from p_product and prior.counterpart_transaction_id is not distinct from p_counterpart then return prior.id; end if;
 if prior.id is not null and prior.status<>'pending' then raise exception '기존 연결을 먼저 해제하세요.'; end if;
 if p_product is not null then
  select * into p from public.financial_products where id=p_product for update;
  if not p.active or p.balance_as_of is null or t.transaction_at<=p.balance_as_of then raise exception '상품의 기준잔액·기준일을 거래 이전으로 설정하세요. 기준잔액에 이미 포함한 거래는 다시 연결하지 마세요.'; end if;
  if p.current_value+coalesce((select sum(x.product_delta) from public.internal_transfers x where x.product_id=p.id and x.occurred_at>p.balance_as_of),0)+t.outflow-t.inflow<0 then raise exception '상품의 계산 잔액이 음수입니다. 기준잔액과 누락 거래를 확인하세요.'; end if;
 else
  if not exists(select 1 from public.cash_accounts where id=p_target_account and active) then raise exception '사용 중인 상대 계좌를 선택하세요.'; end if;
 end if;
 select id into cat from public.finance_categories where direction='transfer' and active and (company_id=t.company_id or company_id is null) order by (company_id is not null) desc,sort_order,id limit 1;
 if cat is null then raise exception '내부거래 분류가 없습니다.'; end if;
 if prior.id is not null then delete from public.internal_transfers where id=prior.id; end if;
 insert into public.internal_transfers(company_id,bank_transaction_id,counterpart_transaction_id,target_account_id,product_id,amount,product_delta,occurred_at,status,created_by)
 values(t.company_id,t.id,p_counterpart,p_target_account,p_product,greatest(t.inflow,t.outflow),case when p_product is not null then t.outflow-t.inflow else 0 end,t.transaction_at,case when p_product is not null then 'product' when p_counterpart is not null then 'matched' else 'pending' end,auth.uid()) returning id into transfer_id;
 update public.bank_transactions set category_id=cat,classification_status='reviewed',updated_by=auth.uid() where id in(p_transaction,p_counterpart);
 return transfer_id;
end $$;
create or replace function public.unlink_internal_transfer(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare x public.internal_transfers;
begin
 select * into x from public.internal_transfers where id=p_id;
 if x.id is null or not public.device_allowed() or not public.can_manage_finance(x.company_id) then raise exception '해당 법인의 재무관리 권한이 필요합니다.'; end if;
 perform pg_advisory_xact_lock(hashtext(x.company_id::text));
 delete from public.internal_transfers where id=p_id;
 update public.bank_transactions set classification_status='unreviewed',category_id=null,updated_by=auth.uid() where id in(x.bank_transaction_id,x.counterpart_transaction_id);
end $$;
create or replace function public.product_transfer_totals() returns table(product_id uuid,adjustment numeric) language sql stable security invoker set search_path='' as $$
 select p.id,coalesce(sum(x.product_delta) filter(where x.occurred_at>p.balance_as_of),0) from public.financial_products p left join public.internal_transfers x on x.product_id=p.id group by p.id;
$$;

create or replace function public.review_transactions(p_rows jsonb,p_confirm boolean default true) returns integer language plpgsql security definer set search_path='' as $$
declare r jsonb; t public.bank_transactions; c public.finance_categories; sid uuid; n integer:=0;
begin
 if not public.device_allowed() or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>500 then raise exception '승인 기기에서 최대 500건씩 처리하세요.'; end if;
 for r in select value from jsonb_array_elements(p_rows) loop
  select * into t from public.bank_transactions where id=(r->>'id')::uuid for update;
  if t.id is null or not public.has_company_access(t.company_id) or not (public.can_manage_finance(t.company_id) or t.owner_id=auth.uid() or t.created_by=auth.uid()) then raise exception '변경 권한이 없는 거래가 포함되어 있습니다.'; end if;
  select * into c from public.finance_categories where id=(r->>'category_id')::uuid;
  if c.id is null or not c.active or (c.company_id is not null and c.company_id<>t.company_id) then raise exception '유효한 확정 분류를 선택하세요.'; end if;
  if c.direction='transfer' and not exists(select 1 from public.internal_transfers x where x.bank_transaction_id=t.id or x.counterpart_transaction_id=t.id) then raise exception '내부거래는 상대 은행 또는 상품을 먼저 연결하세요.'; end if;
  sid:=case when r ? 'matched_schedule_id' then nullif(r->>'matched_schedule_id','')::uuid else t.matched_schedule_id end;
  if t.matched_schedule_id is not null and t.matched_schedule_id is distinct from sid then raise exception '기존 예정 연결을 별도로 정리한 뒤 변경하세요.'; end if;
  if sid is not null then
   if not exists(select 1 from public.schedules s where s.id=sid and s.company_id=t.company_id and (s.matched_transaction_id is null or s.matched_transaction_id=t.id)) then raise exception '예정 연결을 확인하세요.'; end if;
   if not public.can_manage_finance(t.company_id) and not exists(select 1 from public.schedules s where s.id=sid and (s.owner_id=auth.uid() or s.created_by=auth.uid())) then raise exception '해당 일정 수정 권한이 없습니다.'; end if;
  end if;
  update public.bank_transactions set category_id=c.id,classification_status=case when p_confirm then 'reviewed' else 'unreviewed' end,matched_schedule_id=sid,owner_id=case when r ? 'owner_id' then nullif(r->>'owner_id','')::uuid else owner_id end,updated_by=auth.uid() where id=t.id;
  if p_confirm and sid is not null then update public.schedules set status='matched',matched_transaction_id=t.id,updated_by=auth.uid() where id=sid; end if;
  n:=n+1;
 end loop;
 return n;
end $$;
create or replace function public.delete_schedules_batch(p_ids uuid[]) returns integer language plpgsql security definer set search_path='' as $$
declare s public.schedules; n integer:=0; wanted integer;
begin
 if not public.device_allowed() or coalesce(cardinality(p_ids),0)=0 or cardinality(p_ids)>500 then raise exception '최대 500건의 일정을 선택하세요.'; end if;
 select count(distinct x) into wanted from unnest(p_ids) x;
 for s in select * from public.schedules where id=any(p_ids) order by id for update loop
  if not public.has_company_access(s.company_id) or not(public.can_manage_finance(s.company_id) or s.created_by=auth.uid()) then raise exception '삭제 권한이 없는 일정이 포함되어 있습니다.'; end if;
  if s.matched_transaction_id is not null or exists(select 1 from public.bank_transactions t where t.matched_schedule_id=s.id) then raise exception '실제 거래와 연결된 일정이 포함되어 있습니다. 연결을 먼저 확인하세요.'; end if;
  n:=n+1;
 end loop;
 if n<>wanted then raise exception '이미 삭제되었거나 찾을 수 없는 일정이 있습니다. 새로고침하세요.'; end if;
 delete from public.schedules where id=any(p_ids);return n;
end $$;
create or replace function public.apply_exchange_rates(p_company uuid,p_rates jsonb,p_rate_at timestamptz,p_fetched_at timestamptz) returns integer language plpgsql security definer set search_path='' as $$
declare p public.financial_products; rate numeric; n integer:=0;
begin
 if not public.device_allowed() then raise exception '승인된 기기가 필요합니다.'; end if;
 if p_rate_at is null or p_fetched_at is null then raise exception '환율 기준시각을 확인하세요.'; end if;
 for p in select * from public.financial_products where active and currency<>'KRW' and (p_company is null or company_id=p_company) and public.has_company_access(company_id) for update loop
  if not public.can_manage_finance(p.company_id) then continue; end if;
  rate:=(p_rates->>upper(p.currency))::numeric;
  if rate is null or rate<=0 then raise exception '% 환율이 없습니다. 기존 환율을 유지합니다.',p.currency; end if;
  update public.financial_products set exchange_rate=rate,exchange_rate_at=p_rate_at,exchange_rate_fetched_at=p_fetched_at,updated_by=auth.uid() where id=p.id;n:=n+1;
 end loop;return n;
end $$;
-- 직접 수정 권한 없이 읽기/RPC만 허용합니다.
revoke all on function public.check_internal_transfer(),public.protect_linked_transaction(),public.link_internal_transfer(uuid,uuid,uuid,uuid),public.unlink_internal_transfer(uuid),public.product_transfer_totals(),public.review_transactions(jsonb,boolean),public.delete_schedules_batch(uuid[]),public.apply_exchange_rates(uuid,jsonb,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.link_internal_transfer(uuid,uuid,uuid,uuid),public.unlink_internal_transfer(uuid),public.product_transfer_totals(),public.review_transactions(jsonb,boolean),public.delete_schedules_batch(uuid[]),public.apply_exchange_rates(uuid,jsonb,timestamptz,timestamptz) to authenticated;
drop trigger if exists audit_internal_transfers on public.internal_transfers;
create trigger audit_internal_transfers after insert or update or delete on public.internal_transfers for each row execute function public.audit_row_change();
create or replace function public.export_finance_backup()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t text; rows jsonb; data jsonb:='{}';
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '전체 백업은 승인된 관리자 기기에서만 가능합니다.'; end if;
 foreach t in array array['companies','profiles','company_memberships','module_assignments','finance_categories','cash_accounts','import_batches','schedules','bank_transactions','financial_products','monthly_plans','asset_positions','reports','report_versions','approval_steps','audit_logs','internal_transfers'] loop
  execute format('select coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) from public.%I t',t) into rows;
  data:=data||jsonb_build_object(t,rows);
 end loop;
 return jsonb_build_object('format','changjin-finance-backup-v2','exported_at',now(),'data',data,
 'note','업무 데이터 백업입니다. 로그인 계정·비밀번호·기기 인증·Storage 원본 파일은 포함하지 않습니다.');
end $$;

create or replace function public.restore_finance_backup(p_backup jsonb)
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


commit;

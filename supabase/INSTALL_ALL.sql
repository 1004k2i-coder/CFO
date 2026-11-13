-- 신규 Supabase 프로젝트용 통합 설치 SQL입니다. 파일 전체를 한 번 실행하세요.
-- 먼저 Authentication → Users에서 관리자 계정을 생성하세요.
-- 아래 이메일 한 곳만 실제 관리자 이메일로 수정하세요.
begin;
select set_config('finance.install_admin_email','CHANGE_ME@example.com',true);
-- Changjin SC Finance Management Web App
-- Supabase / PostgreSQL schema, RLS, audit trail and approval workflow

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- =========================================================
-- 1. Core master data
-- =========================================================
create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  business_no text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text not null default '',
  department text,
  job_title text,
  role text not null default 'business_user' check (role in (
    'admin','finance_manager','finance_staff','business_user','approver','executive','auditor'
  )),
  active boolean not null default true,
  default_company_id uuid references public.companies(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 사용자 승인 상태를 추가합니다. 기존 계정과 기기는 유지합니다.
alter table public.profiles add column if not exists approval_status text not null default 'approved' check(approval_status in ('pending','approved','rejected'));
alter table public.profiles add column if not exists approved_at timestamptz;
alter table public.profiles add column if not exists approved_by uuid references public.profiles(id);
alter table public.profiles alter column approval_status set default 'pending';
alter table public.profiles alter column active set default false;


create table if not exists public.company_memberships (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  access_level text not null default 'read' check (access_level in ('read','contribute','finance','manage')),
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);

create table if not exists public.module_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  company_id uuid references public.companies(id) on delete cascade,
  module_code text not null check (module_code in (
    'home','bank_upload','transactions','schedules','accounts','reports','approvals','dashboard','admin','audit'
  )),
  can_view boolean not null default true,
  can_create boolean not null default false,
  can_update boolean not null default false,
  can_delete boolean not null default false,
  can_approve boolean not null default false,
  created_at timestamptz not null default now(),
  unique(user_id, company_id, module_code)
);

-- =========================================================
-- 2. Finance master and transaction data
-- =========================================================
create table if not exists public.finance_categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  name text not null,
  direction text not null default 'mixed' check (direction in ('receipt','payment','transfer','mixed')),
  parent_id uuid references public.finance_categories(id) on delete set null,
  keywords text[] not null default '{}',
  active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists finance_categories_unique_name
  on public.finance_categories(coalesce(company_id, '00000000-0000-0000-0000-000000000000'::uuid), name);

create table if not exists public.cash_accounts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bank_name text not null,
  account_name text not null,
  account_number_masked text,
  account_type text not null default 'operating',
  currency text not null default 'KRW',
  current_balance numeric(20,2) not null default 0,
  required_reserve numeric(20,2) not null default 0,
  balance_as_of timestamptz,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.import_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  account_id uuid references public.cash_accounts(id) on delete set null,
  source_type text not null default 'bank_file' check (source_type in ('bank_file','legacy_template','cash_plan','manual','restore')),
  file_name text not null,
  file_hash text,
  storage_path text,
  row_count integer not null default 0,
  imported_count integer not null default 0,
  duplicate_count integer not null default 0,
  status text not null default 'completed' check (status in ('preview','processing','completed','failed','cancelled')),
  notes text,
  uploaded_by uuid references public.profiles(id) on delete set null,
  imported_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.schedules (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  direction text not null check (direction in ('receipt','payment','transfer')),
  due_date date not null,
  counterparty text,
  description text not null default '',
  amount numeric(20,2) not null default 0,
  probability numeric(5,2) not null default 100 check (probability >= 0 and probability <= 100),
  priority text not null default 'normal' check (priority in ('high','normal','low')),
  status text not null default 'planned' check (status in ('planned','matched','completed','overdue','cancelled')),
  owner_id uuid references public.profiles(id) on delete set null,
  recurring_rule jsonb not null default '{}'::jsonb,
  matched_transaction_id uuid,
  source text not null default 'manual',
  memo text,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bank_transactions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  account_id uuid references public.cash_accounts(id) on delete set null,
  import_batch_id uuid references public.import_batches(id) on delete set null,
  transaction_at timestamptz not null,
  bank_summary text,
  bank_code text,
  counterparty text,
  inflow numeric(20,2) not null default 0,
  outflow numeric(20,2) not null default 0,
  balance numeric(20,2),
  branch_name text,
  depositor_code text,
  memo text,
  category_id uuid references public.finance_categories(id) on delete set null,
  suggested_category_id uuid references public.finance_categories(id) on delete set null,
  classification_status text not null default 'unreviewed' check (classification_status in ('unreviewed','reviewed','duplicate','excluded')),
  owner_id uuid references public.profiles(id) on delete set null,
  matched_schedule_id uuid references public.schedules(id) on delete set null,
  source_hash text not null,
  raw_data jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id, source_hash)
);

alter table public.schedules
  drop constraint if exists schedules_matched_transaction_id_fkey;
alter table public.schedules
  add constraint schedules_matched_transaction_id_fkey
  foreign key (matched_transaction_id) references public.bank_transactions(id) on delete set null;

create index if not exists bank_transactions_company_date_idx on public.bank_transactions(company_id, transaction_at desc);
create index if not exists bank_transactions_status_idx on public.bank_transactions(company_id, classification_status);
create index if not exists schedules_company_due_idx on public.schedules(company_id, due_date);

create table if not exists public.financial_products (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_type text not null check (product_type in ('deposit','loan','fx_deposit','mmt','mmf','cma','insurance','other')),
  bank_name text,
  product_name text not null,
  currency text not null default 'KRW',
  principal numeric(20,2) not null default 0,
  current_value numeric(20,2) not null default 0,
  exchange_rate numeric(20,6) not null default 0,
  interest_rate numeric(10,4) not null default 0,
  start_date date,
  maturity_date date,
  available_date date,
  redeemable boolean not null default false,
  pledged boolean not null default false,
  conditions text,
  memo text,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.financial_products add column if not exists exchange_rate numeric(20,6) not null default 0;

create table if not exists public.monthly_plans (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  plan_year integer not null check (plan_year between 2000 and 2200),
  plan_month integer not null check (plan_month between 1 and 12),
  income numeric(20,2) not null default 0,
  salary numeric(20,2) not null default 0,
  trade_payables numeric(20,2) not null default 0,
  interest_expense numeric(20,2) not null default 0,
  other_expense numeric(20,2) not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id, plan_year, plan_month)
);

create table if not exists public.asset_positions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  as_of_date date not null,
  asset_type text not null,
  amount numeric(20,2) not null default 0,
  target_ratio numeric(8,4) not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id, as_of_date, asset_type)
);

-- =========================================================
-- 3. Reports, approvals, versions and audit logs
-- =========================================================
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete set null,
  title text not null,
  report_type text not null default 'cash' check (report_type in ('cash','weekly','monthly','ad_hoc')),
  period_start date not null,
  period_end date not null,
  status text not null default 'draft' check (status in ('draft','submitted','in_review','approved','rejected','archived')),
  summary text,
  snapshot jsonb not null default '{}'::jsonb,
  current_version integer not null default 0,
  created_by uuid not null references public.profiles(id) on delete restrict,
  submitted_at timestamptz,
  approved_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (period_end >= period_start)
);

create table if not exists public.report_versions (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.reports(id) on delete cascade,
  version_no integer not null,
  summary text,
  snapshot jsonb not null,
  change_reason text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(report_id, version_no)
);

create table if not exists public.approval_steps (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.reports(id) on delete cascade,
  sequence_no integer not null,
  approver_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  comment text,
  acted_at timestamptz,
  created_at timestamptz not null default now(),
  unique(report_id, sequence_no)
);

create index if not exists approval_steps_approver_idx on public.approval_steps(approver_id, status);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  company_id uuid references public.companies(id) on delete set null,
  table_name text not null,
  record_id uuid,
  action text not null check (action in ('INSERT','UPDATE','DELETE','APPROVE','REJECT','ARCHIVE','RESTORE')),
  old_data jsonb,
  new_data jsonb,
  changed_by uuid references public.profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);

create index if not exists audit_logs_record_idx on public.audit_logs(table_name, record_id, changed_at desc);
create index if not exists audit_logs_company_idx on public.audit_logs(company_id, changed_at desc);

-- 접속 기기: 원본 토큰은 브라우저에만 보관하며 DB에는 해시만 저장합니다.
create table if not exists public.registered_devices (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 token_hash text not null check(length(token_hash)=64),
 label text not null check(length(label) between 1 and 80),
 status text not null default 'pending' check(status in ('pending','approved','revoked')),
 created_at timestamptz not null default now(),
 approved_at timestamptz,
 approved_by uuid references public.profiles(id),
 unique(user_id, token_hash)
);
alter table public.registered_devices enable row level security;
revoke all on public.registered_devices from anon, authenticated;

create or replace function public.device_allowed()
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.registered_devices dev join public.profiles prof on prof.id=dev.user_id
 where dev.user_id=auth.uid() and prof.active and prof.approval_status='approved' and dev.status='approved'
 and dev.token_hash=encode(extensions.digest(coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'x-device-token',''),'sha256'),'hex'));
$$;

create or replace function public.device_status()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_profile public.profiles; v_device public.registered_devices;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
 select * into v_profile from public.profiles where id=auth.uid();
 if not found then raise exception '프로필이 없습니다. 관리자에게 문의하세요.'; end if;
 select * into v_device from public.registered_devices where user_id=auth.uid()
 and token_hash=encode(extensions.digest(coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'x-device-token',''),'sha256'),'hex');
 return jsonb_build_object('id',v_device.id,'device_status',coalesce(v_device.status,'unregistered'),'approval_status',v_profile.approval_status,
 'status',case when v_profile.approval_status='pending' then 'user_pending' when v_profile.approval_status='rejected' then 'user_rejected' when not v_profile.active then 'inactive' else coalesce(v_device.status,'unregistered') end);
end $$;

create or replace function public.register_device(p_label text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_token text; v_hash text;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and (approval_status='pending' or (approval_status='approved' and active))) then raise exception '신청이 가능한 계정으로 로그인하세요.'; end if;
 v_token:=nullif(current_setting('request.headers',true),'')::jsonb->>'x-device-token';
 if v_token is null or v_token !~ '^[a-f0-9]{64}$' then raise exception '기기 인증값이 올바르지 않습니다.'; end if;
 if p_label is null or length(trim(p_label)) not between 1 and 80 then raise exception '기기 이름은 1자 이상 80자 이하로 입력하세요.'; end if;
 v_hash:=encode(extensions.digest(v_token,'sha256'),'hex');
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 if exists(select 1 from public.registered_devices where user_id=auth.uid() and token_hash=v_hash) then return public.device_status(); end if;
 if (select count(*) from public.registered_devices where user_id=auth.uid())>=20 then raise exception '계정별 기기 한도 20개입니다. 관리자에게 문의하세요.'; end if;
 insert into public.registered_devices(user_id,token_hash,label) values(auth.uid(),v_hash,trim(p_label));
 return public.device_status();
end $$;


-- =========================================================
-- 4. Helper functions
-- =========================================================
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,email,full_name,department,role,active,approval_status)
 values(new.id,new.email,left(coalesce(new.raw_user_meta_data->>'full_name',split_part(coalesce(new.email,''),'@',1)),100),left(new.raw_user_meta_data->>'department',100),'business_user',false,'pending')
 on conflict(id) do update set email=excluded.email,updated_at=now();
 return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of email on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.current_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid() and active = true;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select role = 'admin' and active from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.has_company_access(p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists(
    select 1 from public.company_memberships m
    join public.profiles p on p.id = m.user_id
    where m.company_id = p_company_id
      and m.user_id = auth.uid()
      and p.active = true
  );
$$;

create or replace function public.can_contribute_company(p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists(
    select 1 from public.company_memberships m
    join public.profiles p on p.id = m.user_id
    where m.company_id = p_company_id
      and m.user_id = auth.uid()
      and m.access_level in ('contribute','finance','manage')
      and p.active = true
  );
$$;

create or replace function public.can_manage_finance(p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists(
    select 1 from public.company_memberships m
    join public.profiles p on p.id = m.user_id
    where m.company_id = p_company_id
      and m.user_id = auth.uid()
      and m.access_level in ('finance','manage')
      and p.role in ('finance_manager','finance_staff','admin')
      and p.active = true
  );
$$;

create or replace function public.can_view_finance(p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists(
    select 1 from public.company_memberships m
    join public.profiles p on p.id = m.user_id
    where m.company_id = p_company_id
      and m.user_id = auth.uid()
      and p.role in ('finance_manager','finance_staff','approver','executive','auditor','admin')
      and p.active = true
  );
$$;

create or replace function public.can_view_company_or_report(p_company_id uuid, p_created_by uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin()
    or (p_company_id is not null and public.can_view_finance(p_company_id))
    or p_created_by = auth.uid();
$$;


create or replace function public.is_report_approver(p_report_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.approval_steps
    where report_id = p_report_id and approver_id = auth.uid()
  );
$$;

create or replace function public.can_view_report(p_report_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.reports r
    where r.id = p_report_id
      and (public.can_view_company_or_report(r.company_id, r.created_by) or public.is_report_approver(r.id))
  );
$$;

create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_record uuid;
  v_company uuid;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new);
    v_record := nullif(v_new ->> 'id','')::uuid;
    v_company := nullif(v_new ->> 'company_id','')::uuid;
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    v_record := coalesce(nullif(v_new ->> 'id','')::uuid, nullif(v_old ->> 'id','')::uuid);
    v_company := coalesce(nullif(v_new ->> 'company_id','')::uuid, nullif(v_old ->> 'company_id','')::uuid);
  else
    v_old := to_jsonb(old);
    v_record := nullif(v_old ->> 'id','')::uuid;
    v_company := nullif(v_old ->> 'company_id','')::uuid;
  end if;

  insert into public.audit_logs(company_id, table_name, record_id, action, old_data, new_data, changed_by)
  values (v_company, tg_table_name, v_record, tg_op, v_old, v_new, auth.uid());

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

-- =========================================================
-- 5. Approval workflow RPC functions
-- =========================================================
create or replace function public.submit_report(p_report_id uuid, p_approver_ids uuid[])
returns public.reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report public.reports;
  v_approver uuid;
  v_seq integer := 0;
begin
  if not public.device_allowed() then raise exception '승인된 기기에서만 실행할 수 있습니다.'; end if;
  select * into v_report from public.reports where id = p_report_id for update;
  if not found then raise exception 'Report not found'; end if;
  if not public.can_manage_finance(v_report.company_id) and v_report.created_by <> auth.uid() then
    raise exception 'Not authorized';
  end if;
  if coalesce(array_length(p_approver_ids,1),0) = 0 then
    raise exception 'At least one approver is required';
  end if;

  if v_report.status not in ('draft','rejected') then raise exception '초안 또는 반려 보고서만 제출할 수 있습니다.'; end if;
  if exists(select 1 from unnest(p_approver_ids) a(id) left join public.profiles p on p.id=a.id where p.id is null or not p.active or p.role not in ('admin','approver','executive','finance_manager') or (v_report.company_id is not null and p.role<>'admin' and not exists(select 1 from public.company_memberships m where m.user_id=p.id and m.company_id=v_report.company_id))) then raise exception '결재자의 역할과 법인 권한을 확인하세요.'; end if;
  delete from public.approval_steps where report_id=p_report_id;
  update public.reports
  set current_version = current_version + 1,
      status = 'submitted',
      submitted_at = now(),
      approved_at = null,
      updated_at = now()
  where id = p_report_id
  returning * into v_report;

  insert into public.report_versions(report_id, version_no, summary, snapshot, change_reason, created_by)
  values (v_report.id, v_report.current_version, v_report.summary, v_report.snapshot, '결재 요청', auth.uid());

  delete from public.approval_steps where report_id = p_report_id and status in ('pending','cancelled');

  foreach v_approver in array p_approver_ids loop
    v_seq := v_seq + 1;
    insert into public.approval_steps(report_id, sequence_no, approver_id)
    values (p_report_id, v_seq, v_approver);
  end loop;

  return v_report;
end;
$$;

create or replace function public.act_on_report(p_step_id uuid, p_action text, p_comment text default null)
returns public.reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_step public.approval_steps;
  v_report public.reports;
  v_pending integer;
  v_prior_pending integer;
begin
  if not public.device_allowed() then raise exception '승인된 기기에서만 실행할 수 있습니다.'; end if;
  if p_action not in ('approve','reject') then raise exception 'Invalid action'; end if;

  select * into v_step from public.approval_steps where id = p_step_id for update;
  if not found then raise exception 'Approval step not found'; end if;
  if v_step.approver_id <> auth.uid() then raise exception 'Not assigned approver'; end if;
  if v_step.status <> 'pending' then raise exception 'Approval step already processed'; end if;

  select count(*) into v_prior_pending
  from public.approval_steps
  where report_id = v_step.report_id
    and sequence_no < v_step.sequence_no
    and status <> 'approved';
  if v_prior_pending > 0 then raise exception 'Prior approval step is not completed'; end if;

  update public.approval_steps
  set status = case when p_action='approve' then 'approved' else 'rejected' end,
      comment = p_comment,
      acted_at = now()
  where id = p_step_id;

  select * into v_report from public.reports where id = v_step.report_id for update;

  if p_action = 'reject' then
    update public.reports set status='rejected', updated_at=now() where id=v_report.id returning * into v_report;
    update public.approval_steps set status='cancelled' where report_id=v_report.id and status='pending';
    insert into public.audit_logs(company_id, table_name, record_id, action, new_data, changed_by)
    values (v_report.company_id, 'reports', v_report.id, 'REJECT', jsonb_build_object('comment',p_comment,'step_id',p_step_id), auth.uid());
    return v_report;
  end if;

  select count(*) into v_pending from public.approval_steps where report_id=v_report.id and status='pending';
  if v_pending = 0 then
    update public.reports set status='approved', approved_at=now(), updated_at=now() where id=v_report.id returning * into v_report;
  else
    update public.reports set status='in_review', updated_at=now() where id=v_report.id returning * into v_report;
  end if;

  insert into public.audit_logs(company_id, table_name, record_id, action, new_data, changed_by)
  values (v_report.company_id, 'reports', v_report.id, 'APPROVE', jsonb_build_object('comment',p_comment,'step_id',p_step_id), auth.uid());

  return v_report;
end;
$$;

create or replace function public.archive_report(p_report_id uuid)
returns public.reports
language plpgsql
security definer
set search_path = public
as $$
declare v_report public.reports;
begin
  if not public.device_allowed() then raise exception '승인된 기기에서만 실행할 수 있습니다.'; end if;
  select * into v_report from public.reports where id=p_report_id for update;
  if not found then raise exception 'Report not found'; end if;
  if not ((v_report.company_id is null and public.current_role() in ('admin','finance_manager')) or (v_report.company_id is not null and public.can_manage_finance(v_report.company_id))) then raise exception 'Not authorized'; end if;
  if v_report.status <> 'approved' then raise exception 'Only approved reports can be archived'; end if;
  update public.reports set status='archived', archived_at=now(), updated_at=now() where id=p_report_id returning * into v_report;
  insert into public.audit_logs(company_id, table_name, record_id, action, new_data, changed_by)
  values (v_report.company_id, 'reports', v_report.id, 'ARCHIVE', to_jsonb(v_report), auth.uid());
  return v_report;
end;
$$;

-- =========================================================
-- 6. Updated-at and audit triggers
-- =========================================================
do $$
declare t text;
begin
  foreach t in array array['companies','profiles','finance_categories','cash_accounts','schedules','bank_transactions','financial_products','monthly_plans','asset_positions','reports']
  loop
    execute format('drop trigger if exists %I on public.%I', 'touch_'||t, t);
    execute format('create trigger %I before update on public.%I for each row execute procedure public.touch_updated_at()', 'touch_'||t, t);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['cash_accounts','schedules','bank_transactions','financial_products','monthly_plans','asset_positions','reports']
  loop
    execute format('drop trigger if exists %I on public.%I', 'audit_'||t, t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute procedure public.audit_row_change()', 'audit_'||t, t);
  end loop;
end $$;

-- =========================================================
-- 7. Row Level Security
-- =========================================================
alter table public.companies enable row level security;
alter table public.profiles enable row level security;
alter table public.company_memberships enable row level security;
alter table public.module_assignments enable row level security;
alter table public.finance_categories enable row level security;
alter table public.cash_accounts enable row level security;
alter table public.import_batches enable row level security;
alter table public.bank_transactions enable row level security;
alter table public.schedules enable row level security;
alter table public.financial_products enable row level security;
alter table public.monthly_plans enable row level security;
alter table public.asset_positions enable row level security;
alter table public.reports enable row level security;
alter table public.report_versions enable row level security;
alter table public.approval_steps enable row level security;
alter table public.audit_logs enable row level security;

-- Companies
drop policy if exists companies_select on public.companies;
create policy companies_select on public.companies for select to authenticated
using (public.is_admin() or public.has_company_access(id));
drop policy if exists companies_admin_write on public.companies;
create policy companies_admin_write on public.companies for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
using (
  id = auth.uid()
  or public.is_admin()
  or public.current_role() in ('finance_manager','finance_staff','approver','executive','auditor')
);
drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles for update to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Memberships and module assignments
drop policy if exists memberships_select on public.company_memberships;
create policy memberships_select on public.company_memberships for select to authenticated
using (user_id = auth.uid() or public.is_admin());
drop policy if exists memberships_admin_write on public.company_memberships;
create policy memberships_admin_write on public.company_memberships for all to authenticated
using (public.is_admin()) with check (public.is_admin());
drop policy if exists module_assignments_select on public.module_assignments;
create policy module_assignments_select on public.module_assignments for select to authenticated
using (user_id = auth.uid() or public.is_admin());
drop policy if exists module_assignments_admin_write on public.module_assignments;
create policy module_assignments_admin_write on public.module_assignments for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Finance categories
drop policy if exists categories_select on public.finance_categories;
create policy categories_select on public.finance_categories for select to authenticated
using (company_id is null or public.has_company_access(company_id));
drop policy if exists categories_write on public.finance_categories;
create policy categories_write on public.finance_categories for all to authenticated
using (public.is_admin() or (company_id is not null and public.can_manage_finance(company_id)))
with check (public.is_admin() or (company_id is not null and public.can_manage_finance(company_id)));

-- Reusable company-level data policies
drop policy if exists cash_accounts_select on public.cash_accounts;
create policy cash_accounts_select on public.cash_accounts for select to authenticated using (public.can_view_finance(company_id));
drop policy if exists cash_accounts_write on public.cash_accounts;
create policy cash_accounts_write on public.cash_accounts for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

drop policy if exists import_batches_select on public.import_batches;
create policy import_batches_select on public.import_batches for select to authenticated using (public.can_view_finance(company_id) or uploaded_by=auth.uid());
drop policy if exists import_batches_insert on public.import_batches;
create policy import_batches_insert on public.import_batches for insert to authenticated with check (public.can_contribute_company(company_id));
drop policy if exists import_batches_update on public.import_batches;
create policy import_batches_update on public.import_batches for update to authenticated using (public.can_manage_finance(company_id) or uploaded_by=auth.uid()) with check (public.can_manage_finance(company_id) or uploaded_by=auth.uid());

drop policy if exists transactions_select on public.bank_transactions;
create policy transactions_select on public.bank_transactions for select to authenticated using (public.can_view_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
drop policy if exists transactions_insert on public.bank_transactions;
create policy transactions_insert on public.bank_transactions for insert to authenticated with check (public.can_contribute_company(company_id));
drop policy if exists transactions_update on public.bank_transactions;
create policy transactions_update on public.bank_transactions for update to authenticated
using (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid())
with check (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
drop policy if exists transactions_delete on public.bank_transactions;
create policy transactions_delete on public.bank_transactions for delete to authenticated using (public.can_manage_finance(company_id));

drop policy if exists schedules_select on public.schedules;
create policy schedules_select on public.schedules for select to authenticated using (public.can_view_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
drop policy if exists schedules_insert on public.schedules;
create policy schedules_insert on public.schedules for insert to authenticated with check (public.can_contribute_company(company_id));
drop policy if exists schedules_update on public.schedules;
create policy schedules_update on public.schedules for update to authenticated
using (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid())
with check (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
drop policy if exists schedules_delete on public.schedules;
create policy schedules_delete on public.schedules for delete to authenticated using (public.can_manage_finance(company_id) or created_by=auth.uid());

drop policy if exists products_select on public.financial_products;
create policy products_select on public.financial_products for select to authenticated using (public.can_view_finance(company_id));
drop policy if exists products_write on public.financial_products;
create policy products_write on public.financial_products for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

drop policy if exists monthly_plans_select on public.monthly_plans;
create policy monthly_plans_select on public.monthly_plans for select to authenticated using (public.can_view_finance(company_id));
drop policy if exists monthly_plans_write on public.monthly_plans;
create policy monthly_plans_write on public.monthly_plans for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

drop policy if exists asset_positions_select on public.asset_positions;
create policy asset_positions_select on public.asset_positions for select to authenticated using (public.can_view_finance(company_id));
drop policy if exists asset_positions_write on public.asset_positions;
create policy asset_positions_write on public.asset_positions for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

-- Reports and approval data
drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated
using (public.can_view_company_or_report(company_id, created_by) or public.is_report_approver(id));
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated
with check (
  created_by=auth.uid()
  and ((company_id is null and public.current_role() in ('admin','finance_manager'))
       or (company_id is not null and public.can_manage_finance(company_id)))
);
drop policy if exists reports_update on public.reports;
create policy reports_update on public.reports for update to authenticated
using (
  (company_id is null and public.current_role() in ('admin','finance_manager'))
  or (company_id is not null and public.can_manage_finance(company_id))
)
with check (
  (company_id is null and public.current_role() in ('admin','finance_manager'))
  or (company_id is not null and public.can_manage_finance(company_id))
);
drop policy if exists reports_delete on public.reports;
create policy reports_delete on public.reports for delete to authenticated
using (
  status='draft'
  and ((company_id is null and public.current_role() in ('admin','finance_manager'))
       or (company_id is not null and public.can_manage_finance(company_id)))
);

drop policy if exists report_versions_select on public.report_versions;
create policy report_versions_select on public.report_versions for select to authenticated
using (public.can_view_report(report_id));
drop policy if exists report_versions_insert on public.report_versions;
create policy report_versions_insert on public.report_versions for insert to authenticated
with check (exists(
  select 1 from public.reports r
  where r.id=report_id
    and ((r.company_id is null and public.current_role() in ('admin','finance_manager'))
         or (r.company_id is not null and public.can_manage_finance(r.company_id)))
));

drop policy if exists approval_steps_select on public.approval_steps;
create policy approval_steps_select on public.approval_steps for select to authenticated
using (approver_id=auth.uid() or public.can_view_report(report_id));
-- Direct updates are intentionally blocked. Use act_on_report RPC.

drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs for select to authenticated
using (public.is_admin() or public.current_role() in ('finance_manager','auditor','executive') or (company_id is not null and public.has_company_access(company_id)));

-- =========================================================
-- 8. Storage bucket and policies
-- =========================================================
insert into storage.buckets(id, name, public)
values ('finance-files','finance-files',false)
on conflict (id) do nothing;

drop policy if exists finance_files_select on storage.objects;
create policy finance_files_select on storage.objects for select to authenticated
using (
  bucket_id='finance-files'
  and (
    public.can_view_finance(nullif((storage.foldername(name))[1],'')::uuid)
    or nullif((storage.foldername(name))[2],'')::uuid = auth.uid()
  )
);

drop policy if exists finance_files_insert on storage.objects;
create policy finance_files_insert on storage.objects for insert to authenticated
with check (
  bucket_id='finance-files'
  and public.can_contribute_company(nullif((storage.foldername(name))[1],'')::uuid)
);

drop policy if exists finance_files_update on storage.objects;
create policy finance_files_update on storage.objects for update to authenticated
using (
  bucket_id='finance-files'
  and public.can_manage_finance(nullif((storage.foldername(name))[1],'')::uuid)
)
with check (
  bucket_id='finance-files'
  and public.can_manage_finance(nullif((storage.foldername(name))[1],'')::uuid)
);

drop policy if exists finance_files_delete on storage.objects;
create policy finance_files_delete on storage.objects for delete to authenticated
using (
  bucket_id='finance-files'
  and public.can_manage_finance(nullif((storage.foldername(name))[1],'')::uuid)
);

-- =========================================================
-- 9. Grants
-- =========================================================
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.submit_report(uuid,uuid[]) to authenticated;
grant execute on function public.act_on_report(uuid,text,text) to authenticated;
grant execute on function public.archive_report(uuid) to authenticated;
grant execute on function public.has_company_access(uuid) to authenticated;
grant execute on function public.can_contribute_company(uuid) to authenticated;
grant execute on function public.can_manage_finance(uuid) to authenticated;
grant execute on function public.can_view_finance(uuid) to authenticated;
grant execute on function public.is_report_approver(uuid) to authenticated;
grant execute on function public.can_view_report(uuid) to authenticated;

-- 서비스 관리 역할의 권한입니다. 프로그램 연결에는 이 비밀키를 사용하지 않습니다.
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
create or replace function public.admin_devices()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자 기기가 필요합니다.'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'user_id',d.user_id,'email',p.email,'label',d.label,'status',d.status,'created_at',d.created_at) order by d.created_at desc),'[]'::jsonb)
 from public.registered_devices d join public.profiles p on p.id=d.user_id);
end $$;

create or replace function public.set_device_status(p_id uuid,p_status text)
returns void language plpgsql security definer set search_path='' as $$
declare v_before jsonb; v_after jsonb; v_user_id uuid;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자 기기가 필요합니다.'; end if;
 if p_status is null or p_status not in ('approved','revoked') then raise exception '잘못된 기기 상태입니다.'; end if;
 select to_jsonb(dev)-'token_hash',dev.user_id into v_before,v_user_id from public.registered_devices dev where id=p_id for update;
 if v_before is null then raise exception '기기를 찾을 수 없습니다.'; end if;
 if p_status='approved' and not exists(select 1 from public.profiles where id=v_user_id and active and approval_status='approved') then raise exception '사용자를 먼저 승인하고 활성화하세요.'; end if;
 update public.registered_devices set status=p_status,approved_by=auth.uid(),approved_at=now() where id=p_id
 returning to_jsonb(registered_devices)-'token_hash' into v_after;
 insert into public.audit_logs(table_name,record_id,action,old_data,new_data,changed_by)
 values('registered_devices',p_id,'UPDATE',v_before,v_after,auth.uid());
end $$;

-- 로그인 계정 생성과 비밀번호 변경은 Supabase Authentication에서 처리합니다.
create or replace function public.admin_users(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_target_id uuid; v_before jsonb; v_after jsonb; v_action text:=coalesce(p_payload->>'action','list'); v_membership jsonb; v_device_id uuid; v_role text;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자 기기가 필요합니다.'; end if;
 if v_action='list' then
  return jsonb_build_object('users',(select coalesce(jsonb_agg(to_jsonb(prof)||jsonb_build_object(
   'last_sign_in_at',usr.last_sign_in_at,
   'memberships',(select coalesce(jsonb_agg(to_jsonb(member_row)),'[]'::jsonb) from public.company_memberships member_row where member_row.user_id=prof.id),
   'module_assignments','[]'::jsonb) order by (prof.approval_status='pending') desc,prof.created_at desc),'[]'::jsonb)
   from public.profiles prof join auth.users usr on usr.id=prof.id));
 end if;
 if v_action not in ('update','approve','reject') then raise exception '신규 사용자는 로그인 화면의 이용 신청을 사용하세요.'; end if;
 v_target_id:=(p_payload->>'user_id')::uuid;
 select to_jsonb(prof) into v_before from public.profiles prof where id=v_target_id for update;
 if v_before is null then raise exception '사용자를 찾을 수 없습니다.'; end if;
 if p_payload ? 'email' and lower(p_payload->>'email')<>lower(v_before->>'email') then raise exception '이메일 변경은 Supabase Authentication에서 처리하세요.'; end if;
 if v_target_id=auth.uid() and (v_action='reject' or (p_payload ? 'role' and p_payload->>'role'<>'admin') or (p_payload ? 'active' and not (p_payload->>'active')::boolean)) then raise exception '본인의 관리자 권한이나 활성 상태는 해제할 수 없습니다.'; end if;
 if v_action='update' and v_before->>'approval_status'<>'approved' then raise exception '미승인 계정은 승인 또는 반려 기능으로 처리하세요.'; end if;
 if v_action='reject' then
  update public.profiles set active=false,approval_status='rejected',approved_at=now(),approved_by=auth.uid() where id=v_target_id;
  update public.registered_devices set status='revoked' where user_id=v_target_id;
 else
  v_role:=coalesce(p_payload->>'role',v_before->>'role');
  if v_action='approve' and v_before->>'approval_status'='approved' then raise exception '이미 승인된 사용자입니다. 새로고침 후 권한 수정을 사용하세요.'; end if;
  if v_action='approve' and v_role<>'admin' and (not(p_payload ? 'memberships') or jsonb_typeof(p_payload->'memberships') is distinct from 'array' or jsonb_array_length(p_payload->'memberships')=0) then raise exception '승인할 사용자의 법인을 하나 이상 지정하세요.'; end if;
  update public.profiles set
   full_name=case when p_payload ? 'full_name' then p_payload->>'full_name' else full_name end,
   department=case when p_payload ? 'department' then p_payload->>'department' else department end,
   job_title=case when p_payload ? 'job_title' then p_payload->>'job_title' else job_title end,
   role=v_role,
   active=case when v_action='approve' then true when p_payload ? 'active' then (p_payload->>'active')::boolean else active end,
   approval_status=case when v_action='approve' then 'approved' else approval_status end,
   approved_at=case when v_action='approve' then now() else approved_at end,
   approved_by=case when v_action='approve' then auth.uid() else approved_by end,
   default_company_id=case when p_payload ? 'default_company_id' then (p_payload->>'default_company_id')::uuid else default_company_id end
  where id=v_target_id;
  if p_payload ? 'memberships' then
   if jsonb_typeof(p_payload->'memberships') is distinct from 'array' then raise exception '법인 권한 형식 오류'; end if;
   delete from public.company_memberships where user_id=v_target_id;
   for v_membership in select value from jsonb_array_elements(p_payload->'memberships') loop
    insert into public.company_memberships(user_id,company_id,access_level) values(v_target_id,(v_membership->>'company_id')::uuid,v_membership->>'access_level');
   end loop;
  end if;
  -- 관리자가 식별번호를 확인하여 선택한 한 기기만 함께 승인합니다.
  if v_action='approve' and nullif(p_payload->>'device_id','') is not null then
   v_device_id:=(p_payload->>'device_id')::uuid;
   if not exists(select 1 from public.registered_devices where id=v_device_id and user_id=v_target_id and status='pending') then raise exception '해당 사용자의 승인 대기 기기가 아닙니다. 새로고침하세요.'; end if;
   perform public.set_device_status(v_device_id,'approved');
  end if;
 end if;
 select to_jsonb(prof) into v_after from public.profiles prof where id=v_target_id;
 insert into public.audit_logs(table_name,record_id,action,old_data,new_data,changed_by)
 values('profiles',v_target_id,'UPDATE',v_before,v_after||jsonb_build_object('approval_action',v_action),auth.uid());
 return jsonb_build_object('ok',true,'user_id',v_target_id);
end $$;

create or replace function public.export_finance_backup()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t text; rows jsonb; data jsonb:='{}';
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '전체 백업은 승인된 관리자 기기에서만 가능합니다.'; end if;
 foreach t in array array['companies','profiles','company_memberships','module_assignments','finance_categories','cash_accounts','import_batches','schedules','bank_transactions','financial_products','monthly_plans','asset_positions','reports','report_versions','approval_steps','audit_logs'] loop
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
 foreach t in array array['companies','finance_categories','cash_accounts','import_batches','schedules','bank_transactions','financial_products','monthly_plans','asset_positions','reports','report_versions','approval_steps'] loop
  rows:=p_backup->'data'->t;
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

drop policy if exists approved_device_required on public.companies;
create policy approved_device_required on public.companies as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.profiles;
create policy approved_device_required on public.profiles as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.company_memberships;
create policy approved_device_required on public.company_memberships as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.module_assignments;
create policy approved_device_required on public.module_assignments as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.finance_categories;
create policy approved_device_required on public.finance_categories as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.cash_accounts;
create policy approved_device_required on public.cash_accounts as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.import_batches;
create policy approved_device_required on public.import_batches as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.schedules;
create policy approved_device_required on public.schedules as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.bank_transactions;
create policy approved_device_required on public.bank_transactions as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.financial_products;
create policy approved_device_required on public.financial_products as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.monthly_plans;
create policy approved_device_required on public.monthly_plans as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.asset_positions;
create policy approved_device_required on public.asset_positions as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.reports;
create policy approved_device_required on public.reports as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.report_versions;
create policy approved_device_required on public.report_versions as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.approval_steps;
create policy approved_device_required on public.approval_steps as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists approved_device_required on public.audit_logs;
create policy approved_device_required on public.audit_logs as restrictive for all to authenticated using (public.device_allowed()) with check (public.device_allowed());

drop policy if exists company_boundary on public.cash_accounts;
create policy company_boundary on public.cash_accounts as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.import_batches;
create policy company_boundary on public.import_batches as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.schedules;
create policy company_boundary on public.schedules as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.bank_transactions;
create policy company_boundary on public.bank_transactions as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.financial_products;
create policy company_boundary on public.financial_products as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.monthly_plans;
create policy company_boundary on public.monthly_plans as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.asset_positions;
create policy company_boundary on public.asset_positions as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.reports;
create policy company_boundary on public.reports as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.audit_logs;
create policy company_boundary on public.audit_logs as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists company_boundary on public.finance_categories;
create policy company_boundary on public.finance_categories as restrictive for all to authenticated using (company_id is null or public.has_company_access(company_id)) with check (company_id is null or public.has_company_access(company_id));

drop policy if exists finance_device_required on storage.objects;
create policy finance_device_required on storage.objects as restrictive for all to authenticated
using (bucket_id <> 'finance-files' or public.device_allowed()) with check (bucket_id <> 'finance-files' or public.device_allowed());
revoke update on public.profiles from authenticated;
revoke insert,update,delete on public.report_versions, public.approval_steps from authenticated;
revoke all on public.registered_devices from anon,authenticated;

revoke all on function public.device_allowed() from public,anon,authenticated;
grant execute on function public.device_allowed() to authenticated;

revoke all on function public.device_status() from public,anon,authenticated;
grant execute on function public.device_status() to authenticated;

revoke all on function public.register_device(text) from public,anon,authenticated;
grant execute on function public.register_device(text) to authenticated;

revoke all on function public.touch_updated_at() from public,anon,authenticated;

revoke all on function public.handle_new_user() from public,anon,authenticated;

revoke all on function public.current_role() from public,anon,authenticated;
grant execute on function public.current_role() to authenticated;

revoke all on function public.is_admin() from public,anon,authenticated;
grant execute on function public.is_admin() to authenticated;

revoke all on function public.has_company_access(uuid) from public,anon,authenticated;
grant execute on function public.has_company_access(uuid) to authenticated;

revoke all on function public.can_contribute_company(uuid) from public,anon,authenticated;
grant execute on function public.can_contribute_company(uuid) to authenticated;

revoke all on function public.can_manage_finance(uuid) from public,anon,authenticated;
grant execute on function public.can_manage_finance(uuid) to authenticated;

revoke all on function public.can_view_finance(uuid) from public,anon,authenticated;
grant execute on function public.can_view_finance(uuid) to authenticated;

revoke all on function public.can_view_company_or_report(uuid,uuid) from public,anon,authenticated;
grant execute on function public.can_view_company_or_report(uuid,uuid) to authenticated;

revoke all on function public.is_report_approver(uuid) from public,anon,authenticated;
grant execute on function public.is_report_approver(uuid) to authenticated;

revoke all on function public.can_view_report(uuid) from public,anon,authenticated;
grant execute on function public.can_view_report(uuid) to authenticated;

revoke all on function public.audit_row_change() from public,anon,authenticated;

revoke all on function public.submit_report(uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.submit_report(uuid,uuid[]) to authenticated;

revoke all on function public.act_on_report(uuid,text,text) from public,anon,authenticated;
grant execute on function public.act_on_report(uuid,text,text) to authenticated;

revoke all on function public.archive_report(uuid) from public,anon,authenticated;
grant execute on function public.archive_report(uuid) to authenticated;

revoke all on function public.admin_devices() from public,anon,authenticated;
grant execute on function public.admin_devices() to authenticated;

revoke all on function public.set_device_status(uuid,text) from public,anon,authenticated;
grant execute on function public.set_device_status(uuid,text) to authenticated;

revoke all on function public.admin_users(jsonb) from public,anon,authenticated;
grant execute on function public.admin_users(jsonb) to authenticated;

revoke all on function public.export_finance_backup() from public,anon,authenticated;
grant execute on function public.export_finance_backup() to authenticated;

revoke all on function public.restore_finance_backup(jsonb) from public,anon,authenticated;
grant execute on function public.restore_finance_backup(jsonb) to authenticated;

create or replace function public.protect_report_workflow()
returns trigger language plpgsql set search_path='' as $$
begin
 if current_user='authenticated' then
  if TG_OP='INSERT' and (new.status<>'draft' or new.current_version<>0 or new.approved_at is not null or new.submitted_at is not null or new.archived_at is not null) then raise exception '최초 보고서는 초안 상태로만 저장할 수 있습니다.'; end if;
  if TG_OP='UPDATE' and (old.status not in ('draft','rejected') or new.status is distinct from old.status or new.current_version is distinct from old.current_version or new.created_by is distinct from old.created_by or new.approved_at is distinct from old.approved_at or new.submitted_at is distinct from old.submitted_at or new.archived_at is distinct from old.archived_at) then raise exception '결재 상태는 전용 기능으로 변경하세요.'; end if;
 end if;
 return new;
end $$;
drop trigger if exists protect_report_workflow on public.reports;
create trigger protect_report_workflow before insert or update on public.reports for each row execute function public.protect_report_workflow();
revoke all on function public.protect_report_workflow() from public,anon,authenticated;
-- Optional seed data. Run after the main migration.
insert into public.companies(code,name) values
  ('SAMCO','삼코'),
  ('SAMCHEON','삼천산업'),
  ('CHANGJIN','창진에스씨')
on conflict (code) do nothing;

insert into public.finance_categories(company_id,name,direction,keywords,sort_order) values
  (null,'거래처 수금','receipt',array['매출','수금','입금','외상대금'],10),
  (null,'차입금 수령','receipt',array['대출금','차입금','융자'],20),
  (null,'이자수익','receipt',array['이자수','이자수익'],30),
  (null,'매입대금','payment',array['외상대','매입','업체대금','협력회사'],40),
  (null,'급여·인건비','payment',array['급여','용역대금','외주급여','퇴직금'],50),
  (null,'세금·공과금','payment',array['세금','부가세','원천세','재산세','인지대','사업소세'],60),
  (null,'4대보험','payment',array['국민연금','건강','의보','고용보험','산재보험','보험료'],70),
  (null,'카드대금','payment',array['카드','신한카드','법인카드'],80),
  (null,'대출이자','payment',array['대출이자','이자비용'],90),
  (null,'통신·공공요금','payment',array['통신','오피스넷','수도','전기요금'],100),
  (null,'임차료·렌탈','payment',array['임차료','렌탈','기숙사'],110),
  (null,'내부이체','transfer',array['자사 계좌','MMT이체','MMT출금','타계좌','계좌이체'],120),
  (null,'기타','mixed',array[]::text[],999)
on conflict do nothing;

-- 먼저 생성한 관리자와 다른 기존 로그인 계정의 프로필을 연결합니다.
insert into public.profiles(id,email,full_name)
select id,email,coalesce(raw_user_meta_data->>'full_name',split_part(email,'@',1)) from auth.users
on conflict(id) do nothing;
do $$
declare admin_id uuid;
begin
 select id into admin_id from auth.users where lower(email)=lower(current_setting('finance.install_admin_email'));
 if admin_id is null then raise exception '관리자 이메일을 확인하고 Authentication에서 계정을 먼저 생성하세요. 전체 설치가 취소되었습니다.'; end if;
 update public.profiles set role='admin',active=true,approval_status='approved' where id=admin_id;
 insert into public.company_memberships(company_id,user_id,access_level) select id,admin_id,'manage' from public.companies on conflict(company_id,user_id) do nothing;
end $$;

-- 연결된 계좌·거래·분류의 법인이 서로 다른 경우 저장을 차단합니다.
create or replace function public.check_related_company()
returns trigger language plpgsql security definer set search_path='' as $$
declare row_data jsonb:=to_jsonb(new); field_name text; target_table text; target_id uuid; target_company uuid; i integer;
begin
 for i in 0..(TG_NARGS/2-1) loop
  field_name:=TG_ARGV[i*2];target_table:=TG_ARGV[i*2+1];target_id:=(row_data->>field_name)::uuid;
  if target_id is null then continue; end if;
  execute format('select company_id from public.%I where id=$1',target_table) into target_company using target_id;
  if target_company is distinct from new.company_id and not (target_table='finance_categories' and target_company is null) then raise exception '연결된 자료의 법인이 다릅니다: %',field_name; end if;
 end loop;
 return new;
end $$;
revoke all on function public.check_related_company() from public,anon,authenticated;
drop trigger if exists check_bank_company on public.bank_transactions;
create trigger check_bank_company before insert or update on public.bank_transactions for each row execute function public.check_related_company('account_id','cash_accounts','import_batch_id','import_batches','matched_schedule_id','schedules','category_id','finance_categories','suggested_category_id','finance_categories');
drop trigger if exists check_batch_company on public.import_batches;
create trigger check_batch_company before insert or update on public.import_batches for each row execute function public.check_related_company('account_id','cash_accounts');
drop trigger if exists check_schedule_company on public.schedules;
create trigger check_schedule_company before insert or update on public.schedules for each row execute function public.check_related_company('matched_transaction_id','bank_transactions');



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
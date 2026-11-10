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
returns boolean language sql stable security definer set search_path = '' as $$
 select exists(
 select 1 from public.registered_devices d join public.profiles p on p.id=d.user_id
 where d.user_id=auth.uid() and p.active and d.status='approved'
 and d.token_hash=encode(extensions.digest(coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'x-device-token',''),'sha256'),'hex')
 );
$$;

create or replace function public.device_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare d public.registered_devices;
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and active) then return jsonb_build_object('status','inactive'); end if;
 select * into d from public.registered_devices where user_id=auth.uid()
 and token_hash=encode(extensions.digest(coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'x-device-token',''),'sha256'),'hex');
 return jsonb_build_object('id',d.id,'status',coalesce(d.status,'unregistered'));
end $$;

create or replace function public.register_device(p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare token text; d public.registered_devices;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active) then raise exception '활성 계정으로 로그인하세요.'; end if;
 token:=nullif(current_setting('request.headers',true),'')::jsonb->>'x-device-token';
 if token is null or token !~ '^[a-f0-9]{64}$' then raise exception '기기 인증값이 올바르지 않습니다.'; end if;
 if length(trim(p_label)) not between 1 and 80 then raise exception '기기 이름은 1자 이상 80자 이하로 입력하세요.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 if (select count(*) from public.registered_devices where user_id=auth.uid())>=20 then raise exception '계정별 기기 한도 20개입니다. 관리자에게 문의하세요.'; end if;
 insert into public.registered_devices(user_id,token_hash,label)
 values(auth.uid(),encode(extensions.digest(token,'sha256'),'hex'),trim(p_label))
 on conflict(user_id,token_hash) do nothing;
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
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles(id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(coalesce(new.email,''), '@', 1))
  )
  on conflict (id) do update
  set email = excluded.email,
      updated_at = now();
  return new;
end;
$$;

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
returns void language plpgsql security definer set search_path = '' as $$
declare old_row jsonb; new_row jsonb;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자 기기가 필요합니다.'; end if;
 if p_status not in ('approved','revoked') then raise exception '잘못된 기기 상태입니다.'; end if;
 select to_jsonb(d)-'token_hash' into old_row from public.registered_devices d where id=p_id for update;
 if old_row is null then raise exception '기기를 찾을 수 없습니다.'; end if;
 update public.registered_devices set status=p_status,approved_by=auth.uid(),approved_at=now() where id=p_id
 returning to_jsonb(registered_devices)-'token_hash' into new_row;
 insert into public.audit_logs(table_name,record_id,action,old_data,new_data,changed_by)
 values('registered_devices',p_id,'UPDATE',old_row,new_row,auth.uid());
end $$;

-- 로그인 계정 생성과 비밀번호 변경은 Supabase Authentication에서 처리합니다.
create or replace function public.admin_users(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target_id uuid; old_row jsonb; action text:=coalesce(p_payload->>'action','list'); m jsonb;
begin
 if not public.device_allowed() or not public.is_admin() then raise exception '승인된 관리자 기기가 필요합니다.'; end if;
 if action='list' then
  return jsonb_build_object('users',(select coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object(
   'last_sign_in_at',u.last_sign_in_at,
   'memberships',(select coalesce(jsonb_agg(to_jsonb(m)),'[]'::jsonb) from public.company_memberships m where m.user_id=p.id),
   'module_assignments','[]'::jsonb) order by p.full_name),'[]'::jsonb)
   from public.profiles p join auth.users u on u.id=p.id));
 end if;
 if action not in ('create','update') then raise exception '지원하지 않는 작업입니다.'; end if;
 if action='create' then
  select id into target_id from auth.users where lower(email)=lower(p_payload->>'email');
  if target_id is null then raise exception 'Supabase Authentication → Users에서 이 이메일 계정을 먼저 생성하세요.'; end if;
 else target_id:=(p_payload->>'user_id')::uuid; end if;
 select to_jsonb(p) into old_row from public.profiles p where id=target_id for update;
 if old_row is null then raise exception '사용자를 찾을 수 없습니다.'; end if;
 if p_payload ? 'email' and lower(p_payload->>'email')<>lower(old_row->>'email') then raise exception '이메일 변경은 Supabase Authentication에서 처리하세요.'; end if;
 if target_id=auth.uid() and ((p_payload ? 'role' and p_payload->>'role'<>'admin') or (p_payload ? 'active' and not (p_payload->>'active')::boolean)) then raise exception '본인의 관리자 권한이나 활성 상태는 해제할 수 없습니다.'; end if;
 update public.profiles set
 full_name=case when p_payload ? 'full_name' then p_payload->>'full_name' else full_name end,
 department=case when p_payload ? 'department' then p_payload->>'department' else department end,
 job_title=case when p_payload ? 'job_title' then p_payload->>'job_title' else job_title end,
 role=case when p_payload ? 'role' then p_payload->>'role' else role end,
 active=case when p_payload ? 'active' then (p_payload->>'active')::boolean else active end,
 default_company_id=case when p_payload ? 'default_company_id' then (p_payload->>'default_company_id')::uuid else default_company_id end
 where id=target_id;
 if p_payload ? 'memberships' then
  if jsonb_typeof(p_payload->'memberships')<>'array' then raise exception '법인 권한 형식 오류'; end if;
  delete from public.company_memberships where user_id=target_id;
  for m in select value from jsonb_array_elements(p_payload->'memberships') loop
   insert into public.company_memberships(user_id,company_id,access_level) values(target_id,(m->>'company_id')::uuid,m->>'access_level');
  end loop;
 end if;
 insert into public.audit_logs(table_name,record_id,action,old_data,new_data,changed_by)
 values('profiles',target_id,'UPDATE',old_row,p_payload-'password',auth.uid());
 return jsonb_build_object('ok',true,'user_id',target_id);
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
 update public.profiles set role='admin',active=true where id=admin_id;
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

commit;
select '설치 완료: 사이트에 로그인하여 기기 등록 후 최초 관리자 기기를 Table Editor에서 승인하세요.' as result;

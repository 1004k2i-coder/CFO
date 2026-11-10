-- Changjin SC Finance Management Web App
-- Supabase / PostgreSQL schema, RLS, audit trail and approval workflow

create extension if not exists pgcrypto;

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
  select * into v_report from public.reports where id = p_report_id for update;
  if not found then raise exception 'Report not found'; end if;
  if not public.can_manage_finance(v_report.company_id) and v_report.created_by <> auth.uid() then
    raise exception 'Not authorized';
  end if;
  if coalesce(array_length(p_approver_ids,1),0) = 0 then
    raise exception 'At least one approver is required';
  end if;

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
create policy companies_select on public.companies for select to authenticated
using (public.is_admin() or public.has_company_access(id));
create policy companies_admin_write on public.companies for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Profiles
create policy profiles_select on public.profiles for select to authenticated
using (
  id = auth.uid()
  or public.is_admin()
  or public.current_role() in ('finance_manager','approver','executive','auditor')
);
create policy profiles_self_update on public.profiles for update to authenticated
using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

-- Memberships and module assignments
create policy memberships_select on public.company_memberships for select to authenticated
using (user_id = auth.uid() or public.is_admin());
create policy memberships_admin_write on public.company_memberships for all to authenticated
using (public.is_admin()) with check (public.is_admin());
create policy module_assignments_select on public.module_assignments for select to authenticated
using (user_id = auth.uid() or public.is_admin());
create policy module_assignments_admin_write on public.module_assignments for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Finance categories
create policy categories_select on public.finance_categories for select to authenticated
using (company_id is null or public.has_company_access(company_id));
create policy categories_write on public.finance_categories for all to authenticated
using (public.is_admin() or (company_id is not null and public.can_manage_finance(company_id)))
with check (public.is_admin() or (company_id is not null and public.can_manage_finance(company_id)));

-- Reusable company-level data policies
create policy cash_accounts_select on public.cash_accounts for select to authenticated using (public.can_view_finance(company_id));
create policy cash_accounts_write on public.cash_accounts for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

create policy import_batches_select on public.import_batches for select to authenticated using (public.can_view_finance(company_id) or uploaded_by=auth.uid());
create policy import_batches_insert on public.import_batches for insert to authenticated with check (public.can_contribute_company(company_id));
create policy import_batches_update on public.import_batches for update to authenticated using (public.can_manage_finance(company_id) or uploaded_by=auth.uid()) with check (public.can_manage_finance(company_id) or uploaded_by=auth.uid());

create policy transactions_select on public.bank_transactions for select to authenticated using (public.can_view_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
create policy transactions_insert on public.bank_transactions for insert to authenticated with check (public.can_contribute_company(company_id));
create policy transactions_update on public.bank_transactions for update to authenticated
using (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid())
with check (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
create policy transactions_delete on public.bank_transactions for delete to authenticated using (public.can_manage_finance(company_id));

create policy schedules_select on public.schedules for select to authenticated using (public.can_view_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
create policy schedules_insert on public.schedules for insert to authenticated with check (public.can_contribute_company(company_id));
create policy schedules_update on public.schedules for update to authenticated
using (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid())
with check (public.can_manage_finance(company_id) or owner_id=auth.uid() or created_by=auth.uid());
create policy schedules_delete on public.schedules for delete to authenticated using (public.can_manage_finance(company_id) or created_by=auth.uid());

create policy products_select on public.financial_products for select to authenticated using (public.can_view_finance(company_id));
create policy products_write on public.financial_products for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

create policy monthly_plans_select on public.monthly_plans for select to authenticated using (public.can_view_finance(company_id));
create policy monthly_plans_write on public.monthly_plans for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

create policy asset_positions_select on public.asset_positions for select to authenticated using (public.can_view_finance(company_id));
create policy asset_positions_write on public.asset_positions for all to authenticated using (public.can_manage_finance(company_id)) with check (public.can_manage_finance(company_id));

-- Reports and approval data
create policy reports_select on public.reports for select to authenticated
using (public.can_view_company_or_report(company_id, created_by) or public.is_report_approver(id));
create policy reports_insert on public.reports for insert to authenticated
with check (
  created_by=auth.uid()
  and ((company_id is null and public.current_role() in ('admin','finance_manager'))
       or (company_id is not null and public.can_manage_finance(company_id)))
);
create policy reports_update on public.reports for update to authenticated
using (
  (company_id is null and public.current_role() in ('admin','finance_manager'))
  or (company_id is not null and public.can_manage_finance(company_id))
)
with check (
  (company_id is null and public.current_role() in ('admin','finance_manager'))
  or (company_id is not null and public.can_manage_finance(company_id))
);
create policy reports_delete on public.reports for delete to authenticated
using (
  status='draft'
  and ((company_id is null and public.current_role() in ('admin','finance_manager'))
       or (company_id is not null and public.can_manage_finance(company_id)))
);

create policy report_versions_select on public.report_versions for select to authenticated
using (public.can_view_report(report_id));
create policy report_versions_insert on public.report_versions for insert to authenticated
with check (exists(
  select 1 from public.reports r
  where r.id=report_id
    and ((r.company_id is null and public.current_role() in ('admin','finance_manager'))
         or (r.company_id is not null and public.can_manage_finance(r.company_id)))
));

create policy approval_steps_select on public.approval_steps for select to authenticated
using (approver_id=auth.uid() or public.can_view_report(report_id));
-- Direct updates are intentionally blocked. Use act_on_report RPC.

create policy audit_logs_select on public.audit_logs for select to authenticated
using (public.is_admin() or public.current_role() in ('finance_manager','auditor','executive') or (company_id is not null and public.has_company_access(company_id)));

-- =========================================================
-- 8. Storage bucket and policies
-- =========================================================
insert into storage.buckets(id, name, public)
values ('finance-files','finance-files',false)
on conflict (id) do nothing;

create policy finance_files_select on storage.objects for select to authenticated
using (
  bucket_id='finance-files'
  and (
    public.can_view_finance(nullif((storage.foldername(name))[1],'')::uuid)
    or nullif((storage.foldername(name))[2],'')::uuid = auth.uid()
  )
);

create policy finance_files_insert on storage.objects for insert to authenticated
with check (
  bucket_id='finance-files'
  and public.can_contribute_company(nullif((storage.foldername(name))[1],'')::uuid)
);

create policy finance_files_update on storage.objects for update to authenticated
using (
  bucket_id='finance-files'
  and public.can_manage_finance(nullif((storage.foldername(name))[1],'')::uuid)
)
with check (
  bucket_id='finance-files'
  and public.can_manage_finance(nullif((storage.foldername(name))[1],'')::uuid)
);

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

-- Service role is used only in Netlify Functions, never in the browser.
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

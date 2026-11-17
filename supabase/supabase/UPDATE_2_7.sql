begin;
alter table public.financial_products add column if not exists manual_balance boolean default false;
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
  if p.manual_balance then raise exception '수동 잔액 관리 상품입니다. 현재 잔액을 직접 수정하세요.'; end if;
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

commit;

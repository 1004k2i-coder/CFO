begin;
create or replace function public.review_transactions(p_rows jsonb,p_confirm boolean default true) returns integer language plpgsql security definer set search_path='' as $$
declare r jsonb; t public.bank_transactions; c public.finance_categories; sid uuid; n integer:=0;
begin
 if not public.device_allowed() or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>500 then raise exception '승인 기기에서 최대 500건씩 처리하세요.'; end if;
 for r in select value from jsonb_array_elements(p_rows) loop
  select * into t from public.bank_transactions where id=(r->>'id')::uuid for update;
  if t.id is null or not public.has_company_access(t.company_id) or not (public.can_manage_finance(t.company_id) or t.owner_id=auth.uid() or t.created_by=auth.uid()) then raise exception '변경 권한이 없는 거래가 포함되어 있습니다.'; end if;
  select * into c from public.finance_categories where id=(r->>'category_id')::uuid;
  if c.id is null or not c.active or (c.company_id is not null and c.company_id<>t.company_id) then raise exception '유효한 확정 분류를 선택하세요.'; end if;
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

commit;

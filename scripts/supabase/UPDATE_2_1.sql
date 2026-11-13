-- 버전 2.0이 설치된 기존 프로젝트에 이 파일 전체만 한 번 실행하세요.
-- 계정·기기·재무자료를 삭제하지 않습니다. 재실행해도 승인 상태를 초기화하지 않습니다.
begin;
-- 사용자 승인 상태를 추가합니다. 기존 계정과 기기는 유지합니다.
alter table public.profiles add column if not exists approval_status text not null default 'approved' check(approval_status in ('pending','approved','rejected'));
alter table public.profiles add column if not exists approved_at timestamptz;
alter table public.profiles add column if not exists approved_by uuid references public.profiles(id);
alter table public.profiles alter column approval_status set default 'pending';
alter table public.profiles alter column active set default false;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,email,full_name,department,role,active,approval_status)
 values(new.id,new.email,left(coalesce(new.raw_user_meta_data->>'full_name',split_part(coalesce(new.email,''),'@',1)),100),left(new.raw_user_meta_data->>'department',100),'business_user',false,'pending')
 on conflict(id) do update set email=excluded.email,updated_at=now();
 return new;
end $$;

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

revoke all on function public.handle_new_user() from public,anon,authenticated;
revoke all on function public.device_allowed(), public.device_status(), public.register_device(text), public.admin_users(jsonb), public.set_device_status(uuid,text) from public,anon,authenticated;
grant execute on function public.device_allowed(), public.device_status(), public.register_device(text), public.admin_users(jsonb), public.set_device_status(uuid,text) to authenticated;

commit;
select '사용자 승인 기능 업데이트 완료' as result;

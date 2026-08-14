-- STO Network Product Admin - 회원 이름 변경
-- 회원 상세에 접근 가능한 활성 관리자라면 등급과 무관하게 member.mb_name만 변경할 수 있다.
-- 과거 transactions/metadata는 수정하지 않고 admin_action_logs에 before/after 및 사유를 기록한다.

create or replace function public.rpc_admin_update_member_name(
  p_user_id uuid,
  p_name text,
  p_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_target public.member%rowtype;
  v_previous_name text;
  v_new_name text := nullif(trim(coalesce(p_name, '')), '');
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_log_id uuid;
begin
  -- rpc_admin_get_member와 동일한 기본 관리자 인증을 사용한다.
  -- admin grade(team_lead/center_director/headquarters)에 따른 추가 제한은 두지 않는다.
  v_admin := private.require_admin();

  if p_user_id is null then
    raise exception using errcode = 'P0001', message = 'MEMBER_REQUIRED';
  end if;

  if v_new_name is null then
    raise exception using errcode = 'P0001', message = 'MEMBER_NAME_REQUIRED';
  end if;
  if char_length(v_new_name) > 100 then
    raise exception using errcode = 'P0001', message = 'MEMBER_NAME_TOO_LONG';
  end if;

  if v_reason is null or char_length(v_reason) < 2 then
    raise exception using errcode = 'P0001', message = 'MEMBER_NAME_CHANGE_REASON_REQUIRED';
  end if;
  if char_length(v_reason) > 300 then
    raise exception using errcode = 'P0001', message = 'MEMBER_NAME_CHANGE_REASON_TOO_LONG';
  end if;

  select *
    into v_target
    from public.member m
   where m.user_id = p_user_id
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  v_previous_name := v_target.mb_name;

  if trim(coalesce(v_previous_name, '')) = v_new_name then
    raise exception using errcode = 'P0001', message = 'MEMBER_NAME_UNCHANGED';
  end if;

  begin
    update public.member
       set mb_name = v_new_name,
           updated_at = now()
     where user_id = p_user_id;
  exception
    when unique_violation then
      raise exception using errcode = 'P0001', message = 'MEMBER_NAME_ALREADY_EXISTS';
  end;

  insert into public.admin_action_logs(
    actor_user_id,
    action_type,
    target_user_id,
    reason,
    before_data,
    after_data,
    metadata
  ) values (
    v_admin.user_id,
    'member.name_update',
    p_user_id,
    v_reason,
    jsonb_build_object('mb_name', v_previous_name),
    jsonb_build_object('mb_name', v_new_name),
    jsonb_build_object(
      'targetMemberId', v_target.mb_id,
      'source', 'member_detail'
    )
  ) returning id into v_log_id;

  return jsonb_build_object(
    'userId', p_user_id,
    'memberId', v_target.mb_id,
    'previousName', v_previous_name,
    'name', v_new_name,
    'reason', v_reason,
    'adminLogId', v_log_id
  );
end;
$$;

revoke all on function public.rpc_admin_update_member_name(uuid, text, text) from public, anon;
grant execute on function public.rpc_admin_update_member_name(uuid, text, text) to authenticated;

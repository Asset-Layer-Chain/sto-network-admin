-- 063: Restrict node application reads to center directors and headquarters.
-- Run after 062. Re-create the existing RPCs without changing result contracts.
-- In particular, no changes to update RPC, audit history, or member-facing RPC.

create or replace function public.rpc_admin_get_session()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_grade_label text;
begin
  v_admin := private.require_admin();
  v_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  v_grade_label := case v_grade
    when 'team_lead' then '팀장급'
    when 'center_director' then '센터장'
    when 'headquarters' then '본부'
    else '자산 권한 미설정'
  end;

  return jsonb_build_object(
    'userId', v_admin.user_id,
    'memberNo', v_admin.mb_no,
    'memberId', v_admin.mb_id,
    'name', v_admin.mb_name,
    'email', v_admin.mb_email,
    'profile', v_admin.mb_profile,
    'role', v_admin.role,
    'adminGrade', v_grade,
    'adminGradeLabel', v_grade_label,
    'permissions', jsonb_build_object(
      'memberRead', true,
      'memberListBrowse', v_grade is distinct from 'team_lead',
      'memberSearch', true,
      'assetDeposit', v_grade = 'headquarters',
      'assetWithdrawal', v_grade in ('center_director', 'headquarters'),
      'assetAirdrop', v_grade in ('team_lead', 'center_director', 'headquarters'),
      'reasonPresetManage', v_grade in ('center_director', 'headquarters'),
      'bulkDepositManage', v_grade = 'headquarters',
      'memberReactivate', v_grade = 'headquarters',
      'memberPinReset', v_grade = 'headquarters',
      'nodeApplicationRead', v_grade in ('center_director', 'headquarters'),
      'nodeApplicationManage', v_grade in ('center_director', 'headquarters'),
      'chatManage', true,
      'adminLogRead', true
    )
  );
end;
$$;

revoke all on function public.rpc_admin_get_session() from public, anon;
grant execute on function public.rpc_admin_get_session() to authenticated;

create or replace function public.rpc_admin_list_node_setup_applications(
  p_search text default null,
  p_status text default null,
  p_from_date date default null,
  p_to_date date default null,
  p_page integer default 1,
  p_page_size integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
  v_digits text := regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g');
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := least(100, greatest(1, coalesce(p_page_size, 30)));
  v_total bigint;
  v_items jsonb;
begin
  v_admin := private.require_admin();
  v_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  if coalesce(v_grade, '') not in ('center_director', 'headquarters') then
    raise exception using
      errcode = 'P0001',
      message = 'NODE_APPLICATION_READ_PERMISSION_DENIED';
  end if;

  if v_status is not null and v_status not in ('pending', 'contacting', 'completed', 'rejected') then
    raise exception using errcode = 'P0001', message = 'NODE_APPLICATION_INVALID_STATUS';
  end if;
  if p_from_date is not null and p_to_date is not null and p_from_date > p_to_date then
    raise exception using errcode = 'P0001', message = 'NODE_APPLICATION_INVALID_DATE_RANGE';
  end if;
  if v_search is not null and char_length(v_search) > 100 then
    raise exception using errcode = 'P0001', message = 'NODE_APPLICATION_SEARCH_TOO_LONG';
  end if;

  select count(*) into v_total
    from public.node_setup_applications a
    join public.member m on m.user_id = a.user_id
   where (v_status is null or a.status = v_status)
     and (p_from_date is null or a.created_at >= (p_from_date::timestamp at time zone 'Asia/Seoul'))
     and (p_to_date is null or a.created_at < ((p_to_date + 1)::timestamp at time zone 'Asia/Seoul'))
     and (v_search is null or m.mb_id ilike '%' || v_search || '%'
          or m.mb_name ilike '%' || v_search || '%'
          or m.mb_hp ilike '%' || v_search || '%'
          or a.gopax_memo_id ilike '%' || v_search || '%'
          or (v_digits <> '' and v_search ~ '^[0-9 +().-]+$'
              and regexp_replace(coalesce(m.mb_hp, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'));

  select coalesce(jsonb_agg(q.item order by q.created_at desc, q.id desc), '[]'::jsonb)
    into v_items
    from (
      select a.id, a.created_at,
             jsonb_build_object(
               'id', a.id,
               'userId', a.user_id,
               'memberId', m.mb_id,
               'memberName', m.mb_name,
               'phone', m.mb_hp,
               'gopaxMemoId', a.gopax_memo_id,
               'status', a.status,
               'createdAt', a.created_at,
               'updatedAt', a.updated_at
             ) as item
        from public.node_setup_applications a
        join public.member m on m.user_id = a.user_id
       where (v_status is null or a.status = v_status)
         and (p_from_date is null or a.created_at >= (p_from_date::timestamp at time zone 'Asia/Seoul'))
         and (p_to_date is null or a.created_at < ((p_to_date + 1)::timestamp at time zone 'Asia/Seoul'))
         and (v_search is null or m.mb_id ilike '%' || v_search || '%'
              or m.mb_name ilike '%' || v_search || '%'
              or m.mb_hp ilike '%' || v_search || '%'
              or a.gopax_memo_id ilike '%' || v_search || '%'
              or (v_digits <> '' and v_search ~ '^[0-9 +().-]+$'
              and regexp_replace(coalesce(m.mb_hp, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))
       order by a.created_at desc, a.id desc
       limit v_page_size
       offset (v_page::bigint - 1) * v_page_size
    ) q;

  return jsonb_build_object(
    'items', v_items,
    'page', v_page,
    'pageSize', v_page_size,
    'totalCount', v_total
  );
end;
$$;

create or replace function public.rpc_admin_get_node_setup_application(p_application_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_application jsonb;
  v_history jsonb;
begin
  v_admin := private.require_admin();
  v_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  if coalesce(v_grade, '') not in ('center_director', 'headquarters') then
    raise exception using
      errcode = 'P0001',
      message = 'NODE_APPLICATION_READ_PERMISSION_DENIED';
  end if;

  if p_application_id is null then
    raise exception using errcode = 'P0001', message = 'NODE_APPLICATION_REQUIRED';
  end if;

  select jsonb_build_object(
    'id', a.id,
    'userId', a.user_id,
    'memberId', m.mb_id,
    'memberName', m.mb_name,
    'phone', m.mb_hp,
    'email', m.mb_email,
    'memberStatus', m.status,
    'memberDeleted', m.is_del,
    'gopaxMemoId', a.gopax_memo_id,
    'status', a.status,
    'adminNote', a.admin_note,
    'createdAt', a.created_at,
    'updatedAt', a.updated_at
  ) into v_application
    from public.node_setup_applications a
    join public.member m on m.user_id = a.user_id
   where a.id = p_application_id;

  if v_application is null then
    raise exception using errcode = 'P0001', message = 'NODE_APPLICATION_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(h.item order by h.created_at desc, h.id desc), '[]'::jsonb)
    into v_history
    from (
      select l.id, l.created_at,
             jsonb_build_object(
               'id', l.id,
               'actorMemberId', actor.mb_id,
               'actorName', actor.mb_name,
               'beforeStatus', l.before_data ->> 'status',
               'afterStatus', l.after_data ->> 'status',
               'answer', l.after_data ->> 'adminNote',
               'createdAt', l.created_at
             ) as item
        from public.admin_action_logs l
        left join public.member actor on actor.user_id = l.actor_user_id
       where l.action_type = 'node_application.update'
         and l.metadata ->> 'applicationId' = p_application_id::text
       order by l.created_at desc, l.id desc
       limit 30
    ) h;

  return jsonb_build_object('application', v_application, 'history', v_history);
end;
$$;

revoke all on function public.rpc_admin_list_node_setup_applications(text, text, date, date, integer, integer) from public, anon, authenticated;
revoke all on function public.rpc_admin_get_node_setup_application(uuid) from public, anon, authenticated;
grant execute on function public.rpc_admin_list_node_setup_applications(text, text, date, date, integer, integer) to authenticated;
grant execute on function public.rpc_admin_get_node_setup_application(uuid) to authenticated;

notify pgrst, 'reload schema';

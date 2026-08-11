-- STO Network Product Admin - 전화번호 검색 조건 엄격화 hotfix
-- 영문/아이디 검색어에 포함된 숫자 1~2개가 전화번호 검색으로 확장되는 문제를 막는다.
-- 전화번호 검색은 검색어가 전화번호 문자만 포함하고 숫자 길이가 10자리 이상일 때만 활성화한다.

create index if not exists member_admin_phone_digits_idx
  on public.member (private.normalize_admin_bulk_pos_phone(mb_hp));

create or replace function public.rpc_admin_list_members(
  p_search text default null,
  p_status text default null,
  p_role text default null,
  p_signup_method text default null,
  p_reg_channel text default null,
  p_is_deleted boolean default null,
  p_page integer default 1,
  p_page_size integer default 30,
  p_sort_column text default 'created_at',
  p_sort_direction text default 'desc'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_search_only boolean;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer;
  v_offset integer;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_sort_column text := lower(coalesce(p_sort_column, 'created_at'));
  v_sort_direction text := lower(coalesce(p_sort_direction, 'desc'));
  v_total bigint;
  v_items jsonb;
  v_search_phone text;
  v_search_phone_enabled boolean;
begin
  v_search_phone := regexp_replace(coalesce(v_search, ''), '[^0-9]', '', 'g');
  v_search_phone_enabled := coalesce(v_search ~ '^[0-9[:space:].+()/-]+$', false) and length(v_search_phone) >= 10;
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  v_search_only := v_admin_grade = 'team_lead';
  v_page_size := case
    when v_search_only then least(greatest(coalesce(p_page_size, 20), 1), 20)
    else least(greatest(coalesce(p_page_size, 30), 1), 100)
  end;
  v_offset := (v_page - 1) * v_page_size;

  if v_search_only and v_search is null then
    return jsonb_build_object(
      'items', '[]'::jsonb,
      'page', 1,
      'pageSize', v_page_size,
      'totalCount', 0,
      'searchRequired', true
    );
  end if;

  if v_sort_column not in ('mb_no', 'mb_id', 'mb_name', 'mb_email', 'status', 'role', 'last_login_at', 'created_at', 'updated_at', 'internal_stoc_balance') then
    v_sort_column := 'created_at';
  end if;
  if v_sort_direction not in ('asc', 'desc') then
    v_sort_direction := 'desc';
  end if;

  with filtered as (
    select m.*,
           coalesce(wa.available_balance, 0::numeric) as internal_stoc_balance
      from public.member m
      left join public.wallet_accounts wa
        on wa.user_id = m.user_id
       and wa.asset_code = 'STOC_INT'
       and wa.account_type = 'internal'
     where (
       case
         when v_search_only then
           private.team_lead_member_search_match(
             m.user_id, m.mb_no, m.mb_id, m.mb_name, m.mb_email, m.mb_hp, v_search
           )
           or exists (
             select 1
               from public.wallet_addresses wad
              where wad.user_id = m.user_id
                and lower(wad.address) = lower(v_search)
           )
         else v_search is null or
              m.mb_id ilike '%' || v_search || '%' or
              m.mb_name ilike '%' || v_search || '%' or
              m.mb_email ilike '%' || v_search || '%' or
              coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
              (v_search_phone_enabled and regexp_replace(coalesce(m.mb_hp, ''), '[^0-9]', '', 'g') ilike '%' || v_search_phone || '%') or
              m.user_id::text ilike '%' || v_search || '%' or
              m.mb_no::text ilike '%' || v_search || '%' or
              m.referral_code ilike '%' || v_search || '%' or
              exists (
                select 1
                  from public.wallet_addresses wad
                 where wad.user_id = m.user_id
                   and wad.address ilike '%' || v_search || '%'
              )
       end
     )
       and (p_status is null or p_status = '' or m.status = p_status)
       and (p_role is null or p_role = '' or m.role = p_role)
       and (p_signup_method is null or p_signup_method = '' or m.signup_method = p_signup_method)
       and (p_reg_channel is null or p_reg_channel = '' or m.reg_channel = p_reg_channel)
       and (p_is_deleted is null or coalesce(m.is_del, false) = p_is_deleted)
  )
  select count(*) into v_total from filtered;

  with filtered as (
    select m.*,
           coalesce(wa.available_balance, 0::numeric) as internal_stoc_balance
      from public.member m
      left join public.wallet_accounts wa
        on wa.user_id = m.user_id
       and wa.asset_code = 'STOC_INT'
       and wa.account_type = 'internal'
     where (
       case
         when v_search_only then
           private.team_lead_member_search_match(
             m.user_id, m.mb_no, m.mb_id, m.mb_name, m.mb_email, m.mb_hp, v_search
           )
           or exists (
             select 1
               from public.wallet_addresses wad
              where wad.user_id = m.user_id
                and lower(wad.address) = lower(v_search)
           )
         else v_search is null or
              m.mb_id ilike '%' || v_search || '%' or
              m.mb_name ilike '%' || v_search || '%' or
              m.mb_email ilike '%' || v_search || '%' or
              coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
              (v_search_phone_enabled and regexp_replace(coalesce(m.mb_hp, ''), '[^0-9]', '', 'g') ilike '%' || v_search_phone || '%') or
              m.user_id::text ilike '%' || v_search || '%' or
              m.mb_no::text ilike '%' || v_search || '%' or
              m.referral_code ilike '%' || v_search || '%' or
              exists (
                select 1
                  from public.wallet_addresses wad
                 where wad.user_id = m.user_id
                   and wad.address ilike '%' || v_search || '%'
              )
       end
     )
       and (p_status is null or p_status = '' or m.status = p_status)
       and (p_role is null or p_role = '' or m.role = p_role)
       and (p_signup_method is null or p_signup_method = '' or m.signup_method = p_signup_method)
       and (p_reg_channel is null or p_reg_channel = '' or m.reg_channel = p_reg_channel)
       and (p_is_deleted is null or coalesce(m.is_del, false) = p_is_deleted)
  ), page_data as (
    select *
      from filtered f
     order by
       case when v_sort_column = 'mb_no' and v_sort_direction = 'asc' then f.mb_no end asc,
       case when v_sort_column = 'mb_no' and v_sort_direction = 'desc' then f.mb_no end desc,
       case when v_sort_column = 'mb_id' and v_sort_direction = 'asc' then f.mb_id end asc,
       case when v_sort_column = 'mb_id' and v_sort_direction = 'desc' then f.mb_id end desc,
       case when v_sort_column = 'mb_name' and v_sort_direction = 'asc' then f.mb_name end asc,
       case when v_sort_column = 'mb_name' and v_sort_direction = 'desc' then f.mb_name end desc,
       case when v_sort_column = 'mb_email' and v_sort_direction = 'asc' then f.mb_email end asc,
       case when v_sort_column = 'mb_email' and v_sort_direction = 'desc' then f.mb_email end desc,
       case when v_sort_column = 'status' and v_sort_direction = 'asc' then f.status end asc,
       case when v_sort_column = 'status' and v_sort_direction = 'desc' then f.status end desc,
       case when v_sort_column = 'role' and v_sort_direction = 'asc' then f.role end asc,
       case when v_sort_column = 'role' and v_sort_direction = 'desc' then f.role end desc,
       case when v_sort_column = 'last_login_at' and v_sort_direction = 'asc' then f.last_login_at end asc nulls last,
       case when v_sort_column = 'last_login_at' and v_sort_direction = 'desc' then f.last_login_at end desc nulls last,
       case when v_sort_column = 'created_at' and v_sort_direction = 'asc' then f.created_at end asc,
       case when v_sort_column = 'created_at' and v_sort_direction = 'desc' then f.created_at end desc,
       case when v_sort_column = 'updated_at' and v_sort_direction = 'asc' then f.updated_at end asc,
       case when v_sort_column = 'updated_at' and v_sort_direction = 'desc' then f.updated_at end desc,
       case when v_sort_column = 'internal_stoc_balance' and v_sort_direction = 'asc' then f.internal_stoc_balance end asc,
       case when v_sort_column = 'internal_stoc_balance' and v_sort_direction = 'desc' then f.internal_stoc_balance end desc,
       f.user_id
     offset v_offset
     limit v_page_size
  )
  select coalesce(jsonb_agg(
           to_jsonb(page_data) || jsonb_build_object(
             'internal_stoc_balance', page_data.internal_stoc_balance::text
           )
         ), '[]'::jsonb)
    into v_items
    from page_data;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'page', v_page,
    'pageSize', v_page_size,
    'totalCount', coalesce(v_total, 0),
    'searchRequired', false
  );
end;
$$;

create or replace function public.rpc_admin_search_members(
  p_search text default null,
  p_limit integer default 30,
  p_exclude_room_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_search_only boolean;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_limit integer;
  v_result jsonb;
  v_search_phone text;
  v_search_phone_enabled boolean;
begin
  v_search_phone := regexp_replace(coalesce(v_search, ''), '[^0-9]', '', 'g');
  v_search_phone_enabled := coalesce(v_search ~ '^[0-9[:space:].+()/-]+$', false) and length(v_search_phone) >= 10;
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  v_search_only := v_admin_grade = 'team_lead';
  v_limit := case
    when v_search_only then least(greatest(coalesce(p_limit, 20), 1), 20)
    else least(greatest(coalesce(p_limit, 30), 1), 100)
  end;

  if v_search_only and v_search is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'userId', m.user_id,
    'memberNo', m.mb_no,
    'memberId', m.mb_id,
    'name', m.mb_name,
    'email', m.mb_email,
    'phone', m.mb_hp,
    'profile', m.mb_profile,
    'role', m.role,
    'status', m.status
  ) order by m.mb_name, m.mb_id), '[]'::jsonb)
    into v_result
    from (
      select m.*
        from public.member m
       where m.status = 'active'
         and not coalesce(m.is_del, false)
         and m.user_id <> v_admin.user_id
         and (
           case
             when v_search_only then private.team_lead_member_search_match(
               m.user_id, m.mb_no, m.mb_id, m.mb_name, m.mb_email, m.mb_hp, v_search
             )
             else v_search is null or
                  m.mb_id ilike '%' || v_search || '%' or
                  m.mb_name ilike '%' || v_search || '%' or
                  m.mb_email ilike '%' || v_search || '%' or
                  coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
                  (v_search_phone_enabled and regexp_replace(coalesce(m.mb_hp, ''), '[^0-9]', '', 'g') ilike '%' || v_search_phone || '%') or
                  m.user_id::text ilike '%' || v_search || '%'
           end
         )
         and (p_exclude_room_id is null or not exists (
           select 1 from public.chat_members cm
            where cm.room_id = p_exclude_room_id
              and cm.user_id = m.user_id
              and cm.left_at is null
         ))
       order by m.mb_name, m.mb_id
       limit v_limit
    ) m;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

revoke all on function public.rpc_admin_list_members(text, text, text, text, text, boolean, integer, integer, text, text) from public, anon;
revoke all on function public.rpc_admin_search_members(text, integer, uuid) from public, anon;

grant execute on function public.rpc_admin_list_members(text, text, text, text, text, boolean, integer, integer, text, text) to authenticated;
grant execute on function public.rpc_admin_search_members(text, integer, uuid) to authenticated;

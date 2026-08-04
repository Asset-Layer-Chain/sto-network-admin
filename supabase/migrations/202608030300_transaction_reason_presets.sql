-- STO Network Product Admin - 자산 처리 사유 프리셋
-- 처리 사유 프리셋은 센터장(center_director) 이상만 추가·수정·삭제할 수 있다.

create table if not exists public.admin_transaction_reason_presets (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('deposit', 'withdrawal', 'airdrop')),
  label text not null,
  reason_text text not null,
  sort_order integer not null default 0,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_by uuid references public.member(user_id),
  updated_by uuid references public.member(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists admin_transaction_reason_presets_action_active_idx
  on public.admin_transaction_reason_presets(action, is_active, sort_order, label);

create unique index if not exists admin_transaction_reason_presets_default_uidx
  on public.admin_transaction_reason_presets(action)
  where is_default and is_active;

alter table public.admin_transaction_reason_presets enable row level security;
revoke all on public.admin_transaction_reason_presets from public, anon, authenticated;

create or replace function private.touch_admin_transaction_reason_presets_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.touch_admin_transaction_reason_presets_updated_at() from public, anon, authenticated;
drop trigger if exists admin_transaction_reason_presets_touch_updated_at on public.admin_transaction_reason_presets;
create trigger admin_transaction_reason_presets_touch_updated_at
before update on public.admin_transaction_reason_presets
for each row execute function private.touch_admin_transaction_reason_presets_updated_at();

create or replace function private.require_admin_reason_preset_manage_permission(
  p_user_id uuid,
  p_member_role text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_grade text;
begin
  v_grade := private.admin_grade_for(p_user_id, p_member_role);

  if v_grade not in ('center_director', 'headquarters') then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_MANAGE_PERMISSION_DENIED';
  end if;

  return v_grade;
end;
$$;

create or replace function private.validate_admin_reason_preset_action(p_action text)
returns text
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_action text := lower(trim(coalesce(p_action, '')));
begin
  if v_action not in ('deposit', 'withdrawal', 'airdrop') then
    raise exception using errcode = 'P0001', message = 'INVALID_ADMIN_REASON_PRESET_ACTION';
  end if;
  return v_action;
end;
$$;

create or replace function private.admin_reason_preset_payload(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p.id,
    'action', p.action,
    'label', p.label,
    'reasonText', p.reason_text,
    'sortOrder', p.sort_order,
    'isDefault', p.is_default,
    'isActive', p.is_active,
    'createdBy', p.created_by,
    'updatedBy', p.updated_by,
    'createdAt', p.created_at,
    'updatedAt', p.updated_at
  )
    from public.admin_transaction_reason_presets p
   where p.id = p_id;
$$;

revoke all on function private.require_admin_reason_preset_manage_permission(uuid, text) from public, anon, authenticated;
revoke all on function private.validate_admin_reason_preset_action(text) from public, anon, authenticated;
revoke all on function private.admin_reason_preset_payload(uuid) from public, anon, authenticated;

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
      'chatManage', true,
      'adminLogRead', true
    )
  );
end;
$$;

create or replace function public.rpc_admin_list_transaction_reason_presets(
  p_action text default null,
  p_include_inactive boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_action text := null;
  v_items jsonb;
begin
  v_admin := private.require_admin();

  if nullif(trim(coalesce(p_action, '')), '') is not null then
    v_action := private.validate_admin_reason_preset_action(p_action);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'action', p.action,
    'label', p.label,
    'reasonText', p.reason_text,
    'sortOrder', p.sort_order,
    'isDefault', p.is_default,
    'isActive', p.is_active,
    'createdBy', p.created_by,
    'updatedBy', p.updated_by,
    'createdAt', p.created_at,
    'updatedAt', p.updated_at
  ) order by p.action, p.sort_order, p.label), '[]'::jsonb)
    into v_items
    from public.admin_transaction_reason_presets p
   where (v_action is null or p.action = v_action)
     and (p_include_inactive or p.is_active);

  return coalesce(v_items, '[]'::jsonb);
end;
$$;

create or replace function public.rpc_admin_create_transaction_reason_preset(
  p_action text,
  p_label text,
  p_reason_text text,
  p_sort_order integer default 0,
  p_is_default boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_action text;
  v_label text := trim(coalesce(p_label, ''));
  v_reason_text text := trim(coalesce(p_reason_text, ''));
  v_id uuid;
begin
  v_admin := private.require_admin();
  v_grade := private.require_admin_reason_preset_manage_permission(v_admin.user_id, v_admin.role);
  v_action := private.validate_admin_reason_preset_action(p_action);

  if char_length(v_label) < 2 then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_LABEL_REQUIRED';
  end if;
  if char_length(v_reason_text) < 2 then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_TEXT_REQUIRED';
  end if;

  if coalesce(p_is_default, false) then
    update public.admin_transaction_reason_presets
       set is_default = false,
           updated_by = v_admin.user_id,
           updated_at = now()
     where action = v_action
       and is_default;
  end if;

  insert into public.admin_transaction_reason_presets(
    action, label, reason_text, sort_order, is_default, is_active, created_by, updated_by
  ) values (
    v_action, left(v_label, 80), left(v_reason_text, 300), coalesce(p_sort_order, 0), coalesce(p_is_default, false), true, v_admin.user_id, v_admin.user_id
  ) returning id into v_id;

  insert into public.admin_action_logs(
    actor_user_id, action_type, reason, before_data, after_data, metadata
  ) values (
    v_admin.user_id,
    'reason_preset.create',
    v_reason_text,
    '{}'::jsonb,
    private.admin_reason_preset_payload(v_id),
    jsonb_build_object('adminGrade', v_grade)
  );

  return private.admin_reason_preset_payload(v_id);
end;
$$;

create or replace function public.rpc_admin_update_transaction_reason_preset(
  p_id uuid,
  p_action text,
  p_label text,
  p_reason_text text,
  p_sort_order integer default 0,
  p_is_default boolean default false,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_action text;
  v_label text := trim(coalesce(p_label, ''));
  v_reason_text text := trim(coalesce(p_reason_text, ''));
  v_before jsonb;
  v_id uuid;
begin
  v_admin := private.require_admin();
  v_grade := private.require_admin_reason_preset_manage_permission(v_admin.user_id, v_admin.role);
  v_action := private.validate_admin_reason_preset_action(p_action);

  if char_length(v_label) < 2 then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_LABEL_REQUIRED';
  end if;
  if char_length(v_reason_text) < 2 then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_TEXT_REQUIRED';
  end if;

  v_before := private.admin_reason_preset_payload(p_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_NOT_FOUND';
  end if;

  if coalesce(p_is_default, false) and coalesce(p_is_active, true) then
    update public.admin_transaction_reason_presets
       set is_default = false,
           updated_by = v_admin.user_id,
           updated_at = now()
     where action = v_action
       and id <> p_id
       and is_default;
  end if;

  update public.admin_transaction_reason_presets
     set action = v_action,
         label = left(v_label, 80),
         reason_text = left(v_reason_text, 300),
         sort_order = coalesce(p_sort_order, 0),
         is_default = case when coalesce(p_is_active, true) then coalesce(p_is_default, false) else false end,
         is_active = coalesce(p_is_active, true),
         updated_by = v_admin.user_id,
         updated_at = now()
   where id = p_id
  returning id into v_id;

  insert into public.admin_action_logs(
    actor_user_id, action_type, reason, before_data, after_data, metadata
  ) values (
    v_admin.user_id,
    'reason_preset.update',
    v_reason_text,
    v_before,
    private.admin_reason_preset_payload(v_id),
    jsonb_build_object('adminGrade', v_grade)
  );

  return private.admin_reason_preset_payload(v_id);
end;
$$;

create or replace function public.rpc_admin_delete_transaction_reason_preset(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_before jsonb;
  v_id uuid;
begin
  v_admin := private.require_admin();
  v_grade := private.require_admin_reason_preset_manage_permission(v_admin.user_id, v_admin.role);

  v_before := private.admin_reason_preset_payload(p_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_NOT_FOUND';
  end if;

  update public.admin_transaction_reason_presets
     set is_active = false,
         is_default = false,
         updated_by = v_admin.user_id,
         updated_at = now()
   where id = p_id
  returning id into v_id;

  insert into public.admin_action_logs(
    actor_user_id, action_type, reason, before_data, after_data, metadata
  ) values (
    v_admin.user_id,
    'reason_preset.delete',
    coalesce(v_before ->> 'reasonText', v_before ->> 'label'),
    v_before,
    private.admin_reason_preset_payload(v_id),
    jsonb_build_object('adminGrade', v_grade)
  );

  return private.admin_reason_preset_payload(v_id);
end;
$$;

revoke all on function public.rpc_admin_get_session() from public, anon;
revoke all on function public.rpc_admin_list_transaction_reason_presets(text, boolean) from public, anon;
revoke all on function public.rpc_admin_create_transaction_reason_preset(text, text, text, integer, boolean) from public, anon;
revoke all on function public.rpc_admin_update_transaction_reason_preset(uuid, text, text, text, integer, boolean, boolean) from public, anon;
revoke all on function public.rpc_admin_delete_transaction_reason_preset(uuid) from public, anon;

grant execute on function public.rpc_admin_get_session() to authenticated;
grant execute on function public.rpc_admin_list_transaction_reason_presets(text, boolean) to authenticated;
grant execute on function public.rpc_admin_create_transaction_reason_preset(text, text, text, integer, boolean) to authenticated;
grant execute on function public.rpc_admin_update_transaction_reason_preset(uuid, text, text, text, integer, boolean, boolean) to authenticated;
grant execute on function public.rpc_admin_delete_transaction_reason_preset(uuid) to authenticated;

insert into public.admin_transaction_reason_presets(action, label, reason_text, sort_order, is_default)
select 'airdrop', '에어드랍', '에어드랍', 10, true
where not exists (
  select 1 from public.admin_transaction_reason_presets
   where action = 'airdrop' and label = '에어드랍' and is_active
);

insert into public.admin_transaction_reason_presets(action, label, reason_text, sort_order, is_default)
select 'deposit', 'STOC 프리세일 참여', 'STOC 프리세일 참여', 10, true
where not exists (
  select 1 from public.admin_transaction_reason_presets
   where action = 'deposit' and label = 'STOC 프리세일 참여' and is_active
);

insert into public.admin_transaction_reason_presets(action, label, reason_text, sort_order, is_default)
select 'withdrawal', '오지급 회수', '오지급 회수', 10, false
where not exists (
  select 1 from public.admin_transaction_reason_presets
   where action = 'withdrawal' and label = '오지급 회수' and is_active
);

select pg_notify('pgrst', 'reload schema');

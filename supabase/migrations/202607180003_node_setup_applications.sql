-- 040: 노드 구성 신청 혜택. 회원당 신청 row 1개를 유지하고, 수정 가능한 상태에서는 같은 row를 업데이트한다.

create table if not exists public.node_setup_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  gopax_memo_id text not null,
  status text not null default 'pending'
    check (status in ('pending', 'contacting', 'completed', 'rejected')),
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id)
);
create index if not exists node_setup_applications_status_created_idx
  on public.node_setup_applications(status, created_at desc);
create index if not exists node_setup_applications_user_updated_idx
  on public.node_setup_applications(user_id, updated_at desc);
drop trigger if exists node_setup_applications_set_updated_at on public.node_setup_applications;
create trigger node_setup_applications_set_updated_at
before update on public.node_setup_applications
for each row execute function public.set_updated_at();
alter table public.node_setup_applications enable row level security;
drop policy if exists node_setup_applications_select_self on public.node_setup_applications;
create policy node_setup_applications_select_self
on public.node_setup_applications for select to authenticated
using (user_id = (select auth.uid()));
create or replace function public.rpc_get_node_setup_application()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_application public.node_setup_applications%rowtype;
begin
  v_member := private.require_active_member();

  select *
    into v_application
    from public.node_setup_applications
   where user_id = v_member.user_id;

  if not found then
    return jsonb_build_object('application', null);
  end if;

  return jsonb_build_object(
    'application', jsonb_build_object(
      'id', v_application.id,
      'applicationId', v_application.id,
      'gopaxMemoId', v_application.gopax_memo_id,
      'status', v_application.status,
      'editable', v_application.status in ('pending', 'rejected'),
      'adminNote', v_application.admin_note,
      'createdAt', v_application.created_at,
      'updatedAt', v_application.updated_at
    )
  );
end;
$$;
create or replace function public.rpc_submit_node_setup_application(p_gopax_memo_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_memo text := btrim(coalesce(p_gopax_memo_id, ''));
  v_existing public.node_setup_applications%rowtype;
  v_application public.node_setup_applications%rowtype;
  v_mode text;
begin
  v_member := private.require_active_member();

  if v_memo = '' then
    return jsonb_build_object(
      'ok', false,
      'code', 'memo_required',
      'message', 'GOPAX STOC 메모 ID를 입력해 주세요.',
      'application', null
    );
  end if;

  if length(v_memo) > 80 then
    return jsonb_build_object(
      'ok', false,
      'code', 'memo_too_long',
      'message', '메모 ID는 80자 이내로 입력해 주세요.',
      'application', null
    );
  end if;

  select *
    into v_existing
    from public.node_setup_applications
   where user_id = v_member.user_id
   for update;

  if found then
    if v_existing.status not in ('pending', 'rejected') then
      return jsonb_build_object(
        'ok', false,
        'code', 'locked',
        'message', '이미 담당자 확인이 진행 중이거나 처리가 완료되어 앱에서 수정할 수 없습니다.',
        'application', jsonb_build_object(
          'id', v_existing.id,
          'applicationId', v_existing.id,
          'gopaxMemoId', v_existing.gopax_memo_id,
          'status', v_existing.status,
          'editable', false,
          'adminNote', v_existing.admin_note,
          'createdAt', v_existing.created_at,
          'updatedAt', v_existing.updated_at
        )
      );
    end if;

    update public.node_setup_applications
       set gopax_memo_id = v_memo,
           status = 'pending',
           admin_note = case when status = 'rejected' then null else admin_note end
     where id = v_existing.id
     returning * into v_application;

    v_mode := 'updated';
  else
    insert into public.node_setup_applications(user_id, gopax_memo_id, status)
    values (v_member.user_id, v_memo, 'pending')
    returning * into v_application;

    v_mode := 'created';
  end if;

  return jsonb_build_object(
    'ok', true,
    'mode', v_mode,
    'message', case
      when v_mode = 'created' then '노드 구성 신청이 완료되었습니다.'
      else '신청 내역이 수정되었습니다.'
    end,
    'application', jsonb_build_object(
      'id', v_application.id,
      'applicationId', v_application.id,
      'gopaxMemoId', v_application.gopax_memo_id,
      'status', v_application.status,
      'editable', v_application.status in ('pending', 'rejected'),
      'adminNote', v_application.admin_note,
      'createdAt', v_application.created_at,
      'updatedAt', v_application.updated_at
    )
  );
end;
$$;
revoke all on function public.rpc_get_node_setup_application() from public, anon, authenticated;
revoke all on function public.rpc_submit_node_setup_application(text) from public, anon, authenticated;
grant execute on function public.rpc_get_node_setup_application() to authenticated;
grant execute on function public.rpc_submit_node_setup_application(text) to authenticated;
notify pgrst, 'reload schema';

-- STO & RWA OX quiz / daily two-question reward feature
-- Prerequisites: 202607170001_initial_schema.sql, 202607170002_core_rpc.sql

create table if not exists public.ox_quiz_questions (
  id uuid primary key default gen_random_uuid(),
  content_order integer not null unique check (content_order > 0),
  source_set text not null,
  source_no integer not null check (source_no > 0),
  category text not null default '',
  difficulty text not null default 'general',
  question text not null,
  correct_answer text not null check (correct_answer in ('O', 'X')),
  explanation text not null,
  content_version integer not null default 1 check (content_version > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_set, source_no)
);
create index if not exists ox_quiz_questions_active_order_idx
  on public.ox_quiz_questions(is_active, content_order);
create table if not exists public.ox_quiz_daily_sets (
  id uuid primary key default gen_random_uuid(),
  quiz_date date not null,
  question_order smallint not null check (question_order between 1 and 2),
  question_id uuid not null references public.ox_quiz_questions(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (quiz_date, question_order),
  unique (quiz_date, question_id)
);
create index if not exists ox_quiz_daily_sets_date_idx
  on public.ox_quiz_daily_sets(quiz_date, question_order);
create table if not exists public.ox_quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  quiz_date date not null,
  question_order smallint not null check (question_order between 1 and 2),
  question_id uuid not null references public.ox_quiz_questions(id) on delete restrict,
  selected_answer text not null check (selected_answer in ('O', 'X')),
  is_correct boolean not null,
  reward_amount numeric(36, 18) not null default 0 check (reward_amount in (0, 1)),
  transaction_id uuid unique references public.transactions(id) on delete set null,
  idempotency_key text not null unique,
  answered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, quiz_date, question_order),
  unique (user_id, quiz_date, question_id)
);
create index if not exists ox_quiz_attempts_user_date_idx
  on public.ox_quiz_attempts(user_id, quiz_date desc, answered_at desc);
create index if not exists ox_quiz_attempts_user_result_idx
  on public.ox_quiz_attempts(user_id, is_correct, answered_at desc);
alter table public.ox_quiz_questions enable row level security;
alter table public.ox_quiz_daily_sets enable row level security;
alter table public.ox_quiz_attempts enable row level security;
revoke all on public.ox_quiz_questions from anon, authenticated;
revoke all on public.ox_quiz_daily_sets from anon, authenticated;
revoke all on public.ox_quiz_attempts from anon, authenticated;
create or replace function private.ensure_ox_quiz_daily_set(p_quiz_date date)
returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_count integer;
  v_day_index bigint;
  v_order smallint;
  v_offset integer;
  v_question_id uuid;
begin
  if p_quiz_date is null then
    raise exception 'OX_QUIZ_DATE_REQUIRED';
  end if;

  select count(*) into v_count
  from public.ox_quiz_questions
  where is_active;

  if v_count < 2 then
    raise exception 'OX_QUIZ_QUESTIONS_NOT_READY';
  end if;

  v_day_index := p_quiz_date - date '2026-07-17';

  for v_order in 1..2 loop
    if exists (
      select 1
      from public.ox_quiz_daily_sets
      where quiz_date = p_quiz_date
        and question_order = v_order
    ) then
      continue;
    end if;

    v_offset := (((v_day_index * 2 + (v_order - 1)) % v_count) + v_count) % v_count;

    select id into v_question_id
    from public.ox_quiz_questions
    where is_active
    order by content_order
    offset v_offset
    limit 1;

    insert into public.ox_quiz_daily_sets (
      quiz_date,
      question_order,
      question_id
    ) values (
      p_quiz_date,
      v_order,
      v_question_id
    )
    on conflict (quiz_date, question_order) do nothing;
  end loop;
end;
$$;
create or replace function public.rpc_get_ox_quiz_today()
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_questions jsonb := '[]'::jsonb;
  v_attempt_count integer := 0;
  v_correct_count integer := 0;
  v_reward_total numeric := 0;
begin
  v_member := private.require_active_member();
  perform private.ensure_ox_quiz_daily_set(v_today);

  select
    count(*),
    count(*) filter (where is_correct),
    coalesce(sum(reward_amount), 0)
  into v_attempt_count, v_correct_count, v_reward_total
  from public.ox_quiz_attempts
  where user_id = v_member.user_id
    and quiz_date = v_today;

  select coalesce(jsonb_agg(item order by question_order), '[]'::jsonb)
  into v_questions
  from (
    select
      ds.question_order,
      jsonb_strip_nulls(jsonb_build_object(
        'id', q.id,
        'order', ds.question_order,
        'question', q.question,
        'category', q.category,
        'answered', a.id is not null,
        'selectedAnswer', a.selected_answer,
        'isCorrect', a.is_correct,
        'correctAnswer', case when a.id is not null then q.correct_answer end,
        'explanation', case when a.id is not null then q.explanation end,
        'rewardAmount', a.reward_amount,
        'answeredAt', a.answered_at
      )) as item
    from public.ox_quiz_daily_sets ds
    join public.ox_quiz_questions q on q.id = ds.question_id
    left join public.ox_quiz_attempts a
      on a.user_id = v_member.user_id
     and a.quiz_date = ds.quiz_date
     and a.question_id = ds.question_id
    where ds.quiz_date = v_today
  ) rows_for_day;

  return jsonb_build_object(
    'quizDate', v_today,
    'timeZone', 'Asia/Seoul',
    'maxAttempts', 2,
    'rewardPerCorrect', 1,
    'maxDailyReward', 2,
    'attemptCount', v_attempt_count,
    'correctCount', v_correct_count,
    'rewardTotal', v_reward_total,
    'completed', v_attempt_count >= 2,
    'balance', private.wallet_balance(v_member.user_id, 'STOC_INT'),
    'questions', v_questions
  );
end;
$$;
create or replace function public.rpc_submit_ox_quiz_answer(
  p_question_id uuid,
  p_answer text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_answer text := upper(trim(coalesce(p_answer, '')));
  v_daily public.ox_quiz_daily_sets%rowtype;
  v_question public.ox_quiz_questions%rowtype;
  v_attempt_id uuid := gen_random_uuid();
  v_transaction_id uuid;
  v_is_correct boolean;
  v_attempt_count integer;
  v_correct_count integer;
  v_reward_total numeric;
  v_balance numeric;
  v_request_key text;
begin
  v_member := private.require_active_member();

  if p_question_id is null then
    raise exception 'OX_QUIZ_QUESTION_REQUIRED';
  end if;

  if v_answer not in ('O', 'X') then
    raise exception 'OX_QUIZ_INVALID_ANSWER';
  end if;

  perform private.ensure_ox_quiz_daily_set(v_today);
  perform pg_advisory_xact_lock(
    hashtextextended('ox-quiz:' || v_member.user_id::text || ':' || v_today::text, 0)
  );

  select ds.* into v_daily
  from public.ox_quiz_daily_sets ds
  where ds.quiz_date = v_today
    and ds.question_id = p_question_id
  for update;

  if not found then
    raise exception 'OX_QUIZ_QUESTION_NOT_ASSIGNED';
  end if;

  if exists (
    select 1
    from public.ox_quiz_attempts
    where user_id = v_member.user_id
      and quiz_date = v_today
      and question_id = p_question_id
  ) then
    raise exception 'OX_QUIZ_ALREADY_ANSWERED';
  end if;

  select count(*) into v_attempt_count
  from public.ox_quiz_attempts
  where user_id = v_member.user_id
    and quiz_date = v_today;

  if v_attempt_count >= 2 then
    raise exception 'OX_QUIZ_DAILY_LIMIT_REACHED';
  end if;

  if v_daily.question_order = 2 and not exists (
    select 1
    from public.ox_quiz_attempts
    where user_id = v_member.user_id
      and quiz_date = v_today
      and question_order = 1
  ) then
    raise exception 'OX_QUIZ_PREVIOUS_QUESTION_REQUIRED';
  end if;

  select * into v_question
  from public.ox_quiz_questions
  where id = p_question_id
    and is_active;

  if not found then
    raise exception 'OX_QUIZ_QUESTION_DISABLED';
  end if;

  v_is_correct := v_answer = v_question.correct_answer;
  v_request_key := 'ox-quiz:' || v_member.user_id::text || ':' || v_today::text || ':' || p_question_id::text;

  if v_is_correct then
    v_transaction_id := gen_random_uuid();
    v_balance := private.credit_wallet(v_member.user_id, 'STOC_INT', 1);

    insert into public.transactions (
      id,
      sender_user_id,
      receiver_user_id,
      asset_code,
      amount,
      fee_amount,
      transaction_type,
      status,
      description,
      reference_type,
      reference_id,
      idempotency_key,
      metadata,
      processed_at
    ) values (
      v_transaction_id,
      null,
      v_member.user_id,
      'STOC_INT',
      1,
      0,
      'ox_quiz_reward',
      'completed',
      'OX 퀴즈 정답 보상',
      'ox_quiz',
      v_attempt_id,
      v_request_key,
      jsonb_build_object(
        'quiz_date', v_today,
        'question_id', p_question_id,
        'question_order', v_daily.question_order,
        'request_id', nullif(trim(coalesce(p_idempotency_key, '')), '')
      ),
      now()
    );
  else
    v_balance := private.wallet_balance(v_member.user_id, 'STOC_INT');
  end if;

  insert into public.ox_quiz_attempts (
    id,
    user_id,
    quiz_date,
    question_order,
    question_id,
    selected_answer,
    is_correct,
    reward_amount,
    transaction_id,
    idempotency_key,
    answered_at
  ) values (
    v_attempt_id,
    v_member.user_id,
    v_today,
    v_daily.question_order,
    p_question_id,
    v_answer,
    v_is_correct,
    case when v_is_correct then 1 else 0 end,
    v_transaction_id,
    v_request_key,
    now()
  );

  select
    count(*),
    count(*) filter (where is_correct),
    coalesce(sum(reward_amount), 0)
  into v_attempt_count, v_correct_count, v_reward_total
  from public.ox_quiz_attempts
  where user_id = v_member.user_id
    and quiz_date = v_today;

  return jsonb_build_object(
    'attemptId', v_attempt_id,
    'questionId', p_question_id,
    'questionOrder', v_daily.question_order,
    'selectedAnswer', v_answer,
    'correctAnswer', v_question.correct_answer,
    'isCorrect', v_is_correct,
    'explanation', v_question.explanation,
    'rewardAmount', case when v_is_correct then 1 else 0 end,
    'attemptCount', v_attempt_count,
    'correctCount', v_correct_count,
    'rewardTotal', v_reward_total,
    'completed', v_attempt_count >= 2,
    'balance', v_balance,
    'transactionId', v_transaction_id
  );
end;
$$;
create or replace function public.rpc_get_ox_quiz_history(
  p_month date default null,
  p_result_filter text default 'all',
  p_sort_direction text default 'desc'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_current_month date := date_trunc('month', now() at time zone 'Asia/Seoul')::date;
  v_month date := date_trunc('month', coalesce(p_month, v_current_month))::date;
  v_next_month date := (v_month + interval '1 month')::date;
  v_filter text := lower(trim(coalesce(p_result_filter, 'all')));
  v_sort text := lower(trim(coalesce(p_sort_direction, 'desc')));
  v_records jsonb := '[]'::jsonb;
  v_stats jsonb := '{}'::jsonb;
begin
  v_member := private.require_active_member();

  if v_filter not in ('all', 'correct', 'incorrect') then
    raise exception 'OX_QUIZ_INVALID_HISTORY_FILTER';
  end if;

  if v_sort not in ('asc', 'desc') then
    raise exception 'OX_QUIZ_INVALID_SORT_DIRECTION';
  end if;

  select coalesce(jsonb_agg(item order by
    case when v_sort = 'asc' then answered_at end asc,
    case when v_sort = 'desc' then answered_at end desc
  ), '[]'::jsonb)
  into v_records
  from (
    select
      a.answered_at,
      jsonb_build_object(
        'id', a.id,
        'quizDate', a.quiz_date,
        'questionOrder', a.question_order,
        'question', q.question,
        'selectedAnswer', a.selected_answer,
        'correctAnswer', q.correct_answer,
        'isCorrect', a.is_correct,
        'rewardAmount', a.reward_amount,
        'answeredAt', a.answered_at
      ) as item
    from public.ox_quiz_attempts a
    join public.ox_quiz_questions q on q.id = a.question_id
    where a.user_id = v_member.user_id
      and a.quiz_date >= v_month
      and a.quiz_date < v_next_month
      and (
        v_filter = 'all'
        or (v_filter = 'correct' and a.is_correct)
        or (v_filter = 'incorrect' and not a.is_correct)
      )
  ) history_rows;

  select jsonb_build_object(
    'total', count(*),
    'correct', count(*) filter (where is_correct),
    'incorrect', count(*) filter (where not is_correct),
    'rewardTotal', coalesce(sum(reward_amount), 0)
  ) into v_stats
  from public.ox_quiz_attempts
  where user_id = v_member.user_id
    and quiz_date >= v_month
    and quiz_date < v_next_month;

  return jsonb_build_object(
    'month', v_month,
    'timeZone', 'Asia/Seoul',
    'filter', v_filter,
    'sortDirection', v_sort,
    'stats', v_stats,
    'records', v_records
  );
end;
$$;
revoke all on function private.ensure_ox_quiz_daily_set(date)
  from public, anon, authenticated;
revoke all on function public.rpc_get_ox_quiz_today()
  from public, anon;
revoke all on function public.rpc_submit_ox_quiz_answer(uuid, text, text)
  from public, anon;
revoke all on function public.rpc_get_ox_quiz_history(date, text, text)
  from public, anon;
grant execute on function public.rpc_get_ox_quiz_today()
  to authenticated;
grant execute on function public.rpc_submit_ox_quiz_answer(uuid, text, text)
  to authenticated;
grant execute on function public.rpc_get_ox_quiz_history(date, text, text)
  to authenticated;
-- Seed data is appended below. Correct answers remain inaccessible to clients except
-- after a submitted answer through the security-definer RPC.


insert into public.ox_quiz_questions (
  content_order, source_set, source_no, category, difficulty, question,
  correct_answer, explanation, content_version, is_active
) values
  (1, 'core100', 1, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 실물 자산이나 권리를 토큰으로 표현하는 방식이다', 'O', 'STO는 ‘증권 성격의 권리/가치’를 토큰 형태로 표현하는 개념이야.', 1, true),
  (2, 'core100', 2, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 ‘Security Token Offering’의 약자다', 'O', 'Security Token Offering의 약자이며, 증권형 토큰 발행을 뜻해.', 1, true),
  (3, 'core100', 3, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 누구나 규제 없이 자유롭게 발행할 수 있다', 'X', 'STO는 규제·법적 구조(증권성 판단 등)를 고려해야 해.', 1, true),
  (4, 'core100', 4, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 기존 주식이나 채권 개념과 연결될 수 있다', 'O', '주식·채권처럼 ‘권리’가 있는 구조와 연결될 수 있어.', 1, true),
  (5, 'core100', 5, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 블록체인 기술을 활용한다', 'O', '블록체인(분산원장)으로 발행·기록·이전을 효율화할 수 있어.', 1, true),
  (6, 'core100', 6, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 실물 자산과 무관한 개념이다', 'X', 'STO는 ‘현실의 권리/가치’와 연결되는 경우가 많아.', 1, true),
  (7, 'core100', 7, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 법적 권리와 연결될 수 있다', 'O', '투자자 권리(배당·이자·청구권 등) 같은 법적 권리와 연계될 수 있어.', 1, true),
  (8, 'core100', 8, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 무조건 높은 수익을 보장한다', 'X', '어떤 자산이든 가격 변동·리스크가 있어 ‘보장’은 없어.', 1, true),
  (9, 'core100', 9, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 기존 증권 시장을 완전히 대체한다', 'X', 'STO는 기존 시장을 “대체”라기보다 “보완/확장” 쪽에 가까워.', 1, true),
  (10, 'core100', 10, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 분산원장 기술을 기반으로 한다', 'O', '핵심은 분산원장 기반으로 기록·이전을 관리한다는 점이야.', 1, true),
  (11, 'core100', 11, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 자산을 소수 단위로 나눌 수 있다', 'O', '분할 발행/분할 소유 구조로 소액 참여가 가능해질 수 있어.', 1, true),
  (12, 'core100', 12, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 모든 국가에서 동일한 법적 지위를 가진다', 'X', '국가별 법·규제가 달라 동일 지위로 보긴 어려워.', 1, true),
  (13, 'core100', 13, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 기존 금융 시스템과 공존할 수 있다', 'O', '전통 금융 인프라와 함께 운영되는 하이브리드 모델이 많아.', 1, true),
  (14, 'core100', 14, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 투자 개념이 아닌 경우도 있다', 'O', '‘권리 표현 방식’이라 투자 목적 외(유틸리티적 설계)도 가능해.', 1, true),
  (15, 'core100', 15, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 자산의 소유권을 디지털로 기록한다', 'O', '소유·권리 정보를 디지털로 기록하고 추적성을 높일 수 있어.', 1, true),
  (16, 'core100', 16, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 주로 게임 아이템에만 사용된다', 'X', 'STO는 주로 ‘증권성 자산/권리’와 연결되는 구조야.', 1, true),
  (17, 'core100', 17, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 스마트 계약을 활용할 수 있다', 'O', '스마트 계약으로 권리 행사·정산 등을 자동화할 수 있어.', 1, true),
  (18, 'core100', 18, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 기존 증권보다 투명성이 높을 수 있다', 'O', '기록이 남고 추적이 쉬워 투명성이 높아질 수 있어.', 1, true),
  (19, 'core100', 19, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 실체 없는 자산만 다룬다', 'X', '실물·권리 기반 자산을 다룰 수도 있고, “실체 없음”만은 아니야.', 1, true),
  (20, 'core100', 20, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 발행 시 관련 법규를 고려해야 한다', 'O', '증권성 여부, 공시/승인, 투자자 보호 등 법규 고려가 필요해.', 1, true),
  (21, 'core100', 21, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 일반 암호화폐와 동일한 개념이다', 'X', '일반 암호화폐는 유틸리티/결제 성격이 많고, STO는 증권성 구조가 핵심이야.', 1, true),
  (22, 'core100', 22, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 자산 정보를 블록체인에 기록할 수 있다', 'O', '발행 조건, 소유 이력 같은 정보를 체계적으로 기록할 수 있어.', 1, true),
  (23, 'core100', 23, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 중앙 기관의 역할이 완전히 사라진다', 'X', '중개·규제·감독 기능이 여전히 필요한 경우가 많아.', 1, true),
  (24, 'core100', 24, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 디지털 자산의 한 종류다', 'O', '디지털 자산 범주 안에 포함될 수 있어(설계/규제에 따라).', 1, true),
  (25, 'core100', 25, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 기존 금융 상품 구조를 디지털화한 개념이다', 'O', '기존 금융의 권리 구조를 디지털로 구현하는 접근이야.', 1, true),
  (26, 'core100', 26, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 항상 거래소에 상장된다', 'X', '상장은 선택 사항이며, 비상장/폐쇄형 유통도 가능해.', 1, true),
  (27, 'core100', 27, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 소유권 이전 기록이 가능하다', 'O', '소유권/권리 이전 이력을 남길 수 있어 분쟁 리스크를 낮출 수 있어.', 1, true),
  (28, 'core100', 28, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 규제와 무관하다', 'X', '규제와 밀접하며, 오히려 규제 준수가 중요한 영역이야.', 1, true),
  (29, 'core100', 29, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 자산 기반 토큰이다', 'O', '‘자산/권리 기반’ 설계가 가능하다는 게 핵심이야.', 1, true),
  (30, 'core100', 30, '① STO 기본 개념 (1~30번 | 초급)', 'basic', 'STO는 블록체인 기술 발전과 함께 주목받고 있다', 'O', 'RWA·토큰화 트렌드와 맞물려 관심이 커지고 있어.', 1, true),
  (31, 'core100', 31, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 ‘Real World Assets’의 약자다', 'O', 'Real World Assets: 현실 세계 자산을 뜻해.', 1, true),
  (32, 'core100', 32, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 현실 세계의 자산을 의미한다', 'O', '부동산, 채권, 원자재처럼 현실 기반 자산을 포함해.', 1, true),
  (33, 'core100', 33, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA에는 부동산이 포함될 수 있다', 'O', '대표적 RWA로 부동산이 자주 언급돼.', 1, true),
  (34, 'core100', 34, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 오직 디지털 자산만 의미한다', 'X', 'RWA는 ‘오히려 현실 자산’이 핵심이야.', 1, true),
  (35, 'core100', 35, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 토큰화될 수 있다', 'O', 'RWA는 토큰화로 디지털 형태로 표현될 수 있어.', 1, true),
  (36, 'core100', 36, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 실물 자산과 연결되지 않는다', 'X', 'RWA는 현실 자산과 연결되는 게 전제야.', 1, true),
  (37, 'core100', 37, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 금, 채권, 부동산 등을 포함할 수 있다', 'O', '금, 채권, 부동산 등 폭넓게 포함될 수 있어.', 1, true),
  (38, 'core100', 38, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 실체가 없는 개념이다', 'X', 'RWA는 ‘실체가 있는 자산’이 핵심이야.', 1, true),
  (39, 'core100', 39, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 블록체인과 결합될 수 있다', 'O', '블록체인 결합 시 추적·정산·이전 효율이 좋아질 수 있어.', 1, true),
  (40, 'core100', 40, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 디지털 기술로 관리될 수 있다', 'O', '디지털 시스템으로 관리/기록/정산할 수 있어.', 1, true),
  (41, 'core100', 41, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 자산의 가치를 분할할 수 있다', 'O', '분할 소유/지분화로 접근성을 높일 수 있어.', 1, true),
  (42, 'core100', 42, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 기존 금융 시장과 분리되어 있다', 'X', '기존 금융과 연결돼 운영되는 경우가 많아 “분리”가 아냐.', 1, true),
  (43, 'core100', 43, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 토큰화 과정을 거칠 수 있다', 'O', '실물 자산을 디지털 토큰 구조로 옮기는 과정이 토큰화야.', 1, true),
  (44, 'core100', 44, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 현실 자산의 소유권과 연결될 수 있다', 'O', '소유권·수익권 같은 권리와 연결될 수 있어.', 1, true),
  (45, 'core100', 45, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 항상 투자 상품이다', 'X', 'RWA는 자산 개념이고, 투자 상품은 ‘구조’에 따라 달라져.', 1, true),
  (46, 'core100', 46, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 실물 자산을 디지털로 표현한 개념이다', 'O', '현실 자산의 권리/가치를 디지털로 표현한 게 핵심이야.', 1, true),
  (47, 'core100', 47, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 블록체인이 없어도 존재한다', 'O', '블록체인은 RWA “활용 방식”이고, RWA 자체는 블록체인 없이도 존재해.', 1, true),
  (48, 'core100', 48, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 암호화폐와 동일한 의미다', 'X', '암호화폐는 디지털 토큰 자체가 자산인 경우가 많고, RWA는 현실 자산 기반이야.', 1, true),
  (49, 'core100', 49, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 금융 접근성을 높일 수 있다', 'O', '소액화/접근성 개선으로 참여 문턱을 낮출 수 있어.', 1, true),
  (50, 'core100', 50, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 투명한 기록 관리가 가능하다', 'O', '기록을 체계화하면 투명성과 추적성이 좋아질 수 있어.', 1, true),
  (51, 'core100', 51, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 글로벌 시장과 연결될 수 있다', 'O', '국경을 넘어 유통·투자가 쉬워질 여지가 있어(규제 전제).', 1, true),
  (52, 'core100', 52, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 법적 구조를 고려해야 한다', 'O', '법적 권리/등기/공시 등 구조 설계가 중요해.', 1, true),
  (53, 'core100', 53, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 실물 자산 가치와 무관하다', 'X', 'RWA는 ‘현실 자산 가치’와 연결되는 게 핵심이야.', 1, true),
  (54, 'core100', 54, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 토큰증권과 연결될 수 있다', 'O', 'RWA를 토큰증권(STO) 형태로 설계하는 경우가 있어.', 1, true),
  (55, 'core100', 55, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 실물 기반 경제와 디지털 경제를 잇는다', 'O', '실물경제(자산)와 디지털경제(토큰/기술)를 연결해.', 1, true),
  (56, 'core100', 56, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 단기 유행 개념이다', 'X', '단기 유행이 아니라 인프라/규제 정비와 함께 장기 트렌드로 봐.', 1, true),
  (57, 'core100', 57, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 다양한 산업에 적용 가능하다', 'O', '금융(채권)부터 비금융(탄소크레딧 등)까지 확장 가능해.', 1, true),
  (58, 'core100', 58, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 기존 자산을 더 쉽게 관리할 수 있게 한다', 'O', '기록/정산/유통 효율을 개선할 수 있어.', 1, true),
  (59, 'core100', 59, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 물리적 형태가 반드시 필요하다', 'X', '반드시 ‘물리적 형태’만은 아니고(예: 권리/청구권), 현실 기반이면 가능해.', 1, true),
  (60, 'core100', 60, '② RWA 기본 개념 (31~60번 | 초중급)', 'basic', 'RWA는 현실 자산의 활용 범위를 넓힌다', 'O', '활용/유통/접근성이 커지면서 경제적 활용 범위를 넓혀.', 1, true),
  (61, 'core100', 61, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 RWA를 토큰화하는 방식 중 하나다', 'O', 'RWA를 “증권성 구조”로 토큰화하면 STO가 될 수 있어.', 1, true),
  (62, 'core100', 62, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', '모든 RWA가 반드시 STO 형태여야 한다', 'X', 'RWA는 토큰화 방식이 다양해서 STO만이 정답은 아니야.', 1, true),
  (63, 'core100', 63, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO와 RWA는 서로 다른 개념이지만 연결될 수 있다', 'O', 'RWA(자산)와 STO(권리/발행 구조)는 결합될 수 있어.', 1, true),
  (64, 'core100', 64, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 STO보다 더 넓은 개념이다', 'O', 'RWA는 ‘자산 범주’고 STO는 ‘발행/구조’라 RWA가 더 넓어.', 1, true),
  (65, 'core100', 65, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 RWA의 디지털 표현 방식이다', 'O', 'RWA를 디지털 토큰으로 표현하는 방식 중 하나가 STO 설계야.', 1, true),
  (66, 'core100', 66, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO와 RWA는 완전히 동일한 의미다', 'X', '범주가 달라서 동일 개념으로 보면 이해가 틀어져.', 1, true),
  (67, 'core100', 67, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA 기반 STO는 실물 자산 신뢰가 중요하다', 'O', '실물 기반이면 검증/감사/보관 등 신뢰 장치가 매우 중요해.', 1, true),
  (68, 'core100', 68, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 기술이고 RWA는 자산 개념이다', 'O', 'STO는 구조/기술/규제 설계, RWA는 현실 자산 개념이야.', 1, true),
  (69, 'core100', 69, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 블록체인 없이 존재할 수 없다', 'X', 'RWA는 현실 자산이라 블록체인 없이도 존재해.', 1, true),
  (70, 'core100', 70, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 기존 금융 규제를 무시한다', 'X', 'STO는 규제를 “무시”가 아니라 “준수”가 핵심이야.', 1, true),
  (71, 'core100', 71, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA 토큰화는 투명성을 높일 수 있다', 'O', '기록/추적이 쉬워져 투명성 개선 가능성이 있어.', 1, true),
  (72, 'core100', 72, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 자산의 분할 소유를 가능하게 한다', 'O', '분할 소유로 소액 참여가 가능해질 수 있어.', 1, true),
  (73, 'core100', 73, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 모든 사람에게 투자 수익을 보장한다', 'X', '수익 보장은 없고, 구조/시장에 따라 달라.', 1, true),
  (74, 'core100', 74, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 디지털 자산 시장의 신뢰도를 높일 수 있다', 'O', '실물 기반은 ‘근거 있는 가치’로 신뢰를 높일 수 있어.', 1, true),
  (75, 'core100', 75, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 단순한 포인트 개념과 다르다', 'O', '포인트는 인앱 재화일 수 있지만 STO는 ‘증권성 권리 구조’가 핵심이야.', 1, true),
  (76, 'core100', 76, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA 기반 토큰은 현실 자산과 분리되어 존재한다', 'X', 'RWA 토큰은 현실 자산과 연결되는 구조가 전제야.', 1, true),
  (77, 'core100', 77, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 자산 관리 효율을 높일 수 있다', 'O', '발행/관리/정산 자동화로 효율을 높일 수 있어.', 1, true),
  (78, 'core100', 78, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 기존 금융 인프라를 완전히 제거한다', 'X', '기존 인프라를 “제거”가 아니라 “개선/보완”하는 방향이 많아.', 1, true),
  (79, 'core100', 79, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO와 RWA는 장기적인 산업 변화와 관련 있다', 'O', '자산 디지털화 흐름과 연결된 장기 트렌드야.', 1, true),
  (80, 'core100', 80, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 자산 정보를 체계적으로 기록할 수 있다', 'O', '자산 정보의 기록·추적이 구조적으로 가능해.', 1, true),
  (81, 'core100', 81, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 금융·비금융 영역 모두에 적용 가능하다', 'O', '금융(채권)뿐 아니라 비금융(탄소, IP 등)도 가능해.', 1, true),
  (82, 'core100', 82, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 기술 발전에 따라 확장 가능하다', 'O', '기술·규제 성숙에 따라 적용 범위가 늘 수 있어.', 1, true),
  (83, 'core100', 83, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA 토큰화는 글로벌 시장 접근성을 높일 수 있다', 'O', '국경 간 유통/접근성 개선 여지가 있어(규제/인프라 전제).', 1, true),
  (84, 'core100', 84, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 투기 목적만을 위한 구조다', 'X', '투기만이 목적이 아니라 ‘유통/정산/접근성 개선’이 본질이야.', 1, true),
  (85, 'core100', 85, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 실물 자산의 디지털 활용 방식이다', 'O', '현실 자산을 디지털로 활용하는 방식이 RWA 토큰화야.', 1, true),
  (86, 'core100', 86, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 모든 자산에 무조건 적용 가능하다', 'X', '모든 자산이 토큰화에 적합한 건 아니고, 법/검증/정산 구조가 필요해.', 1, true),
  (87, 'core100', 87, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA와 STO는 Web3 흐름과 연결된다', 'O', 'Web3 인프라(지갑/온체인 기록)와 연결되기 쉬워.', 1, true),
  (88, 'core100', 88, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 정보 공개와 투명성이 중요하다', 'O', '정보 공개·추적성은 투자자 보호에도 중요해.', 1, true),
  (89, 'core100', 89, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 단순히 코인을 의미한다', 'X', '‘코인’ 일반화는 오해고, 현실 자산 기반이 핵심이야.', 1, true),
  (90, 'core100', 90, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 실물 경제와 디지털 경제를 연결한다', 'O', '실물 기반 권리를 디지털로 운용하는 연결 고리 역할을 해.', 1, true),
  (91, 'core100', 91, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA 기반 STO는 신뢰 구조가 핵심이다', 'O', '담보/보관/평가/감사 같은 신뢰 장치가 핵심이야.', 1, true),
  (92, 'core100', 92, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 기술·법·자산이 함께 고려되어야 한다', 'O', '기술만으로 끝나지 않고 법·회계·자산 구조가 함께 가야 해.', 1, true),
  (93, 'core100', 93, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 미래 금융 구조 변화의 한 축이다', 'O', '전통 금융의 디지털 전환 축으로 볼 수 있어.', 1, true),
  (94, 'core100', 94, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 기존 금융을 완전히 부정한다', 'X', '“부정”이 아니라 “업그레이드/보완” 관점이 현실적이야.', 1, true),
  (95, 'core100', 95, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA 토큰화는 관리 비용을 줄일 수 있다', 'O', '서류/중개/정산 비용이 줄 여지가 있어.', 1, true),
  (96, 'core100', 96, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 항상 투자 권유와 함께 제공된다', 'X', 'STO는 투자 권유가 아니라 ‘구조’이며, 제공 방식은 서비스마다 달라.', 1, true),
  (97, 'core100', 97, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA는 자산의 활용 가능성을 확장한다', 'O', '자산 활용 방식이 다양해져 활용 가능성이 커져.', 1, true),
  (98, 'core100', 98, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO는 단기 트렌드로 끝날 개념이다', 'X', '인프라·규제 정비가 진행되면 장기 확장 가능성이 높아.', 1, true),
  (99, 'core100', 99, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'RWA와 STO는 실물 자산 디지털화 흐름의 핵심이다', 'O', '‘현실 자산 디지털화’ 흐름의 핵심 키워드 중 하나야.', 1, true),
  (100, 'core100', 100, '③ STO × RWA 응용 & 이해 (61~100번 | 중급~고급)', 'advanced', 'STO와 RWA는 앞으로 더 많은 분야에서 활용될 수 있다', 'O', '적용 분야(부동산/채권/원자재/권리 등)가 확대될 수 있어.', 1, true),
  (101, 'future60', 1, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융 자산은 소수의 기관만 접근할 수 있는 경우가 많다', 'O', '전통 금융은 정보/상품 접근에 진입장벽이 생기기 쉬워.', 1, true),
  (102, 'future60', 2, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 자산을 소액 단위로 나눠 참여할 수 있게 한다', 'O', '토큰화는 분할 단위를 줄여 소액 참여 가능성을 키워.', 1, true),
  (103, 'future60', 3, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융에서는 자산 거래 기록이 실시간으로 공개되지 않는다', 'O', '전통 금융 기록은 내부 시스템 중심이라 실시간 공개가 제한적이야.', 1, true),
  (104, 'future60', 4, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 거래 기록을 투명하게 확인할 수 있다', 'O', '온체인 기록은 추적·검증이 쉬워질 수 있어.', 1, true),
  (105, 'future60', 5, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융 자산은 국경 간 이동이 쉽다', 'X', '국경 이동은 규제·환전·정산 문제로 쉽지 않은 편이야.', 1, true),
  (106, 'future60', 6, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 디지털 환경에서 자산 이전이 상대적으로 빠르다', 'O', '디지털 기록 기반이면 이전/정산 과정이 간소화될 여지가 있어.', 1, true),
  (107, 'future60', 7, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융 시스템은 중개 기관이 필수다', 'O', '전통 금융은 중개·청산·결제 기관 역할이 크지.', 1, true),
  (108, 'future60', 8, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 중개 구조를 단순화할 수 있다', 'O', '토큰화는 일부 중개 단계를 줄이거나 자동화할 수 있어.', 1, true),
  (109, 'future60', 9, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융은 거래 처리 시간이 짧다', 'X', '전통 금융은 시장/상품에 따라 처리 시간이 길어지기도 해.', 1, true),
  (110, 'future60', 10, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 자동화된 계약 구조를 활용할 수 있다', 'O', '스마트 계약은 조건 충족 시 자동 처리에 강점이 있어.', 1, true),
  (111, 'future60', 11, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융 상품은 구조가 복잡해 이해하기 어렵다', 'O', '상품 구조·설명 방식이 복잡해 정보 비대칭이 생길 수 있어.', 1, true),
  (112, 'future60', 12, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 자산 구조를 비교적 직관적으로 표현할 수 있다', 'O', '토큰 구조는 권리/조건을 비교적 명시적으로 표현할 수 있어.', 1, true),
  (113, 'future60', 13, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융은 24시간 거래가 일반적이다', 'X', '전통 금융은 24시간 거래가 기본이 아니야(시장 시간 존재).', 1, true),
  (114, 'future60', 14, '① 기존 금융과의 차이 (1~20)', 'future', 'STO 기반 자산은 시간 제약이 줄어들 수 있다', 'O', '디지털 유통 구조는 시간 제약을 줄일 가능성이 있어.', 1, true),
  (115, 'future60', 15, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융은 자산 분할이 쉽다', 'X', '전통 금융에서 자산 분할은 법/절차상 제한이 많아.', 1, true),
  (116, 'future60', 16, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 하나의 자산을 여러 명이 나눠 보유할 수 있다', 'O', '토큰화는 분할 소유/지분화를 설계하기가 쉬운 편이야.', 1, true),
  (117, 'future60', 17, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융은 기록 조작 가능성이 완전히 없다', 'X', '전통 금융도 조작 불가능 “완전”은 아니고, 신뢰는 제도/감사로 확보해.', 1, true),
  (118, 'future60', 18, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 위·변조 방지 구조를 가진다', 'O', '분산원장 구조는 위·변조 난이도를 높일 수 있어.', 1, true),
  (119, 'future60', 19, '① 기존 금융과의 차이 (1~20)', 'future', '기존 금융 시스템은 글로벌 통합이 쉽다', 'X', '글로벌 통합은 규제·표준 차이로 쉬운 일이 아니야.', 1, true),
  (120, 'future60', 20, '① 기존 금융과의 차이 (1~20)', 'future', 'STO는 글로벌 표준으로 확장 가능성이 있다', 'O', '표준과 규제가 정비되면 확장성이 커질 수 있어.', 1, true),
  (121, 'future60', 21, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 기존 금융 방식을 그대로 복제한 것이다', 'X', '단순 복제가 아니라 ‘디지털 네이티브’로 재설계 가능하다는 점이 포인트야.', 1, true),
  (122, 'future60', 22, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 자산 관리 방식을 디지털 중심으로 재설계한다', 'O', '발행/관리/정산을 소프트웨어처럼 설계하는 접근이 가능해.', 1, true),
  (123, 'future60', 23, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'RWA는 실물 자산을 그대로 두고 활용 방식을 바꾼다', 'O', '자산은 그대로여도 ‘유통/관리 방식’이 바뀌면 혁신이 돼.', 1, true),
  (124, 'future60', 24, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 종이 기반 증권 구조에 의존한다', 'X', '종이 증권 의존이 아니라 디지털 기록 중심이야.', 1, true),
  (125, 'future60', 25, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 자동화와 프로그래밍이 가능하다', 'O', '규칙을 코드로 구현하면 자동화·감사가 쉬워져.', 1, true),
  (126, 'future60', 26, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'RWA 토큰화는 자산 유동성을 높일 수 있다', 'O', '분할/유통 개선으로 유동성이 늘 가능성이 있어.', 1, true),
  (127, 'future60', 27, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', '기존 금융은 자산 이동 경로가 단순하다', 'X', '전통 금융은 실제로 중개/정산 경로가 복잡한 경우가 많아.', 1, true),
  (128, 'future60', 28, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 복잡한 자산 흐름을 효율적으로 만든다', 'O', '복잡한 흐름을 코드/표준으로 정리하면 효율이 올라가.', 1, true),
  (129, 'future60', 29, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'RWA는 현실 자산의 디지털 확장을 의미한다', 'O', '현실 자산이 디지털 경제에서 ‘활용’되는 게 핵심이야.', 1, true),
  (130, 'future60', 30, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 금융과 기술의 결합 결과다', 'O', '금융(규제/권리) + 기술(블록체인/스마트계약)의 결합이야.', 1, true),
  (131, 'future60', 31, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', '기존 금융은 실시간 정산이 기본이다', 'X', '전통 금융은 실시간 정산이 “기본”은 아니야(T+ 구조 존재).', 1, true),
  (132, 'future60', 32, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 정산 구조를 단순화할 수 있다', 'O', '토큰화는 정산 시간을 줄이려는 시도와 맞닿아 있어.', 1, true),
  (133, 'future60', 33, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'RWA는 기존에 투자하기 어려웠던 자산을 접근 가능하게 만든다', 'O', '고가 자산의 분할은 접근성을 키울 수 있어.', 1, true),
  (134, 'future60', 34, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 자산 정보의 신뢰도를 높인다', 'O', '데이터/기록의 투명성은 신뢰에 직접 영향을 줘.', 1, true),
  (135, 'future60', 35, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', '기존 금융은 투명성이 기본적으로 높다', 'X', '전통 금융도 투명성 장치가 있지만, 정보 비대칭이 남을 수 있어.', 1, true),
  (136, 'future60', 36, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 정보 공개 구조를 강화할 수 있다', 'O', '온체인 기록/공시 구조를 강화하면 공개성이 높아질 수 있어.', 1, true),
  (137, 'future60', 37, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'RWA 토큰화는 관리 비용을 낮출 수 있다', 'O', '서류/중개 비용이 줄면 관리 비용도 낮아질 수 있어.', 1, true),
  (138, 'future60', 38, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 기술 발전에 따라 기능 확장이 가능하다', 'O', '기술 발전(지갑/신원/규제기술)과 함께 기능이 확장돼.', 1, true),
  (139, 'future60', 39, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', '기존 금융은 시스템 변경이 빠르다', 'X', '전통 금융 시스템은 변경이 느린 편이야(규제·리스크 때문).', 1, true),
  (140, 'future60', 40, '② STO·RWA가 ‘혁신’인 이유 (21~40)', 'future', 'STO는 유연한 구조 변경이 가능하다', 'O', '소프트웨어 기반 구조는 개선 주기를 빠르게 만들 수 있어.', 1, true),
  (141, 'future60', 41, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO와 RWA는 일시적인 유행일 가능성이 높다', 'X', '인프라·규제 정비가 진행되면 장기 흐름이 될 가능성이 커.', 1, true),
  (142, 'future60', 42, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 디지털 경제 확장과 함께 성장한다', 'O', '디지털 경제가 커질수록 ‘디지털 자산 인프라’ 필요성이 커져.', 1, true),
  (143, 'future60', 43, '③ 미래 성장성과 확장성 (41~60)', 'future', 'RWA는 전통 금융과 디지털 금융을 연결한다', 'O', '전통 자산을 디지털로 쓰는 다리 역할을 할 수 있어.', 1, true),
  (144, 'future60', 44, '③ 미래 성장성과 확장성 (41~60)', 'future', '기존 금융 시스템은 이미 완성 단계다', 'X', '금융은 계속 변화 중이고, 완성 단계라 보기 어려워.', 1, true),
  (145, 'future60', 45, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 아직 초기 단계다', 'O', '아직 초기라 표준/규제 정착에 따라 확장 여지가 커.', 1, true),
  (146, 'future60', 46, '③ 미래 성장성과 확장성 (41~60)', 'future', 'RWA 시장은 글로벌 자산 규모와 연결된다', 'O', 'RWA는 현실 자산 시장 규모와 연결돼 성장 잠재력이 커.', 1, true),
  (147, 'future60', 47, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 특정 산업에만 적용 가능하다', 'X', '부동산/채권/원자재/권리 등 다양한 산업으로 확장 가능해.', 1, true),
  (148, 'future60', 48, '③ 미래 성장성과 확장성 (41~60)', 'future', 'RWA는 부동산·채권·원자재 등으로 확장 가능하다', 'O', '자산 범위가 넓어 응용처가 많아.', 1, true),
  (149, 'future60', 49, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 금융 접근성을 확대할 수 있다', 'O', '분할/접근성 개선은 참여층을 넓힐 수 있어.', 1, true),
  (150, 'future60', 50, '③ 미래 성장성과 확장성 (41~60)', 'future', '기존 금융은 젊은 세대에게 친숙하다', 'X', '젊은 세대는 모바일/디지털 사용이 익숙해 오히려 친숙한 편이야.', 1, true),
  (151, 'future60', 51, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 디지털 친화적인 세대에게 적합하다', 'O', '디지털 친화 세대는 지갑/앱 기반 경험에 거부감이 적어.', 1, true),
  (152, 'future60', 52, '③ 미래 성장성과 확장성 (41~60)', 'future', 'RWA는 실물 경제와 직접 연결된다', 'O', '실물 경제 기반이라 ‘현실과 연결’된 확장이 가능해.', 1, true),
  (153, 'future60', 53, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 글로벌 규제 정비와 함께 성장할 수 있다', 'O', '규제 정비가 되면 제도권 확장이 가속될 수 있어.', 1, true),
  (154, 'future60', 54, '③ 미래 성장성과 확장성 (41~60)', 'future', 'RWA 토큰화는 장기적인 구조 변화다', 'O', '토큰화는 단기 이벤트가 아니라 인프라 전환에 가까워.', 1, true),
  (155, 'future60', 55, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 기존 금융을 보완하는 역할을 한다', 'O', '기존 금융을 “대체”보다 “보완”하면서 점진 확대가 현실적이야.', 1, true),
  (156, 'future60', 56, '③ 미래 성장성과 확장성 (41~60)', 'future', 'RWA는 Web3 인프라의 핵심 축 중 하나다', 'O', 'Web3 인프라(지갑, 온체인 기록)는 RWA/토큰화 확장에 중요해.', 1, true),
  (157, 'future60', 57, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 기술 발전과 무관하다', 'X', '기술 발전(신원/규제/보안)이 성장 속도에 영향을 줘.', 1, true),
  (158, 'future60', 58, '③ 미래 성장성과 확장성 (41~60)', 'future', 'RWA는 글로벌 자산 시장의 효율성을 높인다', 'O', '정산/관리 효율이 높아지면 시장 전체 효율도 올라갈 수 있어.', 1, true),
  (159, 'future60', 59, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO는 미래 금융 실험 중 하나다', 'O', '새로운 구조 실험이 진행 중이고, 성공 사례가 쌓이면 표준이 돼.', 1, true),
  (160, 'future60', 60, '③ 미래 성장성과 확장성 (41~60)', 'future', 'STO와 RWA는 장기적인 금융 패러다임 변화와 연결된다', 'O', '장기적으로 ‘금융 운영 방식’ 변화 흐름과 연결돼.', 1, true),
  (161, 'misconception30', 1, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 일반적인 암호화폐(코인)와 같은 개념이다.', 'X', 'STO는 코인이 아니라 [증권 성격의 권리를 표현하는 구조]다.', 1, true),
  (162, 'misconception30', 2, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 자산 자체가 아니라 권리 구조를 디지털로 표현한 개념이다.', 'O', '핵심은 가격이 아니라 권리·조건·구조다.', 1, true),
  (163, 'misconception30', 3, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', '‘토큰’이라는 단어가 들어가면 모두 코인이라고 볼 수 있다.', 'X', '토큰은 기술적 표현 방식일 뿐, 성격은 서로 다를 수 있다.', 1, true),
  (164, 'misconception30', 4, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 법과 규제를 전혀 고려하지 않아도 되는 구조다.', 'X', 'STO는 오히려 법·규정 검토가 중요한 영역이다.', 1, true),
  (165, 'misconception30', 5, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA는 현실 세계의 자산을 의미하는 개념이다.', 'O', 'RWA는 부동산·채권 등 현실 자산을 기반으로 한다.', 1, true),
  (166, 'misconception30', 6, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA는 오직 디지털로만 존재하는 자산을 뜻한다.', 'X', 'RWA의 핵심은 현실 자산과의 연결이다.', 1, true),
  (167, 'misconception30', 7, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO와 RWA는 단기간 수익을 위한 개념이다.', 'X', '수익이 아니라 구조와 인프라 변화를 설명하는 개념이다.', 1, true),
  (168, 'misconception30', 8, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 기존 금융을 완전히 없애기 위해 등장했다.', 'X', '대체가 아니라 보완·확장 관점에서 논의된다.', 1, true),
  (169, 'misconception30', 9, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 증권과 관련된 개념이기 때문에 규제와 무관하다.', 'X', '증권과 연결되기 때문에 규제 검토가 필수다.', 1, true),
  (170, 'misconception30', 10, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 소유권이나 권리 이력을 기록하기 쉽게 만든다.', 'O', '디지털 기록으로 추적성과 관리 효율을 높일 수 있다.', 1, true),
  (171, 'misconception30', 11, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 누구나 아무 조건 없이 자유롭게 발행할 수 있다.', 'X', '발행 조건과 법적 구조에 대한 검토가 필요하다.', 1, true),
  (172, 'misconception30', 12, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA는 현실 자산을 디지털로 관리하려는 흐름과 관련 있다.', 'O', '자산을 바꾸는 게 아니라 관리·활용 방식을 바꾸는 것이다.', 1, true),
  (173, 'misconception30', 13, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 투자 행동을 반드시 요구하는 개념이다.', 'X', 'STO는 투자 권유가 아니라 구조 설명 용어다.', 1, true),
  (174, 'misconception30', 14, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO와 RWA는 모두 ‘코인 가격 변동’을 다루는 개념이다.', 'X', '가격보다 자산 구조와 권리 표현이 핵심이다.', 1, true),
  (175, 'misconception30', 15, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 정보 공개와 투명성을 중요하게 다룬다.', 'O', '권리 구조를 명확히 드러내는 것이 중요하다.', 1, true),
  (176, 'misconception30', 16, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA는 현실 자산과 무관한 가상 개념이다.', 'X', 'RWA는 현실 기반 자산을 전제로 한다.', 1, true),
  (177, 'misconception30', 17, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 기술만 있으면 법적 고려 없이 운영할 수 있다.', 'X', '기술·법·제도가 함께 고려돼야 한다.', 1, true),
  (178, 'misconception30', 18, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 기존 주식이나 채권과 완전히 다른 개념이다.', 'X', '기존 금융의 권리 구조를 디지털로 표현한 방식이다.', 1, true),
  (179, 'misconception30', 19, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA 토큰화는 자산 관리 효율을 높일 수 있다.', 'O', '기록·정산·관리 과정이 단순해질 수 있다.', 1, true),
  (180, 'misconception30', 20, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 수익을 보장하는 상품을 의미한다.', 'X', '어떤 수익도 보장되는 구조는 아니다.', 1, true),
  (181, 'misconception30', 21, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 ‘코인’이라는 단어와 혼용해도 의미 차이가 없다.', 'X', '혼용하면 오해가 생기기 쉬워 구분이 중요하다.', 1, true),
  (182, 'misconception30', 22, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA는 디지털 경제와 현실 경제를 연결하는 개념이다.', 'O', '현실 자산을 디지털 환경에서 활용하려는 흐름이다.', 1, true),
  (183, 'misconception30', 23, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 가격 예측이나 투기 게임과 같은 개념이다.', 'X', '투기와는 무관한 구조·제도 중심 개념이다.', 1, true),
  (184, 'misconception30', 24, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 소액 단위로 자산 구조를 설계할 수 있게 한다.', 'O', '분할 설계로 접근성을 넓힐 수 있다.', 1, true),
  (185, 'misconception30', 25, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA는 단기 유행으로 곧 사라질 개념이다.', 'X', '장기적인 자산 디지털화 흐름과 연결돼 있다.', 1, true),
  (186, 'misconception30', 26, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO와 RWA는 모두 법적 검토가 필요 없는 개념이다.', 'X', '오히려 법·규제 검토가 중요한 영역이다.', 1, true),
  (187, 'misconception30', 27, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO는 특정 행동(투자, 거래)을 반드시 해야 이해할 수 있다.', 'X', '개념 학습만으로도 충분히 이해할 수 있다.', 1, true),
  (188, 'misconception30', 28, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'RWA는 현실 자산의 활용 방식을 넓히는 개념이다.', 'O', '자산을 더 다양한 방식으로 활용할 수 있게 한다.', 1, true),
  (189, 'misconception30', 29, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO와 RWA는 개념을 이해한다고 해서 무언가를 구매해야 하는 것은 아니다.', 'O', '학습·이해 목적의 개념이다.', 1, true),
  (190, 'misconception30', 30, '오해 방지용 OX 퀴즈 30문항 (정책 안전형 · 완성본)', 'policy', 'STO와 RWA는 ‘코인 투자’와 동일한 의미로 봐도 된다.', 'X', '투자 개념이 아니라 자산 구조와 기술 흐름을 설명한다.', 1, true)
on conflict (source_set, source_no) do update set
  content_order = excluded.content_order,
  category = excluded.category,
  difficulty = excluded.difficulty,
  question = excluded.question,
  correct_answer = excluded.correct_answer,
  explanation = excluded.explanation,
  content_version = excluded.content_version,
  is_active = excluded.is_active,
  updated_at = now();
notify pgrst, 'reload schema';

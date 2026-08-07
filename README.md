# STO Network Product Admin

`sto-network-admin.stodev.xyz`에서 사용할 별도 관리자 React/Vite 프로젝트입니다.
기존 STO Network와 동일한 Supabase 프로젝트 및 Auth를 사용하며, 중요 변경은 관리자 전용 PostgreSQL RPC로만 수행합니다.

## 포함 기능

- `member` 전체 컬럼 조회
- 회원 검색, 필터, 정렬, 서버 페이지네이션
- 회원 상세: 지갑, 최근 거래, 유입 정보, 탈퇴 요청, 채팅방
- `STOC_INT` 지급(`deposit`), 차감(`withdrawal`), 에어드랍(`airdrop`)
- 관리자 등급별 자산 권한: 팀장급/센터장/본부
- 잔액 행 잠금, 거래 멱등성, 음수 잔액 방지
- 전체 거래 내역 조회
- 본부급 전용 POS 일괄 지급: 엑셀 검증, 2단계 확인, 동일 파일 재사용 차단
- 그룹 채팅방 생성 및 제목 변경
- 채팅방 회원 일괄 추가/제외
- 채팅방 활성 인원 최대 100명 하드 제한
- 관리자 채팅 및 Supabase Realtime 신규 메시지 반영
- 관리자 작업 감사 로그

## 제외 범위

- EC2, Nginx, DNS 설정
- GitHub Actions 및 CI/CD
- 회원 정보 수정, 회원 정지/삭제
- 대량 에어드랍
- 채팅 메시지 삭제
- 관리자 계정/권한 생성 UI

## 실행 준비

```bash
cp .env.example .env.local
npm install
npm run dev
```

`.env.local`:

```env
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<publishable-or-anon-key>
VITE_WEB_BASE_URL=https://sto-network-admin.stodev.xyz
VITE_SUPABASE_AUTH_REDIRECT_URL=https://sto-network-admin.stodev.xyz/auth/callback
VITE_APP_BASE_PATH=/
```

브라우저 프로젝트에 `service_role`, secret key, DB 비밀번호를 넣지 않습니다.

## DB 마이그레이션

기존 STO Network 마이그레이션이 모두 반영된 DB에 다음 파일을 적용합니다.

```text
supabase/migrations/202608010050_product_admin_console.sql
supabase/migrations/202608030100_admin_grade_permissions.sql
supabase/migrations/202608030200_team_lead_member_search.sql
supabase/migrations/202608030300_transaction_reason_presets.sql
supabase/migrations/202608030400_wallet_account_addresses.sql
supabase/migrations/202608030500_signup_attribution_event.sql
supabase/migrations/202608030600_remove_member_devices_consents_from_detail.sql
supabase/migrations/202608030700_limit_signup_attribution_event_columns.sql
supabase/migrations/202608030800_attribution_events_touch_types.sql
supabase/migrations/202608030900_bulk_pos_deposit.sql
```

Supabase CLI를 사용하는 경우:

```bash
supabase link --project-ref <project-ref>
supabase db push
```

SQL Editor로 적용할 수도 있습니다. 이 마이그레이션은 아래 객체를 생성합니다.

- `public.admin_action_logs`
- `public.admin_profiles`
- `private.require_admin()`
- `private.require_super_admin()`
- 관리자 회원/거래/채팅 payload helper
- 관리자 전용 `rpc_admin_*` 함수
- 관리자 채팅 Realtime 조회 RLS 정책
- 채팅방 활성 인원 100명 제한 트리거

## 관리자 계정과 자산 권한

로그인하려는 Auth 사용자의 `public.member.role`이 `admin` 또는 `super_admin`이어야 합니다.
또한 `status = 'active'`, `is_del = false`여야 합니다.

자산 작업은 `public.admin_profiles.admin_grade`에 따라 제한됩니다.

| 관리자 등급 | 에어드랍 | 차감 | 지급 |
|---|:---:|:---:|:---:|
| `team_lead` 팀장급 | O | X | X |
| `center_director` 센터장 | O | O | X |
| `headquarters` 본부 | O | O | O |

POS 일괄 지급은 `headquarters` 본부급만 업로드, 검증, 실행할 수 있습니다.

기존 `super_admin` 계정은 `admin_profiles` 행이 없을 때만 본부 권한으로 호환됩니다.
프로필이 존재하면서 `is_active = false`이면 자산 작업 권한이 없습니다.

테스트 관리자 3개를 연결하려면 먼저 Supabase Authentication에 계정을 생성한 뒤 다음 SQL의 이메일을 확인하고 실행합니다.

```text
supabase/setup/register_admin_accounts.sql
```

기본 예시 이메일:

```text
teamlead.admin@stodev.xyz
center.admin@stodev.xyz
headquarters.admin@stodev.xyz
```

`auth.users`를 직접 INSERT하지 않습니다. 이메일/비밀번호 계정은 Supabase Dashboard에서 만들거나, Google 계정으로 한 번 로그인하여 Auth 사용자를 생성한 뒤 연결 SQL을 실행합니다.

## 자산 처리 규칙

| UI | transaction_type | 잔액 변화 |
|---|---|---:|
| 지급 | `deposit` | 증가 |
| 차감 | `withdrawal` | 감소 |
| 에어드랍 | `airdrop` | 증가 |

- 대상 지갑: `asset_code = 'STOC_INT'`, `account_type = 'internal'`
- `transactions.amount`는 항상 양수
- 차감은 `sender_user_id`에 대상 회원 저장
- 지급/에어드랍은 `receiver_user_id`에 대상 회원 저장
- 모든 처리는 `completed`, `processed_at = now()`로 기록
- 브라우저 재시도 및 중복 클릭은 `idempotency_key`로 차단
- 모든 처리 사유와 변경 전후 잔액은 거래 metadata 및 `admin_action_logs`에 기록

## 주요 관리자 RPC

```text
rpc_admin_get_session
rpc_admin_list_members
rpc_admin_search_members
rpc_admin_get_member
rpc_admin_adjust_stoc
rpc_admin_list_transactions
rpc_admin_validate_bulk_pos_deposit
rpc_admin_execute_bulk_pos_deposit
rpc_admin_list_chat_rooms
rpc_admin_get_chat_room
rpc_admin_create_chat_room
rpc_admin_update_chat_room
rpc_admin_add_chat_members
rpc_admin_remove_chat_members
rpc_admin_join_chat_room
rpc_admin_get_chat_messages
rpc_admin_get_chat_message
rpc_admin_list_action_logs
```

메시지 전송은 기존 `rpc_send_chat_message`를 재사용합니다. 해당 관리자 계정이 방에 없으면 첫 전송 직전에 `rpc_admin_join_chat_room`으로 참여합니다.

## 1차 통합 확인 순서

1. 마이그레이션 파일을 순서대로 적용
2. Auth 계정 3개 생성 후 `register_admin_accounts.sql` 실행
3. 관리자 계정 로그인
4. 팀장급 계정에서 에어드랍만 노출·실행되는지 확인
5. 센터장 계정에서 에어드랍·차감만 노출·실행되는지 확인
6. 본부 계정에서 지급·에어드랍·차감이 모두 노출·실행되는지 확인
7. 권한이 없는 action을 RPC로 직접 호출했을 때 거부되는지 확인
8. 회원 목록 및 상세 전체 컬럼 조회
9. 거래 내역 및 관리자 로그의 `adminGrade` 확인
10. 관리자 + 테스트 회원으로 그룹 채팅방 생성
11. 회원 추가/제외 및 실시간 채팅 확인
12. 100명 초과 추가 요청 차단 확인

상세 점검표는 `docs/INTEGRATION_CHECKLIST.md`를 참고합니다.

## 팀장급 회원 조회 제한

`202608030200_team_lead_member_search.sql` 적용 후 `team_lead` 계정은 회원 관리 진입 시 전체 목록을 받지 않습니다. 회원 ID, 이름, 이메일, 전화번호, UUID 또는 회원번호를 정확히 검색해야 결과가 반환되며 최대 20건으로 제한됩니다. 센터장과 본부 계정의 기존 전체 목록 조회는 유지됩니다.


## POS 일괄 지급

본부급 계정만 사용할 수 있는 대량 `deposit` 기능입니다. 엑셀 필수 컬럼은 아래 5개로 고정합니다.

```text
회원명
연락처
계약기간
지갑주소
지급 수량
```

검증 기준은 회원명, 숫자만 남긴 연락처, 지갑주소 전체 일치입니다. 엑셀 내 중복 행, 금액 오류, 회원/주소 불일치, 이미 완료된 동일 파일 SHA-256 해시가 있으면 전체 지급이 반려됩니다. 실행 시에는 `PAY_N_ROWS` 확인 문구를 입력해야 하며, 성공 후 `transactions.transaction_type = deposit` 기록과 관리자 감사 로그가 생성됩니다.

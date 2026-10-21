# 노드 신청 내역 관리자 기능 (062 + 063)

## 전제 및 배포

- 기반 코드: `sto-network-admin-main-1015-0915.zip` + `002_admin_member_reactivation_pin_reset_no_notice.patch`.
- `202610150061_admin_member_reactivation_pin_reset.sql` → `202610210062_admin_node_setup_applications.sql` → `202610210063_admin_node_application_read_scope.sql` 순서로 적용. 이미 062를 배포했다면 063만 추가 적용.
- 새 RPC 세 개는 `authenticated`에게 EXECUTE가 허용되지만, 함수 내부에서 `private.require_admin()` 및 등급 검증을 수행한다.
- 기존 회원 측 `rpc_get_node_setup_application`은 수정하지 않았다. 회원 앱에 `adminNote`가 실제 표시되는지는 **회원 클라이언트**에서 별도 확인할 것.

## DB/API

| RPC | 역할 | 권한 |
| --- | --- | --- |
| `rpc_admin_list_node_setup_applications` | 검색/상태/신청일 필터, 총 건수 및 페이지별 목록 | `center_director`, `headquarters` |
| `rpc_admin_get_node_setup_application` | 상세(전화번호 포함) 및 최근 30건 관리자 이력 | `center_director`, `headquarters` |
| `rpc_admin_update_node_setup_application` | 상태 변경, 관리자 답변, 감사로그를 원자적으로 저장 | `center_director`, `headquarters` |

- 화면 목록 컬럼: 신청일, 회원ID, 이름, 전화번호, GOPAX 메모 ID, 상태, 수정일, 상세.
- 상세: 회원ID, 이름, 전화번호(`member.mb_hp`), 이메일, 메모 ID, 현재 답변 및 관리자 처리 이력.
- 처리: `pending → contacting/completed/rejected`, `contacting → completed/rejected`. `completed`, `rejected`는 관리자 처리 종료 상태. 회원이 `rejected` 이후 재신청하면 기존 RPC가 같은 행을 `pending`으로 되돌리고 `admin_note`를 비운다.
- 관리자 답변은 기존 `admin_note`에 저장된다. 이 필드는 기존 회원용 RPC에서 `adminNote`로 반환되는 **회원 공개 텍스트**이다. 내부 전용 내용을 입력하지 말 것.
- 동시 편집 방지: 현재 `updated_at`을 `p_expected_updated_at`으로 전달. 충돌 시 `NODE_APPLICATION_STALE` 반환.
- 변경 내역은 `admin_action_logs`에 `node_application.update`로 기록. 테이블 추가 없음. 관리자 처리 로그만 조회하므로 회원의 신청/재신청 자체는 이력 표에 남지 않는다.
- 알림/푸시 전송은 이번 범위에 포함하지 않았다.

## DB 연결 후 검수 목록

1. 센터장/본부는 목록 및 상세(전화번호 포함)를 조회할 수 있고, 팀장은 메뉴/라우트 접근과 RPC 직접 호출 모두 거부되는지 확인.
2. 팀장이 RPC를 직접 호출할 때 수정 거부(`NODE_APPLICATION_MANAGE_PERMISSION_DENIED`) 확인.
3. 센터장/본부가 `pending → contacting → completed` 및 `pending → rejected` 처리할 수 있는지 확인.
4. 답변 누락, 1자, 1001자, 잘못된 상태 전이, 삭제된 회원의 신청 수정이 차단되는지 확인.
5. 두 창에서 같은 신청을 수정한 뒤 두 번째 저장이 `NODE_APPLICATION_STALE`를 반환하는지 확인.
6. 답변이 회원 앱의 기존 조회 RPC `adminNote`로 전달되는지 확인.
7. 처리 이력이 상세와 감사로그에 기록되고 검색 필터/목록 복귀 URL이 유지되는지 확인.

- 조회 권한은 `rpc_admin_get_session().permissions.nodeApplicationRead`와 목록/상세 RPC에서 중복 검증한다. 어드민 UI는 로그인 세션을 새로고침한 후 권한 표시가 갱신된다.

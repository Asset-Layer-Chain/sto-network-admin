import React, { useCallback, useEffect, useState } from 'react';
import { listMembers } from '../api/adminMemberApi.js';
import { useAuth } from '../auth/AuthContext.jsx';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Button, Card, EmptyState, Input, Loading, PageHeader, Pagination, Select, StatusBadge } from '../components/Common.jsx';
import { navigate } from '../router.js';
import { formatDateTime, formatNumber, truncate } from '../utils/format.js';

const initialFilters = {
  search: '', status: '', role: '', signupMethod: '', regChannel: '', isDeleted: '',
  page: 1, pageSize: 30, sortColumn: 'created_at', sortDirection: 'desc',
};

export function MemberListPage() {
  const { admin } = useAuth();
  const searchOnly = admin?.permissions?.memberListBrowse === false;
  const [filters, setFilters] = useState(initialFilters);
  const [applied, setApplied] = useState(initialFilters);
  const [result, setResult] = useState({ items: [], totalCount: 0, page: 1, pageSize: 30, searchRequired: false });
  const [loading, setLoading] = useState(!searchOnly);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    const search = String(applied.search || '').trim();
    if (searchOnly && !search) {
      setResult({ items: [], totalCount: 0, page: 1, pageSize: 20, searchRequired: true });
      setLoading(false);
      setError('');
      return;
    }

    setLoading(true);
    setError('');
    try { setResult(await listMembers(applied)); }
    catch (requestError) { setError(requestError.message); }
    finally { setLoading(false); }
  }, [applied, searchOnly]);

  useEffect(() => { load(); }, [load]);

  const apply = (event) => {
    event?.preventDefault();
    const next = { ...filters, search: filters.search.trim(), page: 1 };
    setApplied(next);
    setFilters(next);
  };

  const reset = () => {
    setFilters(initialFilters);
    setApplied(initialFilters);
  };

  const changePage = (page) => {
    if (searchOnly && !String(applied.search || '').trim()) return;
    setFilters((prev) => ({ ...prev, page }));
    setApplied((prev) => ({ ...prev, page }));
  };

  return (
    <AdminLayout active="members">
      <PageHeader
        title="회원 관리"
        description={searchOnly
          ? '회원 식별정보를 검색해 일치한 회원만 조회합니다.'
          : '회원 기본 정보와 내부 STOC 잔액을 조회합니다.'}
      />
      <Card>
        <form className="filter-grid" onSubmit={apply}>
          <Input
            label="검색"
            value={filters.search}
            onChange={(e) => setFilters({ ...filters, search: e.target.value })}
            placeholder={searchOnly ? '회원 ID, 이름, 이메일, 전화번호, UUID, 회원번호, 지갑 주소' : '아이디, 이름, 이메일, 전화번호, UUID, 지갑 주소'}
          />
          <Select label="상태" value={filters.status} onChange={(e) => setFilters({ ...filters, status: e.target.value })}><option value="">전체</option><option value="pending">pending</option><option value="active">active</option><option value="suspended">suspended</option><option value="deleted">deleted</option></Select>
          <Select label="권한" value={filters.role} onChange={(e) => setFilters({ ...filters, role: e.target.value })}><option value="">전체</option><option value="user">user</option><option value="admin">admin</option><option value="super_admin">super_admin</option></Select>
          <Select label="삭제 여부" value={filters.isDeleted} onChange={(e) => setFilters({ ...filters, isDeleted: e.target.value })}><option value="">전체</option><option value="false">정상</option><option value="true">삭제</option></Select>
          <Input label="가입 방식" value={filters.signupMethod} onChange={(e) => setFilters({ ...filters, signupMethod: e.target.value })} placeholder="legacy, manual, google" />
          <Input label="가입 채널" value={filters.regChannel} onChange={(e) => setFilters({ ...filters, regChannel: e.target.value })} placeholder="web, android" />
          <Select label="정렬" value={`${filters.sortColumn}:${filters.sortDirection}`} onChange={(e) => { const [sortColumn, sortDirection] = e.target.value.split(':'); setFilters({ ...filters, sortColumn, sortDirection }); }}><option value="created_at:desc">가입일 최신순</option><option value="created_at:asc">가입일 오래된순</option><option value="mb_no:desc">회원번호 내림차순</option><option value="mb_no:asc">회원번호 오름차순</option><option value="last_login_at:desc">최근 로그인순</option><option value="internal_stoc_balance:desc">STOC 잔액순</option></Select>
          <div className="filter-actions"><Button type="submit">검색</Button><Button type="button" variant="secondary" onClick={reset}>초기화</Button></div>
        </form>
      </Card>
      <Card className="table-card">
        {loading ? <Loading /> : null}
        {!loading && error ? <EmptyState title={error} description="조회 조건을 확인한 뒤 다시 시도해주세요." /> : null}
        {!loading && !error && searchOnly && result.searchRequired ? (
          <EmptyState title="회원 검색이 필요합니다." description="회원 ID, 이름, 이메일, 전화번호, UUID, 회원번호 또는 지갑 주소를 정확히 입력해주세요." />
        ) : null}
        {!loading && !error && !result.searchRequired && !result.items.length ? <EmptyState title="검색된 회원이 없습니다." /> : null}
        {!loading && !error && result.items.length ? (
          <div className="table-wrap">
            <table>
              <thead><tr><th>회원번호</th><th>회원</th><th>연락처</th><th>상태</th><th>권한</th><th className="align-right">STOC_INT</th><th>가입 방식</th><th>최근 로그인</th><th>가입일</th></tr></thead>
              <tbody>{result.items.map((member) => (
                <tr key={member.user_id} className="clickable-row" onClick={() => navigate(`/members/${member.user_id}`)}>
                  <td>{member.mb_no}</td>
                  <td><strong>{member.mb_name}</strong><small>{member.mb_id}<br />{truncate(member.user_id, 12)}</small></td>
                  <td>{member.mb_email}<small>{member.mb_hp || '-'}</small></td>
                  <td><StatusBadge value={member.status} />{member.is_del ? <small className="text-danger">삭제 표시</small> : null}</td>
                  <td><StatusBadge value={member.role} /></td>
                  <td className="align-right"><strong>{formatNumber(member.internal_stoc_balance)}</strong></td>
                  <td>{member.signup_method}<small>{member.reg_channel}</small></td>
                  <td>{formatDateTime(member.last_login_at)}</td>
                  <td>{formatDateTime(member.created_at)}</td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        ) : null}
        {!result.searchRequired ? <Pagination page={result.page} pageSize={result.pageSize} totalCount={result.totalCount} onChange={changePage} /> : null}
      </Card>
    </AdminLayout>
  );
}

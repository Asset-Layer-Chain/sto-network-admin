import React, { useEffect, useMemo, useState } from 'react';
import { listNodeApplications } from '../api/adminNodeApplicationApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Button, Card, CopyButton, EmptyState, Input, Loading, PageHeader, Pagination, Select } from '../components/Common.jsx';
import { NodeApplicationStatus } from '../components/NodeApplicationStatus.jsx';
import { navigate, useLocation } from '../router.js';
import { formatDateTime } from '../utils/format.js';
import { formatPhoneNumberOrDash } from '../utils/phone.js';

const initial = { search: '', status: '', fromDate: '', toDate: '', page: 1, pageSize: 30 };

function parseFilters(search) {
  const params = new URLSearchParams(search);
  const page = Number(params.get('page'));
  return {
    ...initial,
    search: params.get('q') || '',
    status: params.get('status') || '',
    fromDate: params.get('from') || '',
    toDate: params.get('to') || '',
    page: Number.isSafeInteger(page) && page > 0 ? page : 1,
  };
}

function filtersUrl(filters) {
  const params = new URLSearchParams();
  if (filters.search) params.set('q', filters.search.trim());
  if (filters.status) params.set('status', filters.status);
  if (filters.fromDate) params.set('from', filters.fromDate);
  if (filters.toDate) params.set('to', filters.toDate);
  if (filters.page > 1) params.set('page', String(filters.page));
  const query = params.toString();
  return `/node-applications${query ? `?${query}` : ''}`;
}

export function NodeApplicationListPage() {
  const { search } = useLocation();
  const applied = useMemo(() => parseFilters(search), [search]);
  const [filters, setFilters] = useState(() => parseFilters(search));
  const [result, setResult] = useState({ items: [], totalCount: 0, page: 1, pageSize: 30 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => { setFilters(applied); }, [applied]);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError('');
    listNodeApplications(applied)
      .then((next) => { if (active) setResult(next); })
      .catch((err) => { if (active) setError(err.message); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [applied]);

  const apply = (event) => {
    event.preventDefault();
    navigate(filtersUrl({ ...filters, page: 1 }));
  };

  return (
    <AdminLayout active="node-applications">
      <PageHeader title="노드 신청 내역" description="노드 구성 신청을 조회하고 처리합니다." />
      <Card>
        <form className="filter-grid" onSubmit={apply}>
          <Input label="검색" value={filters.search} maxLength={100} placeholder="회원ID, 이름, 전화번호, GOPAX 메모 ID" onChange={(e) => setFilters({ ...filters, search: e.target.value })} />
          <Select label="처리 상태" value={filters.status} onChange={(e) => setFilters({ ...filters, status: e.target.value })}>
            <option value="">전체</option>
            <option value="pending">신청 대기</option>
            <option value="contacting">연락 중</option>
            <option value="completed">처리 완료</option>
            <option value="rejected">반려</option>
          </Select>
          <Input label="신청 시작일" type="date" value={filters.fromDate} onChange={(e) => setFilters({ ...filters, fromDate: e.target.value })} />
          <Input label="신청 종료일" type="date" value={filters.toDate} min={filters.fromDate || undefined} onChange={(e) => setFilters({ ...filters, toDate: e.target.value })} />
          <div className="filter-actions">
            <Button type="submit">조회</Button>
            <Button type="button" variant="secondary" onClick={() => { setFilters(initial); navigate('/node-applications'); }}>초기화</Button>
          </div>
        </form>
      </Card>
      <Card className="table-card">
        {loading ? <Loading /> : null}
        {!loading && error ? <EmptyState title={error} /> : null}
        {!loading && !error && result.items.length === 0 ? <EmptyState title="노드 신청 내역이 없습니다." /> : null}
        {!loading && !error && result.items.length > 0 ? (
          <div className="table-wrap"><table>
            <thead><tr><th>신청일시</th><th>회원ID</th><th>회원명</th><th>전화번호</th><th>GOPAX 메모 ID</th><th>처리 상태</th><th>수정일시</th><th>관리</th></tr></thead>
            <tbody>{result.items.map((item) => (
              <tr key={item.id}>
                <td>{formatDateTime(item.createdAt)}</td>
                <td>{item.memberId}</td>
                <td>{item.memberName}</td>
                <td>{formatPhoneNumberOrDash(item.phone)}</td>
                <td className="node-memo-cell" title={item.gopaxMemoId}>{item.gopaxMemoId}<CopyButton value={item.gopaxMemoId} /></td>
                <td><NodeApplicationStatus status={item.status} /></td>
                <td>{formatDateTime(item.updatedAt)}</td>
                <td><Button size="sm" variant="secondary" onClick={() => navigate(`/node-applications/${item.id}${search}`)}>상세 보기</Button></td>
              </tr>
            ))}</tbody>
          </table></div>
        ) : null}
        {!loading && !error ? <Pagination page={result.page} pageSize={result.pageSize} totalCount={result.totalCount} onChange={(page) => navigate(filtersUrl({ ...applied, page }))} /> : null}
      </Card>
    </AdminLayout>
  );
}

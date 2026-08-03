import React, { useCallback, useEffect, useState } from 'react';
import { listAdminLogs } from '../api/adminLogApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Badge, Button, Card, EmptyState, Input, Loading, Modal, PageHeader, Pagination, Select } from '../components/Common.jsx';
import { formatDateTime } from '../utils/format.js';

const initial = { search: '', actionType: '', actorUserId: '', fromAt: '', toAt: '', page: 1, pageSize: 30 };

export function AdminLogPage() {
  const [filters, setFilters] = useState(initial);
  const [applied, setApplied] = useState(initial);
  const [result, setResult] = useState({ items: [], totalCount: 0, page: 1, pageSize: 30 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [selected, setSelected] = useState(null);

  const load = useCallback(async () => {
    setLoading(true); setError('');
    try { setResult(await listAdminLogs(applied)); }
    catch (requestError) { setError(requestError.message); }
    finally { setLoading(false); }
  }, [applied]);
  useEffect(() => { load(); }, [load]);

  const apply = (event) => { event.preventDefault(); setApplied({ ...filters, page: 1 }); };
  const changePage = (page) => setApplied((prev) => ({ ...prev, page }));

  return (
    <AdminLayout active="admin-logs">
      <PageHeader title="관리자 작업 로그" description="자산 관리 작업의 변경 전후 데이터를 조회합니다." />
      <Card><form className="filter-grid" onSubmit={apply}>
        <Input label="검색" value={filters.search} onChange={(e) => setFilters({ ...filters, search: e.target.value })} placeholder="관리자, 대상 회원, 사유, 요청 ID" />
        <Select label="작업 유형" value={filters.actionType} onChange={(e) => setFilters({ ...filters, actionType: e.target.value })}><option value="">전체</option><option value="wallet.deposit">wallet.deposit</option><option value="wallet.withdrawal">wallet.withdrawal</option><option value="wallet.airdrop">wallet.airdrop</option></Select>
        <Input label="관리자 UUID" value={filters.actorUserId} onChange={(e) => setFilters({ ...filters, actorUserId: e.target.value })} />
        <Input label="시작일" type="datetime-local" value={filters.fromAt} onChange={(e) => setFilters({ ...filters, fromAt: e.target.value })} />
        <Input label="종료일" type="datetime-local" value={filters.toAt} onChange={(e) => setFilters({ ...filters, toAt: e.target.value })} />
        <div className="filter-actions"><Button type="submit">조회</Button><Button type="button" variant="secondary" onClick={() => { setFilters(initial); setApplied(initial); }}>초기화</Button></div>
      </form></Card>
      <Card className="table-card">
        {loading ? <Loading /> : null}
        {!loading && error ? <EmptyState title={error} /> : null}
        {!loading && !error && !result.items.length ? <EmptyState /> : null}
        {!loading && !error && result.items.length ? <div className="table-wrap"><table><thead><tr><th>일시</th><th>작업</th><th>관리자</th><th>대상 회원</th><th>채팅방</th><th>사유</th><th>요청 ID</th></tr></thead><tbody>{result.items.map((log) => <tr key={log.id} className="clickable-row" onClick={() => setSelected(log)}><td>{formatDateTime(log.createdAt)}</td><td><Badge tone={log.actionType?.startsWith('wallet.') ? 'purple' : 'info'}>{log.actionType}</Badge></td><td>{log.actor?.memberId || '-'}<small>{log.actor?.name}</small></td><td>{log.targetMember?.memberId || '-'}</td><td>{log.targetRoom?.title || '-'}</td><td>{log.reason || '-'}</td><td>{log.idempotencyKey || '-'}</td></tr>)}</tbody></table></div> : null}
        <Pagination page={result.page} pageSize={result.pageSize} totalCount={result.totalCount} onChange={changePage} />
      </Card>
      <Modal open={Boolean(selected)} title="관리자 작업 로그 상세" width="820px" onClose={() => setSelected(null)} footer={<Button variant="secondary" onClick={() => setSelected(null)}>닫기</Button>}>
        {selected ? <div className="log-detail"><dl className="detail-grid"><div><dt>id</dt><dd>{selected.id}</dd></div><div><dt>action_type</dt><dd>{selected.actionType}</dd></div><div><dt>actor</dt><dd>{selected.actor?.memberId} ({selected.actor?.userId})</dd></div><div><dt>created_at</dt><dd>{formatDateTime(selected.createdAt)}</dd></div><div className="detail-wide"><dt>reason</dt><dd>{selected.reason || '-'}</dd></div><div className="detail-wide"><dt>before_data</dt><dd><pre className="json-view">{JSON.stringify(selected.beforeData, null, 2)}</pre></dd></div><div className="detail-wide"><dt>after_data</dt><dd><pre className="json-view">{JSON.stringify(selected.afterData, null, 2)}</pre></dd></div><div className="detail-wide"><dt>metadata</dt><dd><pre className="json-view">{JSON.stringify(selected.metadata, null, 2)}</pre></dd></div></dl></div> : null}
      </Modal>
    </AdminLayout>
  );
}

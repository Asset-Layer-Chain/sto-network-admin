import React, { useCallback, useEffect, useState } from 'react';
import { listTransactions } from '../api/adminTransactionApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Button, Card, EmptyState, Input, Loading, PageHeader, Pagination, Select, StatusBadge } from '../components/Common.jsx';
import { navigate } from '../router.js';
import { formatDateTime, formatNumber } from '../utils/format.js';

const initial = { search: '', transactionType: 'deposit', status: '', assetCode: 'STOC_INT', userId: '', fromAt: '', toAt: '', page: 1, pageSize: 30 };

export function TransactionListPage() {
  const [filters, setFilters] = useState(initial);
  const [applied, setApplied] = useState(initial);
  const [result, setResult] = useState({ items: [], totalCount: 0, page: 1, pageSize: 30 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    setLoading(true); setError('');
    try { setResult(await listTransactions(applied)); }
    catch (requestError) { setError(requestError.message); }
    finally { setLoading(false); }
  }, [applied]);
  useEffect(() => { load(); }, [load]);

  const apply = (event) => { event.preventDefault(); setApplied({ ...filters, page: 1 }); setFilters((prev) => ({ ...prev, page: 1 })); };
  const changePage = (page) => { setFilters((prev) => ({ ...prev, page })); setApplied((prev) => ({ ...prev, page })); };

  return (
    <AdminLayout active="transactions">
      <PageHeader title="거래 내역" description="전체 거래 원장과 관리자 자산 처리 내역을 조회합니다." />
      <Card><form className="filter-grid" onSubmit={apply}>
        <Input label="검색" value={filters.search} onChange={(e) => setFilters({ ...filters, search: e.target.value })} placeholder="거래 ID, 회원 ID, 이름, 이메일, 설명" />
        <Select label="거래 유형" value={filters.transactionType} onChange={(e) => setFilters({ ...filters, transactionType: e.target.value })}><option value="">전체</option><option value="deposit">deposit</option><option value="withdrawal">withdrawal</option><option value="airdrop">airdrop</option><option value="transfer">transfer</option><option value="attendance_reward">attendance_reward</option><option value="roulette_reward">roulette_reward</option><option value="referral_reward">referral_reward</option></Select>
        <Select label="상태" value={filters.status} onChange={(e) => setFilters({ ...filters, status: e.target.value })}><option value="">전체</option><option value="pending">pending</option><option value="processing">processing</option><option value="completed">completed</option><option value="failed">failed</option><option value="cancelled">cancelled</option></Select>
        <Input label="자산 코드" value={filters.assetCode} onChange={(e) => setFilters({ ...filters, assetCode: e.target.value })} />
        <Input label="회원 UUID" value={filters.userId} onChange={(e) => setFilters({ ...filters, userId: e.target.value })} placeholder="선택 입력" />
        <Input label="시작일" type="datetime-local" value={filters.fromAt} onChange={(e) => setFilters({ ...filters, fromAt: e.target.value })} />
        <Input label="종료일" type="datetime-local" value={filters.toAt} onChange={(e) => setFilters({ ...filters, toAt: e.target.value })} />
        <div className="filter-actions"><Button type="submit">조회</Button><Button type="button" variant="secondary" onClick={() => { setFilters(initial); setApplied(initial); }}>초기화</Button></div>
      </form></Card>
      <Card className="table-card">
        {loading ? <Loading /> : null}
        {!loading && error ? <EmptyState title={error} /> : null}
        {!loading && !error && !result.items.length ? <EmptyState /> : null}
        {!loading && !error && result.items.length ? <div className="table-wrap"><table><thead><tr><th>거래일</th><th>유형</th><th>상태</th><th>보낸 회원</th><th>받는 회원</th><th>자산</th><th className="align-right">금액</th><th>설명</th><th>관리자</th></tr></thead><tbody>{result.items.map((tx) => <tr key={tx.id}><td>{formatDateTime(tx.createdAt)}</td><td><StatusBadge value={tx.transactionType} /></td><td><StatusBadge value={tx.status} /></td><td>{tx.sender ? <button className="link-button" onClick={() => navigate(`/members/${tx.sender.userId}`)}>{tx.sender.memberId}<small>{tx.sender.name}</small></button> : '-'}</td><td>{tx.receiver ? <button className="link-button" onClick={() => navigate(`/members/${tx.receiver.userId}`)}>{tx.receiver.memberId}<small>{tx.receiver.name}</small></button> : '-'}</td><td>{tx.assetCode}</td><td className="align-right"><strong>{formatNumber(tx.amount)}</strong></td><td>{tx.description || '-'}</td><td>{tx.adminActor?.memberId || tx.metadata?.admin_actor_member_id || '-'}</td></tr>)}</tbody></table></div> : null}
        <Pagination page={result.page} pageSize={result.pageSize} totalCount={result.totalCount} onChange={changePage} />
      </Card>
    </AdminLayout>
  );
}

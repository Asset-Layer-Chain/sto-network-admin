import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useAuth } from '../auth/AuthContext.jsx';
import { getMember } from '../api/adminMemberApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { AssetAdjustmentModal } from '../components/AssetAdjustmentModal.jsx';
import { Button, Card, CopyButton, EmptyState, Loading, PageHeader, StatusBadge } from '../components/Common.jsx';
import { navigate } from '../router.js';
import { shortenAddress } from '../utils/address.js';
import { formatBoolean, formatDateTime, formatNumber } from '../utils/format.js';

function renderValue(key, value) {
  if (value === null || value === undefined || value === '') return '-';
  if (typeof value === 'boolean') return formatBoolean(value);
  if (typeof value === 'object') return <pre className="json-view">{JSON.stringify(value, null, 2)}</pre>;
  if (key.endsWith('_at') || key.includes('date')) return formatDateTime(value);
  return String(value);
}


function WalletAddressCell({ wallet }) {
  if (!wallet?.address) return '-';
  return (
    <span className="wallet-address-cell">
      <code>{shortenAddress(wallet.address)}</code>
      <CopyButton value={wallet.address} />
      {wallet.address_status ? <small>{wallet.address_status}</small> : null}
    </span>
  );
}

function ObjectFields({ data }) {
  if (!data) return <EmptyState />;
  return (
    <dl className="detail-grid">
      {Object.entries(data).map(([key, value]) => (
        <div key={key} className={typeof value === 'object' && value !== null ? 'detail-wide' : ''}>
          <dt>{key}</dt>
          <dd>{renderValue(key, value)}{['user_id', 'mb_email', 'mb_hp', 'google_id', 'referral_code'].includes(key) && value ? <CopyButton value={value} /> : null}</dd>
        </div>
      ))}
    </dl>
  );
}

export function MemberDetailPage({ userId }) {
  const { admin } = useAuth();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [action, setAction] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try { setData(await getMember(userId)); }
    catch (requestError) { setError(requestError.message); }
    finally { setLoading(false); }
  }, [userId]);

  useEffect(() => { load(); }, [load]);

  const member = data?.member || null;
  const actionMember = useMemo(() => member ? { ...member, internalStocBalance: data?.internalStocBalance ?? data?.internal_stoc_balance ?? 0 } : null, [member, data]);

  return (
    <AdminLayout active="members">
      <PageHeader
        title={member ? `${member.mb_name} 회원 상세` : '회원 상세'}
        description={member ? `${member.mb_id} · ${member.mb_email}` : userId}
        actions={<>
          <Button variant="secondary" onClick={() => navigate('/members')}>목록</Button>
          {member && admin?.permissions?.assetDeposit ? <Button onClick={() => setAction('deposit')}>지급</Button> : null}
          {member && admin?.permissions?.assetAirdrop ? <Button variant="purple" onClick={() => setAction('airdrop')}>에어드랍</Button> : null}
          {member && admin?.permissions?.assetWithdrawal ? <Button variant="danger" onClick={() => setAction('withdrawal')}>차감</Button> : null}
        </>}
      />
      {loading ? <Loading /> : null}
      {!loading && error ? <EmptyState title={error} /> : null}
      {!loading && member ? (
        <div className="detail-stack">
          {!admin?.permissions?.assetDeposit && !admin?.permissions?.assetWithdrawal && !admin?.permissions?.assetAirdrop ? (
            <div className="notice notice-warning">현재 계정에는 자산 처리 권한이 설정되지 않았습니다.</div>
          ) : null}
          <div className="member-summary-grid">
            <Card><span className="summary-label">STOC_INT 사용 가능 잔액</span><strong className="summary-value">{formatNumber(data.internalStocBalance)} STOC</strong></Card>
            <Card><span className="summary-label">회원 상태</span><div className="summary-badges"><StatusBadge value={member.status} /><StatusBadge value={member.role} />{member.is_del ? <StatusBadge value="deleted" /> : null}</div></Card>
            <Card><span className="summary-label">최근 로그인</span><strong className="summary-text">{formatDateTime(member.last_login_at)}</strong></Card>
            <Card><span className="summary-label">가입일</span><strong className="summary-text">{formatDateTime(member.created_at)}</strong></Card>
          </div>

          <Card title="member 전체 컬럼"><ObjectFields data={member} /></Card>

          <Card title={`지갑 계정 (${data.walletAccounts?.length || 0})`}>
            {!data.walletAccounts?.length ? <EmptyState /> : <div className="table-wrap"><table><thead><tr><th>asset_code</th><th>account_type</th><th>chain</th><th>address</th><th className="align-right">available_balance</th><th className="align-right">locked_balance</th><th>updated_at</th></tr></thead><tbody>{data.walletAccounts.map((wallet) => <tr key={wallet.id}><td>{wallet.asset_code}</td><td>{wallet.account_type}</td><td>{wallet.chain || '-'}</td><td><WalletAddressCell wallet={wallet} /></td><td className="align-right">{formatNumber(wallet.available_balance)}</td><td className="align-right">{formatNumber(wallet.locked_balance)}</td><td>{formatDateTime(wallet.updated_at)}</td></tr>)}</tbody></table></div>}
          </Card>

          <Card title={`최근 거래 (${data.recentTransactions?.length || 0})`}>
            {!data.recentTransactions?.length ? <EmptyState /> : <div className="table-wrap"><table><thead><tr><th>유형</th><th>상태</th><th>자산</th><th className="align-right">금액</th><th>상대 회원</th><th>설명</th><th>처리일</th></tr></thead><tbody>{data.recentTransactions.map((tx) => <tr key={tx.id}><td><StatusBadge value={tx.transactionType || tx.transaction_type} /></td><td><StatusBadge value={tx.status} /></td><td>{tx.assetCode || tx.asset_code}</td><td className="align-right">{formatNumber(tx.amount)}</td><td>{tx.sender?.memberId || tx.receiver?.memberId || '-'}</td><td>{tx.description || '-'}</td><td>{formatDateTime(tx.processedAt || tx.processed_at || tx.createdAt || tx.created_at)}</td></tr>)}</tbody></table></div>}
          </Card>

          <div className="two-column">
            <Card title={`기기 (${data.devices?.length || 0})`}><ObjectFields data={data.devices?.length ? Object.fromEntries(data.devices.map((item, index) => [`device_${index + 1}`, item])) : null} /></Card>
            <Card title={`동의 정보 (${data.consents?.length || 0})`}><ObjectFields data={data.consents?.length ? Object.fromEntries(data.consents.map((item, index) => [`consent_${index + 1}`, item])) : null} /></Card>
          </div>
          <div className="two-column">
            <Card title="마케팅 유입 정보"><ObjectFields data={data.marketingAttribution} /></Card>
            <Card title="탈퇴 요청"><ObjectFields data={data.deletionRequest} /></Card>
          </div>
          <Card title={`참여 채팅방 (${data.chatRooms?.length || 0})`}>
            {!data.chatRooms?.length ? <EmptyState /> : <div className="table-wrap"><table><thead><tr><th>방 제목</th><th>역할</th><th>참여일</th><th>퇴장일</th><th>마지막 메시지</th></tr></thead><tbody>{data.chatRooms.map((room) => <tr key={room.roomId} className="clickable-row" onClick={() => navigate(`/chats/${room.roomId}`)}><td>{room.title}</td><td>{room.role}</td><td>{formatDateTime(room.joinedAt)}</td><td>{formatDateTime(room.leftAt)}</td><td>{formatDateTime(room.lastMessageAt)}</td></tr>)}</tbody></table></div>}
          </Card>
        </div>
      ) : null}
      <AssetAdjustmentModal open={Boolean(action)} member={actionMember} action={action} onClose={() => setAction(null)} onCompleted={load} />
    </AdminLayout>
  );
}

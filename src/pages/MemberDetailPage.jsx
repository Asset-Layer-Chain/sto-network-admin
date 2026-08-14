import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useAuth } from '../auth/AuthContext.jsx';
import { getMember } from '../api/adminMemberApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { AssetAdjustmentModal } from '../components/AssetAdjustmentModal.jsx';
import { MemberNameEditModal } from '../components/MemberNameEditModal.jsx';
import { Button, Card, CopyButton, EmptyState, Loading, PageHeader, StatusBadge } from '../components/Common.jsx';
import { navigate } from '../router.js';
import { formatBoolean, formatDateTime, formatNumber } from '../utils/format.js';
import { formatPhoneNumber } from '../utils/phone.js';

const COPYABLE_DETAIL_KEYS = new Set([
  'user_id',
  'mb_email',
  'mb_hp',
  'google_id',
  'referral_code',
  'id',
  'anonymous_id',
  'session_id',
  'raw_url',
  'landing_url',
  'referrer_url',
  'raw_params',
  'attribution_payload',
  'campaign_id',
  'ad_group_id',
  'ad_creative_id',
  'ad_id',
  'click_id',
  'gclid',
  'gbraid',
  'wbraid',
  'gaid_raw',
  'routing_short_id',
  'tracking_template_id',
  'sub_id',
  'sub_id_1',
  'sub_id_2',
  'sub_id_3',
]);

const MEMBER_DETAIL_HIDDEN_KEYS = new Set([
  'signup_attribution_medium',
  'signup_attribution_source',
  'signup_attribution_channel',
  'signup_attribution_ad_group',
  'signup_attribution_campaign',
  'signup_attribution_click_id',
  'signup_attribution_ad_creative',
  'signup_attribution_ad_group_id',
  'signup_attribution_campaign_id',
  'signup_attribution_captured_at',
  'signup_attribution_landing_url',
  'signup_attribution_ad_creative_id',
]);

function renderValue(key, value) {
  if (value === null || value === undefined || value === '') return '-';
  if (key === 'mb_hp') return formatPhoneNumber(value) || '-';
  if (typeof value === 'boolean') return formatBoolean(value);
  if (typeof value === 'object') return <pre className="json-view">{JSON.stringify(value, null, 2)}</pre>;
  if (key.endsWith('_at') || key.includes('date')) return formatDateTime(value);
  return String(value);
}

function getCopyValue(key, value) {
  if (value === null || value === undefined || value === '') return '';
  if (key === 'mb_hp') return formatPhoneNumber(value);
  if (typeof value === 'object') return JSON.stringify(value, null, 2);
  return String(value);
}

function shouldShowCopy(key, value) {
  if (value === null || value === undefined || value === '') return false;
  return COPYABLE_DETAIL_KEYS.has(key);
}

function WalletAddressCell({ wallet }) {
  if (!wallet?.address) return '-';
  return (
    <span className="wallet-address-cell">
      <code title={wallet.address}>{wallet.address}</code>
      <CopyButton value={wallet.address} />
      {wallet.address_status ? <small>{wallet.address_status}</small> : null}
    </span>
  );
}

function ObjectFields({ data, emptyTitle, emptyDescription, excludeKeys, onEditMemberName }) {
  const entries = data && typeof data === 'object' && !Array.isArray(data)
    ? Object.entries(data).filter(([key]) => !excludeKeys?.has(key))
    : [];

  if (!data || entries.length === 0) {
    return <EmptyState title={emptyTitle} description={emptyDescription} />;
  }
  return (
    <dl className="detail-grid">
      {entries.map(([key, value]) => (
        <div key={key} className={typeof value === 'object' && value !== null ? 'detail-wide' : ''}>
          <dt>{key}</dt>
          <dd>
            {renderValue(key, value)}
            {key === 'mb_name' && onEditMemberName ? <Button variant="secondary" size="sm" className="detail-edit-button" onClick={onEditMemberName}>변경</Button> : null}
            {shouldShowCopy(key, value) ? <CopyButton value={getCopyValue(key, value)} /> : null}
          </dd>
        </div>
      ))}
    </dl>
  );
}

const ATTRIBUTION_EVENT_CARDS = [
  { key: 'firstTouch', title: '첫 유입', eventType: 'first_touch' },
  { key: 'lastTouch', title: '마지막 유입', eventType: 'last_touch' },
  { key: 'signup', title: '가입 유입', eventType: 'signup' },
];

function AttributionEvents({ events, fallbackSignupEvent }) {
  const normalizedEvents = {
    firstTouch: events?.firstTouch ?? null,
    lastTouch: events?.lastTouch ?? null,
    signup: events?.signup ?? fallbackSignupEvent ?? null,
  };

  return (
    <div className="attribution-event-grid">
      {ATTRIBUTION_EVENT_CARDS.map((item) => (
        <div key={item.key} className="attribution-event-card">
          <h4>{item.title}</h4>
          <ObjectFields
            data={normalizedEvents[item.key]}
            emptyTitle={`${item.eventType} 이벤트가 없습니다.`}
            emptyDescription={`marketing_attribution_events에서 event_type='${item.eventType}'인 이벤트를 찾지 못했습니다.`}
          />
        </div>
      ))}
    </div>
  );
}

export function MemberDetailPage({ userId }) {
  const { admin } = useAuth();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [action, setAction] = useState(null);
  const [nameEditOpen, setNameEditOpen] = useState(false);

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

          <Card title="member 전체 컬럼"><ObjectFields data={member} excludeKeys={MEMBER_DETAIL_HIDDEN_KEYS} onEditMemberName={() => setNameEditOpen(true)} /></Card>

          <Card title={`지갑 계정 (${data.walletAccounts?.length || 0})`}>
            {!data.walletAccounts?.length ? <EmptyState /> : <div className="table-wrap"><table><thead><tr><th>asset_code</th><th>account_type</th><th>chain</th><th>address</th><th className="align-right">available_balance</th><th className="align-right">locked_balance</th><th>updated_at</th></tr></thead><tbody>{data.walletAccounts.map((wallet) => <tr key={wallet.id}><td>{wallet.asset_code}</td><td>{wallet.account_type}</td><td>{wallet.chain || '-'}</td><td><WalletAddressCell wallet={wallet} /></td><td className="align-right">{formatNumber(wallet.available_balance)}</td><td className="align-right">{formatNumber(wallet.locked_balance)}</td><td>{formatDateTime(wallet.updated_at)}</td></tr>)}</tbody></table></div>}
          </Card>

          <Card title={`최근 거래 (${data.recentTransactions?.length || 0})`}>
            {!data.recentTransactions?.length ? <EmptyState /> : <div className="table-wrap"><table><thead><tr><th>유형</th><th>상태</th><th>자산</th><th className="align-right">금액</th><th>상대 회원</th><th>설명</th><th>처리일</th></tr></thead><tbody>{data.recentTransactions.map((tx) => <tr key={tx.id}><td><StatusBadge value={tx.transactionType || tx.transaction_type} /></td><td><StatusBadge value={tx.status} /></td><td>{tx.assetCode || tx.asset_code}</td><td className="align-right">{formatNumber(tx.amount)}</td><td>{tx.sender?.memberId || tx.receiver?.memberId || '-'}</td><td>{tx.description || '-'}</td><td>{formatDateTime(tx.processedAt || tx.processed_at || tx.createdAt || tx.created_at)}</td></tr>)}</tbody></table></div>}
          </Card>

          <Card title="마케팅 유입 이벤트">
            <AttributionEvents events={data.attributionEvents} fallbackSignupEvent={data.signupAttributionEvent} />
          </Card>

          <Card title="탈퇴 요청"><ObjectFields data={data.deletionRequest} /></Card>
          <Card title={`참여 채팅방 (${data.chatRooms?.length || 0})`}>
            {!data.chatRooms?.length ? <EmptyState /> : <div className="table-wrap"><table><thead><tr><th>방 제목</th><th>역할</th><th>참여일</th><th>퇴장일</th><th>마지막 메시지</th></tr></thead><tbody>{data.chatRooms.map((room) => <tr key={room.roomId} className="clickable-row" onClick={() => navigate(`/chats/${room.roomId}`)}><td>{room.title}</td><td>{room.role}</td><td>{formatDateTime(room.joinedAt)}</td><td>{formatDateTime(room.leftAt)}</td><td>{formatDateTime(room.lastMessageAt)}</td></tr>)}</tbody></table></div>}
          </Card>
        </div>
      ) : null}
      <AssetAdjustmentModal open={Boolean(action)} member={actionMember} action={action} onClose={() => setAction(null)} onCompleted={load} />
      <MemberNameEditModal open={nameEditOpen} member={member} onClose={() => setNameEditOpen(false)} onCompleted={load} />
    </AdminLayout>
  );
}

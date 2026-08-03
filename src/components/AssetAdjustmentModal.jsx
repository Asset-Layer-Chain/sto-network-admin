import React, { useEffect, useMemo, useState } from 'react';
import { adjustStoc } from '../api/adminTransactionApi.js';
import { createIdempotencyKey } from '../api/rpcClient.js';
import { formatNumber } from '../utils/format.js';
import { Button, Input, Modal, Textarea } from './Common.jsx';
import { useToast } from './Toast.jsx';

const ACTIONS = {
  deposit: { title: 'STOC 지급', submit: '지급 확정', sign: 1 },
  withdrawal: { title: 'STOC 차감', submit: '차감 확정', sign: -1 },
  airdrop: { title: 'STOC 에어드랍', submit: '에어드랍 확정', sign: 1 },
};

export function AssetAdjustmentModal({ open, member, action, onClose, onCompleted }) {
  const config = ACTIONS[action] || ACTIONS.deposit;
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [idempotencyKey, setIdempotencyKey] = useState('');
  const { showToast } = useToast();

  useEffect(() => {
    if (!open) return;
    setAmount('');
    setReason('');
    setError('');
    setIdempotencyKey(createIdempotencyKey(`admin-${action}`));
  }, [open, action]);

  const currentBalance = Number(member?.internalStocBalance ?? member?.internal_stoc_balance ?? 0);
  const numericAmount = Number(amount || 0);
  const expected = useMemo(() => currentBalance + (config.sign * numericAmount), [currentBalance, numericAmount, config.sign]);

  const submit = async () => {
    if (!Number.isFinite(numericAmount) || numericAmount <= 0) {
      setError('금액은 0보다 커야 합니다.');
      return;
    }
    if (reason.trim().length < 2) {
      setError('처리 사유를 2자 이상 입력해주세요.');
      return;
    }
    if (action === 'withdrawal' && expected < 0) {
      setError('보유 잔액보다 많이 차감할 수 없습니다.');
      return;
    }

    setSubmitting(true);
    setError('');
    try {
      const result = await adjustStoc({
        userId: member.user_id || member.userId,
        action,
        amount: numericAmount,
        reason,
        idempotencyKey,
      });
      showToast(`${formatNumber(numericAmount)} STOC ${config.submit.replace(' 확정', '')} 처리되었습니다.`);
      onCompleted?.(result);
      onClose?.();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      open={open}
      title={config.title}
      onClose={submitting ? undefined : onClose}
      footer={<><Button variant="secondary" onClick={onClose} disabled={submitting}>취소</Button><Button variant={action === 'withdrawal' ? 'danger' : 'primary'} onClick={submit} disabled={submitting}>{submitting ? '처리 중' : `${formatNumber(numericAmount)} STOC ${config.submit}`}</Button></>}
    >
      <div className="summary-box">
        <div><span>대상 회원</span><strong>{member?.mb_name || member?.name} ({member?.mb_id || member?.memberId})</strong></div>
        <div><span>현재 잔액</span><strong>{formatNumber(currentBalance)} STOC</strong></div>
        <div><span>처리 후 예상</span><strong className={expected < 0 ? 'text-danger' : ''}>{formatNumber(expected)} STOC</strong></div>
      </div>
      <Input label="금액" type="number" min="0" step="any" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0" />
      <Textarea label="처리 사유" rows="4" maxLength="300" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="감사 로그와 거래 메타데이터에 저장됩니다." />
      {error ? <p className="form-error">{error}</p> : null}
    </Modal>
  );
}

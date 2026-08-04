import React, { useEffect, useMemo, useState } from 'react';
import { useAuth } from '../auth/AuthContext.jsx';
import { adjustStoc } from '../api/adminTransactionApi.js';
import { listReasonPresets } from '../api/adminReasonPresetApi.js';
import { createIdempotencyKey } from '../api/rpcClient.js';
import {
  STOC_MAX_AMOUNT,
  calculateStocBalance,
  formatDecimal,
  formatScaledDecimal,
  isValidStocAmount,
} from '../utils/decimal.js';
import { Button, Input, Loading, Modal, Select, Textarea } from './Common.jsx';
import { useToast } from './Toast.jsx';

const ACTIONS = {
  deposit: { title: 'STOC 지급', submit: '지급 확정', sign: 1 },
  withdrawal: { title: 'STOC 차감', submit: '차감 확정', sign: -1 },
  airdrop: { title: 'STOC 에어드랍', submit: '에어드랍 확정', sign: 1 },
};

function normalizeAmountInput(value) {
  const cleaned = String(value ?? '')
    .replace(/,/g, '')
    .replace(/[^\d.]/g, '');

  if (!cleaned) return '';

  const [integerPart, ...fractionParts] = cleaned.split('.');
  const hasDecimalPoint = cleaned.includes('.');
  const normalizedInteger = (integerPart || '0')
    .replace(/^0+(?=\d)/, '')
    .slice(0, 15);
  const normalizedFraction = fractionParts.join('').slice(0, 8);

  return hasDecimalPoint
    ? `${normalizedInteger}.${normalizedFraction}`
    : normalizedInteger;
}

function pickInitialPreset(presets) {
  if (!presets.length) return null;
  return presets.find((item) => item.isDefault) || presets[0];
}

export function AssetAdjustmentModal({ open, member, action, onClose, onCompleted }) {
  const { admin } = useAuth();
  const config = ACTIONS[action] || ACTIONS.deposit;
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [reasonPresets, setReasonPresets] = useState([]);
  const [selectedReasonPresetId, setSelectedReasonPresetId] = useState('custom');
  const [loadingReasonPresets, setLoadingReasonPresets] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [idempotencyKey, setIdempotencyKey] = useState('');
  const { showToast } = useToast();

  useEffect(() => {
    if (!open) return;
    let ignore = false;
    setAmount('');
    setReason('');
    setReasonPresets([]);
    setSelectedReasonPresetId('custom');
    setError('');
    setIdempotencyKey(createIdempotencyKey(`admin-${action}`));
    setLoadingReasonPresets(true);

    listReasonPresets({ action })
      .then((items) => {
        if (ignore) return;
        setReasonPresets(items);
        const initialPreset = pickInitialPreset(items);
        if (initialPreset) {
          setSelectedReasonPresetId(initialPreset.id);
          setReason(initialPreset.reasonText);
        }
      })
      .catch((requestError) => {
        if (!ignore) setError(requestError.message);
      })
      .finally(() => {
        if (!ignore) setLoadingReasonPresets(false);
      });

    return () => { ignore = true; };
  }, [open, action]);

  const currentBalance = String(member?.internalStocBalance ?? member?.internal_stoc_balance ?? '0');
  const expectedScaled = useMemo(
    () => calculateStocBalance(currentBalance, amount || '0', config.sign),
    [currentBalance, amount, config.sign],
  );
  const expectedIsNegative = expectedScaled !== null && expectedScaled < 0n;
  const memberStatus = String(member?.status || '');
  const requiresStatusWarning = memberStatus === 'pending' || memberStatus === 'suspended';

  const selectReasonPreset = (presetId) => {
    setSelectedReasonPresetId(presetId);
    const preset = reasonPresets.find((item) => item.id === presetId);
    if (preset) setReason(preset.reasonText);
  };

  const submit = async () => {
    const permissionKey = {
      deposit: 'assetDeposit',
      withdrawal: 'assetWithdrawal',
      airdrop: 'assetAirdrop',
    }[action];
    if (!permissionKey || !admin?.permissions?.[permissionKey]) {
      setError('현재 관리자 등급으로는 이 자산 작업을 수행할 수 없습니다.');
      return;
    }

    const normalizedAmount = normalizeAmountInput(amount);
    if (!isValidStocAmount(normalizedAmount)) {
      setError(`금액은 0보다 크고, 정수 15자리·소수점 8자리 이내여야 합니다. 최대 ${STOC_MAX_AMOUNT} STOC`);
      return;
    }
    if (reason.trim().length < 2) {
      setError('처리 사유를 2자 이상 입력해주세요.');
      return;
    }
    if (action === 'withdrawal' && expectedIsNegative) {
      setError('보유 잔액보다 많이 차감할 수 없습니다.');
      return;
    }

    setSubmitting(true);
    setError('');
    try {
      const result = await adjustStoc({
        userId: member.user_id || member.userId,
        action,
        amount: normalizedAmount,
        reason,
        idempotencyKey,
      });
      showToast(`${formatDecimal(normalizedAmount)} STOC ${config.submit.replace(' 확정', '')} 처리되었습니다.`);
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
      footer={<><Button variant="secondary" onClick={onClose} disabled={submitting}>취소</Button><Button variant={action === 'withdrawal' ? 'danger' : 'primary'} onClick={submit} disabled={submitting}>{submitting ? '처리 중' : `${formatDecimal(amount || '0')} STOC ${config.submit}`}</Button></>}
    >
      <div className="summary-box">
        <div><span>대상 회원</span><strong>{member?.mb_name || member?.name} ({member?.mb_id || member?.memberId})</strong></div>
        <div><span>회원 상태</span><strong>{memberStatus || '-'}</strong></div>
        <div><span>현재 잔액</span><strong>{formatDecimal(currentBalance)} STOC</strong></div>
        <div><span>처리 후 예상</span><strong className={expectedIsNegative ? 'text-danger' : ''}>{expectedScaled === null ? '-' : `${formatScaledDecimal(expectedScaled)} STOC`}</strong></div>
      </div>
      {requiresStatusWarning ? <div className="notice notice-warning">현재 {memberStatus} 상태인 회원입니다. 상태를 확인한 뒤 처리해주세요.</div> : null}
      <Input
        label="금액"
        type="text"
        inputMode="decimal"
        value={amount}
        onChange={(e) => setAmount(normalizeAmountInput(e.target.value))}
        placeholder="0.00000000"
        autoComplete="off"
      />
      <div className="field-group">
        {loadingReasonPresets ? <Loading label="처리 사유 목록을 불러오는 중입니다." /> : null}
        {!loadingReasonPresets ? (
          <Select
            label="처리 사유 프리셋"
            value={selectedReasonPresetId}
            onChange={(e) => selectReasonPreset(e.target.value)}
          >
            {reasonPresets.map((preset) => (
              <option key={preset.id} value={preset.id}>{preset.label}</option>
            ))}
            <option value="custom">직접 입력</option>
          </Select>
        ) : null}
        {!loadingReasonPresets && !reasonPresets.length ? (
          <p className="field-help">등록된 처리 사유가 없습니다. 직접 입력해주세요.</p>
        ) : null}
        <Textarea
          label="처리 사유 상세"
          rows="4"
          maxLength="300"
          value={reason}
          onChange={(e) => { setReason(e.target.value); setSelectedReasonPresetId('custom'); }}
          placeholder="감사 로그와 거래 메타데이터에 저장됩니다."
        />
      </div>
      {error ? <p className="form-error">{error}</p> : null}
    </Modal>
  );
}

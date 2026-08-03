import React, { useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthContext.jsx';
import { Button, Input } from '../components/Common.jsx';
import { navigate } from '../router.js';

export function LoginPage() {
  const { admin, loading, configured, signInWithPassword, signInWithGoogle } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (admin) navigate('/members', { replace: true });
  }, [admin]);

  const submit = async (event) => {
    event.preventDefault();
    setSubmitting(true);
    setError('');
    try {
      await signInWithPassword({ email, password });
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="login-page">
      <div className="login-panel">
        <div className="login-brand"><span className="brand-mark">S</span><div><strong>STO Network</strong><small>Product Admin</small></div></div>
        <div className="login-copy"><h1>관리자 로그인</h1><p>승인된 admin 또는 super_admin 계정만 접근할 수 있습니다.</p></div>
        {!configured ? <div className="notice notice-danger">`.env.local`에 Supabase 환경변수를 설정해주세요.</div> : null}
        <form onSubmit={submit} className="login-form">
          <Input label="이메일" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required />
          <Input label="비밀번호" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
          {error ? <div className="notice notice-danger">{error}</div> : null}
          <Button type="submit" disabled={submitting || loading || !configured}>{submitting ? '로그인 중' : '이메일로 로그인'}</Button>
        </form>
        <div className="divider"><span>또는</span></div>
        <Button variant="secondary" onClick={() => signInWithGoogle().catch((e) => setError(e.message))} disabled={!configured}>Google 계정으로 로그인</Button>
      </div>
      <div className="login-visual"><div><span>PRODUCT OPERATIONS</span><h2>회원, 자산, 채팅을<br />하나의 화면에서 관리합니다.</h2><p>중요 변경은 RPC와 감사 로그를 통해 처리됩니다.</p></div></div>
    </div>
  );
}

import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { getAuthRedirectUrl, isSupabaseConfigured } from '../config/env.js';
import { getSupabaseClient } from '../api/supabaseClient.js';
import { callRpc, normalizeError } from '../api/rpcClient.js';

const AuthContext = createContext(null);

async function loadAdminSession(session) {
  if (!session) return null;
  return callRpc('rpc_admin_get_session');
}

export function AuthProvider({ children }) {
  const [state, setState] = useState({
    configured: isSupabaseConfigured(),
    loading: true,
    session: null,
    user: null,
    admin: null,
    error: null,
    accessDenied: false,
  });
  const stateRef = useRef(state);
  stateRef.current = state;

  const refreshAdmin = useCallback(async (sessionOverride) => {
    if (!isSupabaseConfigured()) {
      setState((prev) => ({ ...prev, configured: false, loading: false, error: 'Supabase 환경변수를 설정해주세요.' }));
      return null;
    }

    const supabase = getSupabaseClient();
    const session = sessionOverride ?? (await supabase.auth.getSession()).data.session;
    if (!session) {
      setState({ configured: true, loading: false, session: null, user: null, admin: null, error: null, accessDenied: false });
      return null;
    }

    setState((prev) => ({ ...prev, configured: true, loading: true, session, user: session.user, error: null }));
    try {
      const admin = await loadAdminSession(session);
      setState({ configured: true, loading: false, session, user: session.user, admin, error: null, accessDenied: false });
      return admin;
    } catch (error) {
      const normalized = normalizeError(error);
      const denied = normalized.code === 'ADMIN_PERMISSION_REQUIRED' || normalized.code === 'MEMBER_NOT_FOUND';
      setState({
        configured: true,
        loading: false,
        session,
        user: session.user,
        admin: null,
        error: denied ? null : normalized.message,
        accessDenied: denied,
      });
      return null;
    }
  }, []);

  useEffect(() => {
    if (!isSupabaseConfigured()) {
      setState((prev) => ({ ...prev, configured: false, loading: false }));
      return undefined;
    }

    const supabase = getSupabaseClient();
    refreshAdmin();
    const { data } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'INITIAL_SESSION') return;

      if (event === 'TOKEN_REFRESHED') {
        if (!session) return;
        setState((prev) => ({ ...prev, session, user: session.user }));
        return;
      }

      if (event === 'SIGNED_IN') {
        const current = stateRef.current;
        const sameAdminSession = current.admin && current.user?.id === session?.user?.id;
        if (sameAdminSession) {
          setState((prev) => ({ ...prev, session, user: session.user }));
          return;
        }
      }

      queueMicrotask(() => refreshAdmin(session));
    });

    return () => data.subscription.unsubscribe();
  }, [refreshAdmin]);

  const signInWithPassword = useCallback(async ({ email, password }) => {
    const supabase = getSupabaseClient();
    const { data, error } = await supabase.auth.signInWithPassword({ email: String(email || '').trim(), password });
    if (error) throw normalizeError(error);
    await refreshAdmin(data.session);
    return data;
  }, [refreshAdmin]);

  const signInWithGoogle = useCallback(async () => {
    const supabase = getSupabaseClient();
    const { data, error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: getAuthRedirectUrl(),
        queryParams: { prompt: 'select_account' },
      },
    });
    if (error) throw normalizeError(error);
    return data;
  }, []);

  const signOut = useCallback(async () => {
    if (isSupabaseConfigured()) await getSupabaseClient().auth.signOut();
    setState({ configured: isSupabaseConfigured(), loading: false, session: null, user: null, admin: null, error: null, accessDenied: false });
  }, []);

  const value = useMemo(() => ({
    ...state,
    refreshAdmin,
    signInWithPassword,
    signInWithGoogle,
    signOut,
  }), [state, refreshAdmin, signInWithPassword, signInWithGoogle, signOut]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const value = useContext(AuthContext);
  if (!value) throw new Error('AuthProvider가 필요합니다.');
  return value;
}

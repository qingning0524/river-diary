/* Account transport for the console.
 *
 * The account service only knows identity, devices, sessions, entitlements,
 * feedback and security activity.  Memory content never passes through it.
 * This module keeps the same-origin cookie/session rules that the previous
 * console verified, but exposes them as small injectable pieces so they can be
 * tested without a browser.
 */

export const API_BASE = '/v1';
export const LOGIN_URL = 'https://login.flowriver.xyz/';
export const SESSION_COOKIE = 'fr_session';
export const SESSION_LIFETIME_SECONDS = 2592000;
export const REQUEST_TIMEOUT_MS = 20000;

export class AuthRequiredError extends Error {
  constructor(message = '请先登录账号。') { super(message); this.name = 'AuthRequiredError'; this.code = 'auth_required'; }
}
export class AuthExpiredError extends Error {
  constructor(message = '登录已失效，请重新登录。') { super(message); this.name = 'AuthExpiredError'; this.code = 'auth_expired'; }
}
export class AccountSwitchedError extends Error {
  constructor(message = '账号已切换，请重新加载。') { super(message); this.name = 'AccountSwitchedError'; this.code = 'account_switched'; }
}
export class RefreshError extends Error {
  constructor(message = '暂时无法续期登录，请稍后重试。') { super(message); this.name = 'RefreshError'; this.code = 'refresh_failed'; }
}

export function isFlowRiverHost(hostname) {
  return hostname === 'flowriver.xyz' || String(hostname).endsWith('.flowriver.xyz');
}

export function newKey(cryptoRef = globalThis.crypto) {
  if (cryptoRef?.randomUUID) return cryptoRef.randomUUID();
  if (cryptoRef?.getRandomValues) {
    const bytes = cryptoRef.getRandomValues(new Uint8Array(16));
    return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
  }
  return `k_${Date.now().toString(36)}_${Math.random().toString(36).slice(2)}`;
}

export function parseSessionCookie(value) {
  try {
    const parsed = JSON.parse(decodeURIComponent(value));
    if (!parsed || typeof parsed !== 'object' || !parsed.access_token) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function sessionIsFresh(session, now = Date.now(), skewMs = 60000) {
  return Boolean(session?.access_token && Number(session.expires_at) - now > skewMs);
}

export function acceptSessionPayload(data, previous = null) {
  if (!data?.access_token) throw new AuthExpiredError('登录响应缺少令牌。');
  return {
    access_token: data.access_token,
    refresh_token: data.refresh_token ?? previous?.refresh_token,
    revoke_token: data.revoke_token ?? previous?.revoke_token,
    expires_at: Date.now() + Number(data.expires_in || 0) * 1000,
    client_instance_id: data.client_instance_id ?? previous?.client_instance_id,
    user: data.user ?? previous?.user,
    device: data.device ?? previous?.device,
    refresh_request_id: newKey(),
  };
}

export class CookieSessionStore {
  constructor({ documentRef = globalThis.document, locationRef = globalThis.location } = {}) {
    this.documentRef = documentRef;
    this.locationRef = locationRef;
  }

  read() {
    try {
      const cookies = String(this.documentRef?.cookie ?? '').split(/;\s*/);
      const item = cookies.find((value) => value.startsWith(`${SESSION_COOKIE}=`));
      if (!item) return null;
      return parseSessionCookie(item.slice(SESSION_COOKIE.length + 1));
    } catch {
      return null;
    }
  }

  write(session) {
    const hostname = this.locationRef?.hostname ?? '';
    const secure = this.locationRef?.protocol === 'https:' ? '; Secure' : '';
    const domain = isFlowRiverHost(hostname) ? '; Domain=.flowriver.xyz' : '';
    this.documentRef.cookie = `${SESSION_COOKIE}=${encodeURIComponent(JSON.stringify(session))}; Path=/; Max-Age=${SESSION_LIFETIME_SECONDS}; SameSite=Lax${domain}${secure}`;
  }

  clear() {
    const hostname = this.locationRef?.hostname ?? '';
    const secure = this.locationRef?.protocol === 'https:' ? '; Secure' : '';
    const domain = isFlowRiverHost(hostname) ? '; Domain=.flowriver.xyz' : '';
    this.documentRef.cookie = `${SESSION_COOKIE}=; Path=/; Max-Age=0; SameSite=Lax${domain}${secure}`;
  }
}

export const ACCOUNT_ERRORS = {
  password_policy_failed: '请使用 15–128 个字符的长密码，避免常见密码或邮箱地址。',
  invalid_or_expired_challenge: '验证码无效或已过期，请重新获取。',
  rate_limited: '操作较频繁，请稍后再试。',
  idempotency_key_reused: '请求内容已变化，请重新核对后提交。',
  invalid_activation_code: '激活码无效、过期或已使用。',
  reauthentication_required: '确认已过期，请重新获取邮箱验证码。',
  auth_required: '登录已失效，请重新登录。',
  not_found: '没有找到这条记录，可能已变更。',
  mirror_not_found: '云空间里还没有这份副本。',
  mirror_exists: '云空间已有副本，请刷新后再操作。',
  mirror_conflict: '云空间已被另一台设备更新，请刷新后再操作。',
  precondition_required: '云空间状态已变化，请刷新后重试。',
  request_too_large: '云副本太大，服务端没有接收。',
};

export function errorText(response, fallback = '操作没有完成，请重试。') {
  const code = typeof response?.data?.error === 'string'
    ? response.data.error
    : response?.data?.error?.code;
  return ACCOUNT_ERRORS[code] || fallback;
}

export function productLabel(value) {
  if (value === 'riverdiary_premium') return 'River 高级权益';
  return String(value ?? '权益');
}

export function accountStatusLabel(status) {
  return ({ active: '正常', deleting: '注销处理中', recovery_required: '需要恢复', deleted: '已注销' })[status] || '待核对';
}

export const EVENT_LABELS = {
  email_login: '邮箱验证码登录',
  password_login: '密码登录',
  password_reset: '设置 / 修改密码',
  session_revoked: '撤销登录会话',
  device_revoked: '撤销设备登录',
  activation_code_redeemed: '兑换激活码',
  feedback_submitted: '提交反馈',
  memory_mirror_uploaded: '上传加密云副本',
  memory_mirror_downloaded: '下载加密云副本',
  memory_mirror_deleted: '删除加密云副本',
  account_delete_requested: '申请注销账号',
  identity_link_requested: '申请绑定登录身份',
  identity_revocation_requested: '申请移除登录身份',
};

export function eventLabel(kind) {
  return EVENT_LABELS[kind] || '账号服务操作';
}

export function formatDateTime(value, timeZone = 'Asia/Shanghai') {
  if (!value || Number.isNaN(Date.parse(value))) return '尚无记录';
  return new Intl.DateTimeFormat('zh-CN', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(value));
}

export class AccountClient {
  constructor(options = {}) {
    this.store = options.store ?? new CookieSessionStore(options);
    this.fetchImpl = options.fetchImpl ?? ((...args) => globalThis.fetch(...args));
    this.now = options.now ?? (() => Date.now());
    this.newKey = options.newKey ?? (() => newKey(options.cryptoRef));
    this.timeoutMs = options.timeoutMs ?? REQUEST_TIMEOUT_MS;
    this.session = null;
    this.refreshing = null;
    this.listeners = new Set();
  }

  subscribe(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(type, detail) {
    for (const listener of this.listeners) {
      try { listener(type, detail); } catch { /* listeners must not break transport */ }
    }
  }

  adoptShared() {
    const shared = this.store.read();
    if (!shared?.access_token) {
      this.session = null;
      throw new AuthRequiredError();
    }
    if (this.session?.user?.id && shared.user?.id && this.session.user.id !== shared.user.id) {
      this.session = null;
      throw new AccountSwitchedError();
    }
    this.session = shared;
    return shared;
  }

  async request(method, path, body, headers = {}, timeoutMs = this.timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await this.fetchImpl(API_BASE + path, {
        method,
        headers: {
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
          ...headers,
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: controller.signal,
        cache: 'no-store',
      });
      const raw = await response.text();
      let data = null;
      try { data = raw ? JSON.parse(raw) : null; } catch { /* non-JSON error body */ }
      return { ok: response.ok, status: response.status, data };
    } finally {
      clearTimeout(timer);
    }
  }

  async ensureSession(force = false) {
    const shared = this.adoptShared();
    if (!force && sessionIsFresh(shared, this.now())) return shared;
    if (this.refreshing) return this.refreshing;
    shared.refresh_request_id ||= this.newKey();
    this.store.write(shared);
    const token = shared.refresh_token;
    const key = shared.refresh_request_id;
    const instance = shared.client_instance_id;
    const revoke = shared.revoke_token;
    this.refreshing = this.request('POST', '/auth/refresh', {
      refresh_token: token,
      revoke_token: revoke,
      client_instance_id: instance,
    }, { 'Idempotency-Key': key }).then((response) => {
      if (response.ok && response.data?.access_token) {
        const accepted = acceptSessionPayload(response.data, this.session);
        accepted.refresh_request_id = this.newKey();
        this.session = accepted;
        this.store.write(accepted);
        this.emit('session', accepted);
        return accepted;
      }
      if (response.status === 401) {
        this.store.clear();
        this.session = null;
        this.emit('auth-lost');
        throw new AuthExpiredError();
      }
      throw new RefreshError();
    }).finally(() => { this.refreshing = null; });
    return this.refreshing;
  }

  async api(method, path, body, key, retried = false, headers = {}, timeoutMs = this.timeoutMs) {
    const session = await this.ensureSession();
    const token = session.access_token;
    const response = await this.request(method, path, body, {
      Authorization: `Bearer ${token}`,
      ...(key ? { 'Idempotency-Key': key } : {}),
      ...headers,
    }, timeoutMs);
    if (response.status === 401 && !retried) {
      if (this.store.read()?.access_token === token) await this.ensureSession(true);
      return this.api(method, path, body, key, true, headers, timeoutMs);
    }
    if (response.status === 401) {
      this.store.clear();
      this.session = null;
      this.emit('auth-lost');
      throw new AuthExpiredError();
    }
    return response;
  }

  async get(path, timeoutMs = this.timeoutMs) {
    const response = await this.api('GET', path, undefined, undefined, false, {}, timeoutMs);
    if (!response.ok) throw new Error(errorText(response, '读取没有完成，请刷新重试。'));
    return response.data;
  }

  async logout() {
    const session = this.session ?? this.store.read();
    if (!session?.revoke_token) {
      this.store.clear();
      this.session = null;
      return;
    }
    const response = await this.api('POST', '/auth/logout', { revoke_token: session.revoke_token });
    if (response.status !== 204) throw new Error(errorText(response, '退出尚未完成，请重试。'));
    this.store.clear();
    this.session = null;
  }
}

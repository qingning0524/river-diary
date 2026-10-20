import test from 'node:test';
import assert from 'node:assert/strict';
import {
  AccountClient, AuthExpiredError, AuthRequiredError, CookieSessionStore, acceptSessionPayload,
  errorText, formatDateTime, isFlowRiverHost, parseSessionCookie, productLabel, sessionIsFresh,
} from '../assets/account-core.js';

class MemoryStore {
  constructor(session = null) { this.session = session; this.writes = 0; this.clears = 0; }
  read() { return this.session; }
  write(session) { this.writes += 1; this.session = { ...session }; }
  clear() { this.clears += 1; this.session = null; }
}

function session(overrides = {}) {
  return {
    access_token: 'old-access',
    refresh_token: 'refresh-token',
    revoke_token: 'revoke-token',
    expires_at: 2_000_000,
    client_instance_id: 'instance-1',
    user: { id: 'user-1' },
    device: { id: 'device-1' },
    refresh_request_id: 'request-1',
    ...overrides,
  };
}

function response(status, data) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => (data === null ? '' : JSON.stringify(data)),
  };
}

test('cookie helpers parse only complete sessions and respect the FlowRiver domain', () => {
  assert.equal(isFlowRiverHost('user.flowriver.xyz'), true);
  assert.equal(isFlowRiverHost('flowriver.xyz'), true);
  assert.equal(isFlowRiverHost('example.com'), false);
  assert.equal(parseSessionCookie(encodeURIComponent(JSON.stringify({ access_token: 'a' }))).access_token, 'a');
  assert.equal(parseSessionCookie('not-json'), null);
  assert.equal(parseSessionCookie(encodeURIComponent(JSON.stringify({ refresh_token: 'x' }))), null);

  let cookie = '';
  const documentRef = { get cookie() { return cookie; }, set cookie(value) { cookie = value; } };
  const store = new CookieSessionStore({ documentRef, locationRef: { hostname: 'user.flowriver.xyz', protocol: 'https:' } });
  store.write({ access_token: 'a', expires_at: 1 });
  assert.match(cookie, /Domain=\.flowriver\.xyz/);
  assert.match(cookie, /Secure/);
  assert.match(cookie, /SameSite=Lax/);
  assert.equal(store.read().access_token, 'a');
  store.clear();
  assert.match(cookie, /Max-Age=0/);
  assert.equal(store.read(), null);
});

test('freshness and accepted payloads preserve the client instance and refresh key', () => {
  assert.equal(sessionIsFresh(session(), 1_000_000), true);
  assert.equal(sessionIsFresh(session({ expires_at: 1_000_000 }), 1_000_000), false);
  const accepted = acceptSessionPayload({
    access_token: 'new', refresh_token: 'new-refresh', revoke_token: 'new-revoke', expires_in: 3600,
    user: { id: 'user-1' },
  }, session());
  assert.equal(accepted.access_token, 'new');
  assert.equal(accepted.client_instance_id, 'instance-1');
  assert.ok(accepted.expires_at > Date.now());
  assert.notEqual(accepted.refresh_request_id, 'request-1');
});

test('a fresh session skips the refresh endpoint', async () => {
  const calls = [];
  const client = new AccountClient({
    store: new MemoryStore(session()),
    now: () => 1_000_000,
    fetchImpl: async (url, options) => { calls.push({ url, options }); return response(200, {}); },
  });
  await client.ensureSession();
  assert.equal(calls.length, 0);
});

test('401 forces a refresh before the advertised expiry and replays with the new token', async () => {
  const calls = [];
  let meCalls = 0;
  const client = new AccountClient({
    store: new MemoryStore(session({ expires_at: Date.now() + 3_600_000 })),
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      if (url === '/v1/auth/refresh') {
        return response(200, { access_token: 'new-access', refresh_token: 'new-refresh', revoke_token: 'new-revoke', expires_in: 3600 });
      }
      if (url === '/v1/me') {
        meCalls += 1;
        return meCalls === 1 ? response(401, { error: 'auth_required' }) : response(200, { user: { id: 'user-1' } });
      }
      return response(404, {});
    },
  });
  const result = await client.api('GET', '/me');
  assert.equal(result.status, 200);
  const refresh = calls.filter((call) => call.url === '/v1/auth/refresh');
  assert.equal(refresh.length, 1);
  assert.ok(refresh[0].options.headers['Idempotency-Key']);
  const me = calls.filter((call) => call.url === '/v1/me');
  assert.equal(me.length, 2);
  assert.equal(me[1].options.headers.Authorization, 'Bearer new-access');
});

test('refresh retries keep the same request key and a final 401 clears the cookie', async () => {
  const store = new MemoryStore(session({ expires_at: 1_000_000 }));
  const calls = [];
  let refreshCalls = 0;
  const client = new AccountClient({
    store,
    now: () => 1_000_000,
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      if (url === '/v1/auth/refresh') {
        refreshCalls += 1;
        return response(503, { error: 'temporarily_unavailable' });
      }
      return response(401, { error: 'auth_required' });
    },
  });
  await assert.rejects(() => client.ensureSession(), /续期/);
  assert.equal(store.session.refresh_request_id, 'request-1');
  const firstKey = calls[0].options.headers['Idempotency-Key'];
  assert.equal(firstKey, 'request-1');

  let apiCalls = 0;
  const finalClient = new AccountClient({
    store: new MemoryStore(session({ expires_at: Date.now() + 3_600_000 })),
    fetchImpl: async () => { apiCalls += 1; return response(401, { error: 'auth_required' }); },
  });
  await assert.rejects(() => finalClient.api('GET', '/me'), AuthExpiredError);
  assert.equal(finalClient.store.session, null);
  assert.equal(finalClient.store.clears, 1);
});

test('missing sessions fail closed without making a request', async () => {
  let called = false;
  const client = new AccountClient({
    store: new MemoryStore(null),
    fetchImpl: async () => { called = true; return response(200, {}); },
  });
  await assert.rejects(() => client.api('GET', '/me'), AuthRequiredError);
  assert.equal(called, false);
});

test('error text maps known server codes and falls back honestly', () => {
  assert.match(errorText({ data: { error: 'password_policy_failed' } }), /15–128/);
  assert.match(errorText({ data: { error: { code: 'rate_limited' } } }), /稍后/);
  assert.equal(errorText({ data: { error: 'unknown' } }, '自定义'), '自定义');
  assert.equal(productLabel('riverdiary_premium'), 'River 高级权益');
  assert.match(formatDateTime('2026-10-20T01:00:00Z'), /2026/);
  assert.equal(formatDateTime('not a date'), '尚无记录');
});

test('logout clears the cookie only after the server accepts the revocation', async () => {
  const store = new MemoryStore(session({ expires_at: Date.now() + 3_600_000 }));
  const calls = [];
  const client = new AccountClient({
    store,
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return response(url === '/v1/auth/logout' ? 204 : 404, null);
    },
  });
  await client.logout();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/v1/auth/logout');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(store.session, null);
});

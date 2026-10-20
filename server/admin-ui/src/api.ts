export interface AdminSession {
  authenticated: boolean
  username?: string
  setup_required?: boolean
  reauthentication_required?: boolean
}

export interface Overview {
  active_accounts: number
  all_accounts: number
  active_sessions: number
  devices: number
  pending_mail: number
  failed_mail: number
  pending_security: number
  oldest_security_at: string | null
  data_updated_at: string
}

export interface UserRow {
  password_enabled: boolean
  premium: boolean
  id: string
  email: string
  providers: string[]
  status: string
  disabled: boolean
  device_count: number
  session_count: number
  created_at: string
  last_activity_at: string | null
}

export interface UserIdentity {
  id: string
  provider: string
  status: string
  email?: string
  verified_at: string
  forwarding_enabled?: boolean
}

export interface Consent {
  terms_version: string
  privacy_version: string
  source: string
  accepted_at: string
}

export interface UserDetail {
  password_enabled: boolean
  password_updated_at: string | null
  id: string
  status: string
  disabled: boolean
  disabled_at?: string | null
  disabled_reason?: string
  created_at: string
  identities: UserIdentity[]
  entitlements: Entitlement[]
  consents: Consent[]
}

export interface DeviceRow {
  id: string
  instance_id: string
  platform: string
  display_name: string
  created_at: string
  last_seen_at: string
  revoked_at: string | null
  user_id: string
  user_status: string
  user_disabled: boolean
  user_email: string
  active_sessions: number
}

export interface MailJob {
  id: string
  created_at: string
  available_at: string
  expires_at: string
  attempts: number
  completed_at: string | null
  error_code: string | null
  status: string
}

export interface SecurityEvent {
  event_id: string
  user_id: string
  identity_id?: string
  kind: string
  occurred_at: string
  available_at: string
  attempts: number
  delivered_at: string | null
  error_code: string | null
  deletion_status?: string
}

export interface AuditEvent {
  id: number
  admin_id: string
  action: string
  target_type: string
  target_id: string
  reason_code: string
  result: string
  request_id: string
  created_at: string
}

export interface Operations {
  api: { state: string; checked_at: string }
  database: { state: string; ping_ms: number; checked_at: string }
  process: {
    started_at: string
    uptime_seconds: number
    resources: {
      memory?: { total_bytes: number; available_bytes: number }
      disk_root?: { total_bytes: number; available_bytes: number }
      load_average_1_5_15_minutes?: string
      available?: boolean
    }
  }
  backup: { state: string; code?: string; updated_at: string | null; object_name?: string; health?: string; age_seconds?: number | null; expected_interval_seconds?: number }
  restore_drill: { result: string; summary?: string; recorded_at: string | null }
  updated_at: string
}

export interface ConfigItem {
  name: string
  state: 'configured' | 'not_configured' | 'needs_verification'
  detail: string
}

export interface ActivationBatch {
  id: string
  label: string
  product_code: string
  duration_days: number
  expires_at: string | null
  created_at: string
  total_codes: number
  redeemed_count: number
  unused_count: number
  revoked_at: string | null
}

export interface ActivationCode {
  id: string
  batch_id: string
  suffix: string
  created_at: string
  redeemed_at: string | null
  redeemed_user_id: string | null
  revoked_at: string | null
  status: 'unused' | 'redeemed' | 'revoked' | 'expired'
}

export interface IssuedActivationCode {
  id: string
  code: string
  suffix: string
}

export interface Announcement {
  id: string
  level: 'info' | 'warn' | 'critical'
  title: string
  body: string
  placement: 'banner' | 'download' | 'both'
  href: string
  active: boolean
  starts_at: string | null
  ends_at: string | null
  created_at: string
  updated_at: string
  created_by: string
}

export interface InboundMail {
  id: string
  from_addr: string
  from_name: string
  to_addr: string
  subject: string
  text_body: string
  status: 'new' | 'read' | 'replied'
  replied_at: string | null
  created_at: string
}

export interface FeedbackMessage {
  id: string
  contact_email: string
  subject: string
  body: string
  user_agent: string
  status: 'new' | 'read' | 'replied' | 'archived'
  reply_body: string
  replied_at: string | null
  created_at: string
}

export interface OutboundEmail {
  id: string
  recipient: string
  subject: string
  purpose: 'manual' | 'feedback_reply'
  status: 'queued' | 'sent' | 'failed'
  error_code: string
  sent_at: string | null
  created_at: string
  created_by: string
}

export interface ChangelogEntry {
  id: string
  date: string
  version_tag: string
  title: string
  body: string
  is_published: boolean
  created_at: string
  updated_at: string
  published_at: string | null
  created_by: string
}

export interface DownloadArtifact {
  id: string
  platform: 'macos' | 'ios'
  version: string
  filename: string
  size_bytes: number
  sha256: string
  note: string
  is_active: boolean
  created_at: string
  activated_at: string | null
  created_by: string
}

export interface AdminAccount {
  id: string
  username: string
  disabled_at: string | null
  created_at: string
  last_login_at: string | null
  active_sessions: number
  is_you: boolean
}

export interface AdminSessionRow {
  id: string
  username: string
  created_at: string
  last_seen_at: string
  idle_expires_at: string
  absolute_expires_at: string
  is_you: boolean
}

export interface UserSessionRow {
  id: string
  status: string
  created_at: string
  last_seen_at: string
  idle_expires_at: string
  absolute_expires_at: string
  revoked_at: string | null
  platform: string
  device_name: string
  device_revoked: boolean
  currently_valid: boolean
}

export interface Entitlement {
  product_code: string
  starts_at: string
  expires_at: string | null
  grant_source: string
  updated_at: string
}

export interface StatsPoint { date: string; count: number }
export interface StatsMailPoint { date: string; total: number; failed: number }
export interface StatsData {
  days: number
  signups: StatsPoint[]
  redemptions: StatsPoint[]
  mail: StatsMailPoint[]
  active_sessions: number
  devices: number
  users_total: number
  updated_at: string
}

export interface RateLimitBucket {
  key_hex: string
  window_start: string
  hits: number
  expires_at: string
}

export interface BackupRun {
  id: number
  state: 'running' | 'success' | 'failure'
  code: string
  summary: string
  object_name: string
  duration_ms: number
  created_at: string
}

export class APIError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly requestID: string,
  ) {
    super(code)
    this.name = 'APIError'
  }
}

function csrfToken(): string {
  const item = document.cookie.split('; ').find((part) => part.startsWith('__Host-flowriver-admin-csrf='))
  if (!item) return ''
  return decodeURIComponent(item.slice(item.indexOf('=') + 1))
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set('Accept', 'application/json')
  if (init.body !== undefined && !(init.body instanceof FormData)) headers.set('Content-Type', 'application/json')
  if (init.method && init.method !== 'GET' && init.method !== 'HEAD') {
    const token = csrfToken()
    if (token) headers.set('X-CSRF-Token', token)
  }
  const controller = new AbortController()
  let timedOut = false
  const abort = () => controller.abort()
  if (init.signal?.aborted) controller.abort()
  else init.signal?.addEventListener('abort', abort, { once: true })
  const timer = window.setTimeout(() => { timedOut = true; controller.abort() }, 30_000)
  try {
  const response = await fetch(`/admin-api/v1${path}`, {
    ...init,
    headers,
    credentials: 'same-origin',
    cache: 'no-store',
    signal: controller.signal,
  })
  const requestID = response.headers.get('X-Request-ID') ?? ''
  const contentType = response.headers.get('Content-Type') ?? ''
  let body: unknown = null
  if (contentType.includes('application/json')) {
    try { body = await response.json() } catch { throw new APIError(response.status, 'invalid_response', requestID) }
  } else if (response.ok && response.status !== 204) throw new APIError(502, 'invalid_response', requestID)
  if (!response.ok) {
    const envelope = body as { error?: { code?: string } } | null
    throw new APIError(response.status, envelope?.error?.code ?? 'request_failed', requestID)
  }
  return body as T
  } catch (error) {
    if (timedOut) throw new DOMException('请求超时，请重试。', 'TimeoutError')
    throw error
  } finally {
    window.clearTimeout(timer)
    init.signal?.removeEventListener('abort', abort)
  }
}

export const api = {
  get<T>(path: string, signal?: AbortSignal): Promise<T> {
    return request<T>(path, { signal })
  },
  post<T>(path: string, body?: unknown, key?: string, signal?: AbortSignal): Promise<T> {
    const headers = new Headers()
    if (key) headers.set('Idempotency-Key', key)
    return request<T>(path, {
      method: 'POST',
      headers,
      signal,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
  },
  postForm<T>(path: string, form: FormData, options: { onProgress?: (percent: number) => void; signal?: AbortSignal } = {}): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const xhr = new XMLHttpRequest()
      xhr.open('POST', `/admin-api/v1${path}`)
      xhr.withCredentials = true
      xhr.timeout = 600_000
      xhr.setRequestHeader('Accept', 'application/json')
      const token = csrfToken()
      if (token) xhr.setRequestHeader('X-CSRF-Token', token)
      const abort = () => xhr.abort()
      const cleanup = () => options.signal?.removeEventListener('abort', abort)
      xhr.upload.onprogress = (event) => { if (event.lengthComputable) options.onProgress?.(Math.min(100, Math.round(event.loaded / event.total * 100))) }
      xhr.onload = () => {
        cleanup()
        let body: unknown
        try { body = JSON.parse(xhr.responseText) } catch { reject(new APIError(xhr.status, 'invalid_response', xhr.getResponseHeader('X-Request-ID') ?? '')); return }
        if (xhr.status < 200 || xhr.status >= 300) {
          const envelope = body as { error?: { code?: string } }
          reject(new APIError(xhr.status, envelope.error?.code ?? 'request_failed', xhr.getResponseHeader('X-Request-ID') ?? ''))
        } else resolve(body as T)
      }
      xhr.onerror = () => { cleanup(); reject(new TypeError('网络连接失败')) }
      xhr.ontimeout = () => { cleanup(); reject(new DOMException('上传超时，请刷新确认结果。', 'TimeoutError')) }
      xhr.onabort = () => { cleanup(); reject(new DOMException('上传已停止，请刷新确认结果。', 'AbortError')) }
      if (options.signal?.aborted) { reject(new DOMException('上传已取消', 'AbortError')); return }
      options.signal?.addEventListener('abort', abort, { once: true })
      xhr.send(form)
    })
  },
  delete<T>(path: string): Promise<T> {
    return request<T>(path, { method: 'DELETE' })
  },
}

export function formatDate(value?: string | null, withTime = true): string {
  if (!value) return '—'
  const date = new Date(value)
  if (!Number.isFinite(date.valueOf())) return '—'
  return new Intl.DateTimeFormat('zh-CN', {
    timeZone: 'Asia/Shanghai',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    ...(withTime ? { hour: '2-digit', minute: '2-digit', hour12: false } : {}),
  }).format(date)
}

export function bytes(value?: number): string {
  if (value === undefined || !Number.isFinite(value) || value < 0) return '未知'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let amount = value
  let index = 0
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024
    index += 1
  }
  return `${amount.toFixed(index === 0 ? 0 : 1)} ${units[index]}`
}

export function elapsed(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '未知'
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  return days > 0 ? `${days} 天 ${hours} 小时` : `${hours} 小时 ${minutes} 分钟`
}

// Management dates consistently use UTC+8, regardless of the browser's timezone.
export function toShanghaiInput(value?: string | null): string {
  if (!value) return ''
  const date = new Date(value)
  if (!Number.isFinite(date.valueOf())) return ''
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(date)
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value ?? ''
  return `${part('year')}-${part('month')}-${part('day')}T${part('hour')}:${part('minute')}`
}

export function shanghaiDateTimeToISO(value: string): string {
  return new Date(`${value}:00+08:00`).toISOString()
}

export function todayInShanghai(): string {
  return toShanghaiInput(new Date().toISOString()).slice(0, 10)
}

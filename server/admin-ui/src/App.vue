<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import MailPreview from './MailPreview.vue'
import { mailTemplates, mailSnippets, type MailTemplateID, type MailPreviewResponse, type OutboundDetail } from './mail'
import { api, APIError, bytes, elapsed, formatDate, shanghaiDateTimeToISO, toShanghaiInput, todayInShanghai, type ActivationBatch, type ActivationCode, type AdminAccount, type AdminSession, type AdminSessionRow, type Announcement, type AuditEvent, type BackupRun, type FeedbackMessage, type InboundMail, type OutboundEmail, type ChangelogEntry, type ConfigItem, type DeviceRow, type DownloadArtifact, type Entitlement, type IssuedActivationCode, type MailJob, type Operations, type Overview, type RateLimitBucket, type SecurityEvent, type StatsData, type UserDetail, type UserRow, type UserSessionRow } from './api'

type Page = 'overview' | 'users' | 'devices' | 'mail' | 'mailbox' | 'activation' | 'security' | 'announcements' | 'changelog' | 'downloads' | 'admins' | 'insights' | 'ops' | 'settings'

const nav: { id: Page; label: string }[] = [
  { id: 'overview', label: '总览' },
  { id: 'users', label: '用户' },
  { id: 'devices', label: '设备与会话' },
  { id: 'mail', label: '登录与邮件' },
  { id: 'mailbox', label: '反馈与邮件' },
  { id: 'activation', label: '激活码与权益' },
  { id: 'announcements', label: '公告管理' },
  { id: 'changelog', label: '更新日志' },
  { id: 'downloads', label: '下载管理' },
  { id: 'admins', label: '管理员' },
  { id: 'insights', label: '统计与限流' },
  { id: 'security', label: '安全与审计' },
  { id: 'ops', label: '运行与备份' },
  { id: 'settings', label: '设置' },
]

const primaryNav = nav.filter((item) => ['overview', 'users', 'devices', 'mailbox'].includes(item.id))
const navGroups = [
  { id: 'website', label: '官网运营', pages: ['announcements', 'changelog', 'downloads'] as Page[] },
  { id: 'manage', label: '更多管理', pages: ['mail', 'activation', 'admins', 'insights', 'security', 'ops', 'settings'] as Page[] },
]
const openNavGroup = ref('')
const activeNavGroup = computed(() => navGroups.find((group) => group.id === openNavGroup.value))
const fullscreenSupported = document.fullscreenEnabled
const isFullscreen = ref(Boolean(document.fullscreenElement))
function syncFullscreen() { isFullscreen.value = Boolean(document.fullscreenElement) }
async function toggleFullscreen() {
  try {
    if (document.fullscreenElement) await document.exitFullscreen()
    else await document.documentElement.requestFullscreen()
  } catch { notify('浏览器未能切换全屏，请检查浏览器设置后重试。') }
}
const theme = ref<'light' | 'dark'>(window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
function setTheme(value: 'light' | 'dark') {
  theme.value = value
  document.documentElement.dataset.theme = value
  try { localStorage.setItem('flowriver-admin-theme', value) } catch { /* 外观偏好不可存储时仍可切换 */ }
}
function toggleTheme() { setTheme(theme.value === 'light' ? 'dark' : 'light') }
function closeNavigation(restoreFocus = false) {
  const groupID = openNavGroup.value
  openNavGroup.value = ''
  if (restoreFocus && groupID) void nextTick(() => document.getElementById(`nav-group-${groupID}`)?.focus())
}
function toggleNavigation(groupID: string) {
  openNavGroup.value = openNavGroup.value === groupID ? '' : groupID
  if (openNavGroup.value) void nextTick(() => document.querySelector<HTMLElement>('.nav-dropdown .nav-item')?.focus())
}
function closeNavigationOutside(event: PointerEvent) {
  if (!(event.target instanceof Element) || !event.target.closest('.topbar')) closeNavigation()
}

const navIcons: Record<Page, string[]> = {
  overview: ['M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z'],
  users: ['M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2', 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8', 'M17 4a4 4 0 0 1 0 8M22 21v-2a4 4 0 0 0-3-3.87'],
  devices: ['M3 4h14v12H3zM7 20h6M10 16v4', 'M19 9h3v12h-6v-3'],
  mail: ['M3 5h18v14H3zM3 5l9 7 9-7'],
  mailbox: ['M4 4h16v12H4zM8 20h8M12 16v4', 'M9 9l2 2 4-4'],
  activation: ['M3 7h18v4a2 2 0 0 0 0 4v4H3v-4a2 2 0 0 0 0-4z', 'M15 7v3M15 13v2M15 18v1'],
  announcements: ['M3 11l14-6v14L3 13zM3 11v2M17 8a4 4 0 0 1 0 8M7 14v5h3v-4'],
  changelog: ['M4 5h16M4 12h16M4 19h10', 'M18 15l3 3-3 3'],
  downloads: ['M12 3v12M7 10l5 5 5-5', 'M4 19h16'],
  admins: ['M12 3l8 4v5c0 5-8 9-8 9s-8-4-8-9V7z', 'M9 12h6M12 9v6'],
  insights: ['M4 20V10M10 20V4M16 20v-8M22 20H2'],
  security: ['M12 3l9 4v6c0 5-9 8-9 8s-9-3-9-8V7z', 'M8 12l3 3 5-6'],
  ops: ['M3 3v18h18M7 14l4-4 4 3 6-7'],
  settings: ['M4 7h16M4 17h16M9 4v6M15 14v6'],
}

const headings: Record<Page, { title: string; subtitle: string }> = {
  overview: { title: '服务总览', subtitle: '查看账号服务状态和需要处理的事项。' },
  users: { title: '用户管理', subtitle: '按邮箱前缀、完整邮箱或用户 ID 查询，并管理会话、权益与封禁。' },
  devices: { title: '设备与会话', subtitle: '查看账号服务记录和撤销状态。' },
  mail: { title: '登录与邮件', subtitle: '排查验证码任务并重试失败投递；不显示验证码和邮件正文。' },
  mailbox: { title: '反馈与邮件', subtitle: '接收用户反馈、直接回复邮件，并可向任意邮箱发送站内通知。' },
  activation: { title: '激活码与权益', subtitle: '生成或导入一次性兑换码，并查看批次核销情况。' },
  announcements: { title: '公告管理', subtitle: '发布公告到官网公告条与下载区，客户端与官网实时读取。' },
  changelog: { title: '更新日志', subtitle: '维护官网「更新日志」时间线；发布、编辑或删除版本记录。' },
  downloads: { title: '下载管理', subtitle: '上传安装包、填写版本与说明，一键开放或暂停下载。' },
  admins: { title: '管理员管理', subtitle: '创建或禁用管理员、查看在线管理会话并重置动态验证。' },
  insights: { title: '统计与限流', subtitle: '查看注册、兑换与邮件趋势，检查限流桶状态。' },
  security: { title: '安全与审计', subtitle: '追踪安全变更队列和管理员操作。' },
  ops: { title: '运行与备份', subtitle: '分别查看服务、备份历史和恢复记录。' },
  settings: { title: '服务设置', subtitle: '检查外部依赖状态，不展示凭据。' },
}

const session = ref<AdminSession | null>(null)
const page = ref<Page>('overview')
const busy = ref(false)
const loading = ref(false)
const authLoading = ref(true)
const authError = ref('')
const pageError = ref('')
const toast = ref('')
const readyPage = ref<Page | null>(null)
const updatedAt = ref('')
const detailLoading = ref(false)
const detailError = ref('')
const detailOpener = ref<HTMLElement | null>(null)
const detailUserID = ref('')
const deviceQuery = ref('')
const deviceState = ref('')
const mailState = ref('')
const auditLoading = ref(false)
let pageRequest: AbortController | null = null
let detailRequest: AbortController | null = null
let codesRequest: AbortController | null = null
let auditRequest: AbortController | null = null
let toastTimer = 0
const mfaStep = ref(false)
const mfaChallenge = ref('')
const username = ref('')
const password = ref('')
const mfaCode = ref('')

const overview = ref<Overview | null>(null)
const users = ref<UserRow[]>([])
const userCursor = ref('')
const userQuery = ref('')
const userStatus = ref('')
const userPasswordFilter = ref('')
const userProviderFilter = ref('')
const userPremiumFilter = ref('')
const userActivityFilter = ref('')
const showUserFilters = ref(false)
const selectedUserIDs = ref<string[]>([])
const userSummary = ref<{total:number;active:number;disabled:number;password:number;recent:number;premium:number;updated_at:string} | null>(null)
const userActivity = ref<{kind:string;created_at:string;source:string;result:string;reason_code:string}[]>([])
const userTab = ref('overview')
const userTabs = [{id:'overview',label:'概况'}, {id:'access',label:'登录安全'}, {id:'devices',label:'设备会话'}, {id:'entitlements',label:'权益'}, {id:'activity',label:'活动'}]
const userConfirmation = ref<{path:string;message:string;id:string;reason:string} | null>(null)
function userFilterSignature() { return JSON.stringify([userQuery.value.trim(), userStatus.value,userPasswordFilter.value,userProviderFilter.value,userPremiumFilter.value,userActivityFilter.value]) }
function toggleUserSelection(id: string) { selectedUserIDs.value = selectedUserIDs.value.includes(id) ? selectedUserIDs.value.filter(value => value !== id) : [...selectedUserIDs.value,id] }
const allUsersSelected = computed(() => users.value.length > 0 && users.value.every(user => selectedUserIDs.value.includes(user.id)))
function toggleAllUsers() { selectedUserIDs.value = allUsersSelected.value ? [] : users.value.map(user => user.id) }
async function copyUserID(id:string) { try { await navigator.clipboard.writeText(id);notify('用户 ID 已复制。') } catch { notify('无法访问剪贴板，请选中用户 ID 手动复制。') } }
function exportUsers() {
  const rows = selectedUserIDs.value.length ? users.value.filter(user => selectedUserIDs.value.includes(user.id)) : users.value
  const cell = (value:unknown) => { let text = String(value ?? '');if (/^(?:[\t\r]|\s*[=+@\-])/.test(text)) text = "'" + text;return '"' + text.replaceAll('"','""') + '"' }
  const csv = [['用户 ID','邮箱（脱敏）','状态','登录身份','密码','高级权益','设备','有效会话','注册时间','最近活动'],...rows.map(user => [user.id,user.email,user.disabled ? '已封禁' : displayUserStatus(user.status),user.providers.map(displayIdentity).join(' / '),user.password_enabled ? '已设置':'未设置',user.premium ? '有效':'无有效权益',user.device_count,user.session_count,user.created_at,user.last_activity_at ?? ''])].map(row => row.map(cell).join(',')).join('\r\n')
  const url = URL.createObjectURL(new Blob(['\uFEFF'+csv],{type:'text/csv;charset=utf-8'}));const link = document.createElement('a');link.href=url;link.download=`FlowRiver-users-${new Date().toISOString().slice(0,10)}.csv`;link.click();setTimeout(() => URL.revokeObjectURL(url),1000);notify(`已导出 ${rows.length} 个已加载账号，邮箱保持脱敏。`)
}
async function quickUserFilter(kind:string) {
  userStatus.value='';userPasswordFilter.value='';userProviderFilter.value='';userPremiumFilter.value='';userActivityFilter.value=''
  if(kind==='active' || kind==='disabled') userStatus.value=kind
  if(kind==='password') userPasswordFilter.value='set'
  if(kind==='recent') userActivityFilter.value='recent'
  if(kind==='premium') userPremiumFilter.value='active'
  await searchUsers()
}
function userTabKeys(event:KeyboardEvent) {
  if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return
  event.preventDefault();const index=userTabs.findIndex(tab=>tab.id===userTab.value);const next=event.key==='Home'?0:event.key==='End'?userTabs.length-1:(index+(event.key==='ArrowRight'?1:-1)+userTabs.length)%userTabs.length
  userTab.value=userTabs[next].id;void nextTick(()=>document.getElementById(`user-tab-${userTab.value}`)?.focus())
}
const userFilterChips = computed(() => [
  {key:'status',value:userStatus.value,label:userStatus.value ? displayUserStatus(userStatus.value):''},
  {key:'provider',value:userProviderFilter.value,label:userProviderFilter.value==='email'?'邮箱身份':'Apple 身份'},
  {key:'password',value:userPasswordFilter.value,label:userPasswordFilter.value==='set'?'密码已设置':'密码未设置'},
  {key:'premium',value:userPremiumFilter.value,label:userPremiumFilter.value==='active'?'高级权益有效':'无有效高级权益'},
  {key:'activity',value:userActivityFilter.value,label:userActivityFilter.value==='recent'?'近 7 天有活动':'近 7 天无活动'}
].filter(chip=>chip.value))
async function removeUserFilter(key:string) {
  if(key==='status')userStatus.value='';if(key==='provider')userProviderFilter.value='';if(key==='password')userPasswordFilter.value='';if(key==='premium')userPremiumFilter.value='';if(key==='activity')userActivityFilter.value=''
  await searchUsers()
}
async function refreshUserList() {
  const signature=userFilterSignature()
  const [result,summary]=await Promise.all([api.get<{users:UserRow[];next_cursor:string}>(`/users?${userParams()}`),api.get<NonNullable<typeof userSummary.value>>('/users/summary')])
  if(page.value==='users' && isAuthenticated.value && signature===userFilterSignature()) { users.value=result.users;userCursor.value=result.next_cursor;userSummary.value=summary;loadedUserFilter=signature;selectedUserIDs.value=selectedUserIDs.value.filter(id=>result.users.some(user=>user.id===id)) }
}
function userReasonLabel(value:string):string { return ({user_request:'用户申请',suspicious_activity:'可疑活动',policy_violation:'违反条款',other:'其他'} as Record<string,string>)[value] ?? value }
function accountActivityLabel(kind:string):string { return ({email_login:'邮箱登录',password_login:'密码登录',password_reset:'设置 / 重置密码',session_refresh:'续期会话',session_revoked:'撤销会话',account_deleted:'删除账号'} as Record<string,string>)[kind] ?? auditActionLabel(kind) }

const selectedUser = ref<UserDetail | null>(null)
const userPasswordTarget = ref<UserDetail | null>(null)
const userNewPassword = ref('')
const userRepeatPassword = ref('')
const userPasswordReason = ref('user_request')
const userPasswordKey = ref('')
const userPasswordError = ref('')
const userPasswordReauth = ref(false)
const userPasswordAdmin = ref('')
const userPasswordCode = ref('')
const userPasswordValid = computed(() => {
  const normalized = userNewPassword.value.normalize('NFC')
  return [...normalized].length >= 15 && [...normalized].length <= 128 && new TextEncoder().encode(normalized).length <= 512 && normalized.trim().length > 0 && normalized === userRepeatPassword.value.normalize('NFC')
})
function changeUserPasswordKey() { userPasswordKey.value = crypto.randomUUID() }
function openUserPassword(user: UserDetail) {
  userPasswordTarget.value = user; userNewPassword.value = ''; userRepeatPassword.value = ''; userPasswordReason.value = 'user_request'; userPasswordKey.value = crypto.randomUUID(); userPasswordError.value = ''; userPasswordReauth.value = false; userPasswordAdmin.value = ''; userPasswordCode.value = ''
  void nextTick(() => document.getElementById('user-new-password')?.focus())
}
function closeUserPassword() {
  if (busy.value) return
  userPasswordTarget.value = null; userNewPassword.value = ''; userRepeatPassword.value = ''; userPasswordAdmin.value = ''; userPasswordCode.value = ''
  void nextTick(() => document.getElementById('user-password-open')?.focus())
}
async function submitUserPassword() {
  if (!userPasswordTarget.value || !userPasswordValid.value) return
  busy.value = true; userPasswordError.value = ''
  try {
    if (userPasswordReauth.value) await api.post('/auth/reauthenticate', { password: userPasswordAdmin.value, code: userPasswordCode.value })
    await api.post(`/users/${encodeURIComponent(userPasswordTarget.value.id)}/password/reset`, { new_password: userNewPassword.value, reason_code: userPasswordReason.value }, userPasswordKey.value)
    const id = userPasswordTarget.value.id
    busy.value = false; closeUserPassword(); notify('用户密码已重置，旧会话已撤销。'); await openUser(id);await refreshUserList()
  } catch (error) {
    if (error instanceof APIError && error.code === 'recent_mfa_required') { userPasswordReauth.value = true; return }
    if (!handleExpired(error)) userPasswordError.value = errorText(error, '密码未重置，请检查密码规则和账号状态后再试。')
  } finally { busy.value = false }
}
const userDevices = ref<DeviceRow[]>([])
const devices = ref<DeviceRow[]>([])
const deviceCursor = ref('')
let loadedDeviceFilter = ''
let loadedUserFilter = ''
const mailJobs = ref<MailJob[]>([])
const securityEvents = ref<SecurityEvent[]>([])
const auditEvents = ref<AuditEvent[]>([])
const auditCursor = ref<number | null>(null)
const auditActionFilter = ref('')
const auditResultFilter = ref('')
const auditDaysFilter = ref('')
const backupRuns = ref<BackupRun[]>([])
function auditParams(): string {
  const params = new URLSearchParams()
  if (auditActionFilter.value.trim()) params.set('action', auditActionFilter.value.trim())
  if (auditResultFilter.value) params.set('result', auditResultFilter.value)
  if (auditDaysFilter.value) params.set('days', auditDaysFilter.value)
  const query = params.toString()
  return query ? `&${query}` : ''
}
async function applyAuditFilters() {
  auditCursor.value = null
  await loadPage('security')
}
const operations = ref<Operations | null>(null)
const configItems = ref<ConfigItem[]>([])
const activationBatches = ref<ActivationBatch[]>([])
const activationCodes = ref<ActivationCode[]>([])
const selectedActivationBatch = ref('')
const activationLabel = ref('用户体验兑换')
const activationProduct = ref('riverdiary_premium')
const activationDurationDays = ref(30)
const activationCount = ref(10)
const activationExpiresAt = ref('')
const activationImportText = ref('')
const activationMode = ref<'generate' | 'import'>('generate')
const issuedActivationCodes = ref<IssuedActivationCode[]>([])
const issuedCodesSaved = ref(false)
const codesLoading = ref(false)
const codesError = ref('')
const activationBusy = ref(false)
const activationRequestKey = ref(crypto.randomUUID())
const activationStepUpNeeded = ref(false)
const activationStepUpPassword = ref('')
const activationStepUpCode = ref('')

const revokeTarget = ref<DeviceRow | null>(null)
const revokeOpener = ref<HTMLElement | null>(null)
const revokeReason = ref('lost_device')
const idempotencyKey = ref('')
const reauthNeeded = ref(false)
const reauthPassword = ref('')
const reauthCode = ref('')
const currentAdminPassword = ref('')
const newAdminPassword = ref('')
const newAdminPasswordConfirm = ref('')
const currentAdminTotp = ref('')
const passwordBusy = ref(false)

// ---- 通用二次验证(敏感操作失败后按需弹出) ----
const stepUpNeeded = ref(false)
const stepUpPassword = ref('')
const stepUpCode = ref('')
let pendingStepUp: (() => Promise<void>) | null = null
interface AdminMailResult { status: 'sent' | 'queued'; mail_id: string; subject: string }
const mailRequestKeys = new Map<string, { fingerprint: string; key: string }>()
function mailRequestKey(scope: string, payload: unknown): string {
  const fingerprint = JSON.stringify(payload)
  const previous = mailRequestKeys.get(scope)
  if (previous?.fingerprint === fingerprint) return previous.key
  const key = crypto.randomUUID()
  mailRequestKeys.set(scope, { fingerprint, key })
  return key
}
function mailRetryAfterFailure(scope: string, error: unknown) {
  if (error instanceof APIError && [400, 409, 502].includes(error.status)) mailRequestKeys.delete(scope)
}
function mailPendingMessage() { return '发送结果待确认，已保留草稿和发送记录。请先查看发送历史，避免重复发送。' }

function requestStepUp(action: () => Promise<void>, error: unknown): boolean {
  if (error instanceof APIError && error.status === 403 && error.code === 'recent_mfa_required') {
    pendingStepUp = action
    stepUpPassword.value = ''
    stepUpCode.value = ''
    stepUpNeeded.value = true
    void nextTick(() => document.getElementById('global-stepup-password')?.focus())
    return true
  }
  return false
}
async function submitStepUp() {
  if (!pendingStepUp || busy.value) return
  busy.value = true
  pageError.value = ''
  try {
    await api.post('/auth/reauthenticate', { password: stepUpPassword.value, code: stepUpCode.value })
    const action = pendingStepUp
    pendingStepUp = null
    stepUpNeeded.value = false
    stepUpPassword.value = ''
    stepUpCode.value = ''
    await action()
  } catch (error) {
    if (!handleExpired(error)) pageError.value = errorText(error, '重新验证失败，请检查管理员密码和动态验证码。')
  } finally {
    busy.value = false
  }
}
function cancelStepUp() {
  if (busy.value) return
  pendingStepUp = null
  stepUpNeeded.value = false
  stepUpPassword.value = ''
  stepUpCode.value = ''
}

// ---- 反馈收件箱与邮件发送 ----
const feedbackMessages = ref<FeedbackMessage[]>([])
const feedbackCursor = ref('')
const feedbackStatusFilter = ref('')
const feedbackUnread = ref(0)
const feedbackBusy = ref(false)
const replyTarget = ref<FeedbackMessage | null>(null)
const replyBody = ref('')
const replyReauthNeeded = ref(false)
const replyReauthPassword = ref('')
const replyReauthCode = ref('')
const replyError = ref('')
const composeTo = ref('')
const composeSubject = ref('')
const composeBody = ref('')
const composeBusy = ref(false)
const outboundEmails = ref<OutboundEmail[]>([])
const mailboxTab = ref<'inbound' | 'feedback' | 'compose' | 'outbound'>('inbound')
const inboundQuery = ref('')
const inboundStatusFilter = ref('')
const feedbackQuery = ref('')
const outboundQuery = ref('')
const outboundStatusFilter = ref('')
const outboundCursor = ref('')
const composeTemplate = ref<MailTemplateID>('support_reply')
const composeRecipientName = ref('')
const replyTemplate = ref<MailTemplateID>('support_reply')
const replyRecipientName = ref('')
const replyIncludeOriginal = ref(false)
const viewTemplate = ref<MailTemplateID>('support_reply')
const viewRecipientName = ref('')
const viewIncludeOriginal = ref(false)
const previewOpen = ref(false)
const previewLoading = ref(false)
const previewError = ref('')
const previewData = ref<MailPreviewResponse | null>(null)
const previewHistory = ref<OutboundDetail | null>(null)
let previewRequest: AbortController | null = null
interface MailDraft { body: string; template: MailTemplateID; name: string; quote: boolean }
const mailDrafts = new Map<string, MailDraft>()
const pendingMailIDs = new Map<string, string>()
const loadedMailboxFilters = new Map<string, string>()
function rememberMailDraft(kind: 'feedback' | 'inbound') {
  const target = kind === 'feedback' ? replyTarget.value : viewTarget.value
  if (!target) return
  const draft: MailDraft = kind === 'feedback' ? { body: replyBody.value, template: replyTemplate.value, name: replyRecipientName.value, quote: replyIncludeOriginal.value } : { body: viewReplyBody.value, template: viewTemplate.value, name: viewRecipientName.value, quote: viewIncludeOriginal.value }
  if (draft.body.trim()) mailDrafts.set(`${kind}:${target.id}`, draft)
}
function insertMailSnippet(kind: 'compose' | 'feedback' | 'inbound', event: Event) {
  const select = event.target as HTMLSelectElement
  const snippet = mailSnippets.find((item) => item.id === select.value)
  select.value = ''
  if (!snippet) return
  const body = kind === 'compose' ? composeBody : kind === 'feedback' ? replyBody : viewReplyBody
  if (body.value.trim() && !window.confirm('使用快捷回复将替换当前正文，确认继续？')) return
  body.value = snippet.body
}
function mailboxFingerprint(kind: 'inbound' | 'feedback' | 'outbound'): string {
  return JSON.stringify(kind === 'inbound' ? [inboundQuery.value.trim(), inboundStatusFilter.value] : kind === 'feedback' ? [feedbackQuery.value.trim(), feedbackStatusFilter.value] : [outboundQuery.value.trim(), outboundStatusFilter.value])
}
function mailboxParams(kind: 'inbound' | 'feedback' | 'outbound', cursor = ''): URLSearchParams {
  const [query, status] = JSON.parse(mailboxFingerprint(kind)) as string[]
  const params = new URLSearchParams({ limit: '25' })
  if (query) params.set('q', query)
  if (status) params.set('status', status)
  if (cursor) params.set('cursor', cursor)
  return params
}
async function searchMailbox() { await loadPage('mailbox') }
async function openMailPreview(source: 'manual' | 'feedback' | 'inbound') {
  previewRequest?.abort()
  const request = new AbortController(); previewRequest = request
  previewOpen.value = true; previewLoading.value = true; previewError.value = ''; previewData.value = null; previewHistory.value = null
  const payload = source === 'manual' ? { source, to: composeTo.value.trim(), subject: composeSubject.value.trim(), body: composeBody.value, template: composeTemplate.value, recipient_name: composeRecipientName.value }
    : source === 'feedback' ? { source, source_id: replyTarget.value?.id, body: replyBody.value, template: replyTemplate.value, recipient_name: replyRecipientName.value, include_original: replyIncludeOriginal.value }
    : { source, source_id: viewTarget.value?.id, body: viewReplyBody.value, template: viewTemplate.value, recipient_name: viewRecipientName.value, include_original: viewIncludeOriginal.value }
  try { const result = await api.post<MailPreviewResponse>('/mailbox/preview', payload, undefined, request.signal); if (!request.signal.aborted && isAuthenticated.value) previewData.value = result }
  catch (error) { if (!request.signal.aborted && !handleExpired(error)) previewError.value = errorText(error, '预览未生成，请检查邮件内容。') }
  finally { if (previewRequest === request) previewLoading.value = false }
}
async function showOutboundDetail(id: string) {
  previewRequest?.abort(); const request = new AbortController(); previewRequest = request
  previewOpen.value = true; previewLoading.value = true; previewError.value = ''; previewData.value = null; previewHistory.value = null
  try { const result = await api.get<OutboundDetail>(`/mailbox/outbound/${encodeURIComponent(id)}`, request.signal); if (!request.signal.aborted && isAuthenticated.value) previewHistory.value = result }
  catch (error) { if (!request.signal.aborted && !handleExpired(error)) previewError.value = errorText(error, '无法读取这封发送记录。') }
  finally { if (previewRequest === request) previewLoading.value = false }
}
function closeMailPreview() { previewRequest?.abort(); previewOpen.value = false; previewData.value = null; previewHistory.value = null; previewError.value = '' }
async function loadMoreMailbox(kind: 'inbound' | 'feedback' | 'outbound') {
  if (loadedMailboxFilters.get(kind) !== mailboxFingerprint(kind)) { await searchMailbox(); return }
  const cursor = kind === 'inbound' ? inboundCursor.value : kind === 'feedback' ? feedbackCursor.value : outboundCursor.value
  if (!cursor || loading.value) return
  const request = new AbortController(); pageRequest = request; loading.value = true
  try {
    const result = await api.get<{ messages: InboundMail[] | FeedbackMessage[] | OutboundEmail[]; next_cursor: string }>(`/mailbox/${kind}?${mailboxParams(kind, cursor)}`, request.signal)
    if (!request.signal.aborted && isAuthenticated.value && page.value === 'mailbox') {
      if (kind === 'inbound') { const ids = new Set(inboundMail.value.map(x => x.id)); inboundMail.value.push(...(result.messages as InboundMail[]).filter(x => !ids.has(x.id))); inboundCursor.value = result.next_cursor }
      if (kind === 'feedback') { const ids = new Set(feedbackMessages.value.map(x => x.id)); feedbackMessages.value.push(...(result.messages as FeedbackMessage[]).filter(x => !ids.has(x.id))); feedbackCursor.value = result.next_cursor }
      if (kind === 'outbound') { const ids = new Set(outboundEmails.value.map(x => x.id)); outboundEmails.value.push(...(result.messages as OutboundEmail[]).filter(x => !ids.has(x.id))); outboundCursor.value = result.next_cursor }
    }
  } catch (error) { if (!request.signal.aborted && !handleExpired(error)) pageError.value = errorText(error, '更多邮件未能读取，请重试。') }
  finally { if (pageRequest === request) loading.value = false }
}


function feedbackStatusLabel(value: string): string { return ({ new: '未读', read: '已读', replied: '已回复', archived: '已归档' } as Record<string,string>)[value] ?? value }
function feedbackStatusClass(value: string): string { return ({ new: 'status-warning', read: 'status-neutral', replied: 'status-good', archived: 'status-muted' } as Record<string,string>)[value] ?? 'status-neutral' }

async function openFeedbackReply(item: FeedbackMessage) {
  replyTarget.value = item
  const draft = mailDrafts.get(`feedback:${item.id}`)
  replyBody.value = draft?.body ?? ''
  replyTemplate.value = draft?.template ?? 'support_reply'
  replyRecipientName.value = draft?.name ?? ''
  replyIncludeOriginal.value = draft?.quote ?? false
  replyReauthNeeded.value = false
  replyReauthPassword.value = ''
  replyReauthCode.value = ''
  replyError.value = pendingMailIDs.has(`feedback:${item.id}`) ? mailPendingMessage() : ''
  if (item.status === 'new') {
    try {
      await api.post(`/mailbox/feedback/${encodeURIComponent(item.id)}/read`)
      item.status = 'read'; feedbackUnread.value = Math.max(0, feedbackUnread.value - 1)
    } catch (error) { if (!handleExpired(error)) replyError.value = '反馈已打开，但未能标记已读；回复成功后会更新状态。' }
  }
  void nextTick(() => document.getElementById('feedback-reply-body')?.focus())
}
function closeFeedbackReply() {
  if (feedbackBusy.value) return
  rememberMailDraft('feedback')
  replyTarget.value = null
  replyReauthNeeded.value = false
  replyReauthPassword.value = ''
  replyReauthCode.value = ''
}
async function submitFeedbackReply() {
  if (!replyTarget.value || feedbackBusy.value || replyBody.value.trim().length < 2) return
  feedbackBusy.value = true
  replyError.value = ''
  try {
    if (replyReauthNeeded.value) {
      await api.post('/auth/reauthenticate', { password: replyReauthPassword.value, code: replyReauthCode.value })
    }
    const scope = `feedback:${replyTarget.value.id}`
    const payload = { body: replyBody.value, template: replyTemplate.value, recipient_name: replyRecipientName.value, include_original: replyIncludeOriginal.value }
    const result = await api.post<AdminMailResult>(`/mailbox/feedback/${encodeURIComponent(replyTarget.value.id)}/reply`, payload, mailRequestKey(scope, payload))
    if (result.status === 'queued') { pendingMailIDs.set(scope, result.mail_id); replyError.value = mailPendingMessage(); await loadPage('mailbox'); return }
    mailRequestKeys.delete(scope); mailDrafts.delete(scope); pendingMailIDs.delete(scope); replyBody.value = ''
    feedbackBusy.value = false
    closeFeedbackReply()
    notify('回复已交给邮件服务，反馈标记为已回复。')
    await loadPage('mailbox')
  } catch (error) {
    if (error instanceof APIError && error.status === 403 && error.code === 'recent_mfa_required') {
      replyReauthNeeded.value = true
      return
    }
    if (replyTarget.value) mailRetryAfterFailure(`feedback:${replyTarget.value.id}`, error)
    if (!handleExpired(error)) {
      if (error instanceof APIError && error.code === 'feedback_no_contact') replyError.value = '该反馈没有留下联系邮箱，无法邮件回复。'
      else if (error instanceof APIError && error.code === 'mail_delivery_failed') replyError.value = '邮件投递失败，请检查 SMTP 状态后重试。'
      else replyError.value = errorText(error, '回复没有完成，请重试。')
    }
  } finally {
    feedbackBusy.value = false
  }
}
async function archiveFeedback(item: FeedbackMessage) {
  feedbackBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/mailbox/feedback/${encodeURIComponent(item.id)}/archive`)
    await loadPage('mailbox')
    notify('反馈已归档。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '归档没有完成，请重试。')
  } finally {
    feedbackBusy.value = false
  }
}
async function searchFeedback() {
  feedbackCursor.value = ''
  await loadPage('mailbox')
}
async function loadMoreFeedback() {
  if (!feedbackCursor.value || loading.value) return
  const request = new AbortController()
  pageRequest = request
  loading.value = true
  try {
    const params = new URLSearchParams({ limit: '25' })
    if (feedbackStatusFilter.value) params.set('status', feedbackStatusFilter.value)
    params.set('cursor', feedbackCursor.value)
    const result = await api.get<{ messages: FeedbackMessage[]; next_cursor: string; unread: number }>(`/mailbox/feedback?${params}`, request.signal)
    if (!request.signal.aborted && isAuthenticated.value && page.value === 'mailbox') {
      feedbackMessages.value = [...feedbackMessages.value, ...result.messages]
      feedbackCursor.value = result.next_cursor
    }
  } catch (error) {
    if (!request.signal.aborted && !handleExpired(error)) pageError.value = errorText(error, '无法读取下一页。')
  } finally {
    if (pageRequest === request) loading.value = false
  }
}
async function sendComposeMail() {
  if (composeBusy.value || !composeTo.value.trim() || !composeSubject.value.trim() || !composeBody.value.trim()) return
  composeBusy.value = true
  pageError.value = ''
  const run = async () => {
    const payload = { to: composeTo.value.trim(), subject: composeSubject.value.trim(), body: composeBody.value, template: composeTemplate.value, recipient_name: composeRecipientName.value }
    const result = await api.post<AdminMailResult>('/mailbox/send', payload, mailRequestKey('compose', payload))
    if (result.status === 'queued') { pendingMailIDs.set('compose', result.mail_id); notify(mailPendingMessage(), 12_000); await loadPage('mailbox'); return }
    mailRequestKeys.delete('compose'); pendingMailIDs.delete('compose')
    composeTo.value = ''
    composeSubject.value = ''
    composeBody.value = ''
    notify(`邮件已交给邮件服务：${result.subject}`)
    await loadPage('mailbox')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) {
      mailRetryAfterFailure('compose', error)
      if (error instanceof APIError && error.code === 'invalid_recipient') pageError.value = '收件邮箱格式不正确。'
      else if (error instanceof APIError && error.code === 'mail_delivery_failed') pageError.value = '邮件投递失败，已记录在发送历史中。'
      else pageError.value = errorText(error, '发送没有完成，请重试。')
    }
  } finally {
    composeBusy.value = false
  }
}

// ---- 邮件收件箱(入站) ----
const inboundMail = ref<InboundMail[]>([])
const inboundCursor = ref('')
const inboundUnread = ref(0)
const inboundBusy = ref(false)
const viewTarget = ref<InboundMail | null>(null)
const viewReplyBody = ref('')
const viewReauthNeeded = ref(false)
const viewReauthPassword = ref('')
const viewReauthCode = ref('')
const viewError = ref('')

function inboundSenderName(item: InboundMail): string {
  return item.from_name || item.from_addr || '(未知发件人)'
}
function inboundStatusClass(value: string): string { return ({ new: 'status-warning', read: 'status-neutral', replied: 'status-good' } as Record<string,string>)[value] ?? 'status-neutral' }
function inboundStatusLabel(value: string): string { return ({ new: '未读', read: '已读', replied: '已回复' } as Record<string,string>)[value] ?? value }

async function openInboundMail(item: InboundMail) {
  viewTarget.value = item
  const draft = mailDrafts.get(`inbound:${item.id}`)
  viewReplyBody.value = draft?.body ?? ''
  viewTemplate.value = draft?.template ?? 'support_reply'
  viewRecipientName.value = draft?.name ?? Array.from(item.from_name.replace(/\s+/g, ' ').trim()).slice(0, 60).join('')
  viewIncludeOriginal.value = draft?.quote ?? false
  viewReauthNeeded.value = false
  viewReauthPassword.value = ''
  viewReauthCode.value = ''
  viewError.value = pendingMailIDs.has(`inbound:${item.id}`) ? mailPendingMessage() : ''
  if (item.status === 'new') {
    try {
      const result = await api.post<{ status: InboundMail['status'] }>(`/mailbox/inbound/${encodeURIComponent(item.id)}/read`)
      item.status = result.status; inboundUnread.value = Math.max(0, inboundUnread.value - 1)
    } catch (error) { if (!handleExpired(error)) viewError.value = '邮件已打开，但未能标记已读；可使用下方按钮重新验证后重试。' }
  }
  void nextTick(() => document.getElementById('inbound-reply-body')?.focus())
}
async function markCurrentMailRead() {
  if (!viewTarget.value || inboundBusy.value) return
  const target = viewTarget.value
  const run = async () => {
    const result = await api.post<{ status: InboundMail['status'] }>(`/mailbox/inbound/${encodeURIComponent(target.id)}/read`)
    if (target.status === 'new') inboundUnread.value = Math.max(0, inboundUnread.value - 1)
    target.status = result.status
    viewError.value = ''
  }
  inboundBusy.value = true
  try { await run() } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) viewError.value = errorText(error, '无法标记已读，请重试。')
  } finally { inboundBusy.value = false }
}
function closeInboundMail() {
  if (inboundBusy.value) return
  rememberMailDraft('inbound')
  viewTarget.value = null
  viewReauthNeeded.value = false
  viewReauthPassword.value = ''
  viewReauthCode.value = ''
}
async function submitInboundReply() {
  if (!viewTarget.value || inboundBusy.value || viewReplyBody.value.trim().length < 2) return
  inboundBusy.value = true
  viewError.value = ''
  const target = viewTarget.value
  try {
    if (viewReauthNeeded.value) {
      await api.post('/auth/reauthenticate', { password: viewReauthPassword.value, code: viewReauthCode.value })
    }
    const scope = `inbound:${target.id}`
    const payload = { body: viewReplyBody.value, template: viewTemplate.value, recipient_name: viewRecipientName.value, include_original: viewIncludeOriginal.value }
    const result = await api.post<AdminMailResult>(`/mailbox/inbound/${encodeURIComponent(target.id)}/reply`, payload, mailRequestKey(scope, payload))
    if (result.status === 'queued') { pendingMailIDs.set(scope, result.mail_id); viewError.value = mailPendingMessage(); await loadPage('mailbox'); return }
    mailRequestKeys.delete(scope); mailDrafts.delete(scope); pendingMailIDs.delete(scope); viewReplyBody.value = ''
    inboundBusy.value = false
    closeInboundMail()
    notify(`回复已交给邮件服务，收件人 ${target.from_addr}。`)
    await loadPage('mailbox')
  } catch (error) {
    if (error instanceof APIError && error.status === 403 && error.code === 'recent_mfa_required') {
      viewReauthNeeded.value = true
      return
    }
    mailRetryAfterFailure(`inbound:${target.id}`, error)
    if (!handleExpired(error)) viewError.value = errorText(error, '回复没有完成，请重试。')
  } finally {
    inboundBusy.value = false
  }
}
async function deleteInboundMail(item: InboundMail) {
  if (!window.confirm(`确认删除来自 ${inboundSenderName(item)} 的「${item.subject || '（无主题）'}」？`)) return
  inboundBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.delete(`/mailbox/inbound/${encodeURIComponent(item.id)}`)
    viewTarget.value = null
    mailDrafts.delete(`inbound:${item.id}`); mailRequestKeys.delete(`inbound:${item.id}`); pendingMailIDs.delete(`inbound:${item.id}`)
    await loadPage('mailbox')
    notify('邮件已删除。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '删除没有完成，请重试。')
  } finally {
    inboundBusy.value = false
  }
}
async function loadMoreInbound() {
  if (!inboundCursor.value || loading.value) return
  const request = new AbortController()
  pageRequest = request
  loading.value = true
  try {
    const result = await api.get<{ messages: InboundMail[]; next_cursor: string; unread: number }>(`/mailbox/inbound?cursor=${encodeURIComponent(inboundCursor.value)}`, request.signal)
    if (!request.signal.aborted && isAuthenticated.value && page.value === 'mailbox') {
      inboundMail.value = [...inboundMail.value, ...result.messages]
      inboundCursor.value = result.next_cursor
    }
  } catch (error) {
    if (!request.signal.aborted && !handleExpired(error)) pageError.value = errorText(error, '无法读取下一页。')
  } finally {
    if (pageRequest === request) loading.value = false
  }
}

// ---- 公告管理 ----
const announcements = ref<Announcement[]>([])
const annEditingID = ref('')
const annLevel = ref<'info' | 'warn' | 'critical'>('info')
const annTitle = ref('')
const annBody = ref('')
const annPlacement = ref<'banner' | 'download' | 'both'>('banner')
const annHref = ref('')
const annActive = ref(false)
const annStartsAt = ref('')
const annEndsAt = ref('')
const annBusy = ref(false)
function resetAnnForm() {
  annEditingID.value = ''
  annLevel.value = 'info'
  annTitle.value = ''
  annBody.value = ''
  annPlacement.value = 'banner'
  annHref.value = ''
  annActive.value = false
  annStartsAt.value = ''
  annEndsAt.value = ''
}
function editAnnouncement(item: Announcement) {
  annEditingID.value = item.id
  annLevel.value = item.level
  annTitle.value = item.title
  annBody.value = item.body
  annPlacement.value = item.placement
  annHref.value = item.href
  annActive.value = item.active
  annStartsAt.value = toShanghaiInput(item.starts_at)
  annEndsAt.value = toShanghaiInput(item.ends_at)
  void nextTick(() => document.getElementById('ann-title')?.focus())
}
function annTimestamp(): { starts_at?: string; ends_at?: string } {
  const out: { starts_at?: string; ends_at?: string } = {}
  if (annStartsAt.value) out.starts_at = shanghaiDateTimeToISO(annStartsAt.value)
  if (annEndsAt.value) out.ends_at = shanghaiDateTimeToISO(annEndsAt.value)
  return out
}
async function submitAnnouncement() {
  if (annBusy.value || !annTitle.value.trim()) return
  if (annStartsAt.value && annEndsAt.value && annStartsAt.value >= annEndsAt.value) {
    pageError.value = '公告结束时间应晚于开始时间，请检查 UTC+8 时间。'
    return
  }
  annBusy.value = true
  pageError.value = ''
  const editingID = annEditingID.value
  let timestamps: ReturnType<typeof annTimestamp>
  try { timestamps = annTimestamp() } catch {
    annBusy.value = false
    pageError.value = '公告时间无效，请重新选择日期和时间。'
    return
  }
  const payload = { level: annLevel.value, title: annTitle.value, body: annBody.value, placement: annPlacement.value, href: annHref.value, active: annActive.value, ...timestamps }
  const run = async () => {
    if (editingID) await api.post(`/announcements/${encodeURIComponent(editingID)}`, payload)
    else await api.post('/announcements', payload)
    resetAnnForm()
    await loadPage('announcements')
    notify(editingID ? '公告已更新。' : '公告已创建。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '公告没有保存，请检查表单后重试。')
  } finally {
    annBusy.value = false
  }
}
async function toggleAnnouncement(item: Announcement) {
  annBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/announcements/${encodeURIComponent(item.id)}/${item.active ? 'deactivate' : 'activate'}`)
    await loadPage('announcements')
    notify(item.active ? '公告已下线。' : '公告已上线，官网与客户端将在一分钟内读取到。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '状态没有更新，请重试。')
  } finally {
    annBusy.value = false
  }
}
async function deleteAnnouncement(item: Announcement) {
  if (!window.confirm(`确认删除公告「${item.title}」？该操作会写入审计记录。`)) return
  annBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.delete(`/announcements/${encodeURIComponent(item.id)}`)
    await loadPage('announcements')
    notify('公告已删除。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '删除没有完成，请重试。')
  } finally {
    annBusy.value = false
  }
}

// ---- 更新日志管理 ----
const changelogEntries = ref<ChangelogEntry[]>([])
const clEditingID = ref('')
const clDate = ref(todayInShanghai())
const clVersion = ref('')
const clTitle = ref('')
const clBody = ref('')
const clPublished = ref(false)
const clBusy = ref(false)
function resetChangelogForm() {
  clEditingID.value = ''
  clDate.value = todayInShanghai()
  clVersion.value = ''
  clTitle.value = ''
  clBody.value = ''
  clPublished.value = false
}
function editChangelog(item: ChangelogEntry) {
  clEditingID.value = item.id
  clDate.value = item.date
  clVersion.value = item.version_tag
  clTitle.value = item.title
  clBody.value = item.body
  clPublished.value = item.is_published
  void nextTick(() => document.getElementById('cl-title')?.focus())
}
async function submitChangelog() {
  if (clBusy.value || !clTitle.value.trim() || !clDate.value) return
  clBusy.value = true
  pageError.value = ''
  const editingID = clEditingID.value
  const payload = { date: clDate.value, version_tag: clVersion.value, title: clTitle.value, body: clBody.value, is_published: clPublished.value }
  const run = async () => {
    if (editingID) await api.post(`/changelog/${encodeURIComponent(editingID)}`, payload)
    else await api.post('/changelog', payload)
    resetChangelogForm()
    await loadPage('changelog')
    notify(editingID ? '更新日志已保存。' : '更新日志已创建。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '更新日志没有保存，请检查表单后重试。')
  } finally {
    clBusy.value = false
  }
}
async function toggleChangelog(item: ChangelogEntry) {
  clBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/changelog/${encodeURIComponent(item.id)}/${item.is_published ? 'unpublish' : 'publish'}`)
    await loadPage('changelog')
    notify(item.is_published ? '该条目已从官网撤下。' : '已发布，官网更新日志将在一分钟内同步。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '状态没有更新，请重试。')
  } finally {
    clBusy.value = false
  }
}
async function deleteChangelog(item: ChangelogEntry) {
  if (!window.confirm(`确认删除 ${item.date} 的「${item.title}」？该操作会写入审计记录。`)) return
  clBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.delete(`/changelog/${encodeURIComponent(item.id)}`)
    await loadPage('changelog')
    notify('更新日志条目已删除。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '删除没有完成，请重试。')
  } finally {
    clBusy.value = false
  }
}

// ---- 下载管理 ----
const downloads = ref<DownloadArtifact[]>([])
const downloadStorageConfigured = ref(true)
const dlPlatform = ref<'macos' | 'ios'>('macos')
const dlVersion = ref('')
const dlNote = ref('')
const dlFile = ref<File | null>(null)
const dlBusy = ref(false)
const dlProgress = ref<number | null>(null)
let uploadController: AbortController | null = null
function cancelUpload() { uploadController?.abort() }
function onDownloadFileChange(event: Event) {
  const input = event.target as HTMLInputElement
  dlFile.value = input.files?.[0] ?? null
}
async function uploadDownload() {
  if (dlBusy.value || !dlFile.value || !dlVersion.value.trim()) return
  if (dlFile.value.size > 256 * 1024 * 1024 || !dlFile.value.name.toLowerCase().endsWith('.zip')) {
    pageError.value = '请选择不超过 256 MB 的 ZIP 安装包。'; return
  }
  dlBusy.value = true
  dlProgress.value = 0
  pageError.value = ''
  const form = new FormData()
  form.set('platform', dlPlatform.value)
  form.set('version', dlVersion.value.trim())
  form.set('note', dlNote.value.trim())
  form.set('file', dlFile.value)
  const run = async () => {
    uploadController = new AbortController()
    await api.postForm('/downloads', form, { signal: uploadController.signal, onProgress: (value) => { dlProgress.value = value } })
    const input = document.getElementById('dl-file') as HTMLInputElement | null
    if (input) input.value = ''
    dlFile.value = null
    dlVersion.value = ''
    dlNote.value = ''
    await loadPage('downloads')
    notify('安装包已上传。默认不开放下载，确认无误后点击「开放下载」。')
  }
  try {
    const current = await api.get<AdminSession>('/auth/session')
    if (!current.authenticated) throw new APIError(401, 'admin_auth_required', '')
    if (current.reauthentication_required) throw new APIError(403, 'recent_mfa_required', '')
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) {
      if (error instanceof DOMException && ['AbortError', 'TimeoutError'].includes(error.name)) pageError.value = error.message
      else if (error instanceof APIError && error.code === 'download_filename_exists') pageError.value = '服务器上已存在同名文件，请修改文件名后重新上传。'
      else if (error instanceof APIError && error.code === 'invalid_file_type') pageError.value = '只支持 .zip 安装包。'
      else if (error instanceof APIError && error.code === 'download_too_large') pageError.value = '文件超过 256 MB 上限。'
      else pageError.value = errorText(error, '上传没有完成，请重试。')
    }
  } finally {
    dlBusy.value = false
    dlProgress.value = null
    uploadController = null
  }
}
async function toggleDownload(item: DownloadArtifact) {
  dlBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/downloads/${encodeURIComponent(item.id)}/${item.is_active ? 'deactivate' : 'activate'}`)
    await loadPage('downloads')
    notify(item.is_active ? '该版本已暂停下载，官网将显示「紧急修复中」。' : '该版本已开放下载，官网下载卡片会立即更新。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = error instanceof APIError && error.code === 'download_file_unavailable' ? '安装包文件缺失或大小不符，不能开放下载；请重新上传正确版本。' : errorText(error, '状态没有更新，请重试。')
  } finally {
    dlBusy.value = false
  }
}
async function saveDownloadNote(item: DownloadArtifact) {
  dlBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/downloads/${encodeURIComponent(item.id)}/note`, { note: item.note })
    await loadPage('downloads')
    notify('下载说明已更新。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '说明没有保存，请重试。')
  } finally {
    dlBusy.value = false
  }
}

// ---- 管理员管理 ----
const admins = ref<AdminAccount[]>([])
const adminSessionsList = ref<AdminSessionRow[]>([])
const newAdminName = ref('')
const createAdminPassword = ref('')
const adminBusy = ref(false)
const issuedTotpUri = ref('')
const issuedTotpSaved = ref(false)
async function createAdmin() {
  if (adminBusy.value) return
  if (issuedTotpUri.value && !issuedTotpSaved.value) { pageError.value = '请先保存当前验证器设置，再创建其他管理员。'; return }
  adminBusy.value = true
  pageError.value = ''
  const run = async () => {
    const result = await api.post<{ id: string; username: string; totp_uri: string }>('/admins', {
      username: newAdminName.value.trim(),
      password: createAdminPassword.value,
    })
    newAdminName.value = ''
    createAdminPassword.value = ''
    issuedTotpUri.value = result.totp_uri
    issuedTotpSaved.value = false
    await loadPage('admins')
    notify('管理员已创建。请立即让其保存验证器设置 URI，关闭页面后无法再次显示。', 9000)
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) {
      if (error instanceof APIError && error.code === 'admin_username_exists') pageError.value = '该管理员名已存在。'
      else if (error instanceof APIError && error.code === 'invalid_password') pageError.value = '管理员密码需要 12–128 个字符。'
      else if (error instanceof APIError && error.code === 'invalid_username') pageError.value = '管理员名需为 3–64 位字母、数字、点、下划线或连字符。'
      else pageError.value = errorText(error, '管理员没有创建，请重试。')
    }
  } finally {
    adminBusy.value = false
  }
}
async function setAdminDisabled(admin: AdminAccount) {
  const disabling = admin.disabled_at === null
  if (disabling && !window.confirm(`确认禁用管理员「${admin.username}」？其所有管理会话会立即失效。`)) return
  adminBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/admins/${encodeURIComponent(admin.id)}/${disabling ? 'disable' : 'enable'}`, { reason_code: 'other' })
    await loadPage('admins')
    notify(disabling ? '管理员已禁用。' : '管理员已启用。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '状态没有更新，请重试。')
  } finally {
    adminBusy.value = false
  }
}
async function resetAdminTotp(admin: AdminAccount) {
  if (admin.is_you) { pageError.value = '当前账号的验证器请由其他管理员或服务器恢复命令重置。'; return }
  if (issuedTotpUri.value && !issuedTotpSaved.value) { pageError.value = '请先保存当前验证器设置，再重置其他管理员。'; return }
  if (!window.confirm(`确认为「${admin.username}」重置动态验证器？其现有管理会话会全部失效。`)) return
  adminBusy.value = true
  pageError.value = ''
  const run = async () => {
    const result = await api.post<{ totp_uri: string }>(`/admins/${encodeURIComponent(admin.id)}/totp-reset`, { reason_code: 'other' })
    issuedTotpUri.value = result.totp_uri
    issuedTotpSaved.value = false
    await loadPage('admins')
    notify('动态验证器已重置。请立即保存新的设置 URI，旧验证器已失效。', 9000)
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '重置没有完成，请重试。')
  } finally {
    adminBusy.value = false
  }
}
async function revokeAdminSession(row: AdminSessionRow) {
  if (row.is_you && !window.confirm('这是你当前使用的会话，撤销后需要重新登录。确认继续？')) return
  adminBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/admin-sessions/${encodeURIComponent(row.id)}/revoke`)
    if (row.is_you) { session.value = { authenticated: false }; clearPrivateData(); authError.value = '当前会话已撤销，请重新登录。'; return }
    await loadPage('admins')
    notify('管理会话已撤销。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '撤销没有完成，请重试。')
  } finally {
    adminBusy.value = false
  }
}
async function copyTotpUri() {
  try {
    await navigator.clipboard.writeText(issuedTotpUri.value)
    notify('验证器设置 URI 已复制到剪贴板。')
  } catch {
    pageError.value = '剪贴板不可用，请选中设置 URI 后手动复制并保存。'
  }
}

// ---- 统计与限流 ----
const stats = ref<StatsData | null>(null)
const statsDays = ref(30)
const rateLimitBuckets = ref<RateLimitBucket[]>([])
const rlKind = ref('email_hour')
const rlValue = ref('')
const rlResult = ref('')
const insightsBusy = ref(false)
function seriesMax(points: { count: number }[]): number {
  return Math.max(1, ...points.map((point) => point.count))
}
function barPercent(value: number, max: number): number {
  return Math.round((value / max) * 100)
}
async function lookupRateLimit() {
  if (insightsBusy.value || rlValue.value.trim().length < 3) return
  insightsBusy.value = true
  pageError.value = ''
  const payload = { kind: rlKind.value, value: rlValue.value.trim() }
  const run = async () => {
    const result = await api.post<{ found: boolean; hits: number; expires_at?: string }>('/ratelimits/lookup', payload)
    rlResult.value = result.found
      ? `该限流桶当前计数 ${result.hits} 次${result.expires_at ? `，窗口 ${formatDate(result.expires_at)} 过期` : ''}。`
      : '该地址当前没有此类限流记录。'
  }
  try { await run() } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '查询没有完成，请检查输入。')
  } finally { insightsBusy.value = false }
}
async function clearRateLimit() {
  if (insightsBusy.value || rlValue.value.trim().length < 3) return
  insightsBusy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post('/ratelimits/clear', { kind: rlKind.value, value: rlValue.value.trim() })
    rlResult.value = '限流计数已清零，该地址可以立即重试。'
    await loadPage('insights')
    notify('限流桶已清零，操作已记录审计。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '清零没有完成，请重试。')
  } finally {
    insightsBusy.value = false
  }
}

// ---- 用户抽屉:会话、封禁、权益 ----
const userSessionsList = ref<UserSessionRow[]>([])
const moderationReason = ref('user_request')
const entProduct = ref('riverdiary_premium')
const entDuration = ref<number | 'permanent'>(30)
function grantExpires(): number {
  return entDuration.value === 'permanent' ? 0 : entDuration.value
}
function userAction(path: string,message:string) {
  if(!selectedUser.value)return
  userConfirmation.value={path,message,id:selectedUser.value.id,reason:moderationReason.value}
}
async function confirmUserAction() {
  const action=userConfirmation.value
  if(!action)return
  userConfirmation.value=null
  const {path,message}=action
  busy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(path, { reason_code: action.reason })
    await openUser(action.id)
    await refreshUserList()
    notify(message)
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '操作没有完成，请重试。')
  } finally {
    busy.value = false
  }
}
async function grantEntitlement() {
  if (!selectedUser.value) return
  const userID=selectedUser.value.id
  const product=entProduct.value.trim() || 'riverdiary_premium'
  const duration=grantExpires()
  const reason=moderationReason.value
  busy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/users/${encodeURIComponent(userID)}/entitlements`, {
      product_code: product,
      duration_days: duration,
      reason_code: reason,
    })
    await openUser(userID)
    await refreshUserList()
    notify('权益已授予并写入审计。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '权益没有授予，请检查产品代码后重试。')
  } finally {
    busy.value = false
  }
}
async function revokeEntitlement(item: Entitlement) {
  if (!selectedUser.value || !window.confirm(`确认撤销权益「${item.product_code}」？`)) return
  const userID=selectedUser.value.id
  busy.value = true
  pageError.value = ''
  const run = async () => {
    await api.delete(`/users/${encodeURIComponent(userID)}/entitlements/${encodeURIComponent(item.product_code)}`)
    await openUser(userID)
    await refreshUserList()
    notify('权益已撤销。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '撤销没有完成，请重试。')
  } finally {
    busy.value = false
  }
}

const isAuthenticated = computed(() => session.value?.authenticated === true)
const interactionBusy = computed(() => busy.value || activationBusy.value || passwordBusy.value || annBusy.value || clBusy.value || dlBusy.value || adminBusy.value || insightsBusy.value || feedbackBusy.value || inboundBusy.value || composeBusy.value)
const activeDialog = computed(() => stepUpNeeded.value ? 'stepup' : previewOpen.value ? 'preview' : revokeTarget.value ? 'revoke' : userConfirmation.value ? 'userconfirm' : userPasswordTarget.value ? 'password' : viewTarget.value ? 'inbound' : replyTarget.value ? 'feedback' : '')
let dialogOpener: HTMLElement | null = null
watch(activeDialog, async (current, previous) => {
  if (current && !previous) dialogOpener = document.activeElement instanceof HTMLElement ? document.activeElement : null
  document.body.style.overflow = current ? 'hidden' : ''
  await nextTick()
  if (current) {
    const dialogs = [...document.querySelectorAll<HTMLElement>('.modal-backdrop')].filter((item) => !item.inert)
    const dialog = dialogs.at(-1)?.querySelector<HTMLElement>('.dialog')
    if (dialog && !dialog.contains(document.activeElement)) dialog.querySelector<HTMLElement>('input, textarea, select, button')?.focus()
  } else if (dialogOpener?.isConnected) dialogOpener.focus()
})
const activeHeading = computed(() => headings[page.value])
const pageReady = computed(() => readyPage.value === page.value)
const hasUserFilter = computed(() => Boolean(userQuery.value.trim() || userStatus.value || userPasswordFilter.value || userProviderFilter.value || userPremiumFilter.value || userActivityFilter.value))
const visibleDevices = computed(() => devices.value)
const visibleMailJobs = computed(() => mailJobs.value.filter((job) => !mailState.value || (mailState.value === 'attention' ? ['waiting_retry', 'failed', 'delivery_unconfirmed'].includes(job.status) : job.status === mailState.value)))
const serviceReady = computed(() => operations.value?.api.state === 'ready' && operations.value?.database.state === 'ready')

function notify(message: string, duration = 6500) {
  window.clearTimeout(toastTimer)
  toast.value = message
  toastTimer = window.setTimeout(() => { toast.value = '' }, duration)
}

function canLeaveCodes(): boolean {
  if (issuedTotpUri.value && !issuedTotpSaved.value && !window.confirm('新的动态验证器设置尚未保存。离开后无法再次取回，确认离开？')) return false
  return !issuedActivationCodes.value.length || issuedCodesSaved.value || window.confirm('新生成的完整兑换码还未保存。离开后无法再次取回，确认离开？')
}

function protectIssuedCodes(event: BeforeUnloadEvent) {
  if ((!issuedActivationCodes.value.length || issuedCodesSaved.value) && (!issuedTotpUri.value || issuedTotpSaved.value) && !composeBody.value.trim() && !replyBody.value.trim() && !viewReplyBody.value.trim() && mailDrafts.size === 0) return
  event.preventDefault()
  event.returnValue = ''
}

function displayUserStatus(value: string): string { return ({ active: '正常', disabled: '已封禁', deleting: '删除处理中', recovery_required: '需要恢复', deleted: '已删除' } as Record<string,string>)[value] ?? '未知状态' }
function userStatusClass(value: string): string { return ({ active: 'status-good', disabled: 'status-error', deleting: 'status-warning', recovery_required: 'status-error', deleted: 'status-muted' } as Record<string,string>)[value] ?? 'status-muted' }
function displayIdentity(value: string): string { return value === 'apple' ? 'Apple' : value === 'email' ? '邮箱' : value }
function displayMail(value: string): string { return ({ queued: '排队中', waiting_retry: '等待重试', expired: '已过期', failed: '最终失败', handed_to_smtp: '已交给 SMTP', cancelled: '已作废', delivery_unconfirmed: '结果待确认' } as Record<string,string>)[value] ?? '未知状态' }
function mailStatusClass(value: string): string { return ({ queued: 'status-neutral', waiting_retry: 'status-warning', expired: 'status-muted', failed: 'status-error', handed_to_smtp: 'status-good', cancelled: 'status-muted', delivery_unconfirmed: 'status-warning' } as Record<string,string>)[value] ?? 'status-muted' }
function displayEvent(value: string): string { return ({ account_deleted: '账号删除', identity_revoked: '身份撤销', apple_consent_revoked: 'Apple 授权撤回' } as Record<string,string>)[value] ?? value }
function deletionStatusLabel(value: string): string { return ({ pending: '处理中', complete: '已完成', manual_action_required: '需要人工处理' } as Record<string,string>)[value] ?? value }
function configStateLabel(value: ConfigItem['state']): string { return ({ configured: '已配置', needs_verification: '待验证', not_configured: '未配置' })[value] }
function configStateClass(value: ConfigItem['state']): string { return value === 'configured' ? 'status-good' : value === 'not_configured' ? 'status-error' : 'status-warning' }
function auditActionLabel(value: string): string { return ({ 'admin.bootstrap': '创建管理员', 'admin.login.password': '管理员通过密码验证', 'admin.login.mfa': '管理员完成动态验证', 'admin.step_up': '管理员重新验证', 'admin.logout': '管理员退出', 'admin.user.view': '查看用户详情', 'admin.device.revoke': '撤销设备会话', 'admin.user.password.reset': '重置用户密码', 'admin.activation.batch.create': '生成兑换码批次', 'admin.activation.batch.import': '导入兑换码批次', 'admin.activation.code.revoke': '撤销未使用兑换码', activation_code_redeemed: '用户兑换高级权益', 'admin.restore_drill.record': '记录恢复演练', 'admin.announcement.create': '创建公告', 'admin.announcement.update': '更新公告', 'admin.announcement.activate': '上线公告', 'admin.announcement.deactivate': '下线公告', 'admin.announcement.delete': '删除公告', 'admin.changelog.create': '创建更新日志', 'admin.changelog.update': '更新日志条目', 'admin.changelog.delete': '删除更新日志', 'admin.changelog.publish': '发布更新日志', 'admin.changelog.unpublish': '撤下更新日志', 'admin.download.upload': '上传安装包', 'admin.download.activate': '开放下载', 'admin.download.deactivate': '暂停下载', 'admin.download.note': '更新下载说明', 'admin.user.disable': '封禁用户账号', 'admin.user.enable': '解封用户账号', 'admin.user.force_logout': '强制下线用户', 'admin.user.session.revoke': '撤销用户会话', 'admin.user.entitlement.grant': '直接授予权益', 'admin.user.entitlement.revoke': '撤销用户权益', 'admin.account.create': '创建管理员账号', 'admin.account.disable': '禁用管理员', 'admin.account.enable': '启用管理员', 'admin.account.totp_reset': '重置管理员验证器', 'admin.session.revoke': '撤销管理会话', 'admin.mail.retry': '重试邮件任务', 'admin.ratelimit.clear': '清零限流桶' } as Record<string,string>)[value] ?? value }
function backupLabel(value: string): string { return ({ unknown: '未接入', running: '进行中', success: '成功并已校验', failure: '失败' } as Record<string,string>)[value] ?? '未知状态' }
function backupHealthLabel(value?: string): string { return ({ fresh: '最近备份正常', stale: '备份已过期 / 任务未更新', failure: '最近备份失败', running: '备份进行中', unknown: '尚无异机备份记录' } as Record<string,string>)[value ?? 'unknown'] ?? '等待核对' }
function backupHealthClass(value?: string): string { return value === 'fresh' ? 'status-good' : value === 'failure' ? 'status-error' : 'status-warning' }
function backupClass(value: string): string { return value === 'success' ? 'status-good' : value === 'failure' ? 'status-error' : value === 'running' ? 'status-warning' : 'status-muted' }
function drillLabel(value: string): string { return value === 'success' ? '成功 · 已记录' : value === 'failure' ? '失败 · 已记录' : '尚未记录' }
function compactID(value: string): string { return value ? `${value.slice(0, 8)}…${value.slice(-4)}` : '—' }
function announcementLevelLabel(value: string): string { return ({ info: '通知', warn: '警告', critical: '严重' } as Record<string,string>)[value] ?? value }
function announcementLevelClass(value: string): string { return ({ info: 'status-good', warn: 'status-warning', critical: 'status-error' } as Record<string,string>)[value] ?? 'status-neutral' }
function announcementPlacementLabel(value: string): string { return ({ banner: '官网公告条', download: '下载区', both: '公告条 + 下载区' } as Record<string,string>)[value] ?? value }
function grantSourceLabel(value: string): string { return ({ activation_code: '激活码兑换', admin_grant: '管理员授予', admin_revoke: '管理员撤销' } as Record<string,string>)[value] ?? value }
function sessionStateLabel(row: UserSessionRow): string { return row.currently_valid ? '有效' : row.revoked_at ? '已撤销' : '已过期' }
function sessionStateClass(row: UserSessionRow): string { return row.currently_valid ? 'status-good' : 'status-muted' }
function durationLabel(ms: number): string { return ms > 0 ? elapsed(Math.round(ms / 1000)) : '—' }

async function refreshOverview() {
  if (!isAuthenticated.value || page.value !== 'overview' || loading.value || document.visibilityState !== 'visible') return
  await loadPage('overview')
}

function clearPrivateData() {
  pageRequest?.abort()
  detailRequest?.abort()
  codesRequest?.abort()
  auditRequest?.abort()
  readyPage.value = null
  updatedAt.value = ''
  loading.value = false
  detailLoading.value = false
  auditLoading.value = false
  codesLoading.value = false
  detailError.value = ''
  codesError.value = ''
  pageError.value = ''
  closeNavigation()
  pendingStepUp = null
  mailRequestKeys.clear(); mailDrafts.clear(); pendingMailIDs.clear(); loadedMailboxFilters.clear()
  closeMailPreview(); composeRecipientName.value = ''; replyRecipientName.value = ''; viewRecipientName.value = ''
  inboundQuery.value = ''; inboundStatusFilter.value = ''; feedbackQuery.value = ''; outboundQuery.value = ''; outboundStatusFilter.value = ''; outboundCursor.value = ''
  uploadController?.abort()
  uploadController = null
  deviceCursor.value = ''
  loadedDeviceFilter = ''
  loadedUserFilter = ''
  stepUpNeeded.value = false
  stepUpPassword.value = ''
  stepUpCode.value = ''
  userPasswordTarget.value = null
  userConfirmation.value=null;selectedUserIDs.value=[];userSummary.value=null;userActivity.value=[]
  userNewPassword.value = ''
  userRepeatPassword.value = ''
  userPasswordAdmin.value = ''
  userPasswordCode.value = ''
  replyBody.value = ''
  replyReauthPassword.value = ''
  replyReauthCode.value = ''
  viewReplyBody.value = ''
  viewReauthPassword.value = ''
  viewReauthCode.value = ''
  composeTo.value = ''
  composeSubject.value = ''
  composeBody.value = ''
  inboundUnread.value = 0
  feedbackUnread.value = 0
  announcements.value = []
  changelogEntries.value = []
  downloads.value = []
  admins.value = []
  adminSessionsList.value = []
  backupRuns.value = []
  stats.value = null
  rateLimitBuckets.value = []
  rlResult.value = ''
  rlValue.value = ''
  issuedTotpUri.value = ''
  issuedTotpSaved.value = false
  createAdminPassword.value = ''
  newAdminName.value = ''
  userPasswordError.value = ''
  userPasswordReauth.value = false
  userPasswordKey.value = ''
  replyError.value = ''
  viewError.value = ''
  dlFile.value = null
  dlVersion.value = ''
  dlNote.value = ''
  resetAnnForm()
  resetChangelogForm()
  detailUserID.value = ''
  userQuery.value = ''
  userStatus.value = ''
  userCursor.value = ''
  deviceQuery.value = ''
  deviceState.value = ''
  mailState.value = ''
  userSessionsList.value = []
  inboundMail.value = []
  inboundCursor.value = ''
  viewTarget.value = null
  feedbackMessages.value = []
  feedbackCursor.value = ''
  replyTarget.value = null
  outboundEmails.value = []
  revokeTarget.value = null
  password.value = ''
  mfaCode.value = ''
  reauthPassword.value = ''
  reauthCode.value = ''
  currentAdminPassword.value = ''
  newAdminPassword.value = ''
  newAdminPasswordConfirm.value = ''
  currentAdminTotp.value = ''
  activationStepUpPassword.value = ''
  activationStepUpCode.value = ''
  activationImportText.value = ''
  window.clearTimeout(toastTimer)
  toast.value = ''
  overview.value = null
  users.value = []
  selectedUser.value = null
  userDevices.value = []
  devices.value = []
  mailJobs.value = []
  securityEvents.value = []
  auditEvents.value = []
  operations.value = null
  configItems.value = []
  activationBatches.value = []
  activationCodes.value = []
  issuedActivationCodes.value = []
}

function handleExpired(error: unknown): boolean {
  if (error instanceof APIError && error.status === 401) {
    session.value = { authenticated: false }
    clearPrivateData()
    mfaStep.value = false
    mfaChallenge.value = ''
    authError.value = '管理员会话已过期，请重新登录。'
    return true
  }
  return false
}

async function loadSession() {
  authLoading.value = true
  authError.value = ''
  try {
    session.value = await api.get<AdminSession>('/auth/session')
    if (session.value.authenticated) await loadPage('overview')
  } catch {
    authError.value = '无法连接账号服务。请稍后重试，并检查服务状态。'
  } finally {
    authLoading.value = false
  }
}

async function submitLogin() {
  authError.value = ''
  busy.value = true
  try {
    const response = await api.post<{ challenge: string; next: string }>('/auth/login', {
      username: username.value,
      password: password.value,
    })
    mfaChallenge.value = response.challenge
    mfaCode.value = ''
    mfaStep.value = true
    password.value = ''
    await nextTick()
    document.getElementById('admin-mfa')?.focus()
  } catch (error) {
    authError.value = errorText(error, '账号或密码不正确，或者登录暂时不可用。')
  } finally {
    busy.value = false
  }
}

async function submitMfa() {
  authError.value = ''
  busy.value = true
  try {
    session.value = await api.post<AdminSession & { username: string }>('/auth/mfa', {
      challenge: mfaChallenge.value,
      code: mfaCode.value,
    })
    mfaStep.value = false
    mfaChallenge.value = ''
    mfaCode.value = ''
    session.value = await api.get<AdminSession>('/auth/session')
    await loadPage('overview')
  } catch (error) {
    authError.value = errorText(error, '动态验证码无效或登录请求已过期。')
  } finally {
    busy.value = false
  }
}

function returnToPassword() {
  mfaStep.value = false
  mfaChallenge.value = ''
  mfaCode.value = ''
  authError.value = ''
  void nextTick(() => document.getElementById('admin-name')?.focus())
}

async function signOut() {
  if (!canLeaveCodes()) return
  busy.value = true
  try {
    await api.post('/auth/logout')
  } catch (error) {
    if (!handleExpired(error)) {
      pageError.value = errorText(error, '无法安全结束管理员会话。')
      busy.value = false
      return
    }
  }
  session.value = { authenticated: false }
  clearPrivateData()
  page.value = 'overview'
  authError.value = ''
  revokeTarget.value = null
  busy.value = false
}

function errorText(error: unknown, fallback: string): string {
  if (error instanceof APIError && error.code === 'invalid_response') return '服务响应不完整，请刷新确认操作结果后再重试。'
  if (error instanceof APIError && error.code === 'invalid_filename') return '安装包文件名仅支持字母、数字、点、短横线和下划线，请重命名后重试。'
  if (error instanceof DOMException && error.name === 'TimeoutError') return '请求超时，请重试；正在编辑的内容会保留。'
  if (error instanceof APIError) {
    if (error.code === 'invalid_query') return '请输入至少 2 个字符的邮箱前缀、完整邮箱或完整用户 ID。'
    if (error.code === 'use_exact_email_or_user_id') return '请输入完整邮箱或完整用户 ID。'
    if (error.code === 'mail_job_not_retryable') return '该任务已结束、过期或正在处理，不能重新投递；请刷新状态。'
    if (error.code === 'user_not_found') return '该账号已不存在，请刷新用户列表。'
    if (error.status === 429) return '尝试次数过多，请稍候再试。'
    if (error.status === 403 && error.code === 'origin_rejected') return '管理页来源校验失败。请从 https://admin.flowriver.xyz 打开。'
    if (error.code === 'temporarily_unavailable') return '服务暂时不可用，请稍后重试。'
    return fallback
  }
  return fallback
}

async function loadPage(target: Page) {
  if (!isAuthenticated.value) return
  const changingPage = page.value !== target
  if (changingPage && !canLeaveCodes()) return
  closeNavigation()
  pageRequest?.abort()
  codesRequest?.abort()
  auditRequest?.abort()
  codesLoading.value = false
  auditLoading.value = false
  if (changingPage) {
    closeUser(false)
    readyPage.value = null
    updatedAt.value = ''
    issuedActivationCodes.value = []
    issuedCodesSaved.value = false
    issuedTotpUri.value = ''
    issuedTotpSaved.value = false
  }
  const request = new AbortController()
  pageRequest = request
  const get = <T,>(path: string) => api.get<T>(path, request.signal)
  const apply = (update: () => void) => {
    if (!request.signal.aborted && isAuthenticated.value && page.value === target) update()
  }
  page.value = target
  pageError.value = ''
  loading.value = true
  try {
    switch (target) {
      case 'overview': {
        const [summary, accountResult, dependencyResult, runState] = await Promise.all([
          get<Overview>('/overview'), get<{ users: UserRow[] }>('/users?limit=4'),
          get<{ items: ConfigItem[] }>('/config-status'), get<Operations>('/operations'),
        ])
        apply(() => {
          overview.value = summary
          users.value = accountResult.users
          configItems.value = dependencyResult.items
          operations.value = runState
        })
        break
      }
      case 'users': {
        const filter = userFilterSignature()
        const [result,summary] = await Promise.all([get<{ users: UserRow[]; next_cursor: string }>(`/users?${userParams()}`),get<NonNullable<typeof userSummary.value>>('/users/summary')])
        apply(() => { users.value = result.users; userCursor.value = result.next_cursor; loadedUserFilter = filter;userSummary.value=summary;selectedUserIDs.value=[] })
        break
      }
      case 'devices': {
        const filter = JSON.stringify([deviceQuery.value.trim(), deviceState.value])
        const result = await get<{ devices: DeviceRow[]; next_cursor: string }>(`/devices?${deviceParams()}`)
        apply(() => { devices.value = result.devices; deviceCursor.value = result.next_cursor; loadedDeviceFilter = filter })
        break
      }
      case 'mail': {
        const result = await get<{ jobs: MailJob[] }>('/mail-jobs?limit=80')
        apply(() => { mailJobs.value = result.jobs })
        break
      }
      case 'announcements': {
        const result = await get<{ announcements: Announcement[] }>('/announcements')
        apply(() => { announcements.value = result.announcements })
        break
      }
      case 'changelog': {
        const result = await get<{ entries: ChangelogEntry[] }>('/changelog')
        apply(() => { changelogEntries.value = result.entries })
        break
      }
      case 'downloads': {
        const result = await get<{ downloads: DownloadArtifact[]; storage_configured: boolean }>('/downloads')
        apply(() => { downloads.value = result.downloads; downloadStorageConfigured.value = result.storage_configured })
        break
      }
      case 'admins': {
        const [adminList, sessions] = await Promise.all([
          get<{ admins: AdminAccount[] }>('/admins'),
          get<{ sessions: AdminSessionRow[] }>('/admin-sessions'),
        ])
        apply(() => { admins.value = adminList.admins; adminSessionsList.value = sessions.sessions })
        break
      }
      case 'insights': {
        const [statsResult, buckets] = await Promise.all([
          get<StatsData>(`/stats?days=${statsDays.value}`),
          get<{ buckets: RateLimitBucket[] }>('/ratelimits/top'),
        ])
        apply(() => { stats.value = statsResult; rateLimitBuckets.value = buckets.buckets })
        break
      }
      case 'mailbox': {
        const filters = new Map(['inbound', 'feedback', 'outbound'].map(kind => [kind, mailboxFingerprint(kind as 'inbound' | 'feedback' | 'outbound')]))
        const [feedback, inbound, outbound] = await Promise.all([
          get<{ messages: FeedbackMessage[]; next_cursor: string; unread: number }>(`/mailbox/feedback?${mailboxParams('feedback')}`),
          get<{ messages: InboundMail[]; next_cursor: string; unread: number }>(`/mailbox/inbound?${mailboxParams('inbound')}`),
          get<{ messages: OutboundEmail[]; next_cursor: string }>(`/mailbox/outbound?${mailboxParams('outbound')}`),
        ])
        apply(() => {
          feedbackMessages.value = feedback.messages; feedbackCursor.value = feedback.next_cursor; feedbackUnread.value = feedback.unread
          inboundMail.value = inbound.messages; inboundCursor.value = inbound.next_cursor; inboundUnread.value = inbound.unread
          outboundEmails.value = outbound.messages; outboundCursor.value = outbound.next_cursor
          filters.forEach((value, key) => loadedMailboxFilters.set(key, value))
        })
        break
      }
      case 'activation': {
        const result = await get<{ batches: ActivationBatch[] }>('/activation/batches')
        const batchID = result.batches.some((batch) => batch.id === selectedActivationBatch.value) ? selectedActivationBatch.value : ''
        const codes = await get<{ codes: ActivationCode[] }>(`/activation/codes${batchID ? `?batch_id=${encodeURIComponent(batchID)}` : ''}`)
        apply(() => {
          activationBatches.value = result.batches
          selectedActivationBatch.value = batchID
          activationCodes.value = codes.codes
        })
        break
      }
      case 'security': {
        const [security, audit] = await Promise.all([
          get<{ events: SecurityEvent[] }>('/security-events?limit=60'),
          get<{ events: AuditEvent[]; next_before: number | null }>(`/audit?limit=30${auditParams()}`),
        ])
        apply(() => { securityEvents.value = security.events; auditEvents.value = audit.events; auditCursor.value = audit.next_before })
        break
      }
      case 'ops': {
        const [runState, backupHistory] = await Promise.all([
          get<Operations>('/operations'),
          get<{ runs: BackupRun[] }>('/backup-runs'),
        ])
        apply(() => { operations.value = runState; backupRuns.value = backupHistory.runs })
        break
      }
      case 'settings': {
        const result = await get<{ items: ConfigItem[] }>('/config-status')
        apply(() => { configItems.value = result.items })
        break
      }
    }
    apply(() => { readyPage.value = target; updatedAt.value = new Date().toISOString() })
  } catch (error) {
    if (!request.signal.aborted && !handleExpired(error)) pageError.value = errorText(error, '无法读取这组数据。请重试。')
  } finally {
    if (pageRequest === request) loading.value = false
  }
}

async function loadActivationData() {
  await loadPage('activation')
}

async function loadActivationCodes() {
  codesRequest?.abort()
  const request = new AbortController()
  codesRequest = request
  codesLoading.value = true
  codesError.value = ''
  try {
    const query = selectedActivationBatch.value ? `?batch_id=${encodeURIComponent(selectedActivationBatch.value)}` : ''
    const result = await api.get<{ codes: ActivationCode[] }>(`/activation/codes${query}`, request.signal)
    if (!request.signal.aborted && isAuthenticated.value && page.value === 'activation') activationCodes.value = result.codes
  } catch (error) {
    if (!request.signal.aborted && !handleExpired(error)) codesError.value = errorText(error, '无法读取兑换码，请重试。')
  } finally {
    if (codesRequest === request) codesLoading.value = false
  }
}

async function loadMoreAudit() {
  if (auditCursor.value === null || auditLoading.value || loading.value) return
  const request = new AbortController()
  auditRequest = request
  auditLoading.value = true
  try {
    const result = await api.get<{ events: AuditEvent[]; next_before: number | null }>(`/audit?limit=30&before=${auditCursor.value}${auditParams()}`, request.signal)
    if (!request.signal.aborted && isAuthenticated.value && page.value === 'security') {
      auditEvents.value = [...auditEvents.value, ...result.events]
      auditCursor.value = result.next_before
    }
  } catch (error) {
    if (!request.signal.aborted && !handleExpired(error)) pageError.value = errorText(error, '无法读取更早的操作记录。')
  } finally {
    if (auditRequest === request) auditLoading.value = false
  }
}

function activationError(error: unknown): string {
  if (handleExpired(error)) return ''
  if (error instanceof APIError && error.status === 403 && error.code === 'recent_mfa_required') {
    activationStepUpNeeded.value = true
    return '此操作需要重新输入管理员密码和新的动态验证码。'
  }
  if (error instanceof APIError && error.code === 'activation_code_exists') return '有兑换码已存在，未创建该批次。请检查输入后重试。'
  if (error instanceof APIError && error.code === 'activation_code_already_redeemed') return '已兑换的码保留历史记录，不能删除。'
  return errorText(error, '操作没有完成，请检查表单后重试。')
}

async function activationStepUp() {
  if (!activationStepUpNeeded.value) return
  await api.post('/auth/reauthenticate', { password: activationStepUpPassword.value, code: activationStepUpCode.value })
  activationStepUpNeeded.value = false
  activationStepUpPassword.value = ''
  activationStepUpCode.value = ''
}

async function createActivationBatch() {
  if (activationBusy.value || !canLeaveCodes()) return
  pageError.value = ''
  activationBusy.value = true
  try {
    await activationStepUp()
    const common = {
      label: activationLabel.value,
      product_code: activationProduct.value,
      duration_days: activationDurationDays.value,
      ...(activationExpiresAt.value ? { expires_at: shanghaiDateTimeToISO(activationExpiresAt.value) } : {}),
    }
    if (activationMode.value === 'import') {
      const codes = activationImportText.value.split(/[\s,;]+/).map((code) => code.trim()).filter(Boolean)
      const result = await api.post<{ batch: ActivationBatch }>('/activation/batches/import', { ...common, codes })
      selectedActivationBatch.value = result.batch.id
      activationImportText.value = ''
      issuedActivationCodes.value = []
      notify(`已导入 ${result.batch.total_codes} 个兑换码。系统只保留摘要，原始码不会保存。`)
    } else {
      const result = await api.post<{ batch: ActivationBatch; codes: IssuedActivationCode[] }>('/activation/batches', {
        ...common,
        count: activationCount.value,
      }, activationRequestKey.value)
      selectedActivationBatch.value = result.batch.id
      issuedActivationCodes.value = result.codes
      issuedCodesSaved.value = false
      activationRequestKey.value = crypto.randomUUID()
      notify('批次已生成。请立即复制或下载兑换码；关闭页面后服务端无法再次显示完整码。', 9000)
    }
    await loadActivationData()
    if (issuedActivationCodes.value.length) {
      await nextTick()
      document.querySelector('.code-list')?.closest('section')?.scrollIntoView({ block: 'start', behavior: 'smooth' })
    }
  } catch (error) {
    pageError.value = activationError(error)
  } finally {
    activationBusy.value = false
  }
}

async function revokeActivationCode(code: ActivationCode) {
  if (code.status !== 'unused') return
  pageError.value = ''
  activationBusy.value = true
  try {
    await activationStepUp()
    await api.delete(`/activation/codes/${encodeURIComponent(code.id)}`)
    await loadActivationData()
    notify(`尾号 ${code.suffix} 的未使用兑换码已撤销。`)
  } catch (error) {
    pageError.value = activationError(error)
  } finally {
    activationBusy.value = false
  }
}

function downloadActivationCodes() {
  if (!issuedActivationCodes.value.length) return
  const csv = ['code', ...issuedActivationCodes.value.map((item) => item.code)].join('\r\n')
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = 'flowriver-activation-codes.csv'
  link.click()
  window.setTimeout(() => URL.revokeObjectURL(url), 1000)
  issuedCodesSaved.value = true
  notify('已开始下载兑换码，请确认 CSV 文件已保存。')
}

function resetActivationRequestKey() {
  activationRequestKey.value = crypto.randomUUID()
}

function deviceParams(cursor = ''): URLSearchParams {
  const params = new URLSearchParams({ limit: '50' })
  if (deviceQuery.value.trim()) params.set('q', deviceQuery.value.trim())
  if (deviceState.value) params.set('state', deviceState.value)
  if (cursor) params.set('cursor', cursor)
  return params
}
async function searchDevices() { await loadPage('devices') }
async function resetDeviceFilters() { deviceQuery.value = ''; deviceState.value = ''; await searchDevices() }
async function loadMoreDevices() {
  if (JSON.stringify([deviceQuery.value.trim(), deviceState.value]) !== loadedDeviceFilter) { await searchDevices(); return }
  if (!deviceCursor.value || loading.value) return
  const request = new AbortController()
  pageRequest = request
  loading.value = true
  pageError.value = ''
  try {
    const result = await api.get<{ devices: DeviceRow[]; next_cursor: string }>(`/devices?${deviceParams(deviceCursor.value)}`, request.signal)
    if (!request.signal.aborted && isAuthenticated.value && page.value === 'devices') {
      const known = new Set(devices.value.map((item) => item.id))
      devices.value = [...devices.value, ...result.devices.filter((item) => !known.has(item.id))]
      deviceCursor.value = result.next_cursor
      updatedAt.value = new Date().toISOString()
    }
  } catch (error) { if (!request.signal.aborted && !handleExpired(error)) pageError.value = errorText(error, '更多设备没有读取成功，请重试。') }
  finally { if (pageRequest === request) loading.value = false }
}
function userParams(cursor = ''): URLSearchParams {
  const params = new URLSearchParams({ limit: '25' })
  if (userQuery.value.trim()) params.set('q', userQuery.value.trim())
  if (userStatus.value) params.set('status', userStatus.value)
  if(userPasswordFilter.value)params.set('password',userPasswordFilter.value)
  if(userProviderFilter.value)params.set('provider',userProviderFilter.value)
  if(userPremiumFilter.value)params.set('premium',userPremiumFilter.value)
  if(userActivityFilter.value)params.set('activity',userActivityFilter.value)
  if (cursor) params.set('cursor', cursor)
  return params
}

async function searchUsers() {
  selectedUserIDs.value=[];userTab.value='overview'
  closeUser(false)
  await loadPage('users')
}

async function resetUserFilters() {
  userQuery.value = ''
  userStatus.value = '';userPasswordFilter.value='';userProviderFilter.value='';userPremiumFilter.value='';userActivityFilter.value=''
  await searchUsers()
}

async function loadMoreUsers() {
  if (userFilterSignature() !== loadedUserFilter) { await searchUsers(); return }
  if (!userCursor.value || loading.value) return
  const request = new AbortController()
  pageRequest = request
  loading.value = true
  pageError.value = ''
  try {
    const result = await api.get<{ users: UserRow[]; next_cursor: string }>(`/users?${userParams(userCursor.value)}`, request.signal)
    if (!request.signal.aborted && isAuthenticated.value && page.value === 'users') {
      users.value = [...users.value, ...result.users]
      userCursor.value = result.next_cursor
      updatedAt.value = new Date().toISOString()
    }
  } catch (error) {
    if (!request.signal.aborted && !handleExpired(error)) pageError.value = errorText(error, '无法读取下一页。')
  } finally {
    if (pageRequest === request) loading.value = false
  }
}

async function navigateToUser(userID: string, event: MouseEvent) {
  const opener = event.currentTarget as HTMLElement | null
  await loadPage('users')
  if (page.value === 'users' && isAuthenticated.value) {
    detailOpener.value = opener
    await openUser(userID)
  }
}

async function openUser(userID: string, event?: MouseEvent) {
  detailRequest?.abort()
  const request = new AbortController()
  detailRequest = request
  if (event) { detailOpener.value = event.currentTarget as HTMLElement | null;userTab.value='overview' }
  detailUserID.value = userID
  selectedUser.value = null
  userDevices.value = []
  detailError.value = ''
  detailLoading.value = true
  await nextTick()
  document.getElementById('user-detail')?.focus({ preventScroll: true })
  const target = window.innerWidth <= 1400 ? document.getElementById('user-detail') : document.querySelector('.users-workspace')
  target?.scrollIntoView({block:'start',behavior:window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'})
  try {
    const [detail, deviceResult, sessionResult,activityResult] = await Promise.all([
      api.get<UserDetail>(`/users/${encodeURIComponent(userID)}`, request.signal),
      api.get<{ devices: DeviceRow[] }>(`/devices?user_id=${encodeURIComponent(userID)}&limit=100`, request.signal),
      api.get<{ sessions: UserSessionRow[] }>(`/users/${encodeURIComponent(userID)}/sessions`, request.signal),
      api.get<{events:typeof userActivity.value}>(`/users/${encodeURIComponent(userID)}/activity`,request.signal),
    ])
    if (request.signal.aborted || !isAuthenticated.value || page.value !== 'users') return
    selectedUser.value = {...detail,identities:detail.identities??[],entitlements:detail.entitlements??[],consents:detail.consents??[]}
    userDevices.value = deviceResult.devices
    userSessionsList.value = sessionResult.sessions
    userActivity.value=activityResult.events
  } catch (error) {
    if (!request.signal.aborted && !handleExpired(error)) detailError.value = errorText(error, '无法读取账号详情。请重试。')
  } finally {
    if (detailRequest === request) detailLoading.value = false
  }
}

function closeUser(restoreFocus = true) {
  detailRequest?.abort()
  selectedUser.value = null
  detailUserID.value = ''
  userDevices.value = []
  detailLoading.value = false
  detailError.value = ''
  if (restoreFocus) void nextTick(() => {
    if (detailOpener.value?.isConnected) detailOpener.value.focus()
    else document.getElementById('user-search')?.focus()
  })
}

function openRevoke(device: DeviceRow, event: MouseEvent) {
  revokeOpener.value = event.currentTarget as HTMLElement
  revokeTarget.value = device
  revokeReason.value = 'lost_device'
  idempotencyKey.value = crypto.randomUUID()
  reauthNeeded.value = false
  reauthPassword.value = ''
  reauthCode.value = ''
  void nextTick(() => document.getElementById('revoke-reason')?.focus())
}

function closeRevoke() {
  if (busy.value) return
  revokeTarget.value = null
  reauthNeeded.value = false
  reauthPassword.value = ''
  reauthCode.value = ''
  void nextTick(() => revokeOpener.value?.focus())
}

function cycleDialogFocus(event: KeyboardEvent) {
  if (event.key !== 'Tab') return
  const dialog = (event.currentTarget as HTMLElement | null)?.querySelector<HTMLElement>('.dialog')
  if (!dialog) return
  const items = [...dialog.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),a[href],[tabindex="0"]')].filter((item) => item.getClientRects().length > 0)
  if (!items.length) return
  const first = items[0]
  const last = items[items.length - 1]
  if (event.shiftKey && (document.activeElement === first || !dialog.contains(document.activeElement))) { event.preventDefault(); last.focus() }
  else if (!event.shiftKey && (document.activeElement === last || !dialog.contains(document.activeElement))) { event.preventDefault(); first.focus() }
}

async function submitRevoke() {
  if (!revokeTarget.value) return
  busy.value = true
  pageError.value = ''
  try {
    if (reauthNeeded.value) {
      await api.post('/auth/reauthenticate', { password: reauthPassword.value, code: reauthCode.value })
    }
    await api.post(`/devices/${encodeURIComponent(revokeTarget.value.id)}/revoke`, {
      reason_code: revokeReason.value,
    }, idempotencyKey.value)
    busy.value = false
    closeRevoke()
    notify('设备的账号服务会话已撤销。该操作不会删除设备上的本地资料。')
    if (page.value === 'users' && selectedUser.value) await openUser(selectedUser.value.id)
    else if (page.value === 'devices') await loadPage('devices')
  } catch (error) {
    if (error instanceof APIError && error.status === 403 && error.code === 'recent_mfa_required') {
      reauthNeeded.value = true
      return
    }
    if (!handleExpired(error)) pageError.value = errorText(error, '撤销没有完成。请检查实际状态后再试。')
  } finally {
    busy.value = false
  }
}

async function recordRestoreDrill(result: 'success' | 'failure') {
  try {
    await api.post('/operations/restore-drill', { result })
    notify('管理员报告的恢复演练结果已记录；服务器没有代为执行恢复。')
    operations.value = await api.get<Operations>('/operations')
  } catch (error) {
    if (!handleExpired(error)) pageError.value = errorText(error, '无法保存恢复演练记录。')
  }
}

async function retryMailJob(job: MailJob) {
  if (busy.value) return
  busy.value = true
  pageError.value = ''
  const run = async () => {
    await api.post(`/mail-jobs/${encodeURIComponent(job.id)}/retry`)
    await loadPage('mail')
    notify('邮件任务已重新排队，验证码在有效期内会再次投递。')
  }
  try {
    await run()
  } catch (error) {
    if (!requestStepUp(run, error) && !handleExpired(error)) pageError.value = errorText(error, '重试没有完成，请稍后再试。')
  } finally {
    busy.value = false
  }
}

async function changeAdminPassword() {
  pageError.value = ''
  if (newAdminPassword.value !== newAdminPasswordConfirm.value) {
    pageError.value = '两次输入的新密码不一致。'
    return
  }
  if (newAdminPassword.value.length < 12 || newAdminPassword.value.length > 128) {
    pageError.value = '新密码需要 12–128 个字符。'
    return
  }
  passwordBusy.value = true
  try {
    await api.post('/auth/reauthenticate', { password: currentAdminPassword.value, code: currentAdminTotp.value })
    await api.post('/auth/change-password', { current_password: currentAdminPassword.value, new_password: newAdminPassword.value })
    currentAdminPassword.value = ''
    newAdminPassword.value = ''
    newAdminPasswordConfirm.value = ''
    currentAdminTotp.value = ''
    session.value = await api.get<AdminSession>('/auth/session')
    notify('管理员密码已更改；其他管理会话已撤销。')
  } catch (error) {
    if (!handleExpired(error)) pageError.value = errorText(error, '密码未更改，请检查密码和动态验证码。')
  } finally {
    passwordBusy.value = false
  }
}
function agePercent(used: number, total: number): number {
  if (total <= 0) return 0
  return Math.max(0, Math.min(100, Math.round(used / total * 100)))
}

let overviewTimer = 0
onMounted(() => {
  try {
    const savedTheme = localStorage.getItem('flowriver-admin-theme')
    if (savedTheme === 'light' || savedTheme === 'dark') theme.value = savedTheme
  } catch { /* 使用系统外观 */ }
  document.documentElement.dataset.theme = theme.value
  document.addEventListener('pointerdown', closeNavigationOutside)
  document.addEventListener('fullscreenchange', syncFullscreen)
  window.addEventListener('beforeunload', protectIssuedCodes)
  void loadSession()
  overviewTimer = window.setInterval(() => { void refreshOverview() }, 60_000)
})
onUnmounted(() => {
  window.clearInterval(overviewTimer)
  window.clearTimeout(toastTimer)
  window.removeEventListener('beforeunload', protectIssuedCodes)
  document.removeEventListener('pointerdown', closeNavigationOutside)
  document.removeEventListener('fullscreenchange', syncFullscreen)
  document.body.style.overflow = ''
  pageRequest?.abort()
  detailRequest?.abort()
  codesRequest?.abort()
  auditRequest?.abort()
})
</script>

<template>
  <main v-if="authLoading" class="loading-screen" aria-live="polite">
    <span class="spinner" aria-hidden="true"></span><span>正在验证管理会话…</span>
  </main>

  <main v-else-if="!isAuthenticated" class="auth-page">
    <section class="auth-panel">
      <a class="auth-brand" href="#" aria-label="FlowRiver 管理台首页">
        <span class="brand-mark">F</span>
        <span><strong>FlowRiver</strong><small>账号服务管理</small></span>
      </a>
      <template v-if="session?.setup_required">
        <p class="eyebrow">首次设置</p>
        <h1>创建管理员账号</h1>
        <p class="auth-copy">安全地登录服务器，通过一次性引导命令创建管理账号。动态验证码种子只显示一次。</p>
        <pre class="command">sudo systemd-run --pty --wait --collect \
  -p User=flowriver \
  -p EnvironmentFile=/etc/flowriver/server.env \
  /opt/flowriver/bin/flowriver-api admin bootstrap YOUR_ADMIN_NAME</pre>
        <p class="muted">将命令中的 <code>YOUR_ADMIN_NAME</code> 换成 3–64 位管理员名。使用密码管理器保存密码和仅在引导时显示的验证器设置 URI。</p>
        <button class="button button-primary button-block" :disabled="busy" @click="loadSession">我已完成服务器设置，重新检查</button>
      </template>
      <template v-else>
        <p class="eyebrow">管理员工作区</p>
        <h1>{{ mfaStep ? '二次验证' : '登录管理控制台' }}</h1>
        <p class="auth-copy">只供获授权的管理员使用。每次登录都需要动态验证码。</p>
        <form v-if="!mfaStep" class="form-stack" @submit.prevent="submitLogin">
          <label for="admin-name">管理员账号</label>
          <input id="admin-name" v-model="username" class="input" autocomplete="username" required maxlength="64" autofocus />
          <label for="admin-password">密码</label>
          <input id="admin-password" v-model="password" class="input" type="password" autocomplete="current-password" required maxlength="128" />
          <button class="button button-primary button-block" :disabled="busy">{{ busy ? '验证中…' : '继续' }}</button>
        </form>
        <form v-else class="form-stack" @submit.prevent="submitMfa">
          <label for="admin-mfa">6 位验证器代码</label>
          <input id="admin-mfa" v-model="mfaCode" class="input code-input" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" minlength="6" maxlength="6" autofocus required />
          <button class="button button-primary button-block" :disabled="busy">{{ busy ? '验证中…' : '登录' }}</button>
          <button class="text-button" type="button" :disabled="busy" @click="returnToPassword">返回账号和密码</button>
        </form>
        <p v-if="authError" class="notice notice-error" role="alert">{{ authError }}</p><button v-if="authError && !session" class="button button-block" type="button" @click="loadSession">重新检查服务</button>
        <p class="muted auth-footnote">登录请求受到服务器限制；管理会话闲置 15 分钟后到期。</p>
      </template>
    </section>
    <div class="auth-ambient" aria-hidden="true">FLOWRIVER<br />ACCOUNT SERVICES</div>
  </main>

  <div v-else class="app-frame">
    <a class="skip-link" href="#main-content">跳到主要内容</a>
    <header class="topbar" :inert="Boolean(activeDialog)" @keydown.esc="closeNavigation(true)">
      <a class="brand-lockup" href="https://flowriver.xyz" target="_blank" rel="noopener" aria-label="在新标签页打开 FlowRiver 官网">
        <span class="brand-mark">F</span>
        <span class="brand-name"><strong>FlowRiver</strong><small>管理工作台</small></span>
      </a>
      <nav class="primary-nav" aria-label="管理导航">
        <button v-for="item in primaryNav" :key="item.id" type="button" class="nav-item" :disabled="interactionBusy" :class="{ selected: page === item.id }" :aria-current="page === item.id ? 'page' : undefined" @click="loadPage(item.id)">
          <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path v-for="(path, index) in navIcons[item.id]" :key="index" :d="path" /></svg><span>{{ item.label }}</span>
        </button>
        <button v-for="group in navGroups" :id="`nav-group-${group.id}`" :key="group.id" type="button" class="nav-item nav-group-trigger" :disabled="interactionBusy" :class="{ selected: group.pages.includes(page), expanded: openNavGroup === group.id }" :aria-expanded="openNavGroup === group.id" aria-controls="navigation-menu" @click="toggleNavigation(group.id)">
          <span>{{ group.label }}</span><svg class="chevron" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="m4 6 4 4 4-4" /></svg>
        </button>
      </nav>
      <div class="topbar-right">
        <button v-if="fullscreenSupported" class="theme-toggle" type="button" :aria-label="isFullscreen ? '退出全屏' : '进入全屏'" :title="isFullscreen ? '退出全屏' : '进入全屏'" @click="toggleFullscreen">
          <svg v-if="!isFullscreen" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 3H3v5M16 3h5v5M21 16v5h-5M8 21H3v-5" /></svg>
          <svg v-else viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 8h5V3M16 3v5h5M21 16h-5v5M8 21v-5H3" /></svg>
        </button>
        <button class="theme-toggle" type="button" :aria-label="theme === 'light' ? '切换深色外观' : '切换浅色外观'" :title="theme === 'light' ? '深色外观' : '浅色外观'" @click="toggleTheme">
          <svg v-if="theme === 'light'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20.8 13a9 9 0 0 1-9.8-9.8A9 9 0 1 0 20.8 13Z" /></svg>
          <svg v-else viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5" /></svg>
        </button>
        <span class="topbar-separator"></span>
        <button class="admin-menu" type="button" :disabled="interactionBusy" :aria-label="`退出管理员 ${session?.username ?? ''} 的会话`" @click="signOut">
          <span class="avatar">{{ (session?.username ?? 'A').slice(0, 1).toUpperCase() }}</span>
          <span class="account-menu-copy"><span class="admin-name">{{ session?.username }}</span><span class="signout-label">退出登录</span></span>
        </button>
      </div>
      <section v-if="activeNavGroup" id="navigation-menu" class="nav-dropdown" :aria-label="activeNavGroup.label">
        <div class="nav-dropdown-heading"><span>{{ activeNavGroup.label }}</span><button class="text-button" type="button" @click="closeNavigation(true)">收起</button></div>
        <div class="nav-dropdown-grid">
          <button v-for="item in nav.filter(item => activeNavGroup?.pages.includes(item.id))" :key="item.id" class="nav-item" type="button" :class="{ selected: page === item.id }" :aria-current="page === item.id ? 'page' : undefined" @click="loadPage(item.id)">
            <svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path v-for="(path, index) in navIcons[item.id]" :key="index" :d="path" /></svg><span>{{ item.label }}</span>
          </button>
        </div>
      </section>
    </header>

    <div class="shell" :inert="Boolean(activeDialog)">
      <main class="content" id="main-content" tabindex="-1" :aria-busy="loading">
        <div class="breadcrumbs"><span class="secure-dot" aria-hidden="true"></span><span>安全管理区</span><span aria-hidden="true">/</span><span>{{ activeHeading.title }}</span></div>
        <div class="page-title-row">
          <div><h1>{{ activeHeading.title }}</h1><p class="page-subtitle">{{ activeHeading.subtitle }}</p></div>
          <div class="page-actions">
            <span class="update-stamp"><span class="secure-dot" :class="{ 'stale-dot': pageError }"></span>{{ updatedAt ? `读取于 ${formatDate(updatedAt).split(' ')[1] ?? formatDate(updatedAt)}` : '等待读取' }}<small>UTC+8<span v-if="page === 'overview'"> · 每 60 秒更新</span></small></span>
            <button class="button refresh-button" type="button" :disabled="loading || interactionBusy || codesLoading || auditLoading" @click="loadPage(page)"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M20 7v5h-5M4 17v-5h5M6 7a7 7 0 0 1 12-1l2 2M18 17a7 7 0 0 1-12 1l-2-2" /></svg>{{ loading ? '更新中…' : '刷新' }}</button>
          </div>
        </div>

        <div v-if="toast" class="notice notice-success feedback" role="status" aria-live="polite"><span>{{ toast }}</span><button class="text-button" type="button" aria-label="关闭操作提示" @click="toast = ''">关闭</button></div>
        <div v-if="pageError" class="notice notice-error feedback" role="alert"><span>{{ pageError }}<small v-if="pageReady">仍显示上次读取的记录。</small></span><button class="button" type="button" :disabled="loading || interactionBusy" @click="loadPage(page)">重试</button></div>
        <div v-if="loading" class="inline-loading" role="status"><span class="spinner" aria-hidden="true"></span>{{ pageReady ? '正在更新，当前记录保留显示…' : '正在读取服务器数据…' }}</div>
        <div v-if="!pageReady && loading" class="loading-placeholder" aria-hidden="true"><span></span><span></span><span></span><span></span></div>

        <template v-if="pageReady && page === 'overview' && overview">
          <section class="stat-row" aria-label="账号服务指标">
            <div class="stat"><span>当前账号</span><strong>{{ overview.all_accounts }}</strong><small>{{ overview.active_accounts }} 个可用</small></div>
            <div class="stat"><span>有效会话</span><strong>{{ overview.active_sessions }}</strong><small>服务端当前可用</small></div>
            <div class="stat"><span>安全变更待处理</span><strong :class="{ 'value-warning': overview.pending_security > 0 }">{{ overview.pending_security }}</strong><small>{{ overview.oldest_security_at ? `最早 ${formatDate(overview.oldest_security_at)}` : '队列为空' }}</small></div>
            <div class="stat"><span>待发送邮件</span><strong>{{ overview.pending_mail }}</strong><small>{{ overview.failed_mail }} 个近期任务需核对</small></div>
          </section>
          <div class="column-layout">
            <section class="panel">
              <div class="panel-heading"><div><p class="eyebrow">需要跟进</p><h2>服务队列</h2></div><span class="update-label">{{ formatDate(overview.data_updated_at) }}</span></div>
              <button v-if="overview.pending_security" class="task-row" type="button" @click="loadPage('security')"><span class="task-mark task-warning"></span><span><strong>安全变更等待回执</strong><small>{{ overview.pending_security }} 个事件尚未确认</small></span><span class="row-link">查看事件</span></button>
              <button v-if="overview.failed_mail" class="task-row" type="button" @click="loadPage('mail')"><span class="task-mark task-error"></span><span><strong>邮件任务需要检查</strong><small>{{ overview.failed_mail }} 个近期任务失败或待确认</small></span><span class="row-link">查看队列</span></button>
              <button class="task-row" type="button" @click="loadPage('ops')"><span class="task-mark" :class="operations?.backup.health === 'fresh' ? 'task-good' : 'task-warning'"></span><span><strong>最近备份</strong><small>{{ operations?.backup.updated_at ? `${formatDate(operations.backup.updated_at)} · ${backupHealthLabel(operations.backup.health)}` : '尚无异机备份记录，需配置独立存储' }}</small></span><span class="row-link">运行状态</span></button>
              <p v-if="overview.pending_security === 0 && overview.failed_mail === 0" class="empty-inline">当前没有待处理的安全事件或需核对的近期邮件任务。</p>
            </section>
            <section class="panel">
              <div class="panel-heading"><div><p class="eyebrow">服务依赖</p><h2>运行状态</h2></div><button class="text-button" @click="loadPage('settings')">依赖详情</button></div>
              <div class="service-line"><span>账号 API / PostgreSQL</span><span class="status-tag" :class="serviceReady ? 'status-good' : 'status-warning'">{{ serviceReady ? '就绪' : '待检查' }}</span></div>
              <div v-for="item in configItems" :key="item.name" class="service-line"><span>{{ item.name }}</span><span class="status-tag" :class="configStateClass(item.state)">{{ configStateLabel(item.state) }}</span></div>
              <p class="muted compact-note">应用就绪只检查数据库；邮件、Apple 与异机安全日志须各自验证。</p>
            </section>
          </div>
          <section class="panel recent-users">
            <div class="panel-heading"><div><p class="eyebrow">最近创建</p><h2>账号记录</h2></div><button class="text-button" @click="loadPage('users')">浏览全部用户</button></div>
            <div v-if="users.length" class="recent-user-list"><button v-for="user in users.slice(0, 4)" :key="user.id" type="button" class="recent-user" @click="navigateToUser(user.id, $event)"><span><strong>{{ user.email || '无已绑定邮箱' }}</strong><small>{{ user.providers.map(displayIdentity).join(' + ') || '无有效身份' }}</small></span><span class="status-tag" :class="userStatusClass(user.disabled ? 'disabled' : user.status)">{{ displayUserStatus(user.status) }}</span><span class="row-link">详情</span></button></div>
            <p v-else class="empty-inline">尚无账号记录。</p>
          </section>
        </template>

        <template v-if="pageReady && page === 'users'">
        <section class="users-neu" aria-label="用户管理工作区">
          <div class="user-workspace-intro"><div><p class="eyebrow">ACCOUNT WORKSPACE</p><h2>账号工作区</h2><p>查找账号、核对登录与权益，在一处完成处理。</p></div><button class="button" :disabled="!users.length || loading" @click="exportUsers">导出{{ selectedUserIDs.length ? `选中 ${selectedUserIDs.length} 个` : '已加载账号' }}</button></div>
          <div v-if="userSummary" class="user-summary" aria-label="全部账号统计">
            <button v-for="metric in [{id:'total',label:'全部账号',value:userSummary.total},{id:'active',label:'正常账号',value:userSummary.active},{id:'recent',label:'近 7 天活动',value:userSummary.recent},{id:'premium',label:'有效高级权益',value:userSummary.premium}]" :key="metric.id" class="user-stat" :disabled="loading" @click="quickUserFilter(metric.id)"><span>{{ metric.label }}</span><strong>{{ metric.value.toLocaleString() }}</strong><small>{{ metric.id === 'total' ? '查看全部' : '点击筛选' }} ↗</small></button>
          </div>
          <p class="user-data-note">统计覆盖全部账号。最近活动是服务请求时间，不代表当前在线。</p>
          <form class="filter-bar user-search-well" @submit.prevent="searchUsers">
            <label class="search-field"><span>查询账号</span><input id="user-search" v-model="userQuery" type="search" class="input" placeholder="邮箱前缀、完整邮箱或用户 ID" autocomplete="off" :disabled="loading" /></label>
            <label class="select-field"><span>账号状态</span><select v-model="userStatus" class="input select" :disabled="loading" @change="searchUsers"><option value="">全部状态</option><option value="active">正常</option><option value="disabled">已封禁</option><option value="deleting">删除处理中</option><option value="recovery_required">需要恢复</option></select></label>
            <button class="button button-primary" :disabled="loading">查询</button><button v-if="hasUserFilter" class="button" type="button" :disabled="loading" @click="resetUserFilters">清除条件</button>
            <button class="button" type="button" :aria-expanded="showUserFilters" @click="showUserFilters=!showUserFilters">组合筛选{{ showUserFilters ? ' −' : ' +' }}</button>
            <span class="filter-hint">支持邮箱前缀模糊搜索（至少 2 个字符）；列表邮箱脱敏，完整地址在详情中查看。</span>
          </form>
          <div v-if="showUserFilters" class="user-advanced-filters">
            <label>登录身份<select v-model="userProviderFilter" class="input select" @change="searchUsers"><option value="">全部身份</option><option value="email">邮箱</option><option value="apple">Apple</option></select></label>
            <label>密码状态<select v-model="userPasswordFilter" class="input select" @change="searchUsers"><option value="">全部密码状态</option><option value="set">已设置</option><option value="unset">未设置</option></select></label>
            <label>高级权益<select v-model="userPremiumFilter" class="input select" @change="searchUsers"><option value="">全部权益</option><option value="active">当前有效</option><option value="none">无有效权益</option></select></label>
            <label>最近活动<select v-model="userActivityFilter" class="input select" @change="searchUsers"><option value="">全部活动</option><option value="recent">近 7 天有活动</option><option value="inactive">近 7 天无活动</option></select></label>
          </div>
          <div v-if="userFilterChips.length" class="user-filter-chips" aria-label="当前筛选"><button v-for="chip in userFilterChips" :key="chip.key" type="button" :disabled="loading" :aria-label="`清除筛选 ${chip.label}`" @click="removeUserFilter(chip.key)">{{ chip.label }} <span aria-hidden="true">×</span></button></div>
          <div v-if="selectedUserIDs.length" class="user-selection-bar" role="status"><strong>已选中 {{ selectedUserIDs.length }} 个账号</strong><button class="text-button" @click="exportUsers">导出选中</button><button class="text-button" @click="selectedUserIDs=[]">取消选择</button></div>
          <div class="users-workspace" :class="{ 'with-detail': detailUserID }">
          <div class="user-list-area" :aria-busy="loading">
          <div class="table-shell" tabindex="0" :aria-label="activeHeading.title + '记录，可横向滚动'"><table class="data-table"><thead><tr><th><input type="checkbox" :checked="allUsersSelected" :indeterminate="selectedUserIDs.length > 0 && !allUsersSelected" aria-label="选择全部已加载账号" @change="toggleAllUsers" /></th><th>账号</th><th>状态与登录</th><th>设备 / 会话</th><th>最近活动</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
            <tr v-for="user in users" :key="user.id" :class="{ 'selected-row': detailUserID === user.id }"><td><input type="checkbox" :checked="selectedUserIDs.includes(user.id)" :aria-label="`选择账号 ${user.email || user.id}`" @change="toggleUserSelection(user.id)" /></td><td><button class="table-link" @click="openUser(user.id, $event)" :aria-expanded="detailUserID === user.id" aria-controls="user-detail">{{ user.email || '无已绑定邮箱' }}</button><small class="id-preview">{{ compactID(user.id) }}</small></td><td><span class="status-tag" :class="userStatusClass(user.disabled ? 'disabled' : user.status)">{{ displayUserStatus(user.disabled ? 'disabled' : user.status) }}</span><span v-if="user.disabled && user.status !== 'active'" class="status-tag status-error">已封禁</span><small class="user-login-meta">{{ user.password_enabled ? '密码已设置' : '验证码登录' }} · {{ user.premium ? '高级权益' : '普通账号' }}</small></td><td class="numeric">{{ user.device_count }} <small>/ {{ user.session_count }} 有效</small></td><td>{{ formatDate(user.last_activity_at) }}</td><td><button class="text-button" @click="openUser(user.id, $event)" :aria-expanded="detailUserID === user.id" aria-controls="user-detail">查看</button></td></tr>
            <tr v-if="!users.length"><td colspan="6" class="empty-cell">{{ hasUserFilter ? '没有符合条件的账号，请检查完整邮箱或 ID，或清除筛选条件。' : '还没有账号记录。用户完成首次登录后会显示在这里。' }}</td></tr>
          </tbody></table></div>
          <div class="table-footer"><span>已加载 {{ users.length }} 个 · 按注册时间从新到旧</span><button v-if="userCursor" class="button" :disabled="loading" @click="loadMoreUsers">{{ loading ? '正在加载…' : '继续加载' }}</button></div>
          </div>
          <section v-if="detailUserID" id="user-detail" class="detail-panel user-inspector" tabindex="-1" aria-label="用户详情" :aria-busy="detailLoading" @keydown.esc="closeUser()">
            <div v-if="detailLoading || detailError" class="detail-heading"><h2>用户详情</h2><button class="icon-button" type="button" aria-label="关闭用户详情" @click="closeUser()">关闭</button></div>
            <div v-if="detailLoading" class="inline-loading" role="status"><span class="spinner" aria-hidden="true"></span>正在读取身份与设备…</div>
            <div v-if="detailError" class="notice notice-error" role="alert"><p>{{ detailError }}</p><button class="button" type="button" @click="openUser(detailUserID)">重试详情</button></div>
            <template v-if="selectedUser">
            <div class="detail-heading"><div><p class="eyebrow">用户详情 · 已记录管理员访问</p><h2>{{ selectedUser.identities.find((identity) => identity.provider === 'email')?.email || '未绑定邮箱' }}</h2><code>{{ selectedUser.id }}</code></div><button class="icon-button" aria-label="关闭用户详情" @click="closeUser()">关闭</button></div>
            <dl class="detail-grid"><div><dt>账号状态</dt><dd><span class="status-tag" :class="userStatusClass(selectedUser.disabled ? 'disabled' : selectedUser.status)">{{ displayUserStatus(selectedUser.disabled ? 'disabled' : selectedUser.status) }}</span><span v-if="selectedUser.disabled && selectedUser.status !== 'active'" class="status-tag status-error">已封禁</span></dd></div><div><dt>注册时间</dt><dd>{{ formatDate(selectedUser.created_at) }}</dd></div><div><dt>绑定身份</dt><dd>{{ selectedUser.identities.map((identity) => displayIdentity(identity.provider)).join(' + ') || '无' }}</dd></div></dl>
            <div v-if="selectedUser.disabled" class="context-note">该账号已于 {{ formatDate(selectedUser.disabled_at) }} 被封禁，原因：{{ selectedUser.disabled_reason || '—' }}。封禁期间所有登录与令牌立即失效。</div>
            <div class="user-detail-tools"><button class="text-button" @click="copyUserID(selectedUser.id)">复制用户 ID</button><button class="text-button" :disabled="detailLoading" @click="openUser(selectedUser.id)">刷新详情</button></div>
            <div class="user-detail-tabs" role="tablist" aria-label="账号详情" @keydown="userTabKeys"><button v-for="tab in userTabs" :id="`user-tab-${tab.id}`" :key="tab.id" role="tab" :aria-selected="userTab===tab.id" :aria-controls="`user-panel-${tab.id}`" :tabindex="userTab===tab.id?0:-1" @click="userTab=tab.id">{{ tab.label }}</button></div>
            <section v-if="userTab==='overview'" id="user-panel-overview" role="tabpanel" aria-labelledby="user-tab-overview">
              <div class="user-overview-facts"><div><span>已注册</span><strong>{{ Math.max(0,Math.floor((Date.now()-Date.parse(selectedUser.created_at))/86400000)) }} 天</strong></div><div><span>设备记录</span><strong>{{ userDevices.length }}</strong></div><div><span>有效会话</span><strong>{{ userSessionsList.filter(row=>row.currently_valid).length }}</strong></div><div><span>登录密码</span><strong>{{ selectedUser.password_enabled ? '已设置' : '未设置' }}</strong></div></div>
              <p class="context-note">账号服务管理登录与权益。用户日记保存在用户设备，此处不展示日记内容。</p>
            <h3>登录身份</h3><div v-for="identity in selectedUser.identities" :key="identity.id" class="detail-row"><div><strong>{{ displayIdentity(identity.provider) }}</strong><small>{{ identity.email || 'Apple 私人身份标识' }} · 验证于 {{ formatDate(identity.verified_at) }}</small></div><span class="status-tag" :class="identity.status === 'active' ? 'status-good' : 'status-muted'">{{ identity.status === 'active' ? '有效' : '已撤销' }}</span></div>
            <h3>条款记录</h3><div v-for="consent in selectedUser.consents" :key="`${consent.terms_version}-${consent.accepted_at}`" class="detail-row"><div><strong>{{ consent.terms_version }} / {{ consent.privacy_version }}</strong><small>{{ consent.source }} · {{ formatDate(consent.accepted_at) }}</small></div></div>
            </section>
            <section v-if="userTab==='access'" id="user-panel-access" role="tabpanel" aria-labelledby="user-tab-access">
            <h3>登录密码</h3>
            <div class="detail-row"><div><strong>{{ selectedUser.password_enabled ? '已设置密码' : '尚未设置密码' }}</strong><small>最近更新：{{ formatDate(selectedUser.password_updated_at) }}</small></div><span class="status-tag" :class="selectedUser.password_enabled ? 'status-good' : 'status-muted'">{{ selectedUser.password_enabled ? '可用' : '未设置' }}</span></div>
            <p class="muted compact-note">密码仅保存加密摘要，无法查看原密码。重置会撤销该用户所有旧会话。</p>
            <button id="user-password-open" class="button button-danger-outline" :disabled="interactionBusy || selectedUser.status !== 'active' || !selectedUser.identities.some(identity => identity.provider === 'email' && identity.status === 'active')" @click="openUserPassword(selectedUser)">重置用户密码</button>
            <h3>账号操作</h3>
            <div class="detail-row"><div><strong>操作原因（写入审计）</strong><small>封禁会立即撤销全部会话；解封后可重新登录。</small></div></div>
            <div class="row-actions">
              <select aria-label="账号操作原因" v-model="moderationReason" class="input select" style="max-width:180px"><option value="user_request">用户申请</option><option value="suspicious_activity">可疑活动</option><option value="policy_violation">违反条款</option><option value="other">其他</option></select>
              <button v-if="!selectedUser.disabled" class="button button-danger-outline" :disabled="interactionBusy || selectedUser.status !== 'active'" @click="userAction(`/users/${encodeURIComponent(selectedUser.id)}/disable`, '账号已封禁，全部会话已撤销。')">封禁账号</button>
              <button v-else class="button" :disabled="interactionBusy" @click="userAction(`/users/${encodeURIComponent(selectedUser.id)}/enable`, '账号已解封。')">解除封禁</button>
              <button class="button button-danger-outline" :disabled="interactionBusy" @click="userAction(`/users/${encodeURIComponent(selectedUser.id)}/force-logout`, '该用户全部会话已强制下线。')">强制下线全部会话</button>
            </div>
            </section>
            <section v-if="userTab==='entitlements'" id="user-panel-entitlements" role="tabpanel" aria-labelledby="user-tab-entitlements">
            <h3>权益 <span class="count-label">{{ selectedUser.entitlements.length }}</span></h3>
            <p v-if="!selectedUser.entitlements.length" class="empty-inline">该账号当前没有权益记录。</p>
            <div v-for="item in selectedUser.entitlements" :key="item.product_code" class="detail-row"><div><strong><code>{{ item.product_code }}</code></strong><small>{{ grantSourceLabel(item.grant_source) }} · {{ item.expires_at ? `有效期至 ${formatDate(item.expires_at)}` : '永久有效' }} · 更新于 {{ formatDate(item.updated_at) }}</small></div><button class="button button-danger-outline" :disabled="interactionBusy" @click="revokeEntitlement(item)">撤销</button></div>
            <div class="row-actions">
              <input aria-label="权益产品代码" v-model="entProduct" class="input" style="max-width:200px" placeholder="产品代码 riverdiary_premium" />
              <select aria-label="权益时长" v-model.number="entDuration" class="input select" style="max-width:130px"><option value="permanent">永久</option><option :value="7">7 天</option><option :value="30">30 天</option><option :value="90">90 天</option><option :value="365">365 天</option></select>
              <button class="button" :disabled="interactionBusy" @click="grantEntitlement">授予 / 延长权益</button>
            </div>
            <p class="muted compact-note">直接授予会覆盖同产品现有有效期（永久 = 不设到期时间），并记录来源为管理员授予。</p>
            </section>
            <section v-if="userTab==='devices'" id="user-panel-devices" role="tabpanel" aria-labelledby="user-tab-devices">
            <h3>设备与会话 <span class="count-label">{{ userDevices.length }}</span></h3><p v-if="!userDevices.length" class="empty-inline">该账号还没有设备记录。</p><div v-for="device in userDevices" :key="device.id" class="detail-row"><div><strong>{{ device.display_name || device.platform }} · {{ device.platform }}</strong><small>最近活动 {{ formatDate(device.last_seen_at) }} · {{ device.active_sessions }} 个有效会话</small></div><button v-if="!device.revoked_at && device.user_status === 'active'" class="button button-danger-outline" @click="openRevoke(device, $event)">撤销登录</button><span v-else class="status-tag" :class="device.revoked_at ? 'status-muted' : 'status-warning'">{{ device.revoked_at ? '已撤销' : '账号不可登录' }}</span></div>
            <p class="muted compact-note">撤销只使 FlowRiver 账号服务会话失效，不会删除本地日记，也不能撤回旧 iCloud 同步密钥。</p>
            <h3>会话记录 <span class="count-label">{{ userSessionsList.length }}</span></h3>
            <p v-if="!userSessionsList.length" class="empty-inline">该账号还没有会话记录。</p>
            <div v-for="row in userSessionsList" :key="row.id" class="detail-row"><div><strong>{{ row.device_name || row.platform || '未知设备' }} · {{ row.platform || '—' }}</strong><small>创建 {{ formatDate(row.created_at) }} · 最近活动 {{ formatDate(row.last_seen_at) }} · 空闲到期 {{ formatDate(row.idle_expires_at) }}</small></div><div class="row-actions"><span class="status-tag" :class="sessionStateClass(row)">{{ sessionStateLabel(row) }}</span><button v-if="row.currently_valid && selectedUser" class="button button-danger-outline" :disabled="interactionBusy" @click="userAction(`/users/${encodeURIComponent(selectedUser.id)}/sessions/${encodeURIComponent(row.id)}/revoke`, '该会话已撤销。')">撤销</button></div></div>
            </section>
            <section v-if="userTab==='activity'" id="user-panel-activity" role="tabpanel" aria-labelledby="user-tab-activity"><h3>最近 100 条账号与管理活动</h3><p v-if="!userActivity.length" class="empty-inline">暂时没有活动记录。</p><ol class="user-activity-list"><li v-for="(event,index) in userActivity" :key="`${event.created_at}-${index}`"><span class="user-activity-dot"></span><div><strong>{{ accountActivityLabel(event.kind) }}</strong><small>{{ event.source==='administrator' ? '管理员操作' : '账号服务' }}{{ event.reason_code ? ` · ${userReasonLabel(event.reason_code)}` : '' }}</small><time>{{ formatDate(event.created_at) }}</time></div></li></ol></section>
            </template>
          </section>
          </div>
        </section>
        </template>

        <template v-if="pageReady && page === 'devices'">
          <form class="filter-bar" @submit.prevent="searchDevices">
            <label class="search-field"><span>搜索全部设备</span><input v-model="deviceQuery" type="search" class="input" placeholder="设备名称、平台、账号或 ID" /></label>
            <label class="select-field"><span>登录状态</span><select v-model="deviceState" class="input select" @change="searchDevices"><option value="">全部设备</option><option value="active">可登录</option><option value="revoked">已撤销</option></select></label>
            <button class="button" type="submit" :disabled="loading || interactionBusy">搜索</button><button v-if="deviceQuery || deviceState" class="button" type="button" @click="resetDeviceFilters">清除条件</button>
          </form>
          <div class="context-note">最近活动来自服务端请求记录，不代表设备当前在线。撤销只作用于账号服务会话。</div>
          <div class="table-shell" tabindex="0" :aria-label="activeHeading.title + '记录，可横向滚动'"><table class="data-table"><thead><tr><th>设备</th><th>所属账号</th><th>账号状态</th><th>有效会话</th><th>最近活动</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
            <tr v-for="device in visibleDevices" :key="device.id"><td><strong>{{ device.display_name || device.platform }}</strong><small>{{ device.platform }} · {{ compactID(device.id) }}</small></td><td><button class="table-link" @click="navigateToUser(device.user_id, $event)">{{ device.user_email || compactID(device.user_id) }}</button></td><td><span class="status-tag" :class="userStatusClass(device.user_disabled ? 'disabled' : device.user_status)">{{ displayUserStatus(device.user_disabled ? 'disabled' : device.user_status) }}</span></td><td class="numeric">{{ device.active_sessions }}</td><td>{{ formatDate(device.last_seen_at) }}</td><td><button v-if="!device.revoked_at && device.user_status === 'active'" class="button button-danger-outline" @click="openRevoke(device, $event)">撤销</button><span v-else class="status-tag status-muted">{{ device.revoked_at ? '已撤销' : '不可登录' }}</span></td></tr>
            <tr v-if="!visibleDevices.length"><td colspan="6" class="empty-cell">{{ devices.length ? '当前筛选没有匹配的设备。' : '尚无服务设备记录。' }}</td></tr>
          </tbody></table></div>
          <p class="muted compact-note">显示 {{ visibleDevices.length }} / {{ devices.length }} 台已加载设备（最多最新 100 台）。查看账号详情可查询该账号设备。</p>
        <div class="pagination-bar"><span class="muted">已加载 {{ devices.length }} 个符合条件的设备</span><button v-if="deviceCursor" class="button" :disabled="loading || interactionBusy" @click="loadMoreDevices">{{ loading ? '读取中…' : '加载更多设备' }}</button></div>
        </template>

        <template v-if="pageReady && page === 'mail'">
          <div class="filter-bar"><label class="select-field"><span>邮件任务状态</span><select v-model="mailState" class="input select"><option value="">全部任务</option><option value="attention">需要检查（重试 / 失败 / 待确认）</option><option value="queued">排队中</option><option value="handed_to_smtp">已交给 SMTP</option><option value="expired">已过期</option><option value="cancelled">已作废</option><option value="delivery_unconfirmed">结果待确认</option></select></label><span class="filter-hint">显示 {{ visibleMailJobs.length }} / {{ mailJobs.length }} 条已加载记录，最多最近 80 条。</span></div>
          <div class="context-note">任务状态为 {{ '已交给 SMTP' }} 时只表示发信服务器接受了邮件，不表示收件箱已送达。此页不显示验证码、邮件正文或密码。</div>
          <div class="table-shell" tabindex="0" :aria-label="activeHeading.title + '记录，可横向滚动'"><table class="data-table"><thead><tr><th>任务 ID</th><th>状态</th><th>已尝试</th><th>下次处理 / 完成</th><th>错误类别</th><th>有效期</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
            <tr v-for="job in visibleMailJobs" :key="job.id"><td><code>{{ compactID(job.id) }}</code></td><td><span class="status-tag" :class="mailStatusClass(job.status)">{{ displayMail(job.status) }}</span></td><td class="numeric">{{ job.attempts }}</td><td>{{ formatDate(job.completed_at || job.available_at) }}</td><td>{{ job.error_code || '—' }}</td><td>{{ formatDate(job.expires_at) }}</td><td><button v-if="job.status === 'waiting_retry' && job.error_code === 'email_delivery_failed' && Date.parse(job.expires_at) > Date.now()" class="button button-danger-outline" :disabled="interactionBusy" @click="retryMailJob(job)">重试</button></td></tr>
            <tr v-if="!visibleMailJobs.length"><td colspan="7" class="empty-cell">{{ mailJobs.length ? '当前状态下没有邮件任务。' : '没有近期邮件任务记录。' }}</td></tr>
          </tbody></table></div>
          <p class="muted compact-note">重试仅适用于仍有效、等待再次投递的任务，不延长验证码有效期。已过期、已作废、最终失败或结果待确认的任务保留原记录；需要新的验证码时，请从登录页重新申请。</p>
        </template>

        <template v-if="pageReady && page === 'mailbox'">
          <nav class="mailbox-tabs" aria-label="邮件工作区"><button class="button" :class="{ 'button-primary': mailboxTab === 'inbound' }" @click="mailboxTab = 'inbound'">收件箱 <span v-if="inboundUnread">{{ inboundUnread }}</span></button><button class="button" :class="{ 'button-primary': mailboxTab === 'feedback' }" @click="mailboxTab = 'feedback'">用户反馈 <span v-if="feedbackUnread">{{ feedbackUnread }}</span></button><button class="button" :class="{ 'button-primary': mailboxTab === 'compose' }" @click="mailboxTab = 'compose'">写邮件</button><button class="button" :class="{ 'button-primary': mailboxTab === 'outbound' }" @click="mailboxTab = 'outbound'">发送历史</button></nav>
          <section v-if="mailboxTab === 'inbound'" class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">发往 @mail.flowriver.xyz 的全部邮件</p><h2>邮件收件箱</h2></div><span class="status-tag" :class="inboundUnread > 0 ? 'status-warning' : 'status-good'">{{ inboundUnread > 0 ? `${inboundUnread} 封未读` : '没有未读' }}</span></div>
            <form class="filter-bar" @submit.prevent="searchMailbox"><label class="search-field"><span>搜索来信</span><input v-model="inboundQuery" class="input" type="search" maxlength="200" placeholder="发件人、主题或正文" /></label><label class="select-field"><span>状态</span><select v-model="inboundStatusFilter" class="input select" @change="searchMailbox"><option value="">全部</option><option value="new">未读</option><option value="read">已读</option><option value="replied">已回复</option></select></label><button class="button" :disabled="loading">搜索</button></form>
            <div class="table-shell embedded-table" tabindex="0" aria-label="邮件收件箱，可横向滚动"><table class="data-table"><thead><tr><th><span class="sr-only">状态</span></th><th>发件人</th><th>主题</th><th>正文预览</th><th>时间</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="item in inboundMail" :key="item.id" :class="{ 'selected-row': viewTarget?.id === item.id }"><td><span class="status-tag" :class="inboundStatusClass(item.status)">{{ inboundStatusLabel(item.status) }}</span></td><td><strong :style="item.status === 'new' ? 'font-weight:800' : ''">{{ inboundSenderName(item) }}</strong><small>{{ item.from_addr }}</small></td><td><strong>{{ item.subject || '（无主题）' }}</strong></td><td><small>{{ item.text_body.slice(0, 60).replace(/\r?\n/g, ' ') }}{{ item.text_body.length > 60 ? '…' : '' }}</small></td><td>{{ formatDate(item.created_at) }}</td><td><div class="row-actions"><button class="button" :disabled="inboundBusy" @click="openInboundMail(item)">查看</button><button class="text-button" :disabled="inboundBusy" @click="deleteInboundMail(item)">删除</button></div></td></tr>
              <tr v-if="!inboundMail.length"><td colspan="6" class="empty-cell">收件箱是空的。任何发往 account@mail.flowriver.xyz 的邮件都会出现在这里。</td></tr>
            </tbody></table></div>
            <div class="table-footer"><span>显示 {{ inboundMail.length }} 封</span><button v-if="inboundCursor" class="button" :disabled="loading" @click="loadMoreMailbox('inbound')">{{ loading ? '正在加载…' : '加载更早邮件' }}</button></div>
          </section>

          <section v-if="mailboxTab === 'feedback'" class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">来自官网反馈表单</p><h2>用户反馈收件箱</h2></div><span class="status-tag" :class="feedbackUnread > 0 ? 'status-warning' : 'status-good'">{{ feedbackUnread > 0 ? `${feedbackUnread} 条未读` : '没有未读' }}</span></div>
            <form class="filter-bar" @submit.prevent="searchFeedback">
              <label class="search-field"><span>搜索反馈</span><input v-model="feedbackQuery" class="input" type="search" maxlength="200" placeholder="联系邮箱、主题或内容" /></label><button class="button" :disabled="loading">搜索</button><label class="select-field"><span>反馈状态</span><select v-model="feedbackStatusFilter" class="input select" @change="searchFeedback"><option value="">全部</option><option value="new">未读</option><option value="read">已读</option><option value="replied">已回复</option><option value="archived">已归档</option></select></label>
              <span class="filter-hint">回复会以邮件发送到用户留下的联系邮箱，并记录发送历史。</span>
            </form>
            <div class="table-shell embedded-table" tabindex="0" aria-label="用户反馈列表，可横向滚动"><table class="data-table"><thead><tr><th>状态</th><th>联系邮箱</th><th>主题 / 内容</th><th>时间</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="item in feedbackMessages" :key="item.id"><td><span class="status-tag" :class="feedbackStatusClass(item.status)">{{ feedbackStatusLabel(item.status) }}</span></td><td>{{ item.contact_email || '未留邮箱' }}</td><td><strong>{{ item.subject || '（无主题）' }}</strong><small>{{ item.body.slice(0, 80) }}{{ item.body.length > 80 ? '…' : '' }}</small></td><td>{{ formatDate(item.created_at) }}</td><td><div class="row-actions"><button class="button" :disabled="feedbackBusy" @click="openFeedbackReply(item)">{{ item.status === 'archived' || !item.contact_email ? '查看' : item.status === 'replied' ? '查看 / 继续回复' : '回复' }}</button><button v-if="item.status !== 'archived'" class="text-button" :disabled="feedbackBusy" @click="archiveFeedback(item)">归档</button><span v-else class="status-tag status-muted">已归档</span></div></td></tr>
              <tr v-if="!feedbackMessages.length"><td colspan="5" class="empty-cell">还没有收到用户反馈。官网反馈表单的留言会出现在这里。</td></tr>
            </tbody></table></div>
            <div class="table-footer"><span>显示 {{ feedbackMessages.length }} 条</span><button v-if="feedbackCursor" class="button" :disabled="loading" @click="loadMoreMailbox('feedback')">{{ loading ? '正在加载…' : '继续加载' }}</button></div>
          </section>

          <details v-if="mailboxTab === 'compose'" class="panel section-panel" open>
            <summary class="create-summary"><span><strong>发送邮件</strong><small>向任意邮箱发送通知或回复，使用统一品牌模板，支持发送前预览</small></span><span class="button button-primary" aria-hidden="true">写邮件 <span class="disclosure-arrow">＋</span></span></summary>
            <form class="activation-form" @submit.prevent="sendComposeMail">
              <div class="filter-bar">
                <label class="search-field"><span>收件邮箱</span><input v-model="composeTo" class="input" type="email" maxlength="254" required placeholder="user@example.com" /></label>
                <label class="search-field"><span>主题（必填，最多 188 字）</span><input v-model="composeSubject" class="input" maxlength="188" required placeholder="例如：关于你反馈的修复说明" /></label>
              </div>
              <div class="filter-bar"><label class="select-field"><span>品牌模板</span><select v-model="composeTemplate" class="input select"><option v-for="item in mailTemplates" :key="item.id" :value="item.id">{{ item.label }}</option></select></label><label class="search-field"><span>收件人称呼（可选）</span><input v-model="composeRecipientName" class="input" maxlength="60" placeholder="例如：林女士" /></label><label class="select-field"><span>快捷回复</span><select class="input select" @change="insertMailSnippet('compose', $event)"><option value="">选择正文范例</option><option v-for="item in mailSnippets" :key="item.id" :value="item.id">{{ item.label }}</option></select></label></div>
              <label for="compose-body">正文（最多 8000 字，称呼与签名自动添加）</label>
              <textarea id="compose-body" v-model="composeBody" class="input" rows="6" maxlength="8000" required placeholder="邮件正文"></textarea>
              <div class="row-actions"><button class="button" type="button" :disabled="composeBusy || !composeTo.trim() || !composeSubject.trim()" @click="openMailPreview('manual')">预览邮件</button><button class="button button-primary" :disabled="composeBusy || !composeTo.trim() || !composeSubject.trim() || !composeBody.trim()">{{ composeBusy ? '正在发送…' : '发送邮件' }}</button></div><button v-if="pendingMailIDs.has('compose')" class="text-button" type="button" @click="showOutboundDetail(pendingMailIDs.get('compose')!)">查看待确认的发送记录</button>
              <p class="muted compact-note">空行分段；每行以「- 」开头可显示为列表。邮件包含品牌 HTML 与纯文本版本，发送会登记审计与历史。</p>
            </form>
          </details>

          <section v-if="mailboxTab === 'outbound'" class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">含回复与主动发送</p><h2>发送历史</h2></div><span class="count-label">{{ outboundEmails.length }} 条</span></div>
            <form class="filter-bar" @submit.prevent="searchMailbox"><label class="search-field"><span>搜索发送记录</span><input v-model="outboundQuery" class="input" type="search" maxlength="200" placeholder="收件人、主题或参考编号" /></label><label class="select-field"><span>状态</span><select v-model="outboundStatusFilter" class="input select" @change="searchMailbox"><option value="">全部</option><option value="sent">已交给邮件服务</option><option value="failed">失败</option><option value="queued">结果待确认</option></select></label><button class="button" :disabled="loading">搜索</button></form>
            <div class="table-shell embedded-table" tabindex="0" aria-label="邮件发送历史，可横向滚动"><table class="data-table"><thead><tr><th>状态</th><th>收件人</th><th>主题</th><th>类型</th><th>发送时间</th><th>操作人</th><th>详情</th></tr></thead><tbody>
              <tr v-for="item in outboundEmails" :key="item.id"><td><span class="status-tag" :class="item.status === 'sent' ? 'status-good' : item.status === 'failed' ? 'status-error' : 'status-warning'">{{ item.status === 'sent' ? '已交给邮件服务' : item.status === 'failed' ? '失败' : '处理中 / 结果待确认' }}</span></td><td>{{ item.recipient }}</td><td><strong>{{ item.subject }}</strong><small v-if="item.error_code">{{ item.error_code }}</small></td><td>{{ item.purpose === 'feedback_reply' ? '回复邮件' : '主动发送' }}</td><td>{{ formatDate(item.sent_at || item.created_at) }}</td><td>{{ item.created_by || '—' }}</td><td><button class="button" @click="showOutboundDetail(item.id)">查看邮件</button></td></tr>
              <tr v-if="!outboundEmails.length"><td colspan="7" class="empty-cell">还没有发送记录。</td></tr>
            </tbody></table></div><div class="table-footer"><span>显示 {{ outboundEmails.length }} 条</span><button v-if="outboundCursor" class="button" :disabled="loading" @click="loadMoreMailbox('outbound')">继续加载发送记录</button></div>
          </section>
        </template>

        <template v-if="pageReady && page === 'activation'">
          <details class="panel section-panel activation-create">
            <summary class="create-summary"><span><strong>新建兑换批次</strong><small>生成随机码或导入已有兑换码</small></span><span class="button button-primary" aria-hidden="true">新建批次 <span class="disclosure-arrow">＋</span></span></summary>
            <p class="notice notice-warning">完整兑换码只显示一次，生成后请立即保存。</p>
            <form class="activation-form" @submit.prevent="createActivationBatch">
              <div class="filter-bar">
                <label class="select-field"><span>创建方式</span><select v-model="activationMode" class="input select" @change="resetActivationRequestKey"><option value="generate">安全随机生成</option><option value="import">导入已有兑换码</option></select></label>
                <label class="search-field"><span>批次名称</span><input v-model="activationLabel" class="input" maxlength="120" required placeholder="例如：秋季体验码" @input="resetActivationRequestKey" /></label>
                <label class="search-field"><span>产品权益代码</span><input v-model="activationProduct" class="input" maxlength="64" required pattern="[a-z0-9][a-z0-9._\-]*" @input="resetActivationRequestKey" /></label>
                <label class="select-field"><span>权益期限</span><select v-model.number="activationDurationDays" class="input select" @change="resetActivationRequestKey"><option :value="0">永久</option><option :value="7">7 天</option><option :value="30">30 天</option><option :value="90">90 天</option><option :value="365">365 天</option></select></label>
                <label class="select-field"><span>兑换截止（UTC+8，可选）</span><input v-model="activationExpiresAt" class="input" type="datetime-local" @input="resetActivationRequestKey" /></label>
                <label v-if="activationMode === 'generate'" class="select-field"><span>生成数量</span><input v-model.number="activationCount" class="input" type="number" min="1" max="500" required @input="resetActivationRequestKey" /></label>
              </div>
              <label v-if="activationMode === 'import'" for="activation-import-codes">每行一个兑换码，也可用空格或逗号分隔（最多 400 个）</label>
              <textarea v-if="activationMode === 'import'" id="activation-import-codes" v-model="activationImportText" class="input" rows="7" autocomplete="off" spellcheck="false" placeholder="粘贴需要导入的兑换码" required></textarea>
              <p v-if="activationMode === 'generate'" class="muted compact-note">新码由密码学随机数生成，数据库只保存带服务端密钥的摘要。生成后请立即下载 CSV 或复制保存。</p>
              <p v-else class="muted compact-note">导入的明文只用于本次创建；服务端只保存摘要，导入成功后网页会清空输入框。</p>
              <div v-if="activationStepUpNeeded" class="context-note">
                <strong>敏感操作需要重新验证</strong>
                <label for="activation-stepup-password">管理员密码</label><input id="activation-stepup-password" v-model="activationStepUpPassword" class="input" type="password" autocomplete="current-password" />
                <label for="activation-stepup-code">新的 6 位动态验证码</label><input id="activation-stepup-code" v-model="activationStepUpCode" class="input code-input" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" />
              </div>
              <button class="button button-primary" :disabled="activationBusy || (activationStepUpNeeded && (!activationStepUpPassword || activationStepUpCode.length !== 6))">{{ activationBusy ? '正在处理…' : activationMode === 'generate' ? '生成兑换码' : '导入兑换码' }}</button>
            </form>
          </details>

          <section v-if="issuedActivationCodes.length" class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">请现在保存</p><h2>新生成的完整兑换码</h2></div><button class="button button-primary" type="button" @click="downloadActivationCodes">下载 CSV</button></div>
            <p class="notice notice-warning">完整兑换码只保存在当前页面内存中。离开页面或刷新后，服务端不能再次取回原码；可根据批次统计重新生成未使用码。</p>
            <div class="code-list"><code v-for="code in issuedActivationCodes" :key="code.id">{{ code.code }}</code></div>
          </section>

          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">批次统计</p><h2>兑换码批次</h2></div><span class="count-label">{{ activationBatches.length }} 个批次</span></div>
            <div class="table-shell embedded-table" tabindex="0" :aria-label="activeHeading.title + '记录，可横向滚动'"><table class="data-table"><thead><tr><th>批次</th><th>权益</th><th>期限</th><th>码数</th><th>已兑换</th><th>可用</th><th>兑换截止</th><th>创建时间</th></tr></thead><tbody>
              <tr v-for="batch in activationBatches" :key="batch.id" :class="{ 'selected-row': selectedActivationBatch === batch.id }"><td><button class="table-link" type="button" @click="selectedActivationBatch = batch.id; void loadActivationCodes()">{{ batch.label }}</button><small class="id-preview">{{ compactID(batch.id) }}</small></td><td><code>{{ batch.product_code }}</code></td><td>{{ batch.duration_days === 0 ? '永久' : `${batch.duration_days} 天` }}</td><td class="numeric">{{ batch.total_codes }}</td><td class="numeric">{{ batch.redeemed_count }}</td><td class="numeric">{{ batch.unused_count }}</td><td>{{ formatDate(batch.expires_at) }}</td><td>{{ formatDate(batch.created_at) }}</td></tr>
              <tr v-if="!activationBatches.length"><td colspan="8" class="empty-cell">尚无兑换码批次。</td></tr>
            </tbody></table></div>
          </section>

          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">仅显示尾号</p><h2>{{ selectedActivationBatch ? '该批次兑换码' : '最近兑换码' }}</h2></div><label class="select-field"><span>筛选批次</span><select v-model="selectedActivationBatch" class="input select" @change="() => loadActivationCodes()"><option value="">所有批次</option><option v-for="batch in activationBatches" :key="batch.id" :value="batch.id">{{ batch.label }}</option></select></label></div>
            <div v-if="codesLoading" class="inline-loading" role="status"><span class="spinner" aria-hidden="true"></span>正在读取该批次兑换码…</div>
            <p v-if="codesError" class="notice notice-error" role="alert">{{ codesError }} <button class="text-button" type="button" @click="loadActivationCodes">重试</button></p>
            <div v-if="!codesLoading && !codesError" class="table-shell embedded-table" tabindex="0" :aria-label="activeHeading.title + '记录，可横向滚动'"><table class="data-table"><thead><tr><th>尾号</th><th>状态</th><th>兑换时间</th><th>用户 ID</th><th>创建时间</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="code in activationCodes" :key="code.id"><td><code>•••• {{ code.suffix }}</code></td><td><span class="status-tag" :class="code.status === 'unused' ? 'status-good' : code.status === 'redeemed' ? 'status-neutral' : code.status === 'expired' ? 'status-warning' : 'status-muted'">{{ code.status === 'unused' ? '未使用' : code.status === 'redeemed' ? '已兑换' : code.status === 'expired' ? '已过期' : '已撤销' }}</span></td><td>{{ formatDate(code.redeemed_at) }}</td><td><code>{{ code.redeemed_user_id ? compactID(code.redeemed_user_id) : '—' }}</code></td><td>{{ formatDate(code.created_at) }}</td><td><button v-if="code.status === 'unused'" class="button button-danger-outline" type="button" :disabled="activationBusy" @click="revokeActivationCode(code)">撤销</button></td></tr>
              <tr v-if="!activationCodes.length"><td colspan="6" class="empty-cell">没有符合条件的兑换码。</td></tr>
            </tbody></table></div>
            <p class="muted compact-note">撤销只对未使用码开放，并保留审计记录。已兑换码不可删除，权益和兑换历史不会被静默改写。</p>
          </section>
        </template>

        <template v-if="pageReady && page === 'announcements'">
          <details class="panel section-panel" :open="annEditingID !== ''">
            <summary class="create-summary"><span><strong>{{ annEditingID ? '编辑公告' : '发布新公告' }}</strong><small>上线后官网公告条与客户端会实时读取</small></span><span class="button button-primary" aria-hidden="true">{{ annEditingID ? '正在编辑' : '新建公告' }} <span class="disclosure-arrow">＋</span></span></summary>
            <form class="activation-form" @submit.prevent="submitAnnouncement">
              <div class="filter-bar">
                <label class="select-field"><span>级别</span><select v-model="annLevel" class="input select"><option value="info">通知</option><option value="warn">警告</option><option value="critical">严重</option></select></label>
                <label class="search-field"><span>标题（必填）</span><input id="ann-title" v-model="annTitle" class="input" maxlength="120" required placeholder="例如：macOS 版紧急修复中" /></label>
                <label class="select-field"><span>展示位置</span><select v-model="annPlacement" class="input select"><option value="banner">官网公告条</option><option value="download">下载区</option><option value="both">公告条 + 下载区</option></select></label>
                <label class="search-field"><span>跳转链接（可选）</span><input v-model="annHref" class="input" maxlength="300" placeholder="/download 或 https://…" /></label>
                <label class="search-field"><span>开始时间（UTC+8，可选）</span><input v-model="annStartsAt" class="input" type="datetime-local" /></label>
                <label class="search-field"><span>结束时间（UTC+8，可选）</span><input v-model="annEndsAt" class="input" type="datetime-local" /></label>
              </div>
              <label for="ann-body">正文（可选，最多 500 字）</label>
              <textarea id="ann-body" v-model="annBody" class="input" rows="3" maxlength="500" placeholder="显示在公告条或下载卡片上的说明文字"></textarea>
              <label class="check-line"><input type="checkbox" v-model="annActive" /> 立即上线（上线后约 30 秒内同步到官网与客户端）</label>
              <div class="row-actions">
                <button class="button button-primary" :disabled="annBusy || !annTitle.trim()">{{ annBusy ? '正在保存…' : annEditingID ? '保存修改' : '创建公告' }}</button>
                <button v-if="annEditingID" class="button" type="button" :disabled="annBusy" @click="resetAnnForm">取消编辑</button>
              </div>
            </form>
          </details>

          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">官网与客户端数据源</p><h2>全部公告</h2></div><span class="count-label">{{ announcements.length }} 条</span></div>
            <div class="table-shell embedded-table" tabindex="0" aria-label="公告列表，可横向滚动"><table class="data-table"><thead><tr><th>状态</th><th>级别</th><th>标题 / 正文</th><th>位置</th><th>时间窗口</th><th>更新于</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="item in announcements" :key="item.id"><td><span class="status-tag" :class="item.active ? 'status-good' : 'status-muted'">{{ item.active ? '已上线' : '未上线' }}</span></td><td><span class="status-tag" :class="announcementLevelClass(item.level)">{{ announcementLevelLabel(item.level) }}</span></td><td><strong>{{ item.title }}</strong><small v-if="item.body">{{ item.body }}</small></td><td>{{ announcementPlacementLabel(item.placement) }}</td><td>{{ item.starts_at ? formatDate(item.starts_at, false) : '—' }} ~ {{ item.ends_at ? formatDate(item.ends_at, false) : '∞' }}</td><td>{{ formatDate(item.updated_at) }}</td><td><div class="row-actions"><button class="button" :disabled="annBusy" @click="toggleAnnouncement(item)">{{ item.active ? '下线' : '上线' }}</button><button class="text-button" :disabled="annBusy" @click="editAnnouncement(item)">编辑</button><button class="text-button" :disabled="annBusy" @click="deleteAnnouncement(item)">删除</button></div></td></tr>
              <tr v-if="!announcements.length"><td colspan="7" class="empty-cell">还没有公告。创建并上线后，官网公告条会自动显示。</td></tr>
            </tbody></table></div>
          </section>
        </template>

        <template v-if="pageReady && page === 'changelog'">
          <details class="panel section-panel" :open="clEditingID !== ''">
            <summary class="create-summary"><span><strong>{{ clEditingID ? '编辑日志条目' : '新建日志条目' }}</strong><small>发布后显示在官网「更新日志」时间线</small></span><span class="button button-primary" aria-hidden="true">{{ clEditingID ? '正在编辑' : '新建条目' }} <span class="disclosure-arrow">＋</span></span></summary>
            <form class="activation-form" @submit.prevent="submitChangelog">
              <div class="filter-bar">
                <label class="search-field"><span>日期（显示在时间线上）</span><input v-model="clDate" class="input" type="date" required /></label>
                <label class="search-field"><span>版本标签（可选）</span><input v-model="clVersion" class="input" maxlength="40" placeholder="例如 v1.1 · Server" /></label>
                <label class="check-line" style="align-self:end"><input type="checkbox" v-model="clPublished" /> 发布（官网可见）</label>
              </div>
              <label for="cl-title">标题（必填）</label>
              <input id="cl-title" v-model="clTitle" class="input" maxlength="160" required placeholder="例如：月信草稿跨设备同步" />
              <label for="cl-body">正文（可选，支持换行，每行一条要点）</label>
              <textarea id="cl-body" v-model="clBody" class="input" rows="5" maxlength="4000" placeholder="每行一条更新要点，官网按列表展示"></textarea>
              <div class="row-actions">
                <button class="button button-primary" :disabled="clBusy || !clTitle.trim()">{{ clBusy ? '正在保存…' : clEditingID ? '保存修改' : '创建条目' }}</button>
                <button v-if="clEditingID" class="button" type="button" :disabled="clBusy" @click="resetChangelogForm">取消编辑</button>
              </div>
            </form>
          </details>

          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">官网 /v1/changelog 数据源</p><h2>全部日志条目</h2></div><span class="count-label">{{ changelogEntries.length }} 条</span></div>
            <div class="table-shell embedded-table" tabindex="0" aria-label="更新日志列表，可横向滚动"><table class="data-table"><thead><tr><th>状态</th><th>日期</th><th>版本</th><th>标题 / 要点</th><th>更新于</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="item in changelogEntries" :key="item.id"><td><span class="status-tag" :class="item.is_published ? 'status-good' : 'status-muted'">{{ item.is_published ? '已发布' : '草稿' }}</span></td><td><code>{{ item.date }}</code></td><td>{{ item.version_tag || '—' }}</td><td><strong>{{ item.title }}</strong><small>{{ item.body.split(/\r?\n/).filter(Boolean).slice(0, 3).join('；') }}{{ item.body.split(/\r?\n/).filter(Boolean).length > 3 ? '…' : '' }}</small></td><td>{{ formatDate(item.updated_at) }}</td><td><div class="row-actions"><button class="button" :class="{ 'button-danger-outline': item.is_published }" :disabled="clBusy" @click="toggleChangelog(item)">{{ item.is_published ? '撤下' : '发布' }}</button><button class="text-button" :disabled="clBusy" @click="editChangelog(item)">编辑</button><button class="text-button" :disabled="clBusy" @click="deleteChangelog(item)">删除</button></div></td></tr>
              <tr v-if="!changelogEntries.length"><td colspan="6" class="empty-cell">还没有日志条目。</td></tr>
            </tbody></table></div>
          </section>
        </template>

        <template v-if="pageReady && page === 'downloads'">
          <details class="panel section-panel" open>
            <summary class="create-summary"><span><strong>上传新版本</strong><small>上传后默认不开放，确认后再开放下载</small></span><span class="button button-primary" aria-hidden="true">上传安装包 <span class="disclosure-arrow">＋</span></span></summary>
            <p v-if="!downloadStorageConfigured" class="notice notice-warning">服务器未配置 DOWNLOAD_DIR，上传功能不可用；请在 /etc/flowriver/server.env 中配置后重启服务。</p>
            <form class="activation-form" @submit.prevent="uploadDownload">
              <div class="filter-bar">
                <label class="select-field"><span>平台</span><select v-model="dlPlatform" class="input select"><option value="macos">macOS</option><option value="ios">iOS（预留）</option></select></label>
                <label class="search-field"><span>版本号（必填）</span><input v-model="dlVersion" class="input" maxlength="60" required placeholder="例如 20261001 或 1.2.0" /></label>
                <label class="search-field"><span>文件（.zip，≤256 MB）</span><input id="dl-file" type="file" class="input" accept=".zip,application/zip" required @change="onDownloadFileChange" /></label>
              </div>
              <label for="dl-note">下载卡片说明（可选，例如「因偶发 bug 紧急修复中」）</label>
              <textarea id="dl-note" v-model="dlNote" class="input" rows="2" maxlength="500"></textarea>
              <button class="button button-primary" :disabled="dlBusy || !dlFile || !dlVersion.trim() || !downloadStorageConfigured">{{ dlBusy ? (dlProgress === 100 ? '校验并保存中…' : `正在上传 ${dlProgress ?? 0}%`) : '上传安装包' }}</button>
            <div v-if="dlBusy" class="upload-status" role="status" aria-live="polite"><progress :value="dlProgress ?? 0" max="100" aria-label="安装包上传进度"></progress><span>{{ dlProgress === 100 ? '文件传输完成，等待服务端校验与保存。' : `已传输 ${dlProgress ?? 0}%` }}</span><button class="button" type="button" @click="cancelUpload">停止上传</button></div>
            </form>
          </details>

          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">开放中的版本会出现在官网</p><h2>安装包版本</h2></div><span class="count-label">{{ downloads.length }} 个版本</span></div>
            <div class="table-shell embedded-table" tabindex="0" aria-label="安装包列表，可横向滚动"><table class="data-table"><thead><tr><th>状态</th><th>平台 / 版本</th><th>文件</th><th>大小</th><th>SHA-256</th><th>说明</th><th>激活时间</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="item in downloads" :key="item.id"><td><span class="status-tag" :class="item.is_active ? 'status-good' : 'status-muted'">{{ item.is_active ? '开放下载' : '未开放' }}</span></td><td><strong>{{ item.platform === 'macos' ? 'macOS' : 'iOS' }}</strong><small>{{ item.version }}</small></td><td><code class="truncate-code">{{ item.filename }}</code></td><td>{{ bytes(item.size_bytes) }}</td><td><code class="truncate-code">{{ item.sha256.slice(0, 12) }}…</code></td><td><input v-model="item.note" class="input" maxlength="500" style="min-width:200px" /></td><td>{{ formatDate(item.activated_at) }}</td><td><div class="row-actions"><button class="button" :class="{ 'button-danger-outline': item.is_active }" :disabled="dlBusy" @click="toggleDownload(item)">{{ item.is_active ? '暂停下载' : '开放下载' }}</button><button class="text-button" :disabled="dlBusy || item.note === undefined" @click="saveDownloadNote(item)">保存说明</button></div></td></tr>
              <tr v-if="!downloads.length"><td colspan="8" class="empty-cell">还没有上传过安装包。</td></tr>
            </tbody></table></div>
            <p class="muted compact-note">同一平台同时只有一个版本开放下载；开放/暂停会写入审计，官网下载卡片与 /v1/site-status 实时同步。</p>
          </section>
        </template>

        <template v-if="pageReady && page === 'admins'">
          <section v-if="issuedTotpUri" class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">仅显示一次</p><h2>验证器设置 URI</h2></div></div>
            <p class="notice notice-warning">请立即让对应管理员用验证器 App 扫码或保存下面的 URI；关闭本页后服务端无法再次显示。</p>
            <code class="totp-uri">{{ issuedTotpUri }}</code>
            <div class="row-actions"><button class="button" type="button" @click="copyTotpUri">复制 URI</button><button class="button button-primary" type="button" :disabled="!issuedTotpSaved" @click="issuedTotpUri = ''">我已保存，关闭</button></div>
            <label class="check-line"><input type="checkbox" v-model="issuedTotpSaved" /> 我已确认对方保存了验证器</label>
          </section>
          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">通过管理台创建</p><h2>新建管理员</h2></div></div>
            <form class="activation-form" @submit.prevent="createAdmin">
              <div class="filter-bar">
                <label class="search-field"><span>管理员名</span><input v-model="newAdminName" class="input" maxlength="64" required placeholder="3–64 位字母数字" autocomplete="off" /></label>
                <label class="search-field"><span>初始密码（12–128 位）</span><input v-model="createAdminPassword" class="input" type="password" maxlength="128" required autocomplete="new-password" /></label>
              </div>
              <button class="button button-primary" :disabled="adminBusy || !newAdminName.trim() || createAdminPassword.length < 12 || Boolean(issuedTotpUri && !issuedTotpSaved)">{{ adminBusy ? '正在创建…' : '创建管理员' }}</button>
              <p class="muted compact-note">创建成功后一次性返回验证器设置 URI；新管理员首次登录仍需密码 + TOTP。SSH 引导命令保持可用。</p>
            </form>
          </section>
          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">禁用会立即撤销其全部会话</p><h2>管理员账号</h2></div><span class="count-label">{{ admins.length }} 个账号</span></div>
            <div class="table-shell embedded-table" tabindex="0" aria-label="管理员列表"><table class="data-table"><thead><tr><th>账号</th><th>状态</th><th>在线会话</th><th>最近登录</th><th>创建时间</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="admin in admins" :key="admin.id"><td><strong>{{ admin.username }}</strong><small v-if="admin.is_you">（当前登录）</small><small class="id-preview">{{ compactID(admin.id) }}</small></td><td><span class="status-tag" :class="admin.disabled_at ? 'status-error' : 'status-good'">{{ admin.disabled_at ? '已禁用' : '启用' }}</span></td><td class="numeric">{{ admin.active_sessions }}</td><td>{{ formatDate(admin.last_login_at) }}</td><td>{{ formatDate(admin.created_at) }}</td><td><div class="row-actions"><button v-if="!admin.is_you" class="button" :class="{ 'button-danger-outline': !admin.disabled_at }" :disabled="adminBusy" @click="setAdminDisabled(admin)">{{ admin.disabled_at ? '启用' : '禁用' }}</button><button class="button" :disabled="adminBusy || Boolean(admin.disabled_at) || admin.is_you" :title="admin.is_you ? '当前账号请由其他管理员或服务器恢复命令重置' : '重置动态验证器'" @click="resetAdminTotp(admin)">重置验证器</button></div></td></tr>
              <tr v-if="!admins.length"><td colspan="6" class="empty-cell">没有管理员账号记录。</td></tr>
            </tbody></table></div>
          </section>
          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">闲置 15 分钟自动过期</p><h2>在线管理会话</h2></div><span class="count-label">{{ adminSessionsList.length }} 个会话</span></div>
            <div class="table-shell embedded-table" tabindex="0" aria-label="管理会话列表"><table class="data-table"><thead><tr><th>管理员</th><th>创建时间</th><th>最近活动</th><th>绝对到期</th><th><span class="sr-only">操作</span></th></tr></thead><tbody>
              <tr v-for="row in adminSessionsList" :key="row.id"><td><strong>{{ row.username }}</strong><small v-if="row.is_you">（你）</small></td><td>{{ formatDate(row.created_at) }}</td><td>{{ formatDate(row.last_seen_at) }}</td><td>{{ formatDate(row.absolute_expires_at) }}</td><td><button class="button button-danger-outline" :disabled="adminBusy" @click="revokeAdminSession(row)">撤销</button></td></tr>
              <tr v-if="!adminSessionsList.length"><td colspan="5" class="empty-cell">当前没有在线管理会话。</td></tr>
            </tbody></table></div>
          </section>
        </template>

        <template v-if="pageReady && page === 'insights' && stats">
          <div class="filter-bar"><label class="select-field"><span>统计时间范围（UTC+8）</span><select v-model="statsDays" class="input select" @change="loadPage('insights')"><option :value="7">最近 7 天</option><option :value="30">最近 30 天</option><option :value="90">最近 90 天</option></select></label></div>
          <section class="stat-row ops-stats">
            <div class="stat"><span>账号总数</span><strong>{{ stats.users_total }}</strong><small>服务端累计</small></div>
            <div class="stat"><span>有效会话</span><strong>{{ stats.active_sessions }}</strong><small>当前可用</small></div>
            <div class="stat"><span>设备总数</span><strong>{{ stats.devices }}</strong><small>含已撤销</small></div>
            <div class="stat"><span>统计窗口</span><strong class="state-word">{{ stats.days }} 天</strong><small>{{ formatDate(stats.updated_at) }} 更新</small></div>
          </section>
          <div class="column-layout ops-columns">
            <section class="panel"><p class="eyebrow">每日新增</p><h2>注册趋势</h2>
              <div class="chart"><div v-for="point in stats.signups" :key="point.date" class="chart-row"><span class="chart-date">{{ point.date.slice(5) }}</span><span class="chart-bar"><span class="chart-fill" :style="{ width: barPercent(point.count, seriesMax(stats.signups)) + '%' }"></span></span><span class="chart-value">{{ point.count }}</span></div></div>
            </section>
            <section class="panel"><p class="eyebrow">每日兑换</p><h2>权益兑换趋势</h2>
              <div class="chart"><div v-for="point in stats.redemptions" :key="point.date" class="chart-row"><span class="chart-date">{{ point.date.slice(5) }}</span><span class="chart-bar"><span class="chart-fill chart-fill-mint" :style="{ width: barPercent(point.count, seriesMax(stats.redemptions)) + '%' }"></span></span><span class="chart-value">{{ point.count }}</span></div></div>
              <p class="eyebrow" style="margin-top:18px">每日验证码邮件</p><h2 class="sr-only">邮件量</h2><p class="muted compact-note">异常包含失败与结果待确认，不包含已过期或已作废。验证码任务状态保留 30 天；更早或已清理的历史为空时，不代表没有邮件。</p>
              <div class="chart"><div v-for="point in stats.mail" :key="'m' + point.date" class="chart-row"><span class="chart-date">{{ point.date.slice(5) }}</span><span class="chart-bar"><span class="chart-fill chart-fill-sky" :style="{ width: barPercent(point.total, seriesMax(stats.mail.map((point) => ({ count: point.total })))) + '%' }"></span></span><span class="chart-value">{{ point.total }}<small v-if="point.failed"> / 异常 {{ point.failed }}</small></span></div></div>
            </section>
          </div>
          <section class="panel section-panel">
            <div class="panel-heading"><div><p class="eyebrow">按邮箱 / IP 查询并清零</p><h2>限流检查器</h2></div></div>
            <form class="activation-form" @submit.prevent="lookupRateLimit">
              <div class="filter-bar">
                <label class="select-field"><span>限流类别</span><select v-model="rlKind" class="input select"><option value="email_hour">验证码邮件 · 每邮箱/小时</option><option value="email_day">验证码邮件 · 每邮箱/天</option><option value="ip_hour">验证码邮件 · 每 IP/小时</option><option value="password_email_hour">密码登录 · 每邮箱/小时</option><option value="password_ip_quarter">密码登录 · 每 IP/15 分钟</option><option value="feedback_ip_hour">官网反馈 · 每 IP/小时</option></select></label>
                <label class="search-field"><span>邮箱或 IP</span><input v-model="rlValue" class="input" minlength="3" maxlength="254" required placeholder="user@example.com 或 1.2.3.4" /></label>
                <button class="button" type="submit" :disabled="insightsBusy">查询状态</button>
                <button class="button button-danger-outline" type="button" :disabled="insightsBusy || rlValue.trim().length < 3" @click="clearRateLimit">清零限流</button>
              </div>
              <p v-if="rlResult" class="notice notice-info">{{ rlResult }}</p>
            </form>
            <div class="table-shell embedded-table" tabindex="0" aria-label="活跃限流桶"><table class="data-table"><thead><tr><th>限流桶（摘要）</th><th>窗口开始</th><th>计数</th><th>过期时间</th></tr></thead><tbody>
              <tr v-for="bucket in rateLimitBuckets" :key="bucket.key_hex + bucket.window_start"><td><code>{{ bucket.key_hex }}</code></td><td>{{ formatDate(bucket.window_start) }}</td><td class="numeric">{{ bucket.hits }}</td><td>{{ formatDate(bucket.expires_at) }}</td></tr>
              <tr v-if="!rateLimitBuckets.length"><td colspan="4" class="empty-cell">当前没有活跃限流桶。</td></tr>
            </tbody></table></div>
            <p class="muted compact-note">桶的键以 HMAC 摘要保存，服务端无法反查原始邮箱或 IP；清零指定地址前请先用查询确认命中。</p>
          </section>
        </template>

        <template v-if="pageReady && page === 'security'">
          <section class="panel section-panel"><div class="panel-heading"><div><p class="eyebrow">异机日志回执决定状态</p><h2>账号安全变更</h2></div></div>
            <div class="table-shell embedded-table" tabindex="0" :aria-label="activeHeading.title + '记录，可横向滚动'"><table class="data-table"><thead><tr><th>操作</th><th>用户 ID</th><th>状态</th><th>次数</th><th>最近尝试</th><th>错误类别</th></tr></thead><tbody>
              <tr v-for="event in securityEvents" :key="event.event_id"><td>{{ displayEvent(event.kind) }}</td><td><code>{{ compactID(event.user_id) }}</code></td><td><span class="status-tag" :class="event.delivered_at ? 'status-good' : 'status-warning'">{{ event.delivered_at ? '已收到回执' : '等待回执' }}</span><small v-if="event.deletion_status">删除 {{ deletionStatusLabel(event.deletion_status) }}</small></td><td class="numeric">{{ event.attempts }}</td><td>{{ formatDate(event.delivered_at || event.available_at) }}</td><td>{{ event.error_code || '—' }}</td></tr>
              <tr v-if="!securityEvents.length"><td colspan="6" class="empty-cell">没有安全变更事件。</td></tr>
            </tbody></table></div>
          </section>
          <section class="panel section-panel"><div class="panel-heading"><div><p class="eyebrow">最近操作记录</p><h2>管理员审计</h2></div><span class="update-label">保留 90 天</span></div>
            <form class="filter-bar" @submit.prevent="applyAuditFilters">
              <label class="search-field"><span>操作类型</span><input v-model="auditActionFilter" type="search" class="input" placeholder="如 admin.user.disable（可留空）" /></label>
              <label class="select-field"><span>结果</span><select v-model="auditResultFilter" class="input select"><option value="">全部结果</option><option value="success">成功</option><option value="denied">被拒绝</option><option value="failure">失败</option></select></label>
              <label class="select-field"><span>时间范围</span><select v-model="auditDaysFilter" class="input select"><option value="">全部</option><option value="1">最近 24 小时</option><option value="7">最近 7 天</option><option value="30">最近 30 天</option><option value="90">最近 90 天</option></select></label>
              <button class="button" type="submit" :disabled="loading || auditLoading">应用筛选</button>
              <button v-if="auditActionFilter || auditResultFilter || auditDaysFilter" class="button" type="button" :disabled="loading || auditLoading" @click="auditActionFilter = ''; auditResultFilter = ''; auditDaysFilter = ''; applyAuditFilters()">清除</button>
            </form>
            <div class="audit-list"><div v-for="event in auditEvents" :key="event.id" class="audit-row"><span class="audit-mark" :class="event.result === 'success' ? 'audit-ok' : 'audit-warn'"></span><span class="audit-main"><strong>{{ auditActionLabel(event.action) }}</strong><small>{{ event.admin_id || '系统初始化' }} · {{ event.target_type }} {{ compactID(event.target_id) }} · 原因 {{ event.reason_code || '—' }}</small></span><span class="audit-time">{{ formatDate(event.created_at) }}</span></div><p v-if="!auditEvents.length" class="empty-inline">暂无符合条件的管理员操作记录。</p></div>
            <div class="table-footer"><span>已显示 {{ auditEvents.length }} 条操作</span><button v-if="auditCursor !== null" class="button" type="button" :disabled="auditLoading || loading" @click="loadMoreAudit">{{ auditLoading ? '正在加载…' : '加载更早记录' }}</button></div>
          </section>
        </template>

        <template v-if="pageReady && page === 'ops' && operations">
          <section class="stat-row ops-stats"><div class="stat"><span>服务 API</span><strong class="state-word">{{ operations.api.state === 'ready' ? '就绪' : '异常' }}</strong><small>{{ formatDate(operations.api.checked_at) }}</small></div><div class="stat"><span>数据库连接</span><strong class="state-word">{{ operations.database.ping_ms }} <small>ms</small></strong><small>{{ formatDate(operations.database.checked_at) }}</small></div><div class="stat"><span>进程运行时间</span><strong class="state-word">{{ elapsed(operations.process.uptime_seconds) }}</strong><small>最近启动 {{ formatDate(operations.process.started_at) }}</small></div><div class="stat"><span>负载平均值</span><strong class="state-word">{{ operations.process.resources.load_average_1_5_15_minutes || '未知' }}</strong><small>1 / 5 / 15 分钟</small></div></section>
          <div class="column-layout ops-columns"><section class="panel"><p class="eyebrow">实时读取</p><h2>系统资源</h2><div class="resource-item"><div class="resource-label"><span>内存可用</span><strong v-if="operations.process.resources.memory">{{ bytes(operations.process.resources.memory.available_bytes) }} / {{ bytes(operations.process.resources.memory.total_bytes) }}</strong><strong v-else>未接入</strong></div><progress v-if="operations.process.resources.memory" :value="agePercent(operations.process.resources.memory.total_bytes - operations.process.resources.memory.available_bytes, operations.process.resources.memory.total_bytes)" max="100" aria-label="内存使用率"></progress></div><div class="resource-item"><div class="resource-label"><span>系统盘可用</span><strong v-if="operations.process.resources.disk_root">{{ bytes(operations.process.resources.disk_root.available_bytes) }} / {{ bytes(operations.process.resources.disk_root.total_bytes) }}</strong><strong v-else>未接入</strong></div><progress v-if="operations.process.resources.disk_root" :value="agePercent(operations.process.resources.disk_root.total_bytes - operations.process.resources.disk_root.available_bytes, operations.process.resources.disk_root.total_bytes)" max="100" aria-label="系统盘使用率"></progress></div><p class="muted compact-note">资源数据直接读取 Linux；负载平均值不是 CPU 使用百分比。</p></section>
          <section class="panel"><p class="eyebrow">加密异机备份</p><h2>数据库备份</h2><div class="service-line"><span>备份健康状态</span><span class="status-tag" :class="backupHealthClass(operations.backup.health)">{{ backupHealthLabel(operations.backup.health) }}</span></div><div class="service-line"><span>最近任务结果</span><span>{{ backupLabel(operations.backup.state) }}</span></div><div class="service-line"><span>更新时间</span><span>{{ formatDate(operations.backup.updated_at) }}</span></div><div class="service-line"><span>对象名称</span><code class="truncate-code">{{ operations.backup.object_name || '—' }}</code></div><div class="service-line"><span>恢复演练记录</span><span class="status-tag" :class="operations.restore_drill.result === 'success' ? 'status-good' : operations.restore_drill.result === 'failure' ? 'status-error' : 'status-warning'">{{ drillLabel(operations.restore_drill.result) }}</span></div><p v-if="operations.restore_drill.summary === 'manual_record'" class="muted compact-note">结果由管理员登记，服务不会自动验证恢复。</p><div class="row-actions"><button class="button" @click="recordRestoreDrill('success')">记录恢复演练通过</button><button class="button button-danger-outline" @click="recordRestoreDrill('failure')">记录恢复演练失败</button></div><p class="muted compact-note">异机备份需要独立存储和已启用的定时任务；同机发布快照不能替代异机备份。任务应每小时更新，超过 2 小时没有新记录会显示过期。只有在隔离环境实际恢复后再登记演练结果。</p></section></div>
          <section class="panel section-panel"><div class="panel-heading"><div><p class="eyebrow">backup.sh 每次运行都会落库</p><h2>备份历史</h2></div><span class="count-label">{{ backupRuns.length }} 条记录</span></div>
            <div class="table-shell embedded-table" tabindex="0" aria-label="备份历史"><table class="data-table"><thead><tr><th>时间</th><th>状态</th><th>耗时</th><th>对象</th><th>错误类别</th></tr></thead><tbody>
              <tr v-for="run in backupRuns" :key="run.id"><td>{{ formatDate(run.created_at) }}</td><td><span class="status-tag" :class="backupClass(run.state)">{{ backupLabel(run.state) }}</span></td><td>{{ durationLabel(run.duration_ms) }}</td><td><code class="truncate-code">{{ run.object_name || '—' }}</code></td><td>{{ run.code || '—' }}</td></tr>
              <tr v-if="!backupRuns.length"><td colspan="5" class="empty-cell">尚无异机备份历史。配置独立存储并启用定时任务后，才会产生运行记录。</td></tr>
            </tbody></table></div>
            <p class="muted compact-note">历史记录保存在数据库 backup_runs 表中，最多展示最近 100 次；最新状态仍以上方「数据库备份」为准。</p>
          </section>
        </template>

        <template v-if="pageReady && page === 'settings'">
          <section class="panel section-panel"><p class="eyebrow">无需向网页提供密钥值</p><h2>外部服务</h2><div v-for="item in configItems" :key="item.name" class="detail-row"><div><strong>{{ item.name }}</strong><small>{{ item.detail }}</small></div><span class="status-tag" :class="configStateClass(item.state)">{{ configStateLabel(item.state) }}</span></div></section>
          <section class="panel section-panel"><p class="eyebrow">管理员会话</p><h2>安全要求</h2><div class="service-line"><span>登录方式</span><strong>专属密码 + TOTP 动态验证码</strong></div><div class="service-line"><span>登录保护</span><strong>失败限速 / 重放验证码拒绝 / CSRF 来源验证</strong></div><div class="service-line"><span>敏感操作</span><strong>重新验证密码与动态验证码</strong></div><div class="service-line"><span>管理入口</span><strong>admin.flowriver.xyz · 独立回环监听</strong></div><p class="muted compact-note">配置状态只检查服务端已加载的设置；外部服务实际送达和安全日志回执须单独验收。</p></section>
          <section class="panel section-panel"><p class="eyebrow">仅影响当前管理员</p><h2>更改管理员密码</h2><form class="password-form" @submit.prevent="changeAdminPassword"><label for="current-admin-password">当前密码</label><input id="current-admin-password" v-model="currentAdminPassword" class="input" type="password" autocomplete="current-password" required maxlength="128" /><label for="current-admin-totp">新的动态验证码</label><input id="current-admin-totp" v-model="currentAdminTotp" class="input code-input" inputmode="numeric" autocomplete="one-time-code" required pattern="[0-9]{6}" maxlength="6" /><label for="new-admin-password">新密码</label><input id="new-admin-password" v-model="newAdminPassword" class="input" type="password" autocomplete="new-password" required minlength="12" maxlength="128" /><label for="new-admin-password-confirm">再次输入新密码</label><input id="new-admin-password-confirm" v-model="newAdminPasswordConfirm" class="input" type="password" autocomplete="new-password" required minlength="12" maxlength="128" /><button class="button button-primary" :disabled="passwordBusy">{{ passwordBusy ? '正在更新…' : '验证并更改密码' }}</button></form><p class="muted compact-note">密码使用 Argon2id 保存，不会写入浏览器本地存储。</p></section>
        </template>
      </main>
    </div>

    <div v-if="userConfirmation" class="modal-backdrop" @keydown.esc="userConfirmation=null" @keydown="cycleDialogFocus"><section class="dialog user-action-dialog" role="dialog" aria-modal="true" aria-labelledby="user-confirm-title"><p class="eyebrow">确认账号操作</p><h2 id="user-confirm-title">{{ userConfirmation.path.endsWith('/disable') ? '封禁此账号？' : userConfirmation.path.endsWith('/enable') ? '解除封禁？' : '撤销登录会话？' }}</h2><p>账号 {{ userConfirmation.id }}</p><p class="muted">{{ userConfirmation.path.endsWith('/enable') ? '恢复登录权限。已撤销的会话不会恢复，用户需要重新登录。' : '该操作会使对应会话立即失效，用户需要重新登录。设备上的日记会保留。' }}</p><p class="context-note">原因：{{ userReasonLabel(userConfirmation.reason) }} · 操作将写入审计</p><div class="dialog-actions"><button class="button" @click="userConfirmation=null">取消</button><button class="button button-danger" @click="confirmUserAction">确认操作</button></div></section></div>
    <div v-if="userPasswordTarget" class="modal-backdrop" :inert="stepUpNeeded" @keydown="cycleDialogFocus" @keydown.esc="closeUserPassword">
      <section class="dialog" role="dialog" aria-modal="true" aria-labelledby="user-password-title">
        <p class="eyebrow">用户账号 · 密码管理</p><h2 id="user-password-title">重置用户密码</h2>
        <p>{{ userPasswordTarget.identities.find(identity => identity.provider === 'email' && identity.status === 'active')?.email }}</p>
        <p class="muted">重置后旧密码、旧改密验证码和旧会话都会失效。请确认用户身份，并通过可靠渠道告知新密码。</p>
        <form class="password-form" @submit.prevent="submitUserPassword">
          <label for="user-new-password">新密码 · 15–128 个字符</label><input id="user-new-password" v-model="userNewPassword" type="password" autocomplete="new-password" :disabled="busy" @input="changeUserPasswordKey" />
          <label for="user-repeat-password">再次输入新密码</label><input id="user-repeat-password" v-model="userRepeatPassword" type="password" autocomplete="new-password" :disabled="busy" />
          <small v-if="userRepeatPassword && userNewPassword.normalize('NFC') !== userRepeatPassword.normalize('NFC')">两次输入的密码不一致。</small>
          <label for="user-password-reason">重置原因</label><select id="user-password-reason" v-model="userPasswordReason" :disabled="busy" @change="changeUserPasswordKey"><option value="user_request">用户申请</option><option value="suspicious_activity">可疑登录</option><option value="other">其他</option></select>
          <template v-if="userPasswordReauth"><p>请重新验证管理员身份。</p><label for="user-password-admin">管理员密码</label><input id="user-password-admin" v-model="userPasswordAdmin" type="password" autocomplete="current-password" :disabled="busy" /><label for="user-password-code">6 位动态验证码</label><input id="user-password-code" v-model="userPasswordCode" inputmode="numeric" maxlength="6" autocomplete="one-time-code" :disabled="busy" /></template>
          <p v-if="userPasswordError" class="notice notice-error" role="alert">{{ userPasswordError }}</p>
          <div class="dialog-actions"><button class="button" type="button" :disabled="busy" @click="closeUserPassword">取消</button><button class="button button-danger" type="submit" :disabled="busy || !userPasswordValid || (userPasswordReauth && (!userPasswordAdmin || userPasswordCode.length !== 6))">{{ busy ? '正在重置…' : userPasswordReauth ? '验证并重置密码' : '确认重置密码' }}</button></div>
        </form>
      </section>
    </div>
    <div v-if="revokeTarget" class="modal-backdrop" :inert="stepUpNeeded" @mousedown.self="closeRevoke" @keydown.esc="closeRevoke" @keydown="cycleDialogFocus">
      <section class="dialog" role="dialog" aria-modal="true" aria-labelledby="revoke-title">
        <button class="dialog-close" type="button" aria-label="关闭" :disabled="busy" @click="closeRevoke">×</button>
        <p class="eyebrow">设备安全操作</p><h2 id="revoke-title">撤销账号服务登录</h2>
        <p class="dialog-copy"><strong>{{ revokeTarget.display_name || revokeTarget.platform }}</strong> · {{ revokeTarget.user_email || compactID(revokeTarget.user_id) }}</p>
        <div class="context-note">此操作会撤销该设备全部账号服务会话，并记录操作者与原因。设备上的日记仍保留。</div>
        <label for="revoke-reason">操作原因</label><select id="revoke-reason" v-model="revokeReason" class="input select"><option value="lost_device">用户报告设备遗失</option><option value="user_request">用户请求撤销</option><option value="suspicious_activity">发现可疑活动</option><option value="other">其他已核实原因</option></select>
        <template v-if="reauthNeeded"><p class="notice notice-warning" role="status">此敏感操作需要重新验证密码和动态验证码。</p><label for="step-up-password">管理员密码</label><input id="step-up-password" v-model="reauthPassword" class="input" type="password" autocomplete="current-password" /><label for="step-up-totp">新的一次性动态验证码</label><input id="step-up-totp" v-model="reauthCode" class="input code-input" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" /></template>
        <p v-if="pageError" class="notice notice-error" role="alert">{{ pageError }}</p>
        <div class="dialog-actions"><button class="button" :disabled="busy" @click="closeRevoke">取消</button><button class="button button-danger" :disabled="busy || (reauthNeeded && (!reauthPassword || reauthCode.length !== 6))" @click="submitRevoke">{{ busy ? '处理中…' : reauthNeeded ? '重新验证并撤销' : '确认撤销' }}</button></div>
      </section>
    </div>
    <div v-if="viewTarget" class="modal-backdrop" :inert="stepUpNeeded || previewOpen" @keydown.esc="closeInboundMail" @keydown="cycleDialogFocus">
      <section class="dialog" role="dialog" aria-modal="true" aria-labelledby="inbound-view-title">
        <button class="dialog-close" type="button" aria-label="关闭" :disabled="inboundBusy" @click="closeInboundMail">×</button>
        <p class="eyebrow">邮件收件箱</p>
        <h2 id="inbound-view-title">{{ viewTarget.subject || '（无主题）' }}</h2>
        <p class="dialog-copy"><strong>{{ inboundSenderName(viewTarget) }}</strong> · {{ viewTarget.from_addr }} · {{ formatDate(viewTarget.created_at) }}<template v-if="viewTarget.status === 'replied'"> · <span class="status-tag status-good">已回复</span></template></p>
        <pre class="mail-body">{{ viewTarget.text_body || '（此邮件没有可显示的文本正文）' }}</pre>
        <form class="password-form" @submit.prevent="submitInboundReply">
          <div class="filter-bar"><label class="select-field"><span>品牌模板</span><select v-model="viewTemplate" class="input select"><option v-for="item in mailTemplates" :key="item.id" :value="item.id">{{ item.label }}</option></select></label><label class="search-field"><span>收件人称呼</span><input v-model="viewRecipientName" class="input" maxlength="60" /></label><label class="select-field"><span>快捷回复</span><select class="input select" @change="insertMailSnippet('inbound', $event)"><option value="">选择正文范例</option><option v-for="item in mailSnippets" :key="item.id" :value="item.id">{{ item.label }}</option></select></label></div><label class="check-line"><input type="checkbox" v-model="viewIncludeOriginal" /> 附上原始内容摘要</label><label for="inbound-reply-body">回复（发送到 {{ viewTarget.from_addr }}）</label>
          <textarea id="inbound-reply-body" v-model="viewReplyBody" class="input" rows="5" maxlength="8000" placeholder="输入回复内容…"></textarea>
          <template v-if="viewReauthNeeded">
            <p class="notice notice-warning" role="status">此敏感操作需要重新验证密码和动态验证码。</p>
            <label for="inbound-view-password">管理员密码</label><input id="inbound-view-password" v-model="viewReauthPassword" class="input" type="password" autocomplete="current-password" />
            <label for="inbound-view-totp">6 位动态验证码</label><input id="inbound-view-totp" v-model="viewReauthCode" class="input code-input" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" />
          </template>
          <p v-if="viewError" class="notice notice-error" role="alert">{{ viewError }}</p>
          <div class="dialog-actions">
            <button v-if="viewTarget.status === 'new'" class="button" type="button" :disabled="inboundBusy" @click="markCurrentMailRead">标记已读</button><button class="button button-danger-outline" type="button" :disabled="inboundBusy" @click="deleteInboundMail(viewTarget)">删除</button>
            <button class="button" type="button" :disabled="inboundBusy" @click="closeInboundMail">关闭</button>
            <button class="button" type="button" :disabled="inboundBusy" @click="openMailPreview('inbound')">预览邮件</button><button class="button button-primary" type="submit" :disabled="inboundBusy || viewReplyBody.trim().length < 2 || (viewReauthNeeded && (!viewReauthPassword || viewReauthCode.length !== 6))">{{ inboundBusy ? '正在发送…' : '发送回复' }}</button>
          </div>
        </form>
      </section>
    </div>
    <div v-if="replyTarget" class="modal-backdrop" :inert="stepUpNeeded || previewOpen" @keydown.esc="closeFeedbackReply" @keydown="cycleDialogFocus">
      <section class="dialog" role="dialog" aria-modal="true" aria-labelledby="feedback-reply-title">
        <button class="dialog-close" type="button" aria-label="关闭" :disabled="feedbackBusy" @click="closeFeedbackReply">×</button>
        <p class="eyebrow">用户反馈 · 邮件回复</p>
        <h2 id="feedback-reply-title">{{ replyTarget.subject || '（无主题）' }}</h2>
        <p class="dialog-copy"><strong>{{ replyTarget.contact_email || '未留邮箱' }}</strong> · {{ formatDate(replyTarget.created_at) }}</p>
        <div class="context-note">{{ replyTarget.body }}</div>
        <p v-if="replyTarget.reply_body" class="context-note"><strong>上一条回复</strong><br>{{ replyTarget.reply_body }}</p><p v-if="!replyTarget.contact_email || replyTarget.status === 'archived'" class="notice notice-info">这条反馈可查看，但无法邮件回复。</p><form v-else class="password-form" @submit.prevent="submitFeedbackReply">
          <div class="filter-bar"><label class="select-field"><span>品牌模板</span><select v-model="replyTemplate" class="input select"><option v-for="item in mailTemplates" :key="item.id" :value="item.id">{{ item.label }}</option></select></label><label class="search-field"><span>收件人称呼</span><input v-model="replyRecipientName" class="input" maxlength="60" /></label><label class="select-field"><span>快捷回复</span><select class="input select" @change="insertMailSnippet('feedback', $event)"><option value="">选择正文范例</option><option v-for="item in mailSnippets" :key="item.id" :value="item.id">{{ item.label }}</option></select></label></div><label class="check-line"><input type="checkbox" v-model="replyIncludeOriginal" /> 附上原始内容摘要</label><label for="feedback-reply-body">回复内容（将以邮件发送）</label>
          <textarea id="feedback-reply-body" v-model="replyBody" class="input" rows="5" maxlength="4000" required></textarea>
          <template v-if="replyReauthNeeded">
            <p class="notice notice-warning" role="status">此敏感操作需要重新验证密码和动态验证码。</p>
            <label for="feedback-reply-password">管理员密码</label><input id="feedback-reply-password" v-model="replyReauthPassword" class="input" type="password" autocomplete="current-password" />
            <label for="feedback-reply-totp">6 位动态验证码</label><input id="feedback-reply-totp" v-model="replyReauthCode" class="input code-input" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" />
          </template>
          <p v-if="replyError" class="notice notice-error" role="alert">{{ replyError }}</p>
          <div class="dialog-actions"><button class="button" type="button" :disabled="feedbackBusy" @click="closeFeedbackReply">取消</button><button class="button" type="button" :disabled="feedbackBusy" @click="openMailPreview('feedback')">预览邮件</button><button class="button button-primary" type="submit" :disabled="feedbackBusy || replyBody.trim().length < 2 || (replyReauthNeeded && (!replyReauthPassword || replyReauthCode.length !== 6))">{{ feedbackBusy ? '正在发送…' : '发送回复' }}</button></div>
        </form>
      </section>
    </div>
    <div v-if="previewOpen" class="modal-backdrop" @keydown.esc="closeMailPreview" @keydown="cycleDialogFocus"><section class="dialog mail-preview-dialog" role="dialog" aria-modal="true" aria-labelledby="mail-preview-title"><button class="dialog-close" type="button" aria-label="关闭邮件预览" @click="closeMailPreview">×</button><p class="eyebrow">{{ previewHistory ? '发送历史 · 内容快照' : '发送前预览' }}</p><h2 id="mail-preview-title">{{ previewHistory ? '邮件详情' : '确认您的邮件格式' }}</h2><p v-if="previewLoading" class="inline-loading" role="status">正在生成邮件预览…</p><p v-if="previewError" class="notice notice-error" role="alert">{{ previewError }}</p><template v-if="previewData || previewHistory"><div class="preview-envelope"><p><strong>收件人</strong> {{ previewData?.to ?? previewHistory?.recipient }}</p><p><strong>主题</strong> {{ previewData?.subject ?? previewHistory?.subject }}</p><small v-if="previewData?.threaded">将沿用原邮件会话的回复标识</small><small v-if="previewHistory">{{ previewHistory.status === 'sent' ? '已交给邮件服务' : previewHistory.status === 'failed' ? '发送失败' : '发送结果待确认' }} · {{ formatDate(previewHistory.sent_at ?? previewHistory.created_at) }}</small><p v-if="previewHistory?.legacy" class="muted">这封历史邮件使用纯文本格式。</p></div><MailPreview :formatted="previewData?.formatted ?? previewHistory?.formatted" :legacy="previewHistory?.legacy" :legacy-body="previewHistory?.body" /></template><div class="dialog-actions"><button class="button" type="button" @click="closeMailPreview">{{ previewHistory ? '关闭详情' : '返回编辑' }}</button></div></section></div>
    <div v-if="stepUpNeeded" class="modal-backdrop" @keydown.esc="cancelStepUp" @keydown="cycleDialogFocus">
      <section class="dialog" role="dialog" aria-modal="true" aria-labelledby="stepup-global-title">
        <button class="dialog-close" type="button" aria-label="关闭" :disabled="busy" @click="cancelStepUp">×</button>
        <p class="eyebrow">敏感操作</p><h2 id="stepup-global-title">重新验证管理员身份</h2>
        <p class="dialog-copy">此操作需要输入管理员密码和新的动态验证码。</p>
        <form class="password-form" @submit.prevent="submitStepUp">
          <label for="global-stepup-password">管理员密码</label><input id="global-stepup-password" v-model="stepUpPassword" class="input" type="password" autocomplete="current-password" required />
          <label for="global-stepup-code">6 位动态验证码</label><input id="global-stepup-code" v-model="stepUpCode" class="input code-input" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required />
          <p v-if="pageError" class="notice notice-error" role="alert">{{ pageError }}</p>
          <div class="dialog-actions"><button class="button" type="button" :disabled="busy" @click="cancelStepUp">取消</button><button class="button button-primary" type="submit" :disabled="busy || !stepUpPassword || stepUpCode.length !== 6">{{ busy ? '验证中…' : '验证并继续' }}</button></div>
        </form>
      </section>
    </div>
  </div>
</template>

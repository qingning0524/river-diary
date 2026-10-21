/* River MemoryOS console.
 *
 * A static, local-first reading room for a user's memory mirror.  The account
 * service is used for identity, devices, entitlements, feedback and an optional
 * end-to-end encrypted cloud mirror.  A memory mirror is parsed in this tab; it
 * is only sent as ciphertext after the user explicitly enables cloud sync.
 */

import {
  MAX_IMPORT_BYTES, MIRROR_FORMAT, MIRROR_VERSION, answerFromMemory, buildStats,
  collectionEntries, dateFromKey, escapeHtml, filterEntries,
  formatDateCN, forgottenEntry, groupByMonth, highlightHtml,
  normalizeArchive, onThisDay, placeSummary, queryTerms,
  relatedEntries, relativeDayCN, searchEntries, sortEntries, tagSummary, todayKey, truncate,
  weekdayCN,
} from './memory-core.js?v=20261020-cloud';
import { DEMO_PERSONA, buildDemoArchive } from './demo-data.js?v=20261020-cloud';
import {
  CLOUD_MIN_PASSPHRASE, buildCloudEnvelope, decryptCloudEnvelope, validateCloudPassphrase,
} from './cloud-core.js?v=20261020-cloud';
import {
  AccountClient, AccountSwitchedError, AuthExpiredError, AuthRequiredError, LOGIN_URL,
  acceptSessionPayload, accountStatusLabel, errorText, eventLabel, formatDateTime, newKey,
  productLabel,
} from './account-core.js?v=20261020-cloud';

const APP_VERSION = '2026.10.20';
const ARCHIVE_KEY = 'river.console.archive.v1';
const THEME_KEY = 'river.console.theme.v1';
const FAVORITES_KEY = 'river.console.favorites.v1';
const UNDERSTANDING_KEY = 'river.console.understanding.v1';
const ROUTES = new Set(['home', 'river', 'collections', 'places', 'understanding', 'ask', 'cloud', 'account']);
const ACCOUNT_SECTIONS = ['overview', 'devices', 'entitlements', 'security', 'activity', 'feedback', 'preferences', 'cloud'];
const THEMES = [
  { id: 'soft', name: '柔光', detail: '海雾蓝 · 柔光拟态', color: '#edf1f6' },
  { id: 'journal', name: '手记', detail: '暖白纸面 · 阅读模式', color: '#f4efe6' },
  { id: 'night', name: '夜色', detail: '深色蓝 · 夜间使用', color: '#202935' },
];
const KIND_LABELS = {
  journal: '文字', auto: '自动日记', note: '速记', photo: '照片', place: '地点', milestone: '节点', context: '设备上下文',
};
const KIND_ICONS = {
  journal: 'journal', auto: 'sync', note: 'quick-note', photo: 'photo', place: 'location', milestone: 'success', context: 'sync',
};
const FEEDBACK_STATUS = { new: '已收到', read: '处理中', replied: '已回复', archived: '已归档' };

const state = {
  preview: false,
  route: { space: 'home', sub: '' },
  archive: emptyArchive(),
  entries: [],
  collections: [],
  understandings: [],
  stats: buildStats([]),
  memorySource: 'empty',
  importMeta: null,
  favoriteOverrides: {},
  understandingOverrides: {},
  filters: { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: '', collection: '', day: '' },
  timelineLimit: 30,
  selectedPlace: null,
  forgottenSeed: 0,
  ask: { messages: [], scope: 'all' },
  cloud: { meta: null, loading: null, error: '' },
  account: {
    client: null, me: null, identities: [], entitlements: [], devices: [], sessions: [],
    password: null, redemptions: [], activity: [], feedback: [], offline: false,
    loadingCore: false, coreLoading: null, sectionLoaded: {}, sectionLoading: {},
    deviceFilter: 'all', error: '',
    pwChallenge: null, pwAfter: 0, pwKey: newKey(), redeemKey: newKey(), feedbackKey: newKey(),
    deletionChallenge: null, deletionVerifyKey: newKey(), deletionKey: newKey(), deletionProof: null,
  },
  command: { items: [], active: 0, query: '' },
  importCandidate: null,
  dialogResolve: null,
  correctionId: null,
  detailId: null,
};

let renderToken = 0;
let toastTimer = 0;
let filterTimer = 0;
let clockTimer = 0;
let bootstrapped = false;

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const prefersReducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;

function emptyArchive() {
  return { format: MIRROR_FORMAT, version: MIRROR_VERSION, entries: [], contexts: [], collections: [], understandings: [], persona: null };
}

function icon(name, className = '') {
  return `<svg class="glyph ${className}" aria-hidden="true" focusable="false"><use href="#i-${escapeHtml(name)}"></use></svg>`;
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/`/g, '&#96;');
}

function readLocal(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw === null ? fallback : JSON.parse(raw);
  } catch { return fallback; }
}

function writeLocal(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ }
}

function removeLocal(key) {
  try { localStorage.removeItem(key); } catch { /* private mode */ }
}

function currentOwnerId() {
  return state.account.client?.session?.user?.id || state.account.me?.user?.id || '';
}

function readSession(key) {
  try {
    const raw = sessionStorage.getItem(key);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

function writeSession(key, value) {
  try { sessionStorage.setItem(key, JSON.stringify(value)); return true; } catch { return false; }
}

function removeSession(key) {
  try { sessionStorage.removeItem(key); } catch { /* ignore */ }
}

function count(value) {
  return new Intl.NumberFormat('zh-CN').format(Number(value) || 0);
}

function initials(name) {
  const value = String(name ?? '').trim();
  return value ? [...value][0].toUpperCase() : '记';
}

function sourceChip(entry) {
  const iconName = KIND_ICONS[entry.kind] || 'journal';
  return `<span class="source-chip">${icon(iconName)} ${escapeHtml(entry.source?.label || KIND_LABELS[entry.kind] || '记录')}</span>`;
}

/* ---------- boot ---------- */

function init() {
  if (bootstrapped) return;
  bootstrapped = true;
  const params = new URLSearchParams(location.search);
  state.preview = ['1', 'true'].includes(params.get('preview')) || ['1', 'true'].includes(params.get('demo'));
  state.favoriteOverrides = readLocal(FAVORITES_KEY, {}) || {};
  state.understandingOverrides = readSession(UNDERSTANDING_KEY) || {};
  const storedTheme = readLocal(THEME_KEY, null);
  const initialTheme = THEMES.some((theme) => theme.id === storedTheme)
    ? storedTheme
    : (window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'night' : 'soft');
  applyTheme(initialTheme, { announce: false });
  bindShell();
  updateTopbarDate();
  clockTimer = setInterval(updateTopbarDate, 60000);
  if (state.preview) {
    startPreview();
    return;
  }
  startAccountMode();
}

function startPreview() {
  state.favoriteOverrides = {};
  state.understandingOverrides = {};
  const archive = normalizeArchive(buildDemoArchive(new Date()), {
    now: new Date(), sourceLabel: '示例记忆 · 合成内容',
  });
  if (archive.ok) applyArchive(archive, { source: 'demo', persist: false });
  state.account.client = null;
  updateShellIdentity();
  bindRoute();
  renderCurrentRoute({ focus: true });
  pendingBadge();
}

async function startAccountMode() {
  const client = new AccountClient();
  state.account.client = client;
  client.subscribe((type) => {
    if (type === 'auth-lost') redirectToLogin();
  });
  try {
    await client.ensureSession();
  } catch (error) {
    if (error instanceof AuthRequiredError || error instanceof AuthExpiredError) {
      redirectToLogin();
      return;
    }
    if (error instanceof AccountSwitchedError) {
      location.reload();
      return;
    }
    state.account.offline = true;
  }
  const restored = restoreArchive();
  if (restored) applyArchive(restored.archive, { source: restored.source, persist: false, meta: restored.meta });
  updateShellIdentity();
  bindRoute();
  renderCurrentRoute({ focus: true });
  loadAccountCore().catch((error) => {
    if (error instanceof AuthRequiredError || error instanceof AuthExpiredError) {
      redirectToLogin();
      return;
    }
    if (error instanceof AccountSwitchedError) {
      location.reload();
      return;
    }
    state.account.offline = true;
    state.account.error = error instanceof TypeError || error?.name === 'AbortError'
      ? '账号服务暂时离线，记忆副本仍可浏览。'
      : (error.message || '账号服务暂时不可用。');
    updateShellIdentity();
    if (state.route.space === 'account' || state.route.space === 'home') refreshView();
  });
  window.setTimeout(() => {
    if (!state.account.loadedCore && !state.account.loadingCore) {
      state.account.offline = true;
      updateShellIdentity();
      if (state.route.space === 'home') refreshView();
    }
  }, 8000);
}

function redirectToLogin() {
  if (state.preview) return;
  location.assign(LOGIN_URL);
}

function restoreArchive() {
  const payload = readSession(ARCHIVE_KEY);
  if (!payload) return null;
  const owner = payload.ownerId || '';
  const current = currentOwnerId();
  if (current && (!owner || owner !== current)) {
    removeSession(ARCHIVE_KEY);
    removeSession(UNDERSTANDING_KEY);
    removeLocal(FAVORITES_KEY);
    state.understandingOverrides = {};
    state.favoriteOverrides = {};
    return null;
  }
  try {
    const archive = normalizeArchive(payload, {
      now: new Date(),
      sourceLabel: payload.sourceLabel || '本标签页保留的副本',
    });
    if (!archive.ok) return null;
    return {
      archive,
      source: ['local', 'cloud'].includes(payload.memorySource) ? payload.memorySource : 'import',
      meta: payload.importMeta || null,
    };
  } catch {
    return null;
  }
}

function persistArchive() {
  if (state.preview || state.memorySource === 'demo') return;
  const payload = {
    ...state.archive,
    sourceLabel: state.archive.sourceLabel || '本机记忆副本',
    memorySource: state.memorySource,
    importMeta: state.importMeta,
    ownerId: currentOwnerId(),
    savedAt: new Date().toISOString(),
  };
  const raw = JSON.stringify(payload);
  if (raw.length > 4_600_000) {
    toast('副本较大，只保留在当前页面；刷新后需要重新导入。');
    return;
  }
  if (!writeSession(ARCHIVE_KEY, payload)) {
    toast('浏览器没有允许本标签页保存副本；刷新后需要重新导入。');
  }
}

function applyArchive(archive, options = {}) {
  const { source = 'import', persist = false, meta = null } = options;
  state.archive = { ...archive };
  state.archive.persona = archive.persona ?? null;
  state.entries = Array.isArray(archive.entries) ? archive.entries : [];
  state.collections = Array.isArray(archive.collections) ? archive.collections : [];
  state.understandings = Array.isArray(archive.understandings) ? archive.understandings : [];
  state.memorySource = source;
  state.importMeta = meta;
  state.selectedPlace = null;
  state.ask.messages = [];
  state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: '', collection: '', day: '' };
  state.timelineLimit = 30;
  applyFavoriteOverrides();
  state.stats = buildStats(state.entries);
  if (persist) persistArchive();
  updateShellIdentity();
  pendingBadge();
}

function applyFavoriteOverrides() {
  for (const entry of state.entries) {
    if (Object.prototype.hasOwnProperty.call(state.favoriteOverrides, entry.id)) {
      entry.favorite = Boolean(state.favoriteOverrides[entry.id]);
    }
  }
}

function clearArchive() {
  state.archive = emptyArchive();
  state.entries = [];
  state.collections = [];
  state.understandings = [];
  state.stats = buildStats([]);
  state.memorySource = 'empty';
  state.importMeta = null;
  state.selectedPlace = null;
  state.ask.messages = [];
  state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: '', collection: '', day: '' };
  state.timelineLimit = 30;
  if (!state.preview) {
    removeSession(ARCHIVE_KEY);
    removeSession(UNDERSTANDING_KEY);
  }
  state.understandingOverrides = {};
  updateShellIdentity();
  pendingBadge();
}

function rememberArchiveSource() {
  if (state.memorySource === 'demo') return;
  persistArchive();
}

/* ---------- shell / theme ---------- */

function applyTheme(id, { announce = true } = {}) {
  const theme = THEMES.find((item) => item.id === id) || THEMES[0];
  document.documentElement.dataset.theme = theme.id;
  state.theme = theme.id;
  writeLocal(THEME_KEY, theme.id);
  const meta = $('#theme-color');
  if (meta) meta.setAttribute('content', theme.color);
  const button = $('#btn-theme');
  if (button) {
    const next = THEMES[(THEMES.findIndex((item) => item.id === theme.id) + 1) % THEMES.length];
    button.setAttribute('aria-label', `当前${theme.name}外观，切换到${next.name}`);
    button.title = `外观：${theme.name} · 点击切换`;
  }
  $$('[data-theme-choice]').forEach((choice) => {
    choice.setAttribute('aria-pressed', String(choice.dataset.themeChoice === theme.id));
  });
  if (announce) toast(`已切换到${theme.name}外观。`);
}

function cycleTheme() {
  const index = THEMES.findIndex((item) => item.id === state.theme);
  applyTheme(THEMES[(index + 1) % THEMES.length].id);
}

function updateTopbarDate() {
  const el = $('#topbar-date');
  if (!el) return;
  const now = new Date();
  el.textContent = `${formatDateCN(now, { withWeekday: true })} · 第 ${isoWeek(now)} 周`;
}

function isoWeek(date) {
  const probe = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  const day = probe.getUTCDay() || 7;
  probe.setUTCDate(probe.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(probe.getUTCFullYear(), 0, 1));
  return Math.ceil((((probe - yearStart) / 86400000) + 1) / 7);
}

function updateShellIdentity() {
  const name = personaName();
  const avatar = $('#topbar-avatar');
  if (avatar) avatar.textContent = state.preview ? '示' : initials(name);
  const accountButton = $('#btn-account');
  if (accountButton) {
    accountButton.setAttribute('aria-label', state.preview ? '打开演示账号说明' : '打开账号与设置');
    accountButton.title = state.preview ? '演示模式' : (email() || '账号与设置');
  }
  const chipText = $('#local-chip span');
  if (chipText) {
    chipText.textContent = state.preview
      ? (state.memorySource === 'import' ? '本地副本' : '演示记忆')
      : state.memorySource === 'cloud' ? '加密云副本' : '本机记忆';
  }
  pendingBadge();
}

function pendingBadge() {
  const badge = $('#understanding-badge');
  if (!badge) return;
  const pending = effectiveUnderstandings().filter((item) => item.status === 'pending').length;
  badge.hidden = pending === 0;
  badge.textContent = String(pending);
  badge.setAttribute('aria-label', `${pending} 条理解待确认`);
}

function personaName() {
  if (state.archive.persona?.name) return state.archive.persona.name;
  const email = accountEmail();
  if (email) return email.split('@')[0] || '记录者';
  if (state.preview) return DEMO_PERSONA.name;
  return '记录者';
}

function accountEmail() {
  return state.account.me?.identities?.find((item) => item.provider === 'email' && item.status === 'active')?.email || '';
}

function email() {
  return accountEmail();
}

function bindShell() {
  $('#btn-theme')?.addEventListener('click', cycleTheme);
  $('#btn-account')?.addEventListener('click', () => navigate('account'));
  $('#search-trigger')?.addEventListener('click', openCommand);
  $('#local-chip')?.addEventListener('click', openPrivacy);
  $('#privacy-open')?.addEventListener('click', openPrivacy);
  $('#privacy-dialog')?.addEventListener('close', () => {});
  $('#action-dialog')?.addEventListener('close', resolveActionDialog);
  $('#memory-dialog')?.addEventListener('click', (event) => {
    if (event.target === $('#memory-dialog')) $('#memory-dialog').close();
  });
  $('#command-dialog')?.addEventListener('click', (event) => {
    if (event.target === $('#command-dialog')) $('#command-dialog').close();
  });
  $('#command-dialog')?.addEventListener('close', () => {
    state.command.query = '';
    const input = $('#command-input');
    if (input) input.value = '';
  });
  $('#command-input')?.addEventListener('input', (event) => {
    state.command.query = event.target.value;
    state.command.active = 0;
    renderCommandResults();
  });
  $('#command-input')?.addEventListener('keydown', handleCommandKey);
  $('#command-results')?.addEventListener('click', (event) => {
    const item = event.target.closest('[data-command-index]');
    if (item) activateCommand(Number(item.dataset.commandIndex));
  });
  $('#command-results')?.addEventListener('mousemove', (event) => {
    const item = event.target.closest('[data-command-index]');
    if (item && Number(item.dataset.commandIndex) !== state.command.active) {
      state.command.active = Number(item.dataset.commandIndex);
      paintCommandSelection();
    }
  });
  $('#memory-dialog')?.addEventListener('click', (event) => {
    const action = event.target.closest('[data-detail-action]');
    if (action) handleDetailAction(action);
  });
  $('#import-pick')?.addEventListener('click', () => $('#import-file')?.click());
  $('#import-file')?.addEventListener('change', (event) => {
    const file = event.target.files?.[0];
    if (file) inspectImportFile(file);
  });
  $('#import-confirm')?.addEventListener('click', confirmImport);
  const drop = $('#import-drop');
  if (drop) {
    for (const type of ['dragenter', 'dragover']) {
      drop.addEventListener(type, (event) => { event.preventDefault(); drop.classList.add('dragover'); });
    }
    for (const type of ['dragleave', 'drop']) {
      drop.addEventListener(type, (event) => { event.preventDefault(); drop.classList.remove('dragover'); });
    }
    drop.addEventListener('drop', (event) => {
      const file = event.dataTransfer?.files?.[0];
      if (file) inspectImportFile(file);
    });
  }
  $('#correction-form')?.addEventListener('submit', submitCorrection);
  document.addEventListener('click', handleGlobalClick);
  document.addEventListener('submit', handleGlobalSubmit);
  document.addEventListener('input', handleGlobalInput);
  document.addEventListener('change', handleGlobalChange);
  document.addEventListener('keydown', handleGlobalKeydown);
  window.addEventListener('hashchange', () => renderCurrentRoute({ focus: true }));
  window.addEventListener('scroll', () => {}, { passive: true });
  window.setInterval(tickPasswordButton, 1000);
}

function navigate(space, sub = '') {
  const target = `#/${space}${sub ? `/${sub}` : ''}`;
  if (location.hash === target) {
    renderCurrentRoute({ focus: false });
    return;
  }
  location.hash = target;
}

function parseRoute() {
  const raw = location.hash.replace(/^#\/?/, '');
  const [space, ...rest] = raw.split('/');
  return { space: ROUTES.has(space) ? space : 'home', sub: rest.join('/') };
}

function bindRoute() {
  if (!location.hash) history.replaceState(null, '', '#/home');
  state.route = parseRoute();
}

function renderCurrentRoute({ focus = false } = {}) {
  state.route = parseRoute();
  const token = ++renderToken;
  updateNav();
  if (state.route.space === 'account') {
    renderAccountRoute(state.route.sub, token, { focus });
    return;
  }
  if (state.route.space === 'cloud') {
    renderAccountRoute('cloud', token, { focus, standalone: true });
    return;
  }
  const html = renderSpace(state.route.space);
  setView(html);
  if (focus) focusHeading();
  document.title = `${routeTitle(state.route.space)} · 河流日记`;
  if (focus) window.scrollTo({ top: 0, behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
}

function refreshView() {
  const token = ++renderToken;
  if (state.route.space === 'account') {
    renderAccountRoute(state.route.sub, token, { focus: false });
    return;
  }
  if (state.route.space === 'cloud') {
    renderAccountRoute('cloud', token, { focus: false, standalone: true });
    return;
  }
  setView(renderSpace(state.route.space));
  afterRender(state.route.space);
}

function setView(html) {
  const view = $('#view');
  if (!view) return;
  view.innerHTML = html;
  afterRender(state.route.space);
}

function afterRender(space) {
  if (space === 'ask') {
    const scroll = $('#chat-scroll');
    if (scroll) scroll.scrollTop = scroll.scrollHeight;
  }
  if (space === 'account') {
    tickPasswordButton();
    const nav = $('.account-tabs');
    const activeTab = $('.account-tab[aria-current="page"]');
    if (nav && activeTab && nav.scrollWidth > nav.clientWidth) {
      const navRect = nav.getBoundingClientRect();
      const tabRect = activeTab.getBoundingClientRect();
      nav.scrollLeft += tabRect.left - navRect.left - (navRect.width - tabRect.width) / 2;
    }
  }
}

function focusHeading() {
  const heading = $('#view h1, #view h2');
  if (!heading) return;
  if (!heading.hasAttribute('tabindex')) heading.setAttribute('tabindex', '-1');
  heading.focus({ preventScroll: true });
}

function updateNav() {
  $$('[data-space]').forEach((link) => {
    const active = link.dataset.space === state.route.space;
    if (active) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  });
}

function routeTitle(space) {
  return ({
    home: '记忆首页', river: '长河', collections: '合集与章节', places: '地点里的我',
    understanding: 'River 的理解', ask: '问 River', cloud: '云空间', account: '账号与设置',
  })[space] || '记忆控制台';
}

function renderSpace(space) {
  switch (space) {
    case 'river': return renderRiver();
    case 'collections': return renderCollections();
    case 'places': return renderPlaces();
    case 'understanding': return renderUnderstanding();
    case 'ask': return renderAsk();
    case 'cloud': return renderCloudSkeleton();
    case 'account': return renderAccountSkeleton('overview');
    default: return renderHome();
  }
}

/* ---------- home ---------- */

function renderHome() {
  const banner = renderPreviewBanner();
  if (!state.entries.length) return `${banner}${renderHomeEmpty()}`;
  const now = new Date();
  const stats = state.stats;
  const name = personaName();
  const today = todayKey(now);
  const todayEntries = state.entries.filter((entry) => entry.date === today);
  const recent = sortEntries(state.entries, 'desc').slice(0, 4);
  const onThis = onThisDay(state.entries, now);
  const forgotten = forgottenEntry(state.entries, now, state.forgottenSeed);
  const pending = effectiveUnderstandings().filter((item) => item.status === 'pending').slice(0, 2);
  const firstYear = stats.first ? stats.first.slice(0, 4) : '';
  const sourceText = state.memorySource === 'demo'
    ? '这是一份合成演示副本。'
    : state.memorySource === 'cloud'
      ? '这份副本从云空间解密后只存在这个标签页；服务器只保存密文。'
      : '记忆副本在这个标签页里读取；除非你主动开启云空间，否则不会上传。';
  const todayBlock = todayEntries.length
    ? `<div class="today-strip panel">
        <span class="today-mark">${icon('today')}</span>
        <div class="today-copy"><strong>今天 · ${escapeHtml(todayEntries.at(-1).time || '已经留下')}</strong><p>${escapeHtml(truncate(todayEntries.at(-1).body || todayEntries.at(-1).title, 90))}</p></div>
        <button class="btn small ghost" type="button" data-open="${escapeAttr(todayEntries.at(-1).id)}">读一读</button>
      </div>`
    : `<div class="today-strip panel">
        <span class="today-mark">${icon('journal')}</span>
        <div class="today-copy"><strong>今天还没有可读的记录</strong><p>控制台只读。今天的新内容仍由原生 App 记录，网页不会代写。</p></div>
        <a class="btn small ghost" href="#/river">翻翻长河</a>
      </div>`;
  const pendingSection = pending.length ? `
    <section class="section">
      <div class="section-head"><h2>正在成形的理解</h2><a class="text-link" href="#/understanding">全部 ${effectiveUnderstandings().filter((item) => item.status === 'pending').length} 条 →</a></div>
      <div class="u-grid">${pending.map((item) => renderUnderstandingMini(item)).join('')}</div>
    </section>` : '';
  return `${banner}
  <section class="hero panel">
    <div class="hero-grid">
      <div>
        <p class="eyebrow">MEMORY HOME · ${state.memorySource === 'demo' ? 'SYNTHETIC PREVIEW' : 'LOCAL FIRST'}</p>
        <h1>你好，<em>${escapeHtml(name)}</em>。<br>你的河流在这里。</h1>
        <p class="hero-lede">这是你留下的 ${count(stats.count)} 段记忆，从 ${firstYear} 年流到今天。没有被评分，也没有被催更。${sourceText}</p>
        <div class="hero-meta">
          <span>${icon('timeline')} ${count(stats.dayCount)} 天</span>
          <a href="#/places">${icon('location')} ${count(stats.places.length)} 个地点</a>
          <a href="#/collections">${icon('chapter')} ${count(state.collections.length)} 个合集</a>
          <span>${icon('shield')} ${state.memorySource === 'cloud' ? '已加密上云' : '未上传'}</span>
        </div>
        <div class="hero-actions">
          <a class="btn primary" href="#/river">${icon('timeline')} 翻翻长河</a>
          <button class="btn ghost" type="button" data-action="import">${icon('export')} 导入副本</button>
          <a class="btn ghost" href="#/ask">${icon('chat')} 问问 River</a>
        </div>
      </div>
      <div class="hero-art" aria-hidden="true">${renderHeroArt()}</div>
    </div>
  </section>
  ${todayBlock}
  <div class="home-grid">
    <div class="home-main">
      ${renderRibbon()}
      <section class="panel panel-pad">
        <div class="panel-head"><h2>最近留下的</h2><a class="text-link" href="#/river">查看全部 →</a></div>
        <div class="memory-list">${recent.map((entry) => renderMemoryRow(entry)).join('')}</div>
      </section>
      ${pendingSection}
    </div>
    <aside class="home-rail">
      ${renderOnThisDay(onThis, now)}
      ${renderForgotten(forgotten)}
      ${renderMemoryStatus()}
    </aside>
  </div>
  <div class="metric-grid">
    <article class="metric"><span>记忆段数</span><strong>${count(stats.count)}</strong><small>${stats.first ? `${formatDateCN(stats.first)} 起` : '还没有开始'}</small></article>
    <article class="metric"><span>留下记忆的天数</span><strong>${count(stats.dayCount)}</strong><small>不要求连续</small></article>
    <article class="metric"><span>地点</span><strong>${count(stats.places.length)}</strong><small>${stats.places[0]?.name ? escapeHtml(stats.places[0].name) : '地点只来自副本'}</small></article>
    <article class="metric"><span>收藏</span><strong>${count(stats.favorites)}</strong><small>你主动留下的书签</small></article>
  </div>
  <div class="home-shortcuts">
    <a class="panel shortcut" href="#/collections">
      <span class="shortcut-icon">${icon('chapter')}</span>
      <span class="shortcut-copy"><strong>合集与章节</strong><small>${count(state.collections.length)} 个合集 · 把散落的日子收起来</small></span>
      ${icon('forward')}
    </a>
    <a class="panel shortcut" href="#/places">
      <span class="shortcut-icon">${icon('map')}</span>
      <span class="shortcut-copy"><strong>地点里的我</strong><small>${count(stats.places.length)} 个地点 · 在同一个地方遇见自己</small></span>
      ${icon('forward')}
    </a>
  </div>
  <p class="fine-print" style="margin-top:16px">这里展示的是只读副本。修改与补写仍在原生 App 中完成；云空间只保存你主动上传的加密快照。${state.memorySource === 'demo' ? ' 演示数据全部为合成内容。' : ''}</p>
  `;
}

function renderHomeEmpty() {
  return `
  <section class="hero panel">
    <div class="hero-grid">
      <div>
        <p class="eyebrow">MEMORY HOME · 还没有副本</p>
        <h1>你好，<em>${escapeHtml(personaName())}</em>。<br>先把过去带到这里。</h1>
        <p class="hero-lede">网页控制台是只读窗口。要看日记，请先在 Mac 的「设置 → 隐私与备份 → 网页控制台副本」或 iPhone 的「设置 → 导出我的记录 → 网页控制台」导出 JSON，再在这里导入；也可以从另一台设备已上传的加密云空间恢复。当前导出的是本机可读日记，完整记忆镜像仍在接入（T12）。</p>
        <div class="hero-meta"><span>${icon('shield')} 默认只在当前标签页</span><span>${icon('lock')} 不调用模型</span><span>${icon('database')} 可随时清除</span></div>
        <div class="hero-actions">
          <button class="btn primary" type="button" data-action="import">${icon('export')} 导入记忆副本</button>
          ${state.preview ? '' : `<button class="btn ghost" type="button" data-action="open-cloud">${icon('cloud')} 从云空间恢复</button>`}
          <button class="btn ghost" type="button" data-action="demo">看看示例</button>
        </div>
      </div>
      <div class="hero-art" aria-hidden="true">${renderHeroArt()}</div>
    </div>
  </section>
  <div class="account-grid" style="margin-top:22px">
    <article class="panel panel-pad">
      <p class="eyebrow">LOCAL FIRST</p>
      <h2 class="serif" style="font-size:24px;margin-top:4px">记忆默认不走云端。</h2>
      <p class="muted small" style="margin-top:7px">副本默认在浏览器内存和当前标签页的会话存储里；关闭标签页后就不再保留。登录后你可以主动开启端到端加密云空间，届时服务器只接收密文。</p>
      <div class="account-note">${icon('shield')} 导入的文件不会附带账号信息；控制台只读取文件内容，不把正文写入 localStorage，也不会上传明文。</div>
    </article>
    <article class="panel panel-pad">
      <p class="eyebrow">FROM THE APPS</p>
      <h2 class="serif" style="font-size:24px;margin-top:4px">副本从哪里来？</h2>
      <p class="muted small" style="margin-top:7px">Mac 在「设置 → 隐私与备份 → 网页控制台副本」，iPhone 在「设置 → 导出我的记录 → 网页控制台」导出 JSON；若当前安装版本没有该入口，请更新到包含网页副本导出的构建。也可以导入符合 <code>river.memory-mirror</code> 的 JSON，或从另一台设备已上传的云空间恢复。</p>
      <div class="empty-actions" style="justify-content:flex-start;margin-top:14px"><a class="btn small ghost" href="https://flowriver.xyz/#download">下载客户端 ↗</a><a class="btn small ghost" href="https://flowriver.xyz/privacy.html">隐私说明 ↗</a></div>
    </article>
  </div>
  `;
}

function renderPreviewBanner() {
  if (!state.preview) return '';
  const imported = state.memorySource === 'import';
  return `<div class="preview-banner">
    <span class="tag accent">${imported ? '演示环境' : '演示模式'}</span>
    <span>${imported ? '你在这个标签页里载入了自己的副本。账号服务仍未连接。' : '这些记忆是合成的示例，用来展示控制台的样子。'}</span>
    <strong>不会写入你的账号。</strong>
    <button class="btn tiny ghost" type="button" data-action="exit-preview">退出演示</button>
  </div>`;
}

function renderHeroArt() {
  return `<svg viewBox="0 0 380 250" role="presentation">
    <defs>
      <linearGradient id="hero-flow-a" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="var(--accent)" stop-opacity=".55"/>
        <stop offset="1" stop-color="var(--accent)" stop-opacity=".05"/>
      </linearGradient>
      <linearGradient id="hero-flow-b" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="var(--ink)" stop-opacity=".18"/>
        <stop offset="1" stop-color="var(--ink)" stop-opacity="0"/>
      </linearGradient>
    </defs>
    <path class="ribbon-flow-2" d="M-10 188 C60 154 118 196 178 152 C238 108 292 144 392 82" stroke="url(#hero-flow-a)" stroke-width="22" opacity=".4"/>
    <path class="hero-water" d="M10 175 C70 128 126 174 184 132 C242 90 306 126 370 70" fill="none" stroke="url(#hero-flow-b)" stroke-width="1.2"/>
    <path class="hero-water" d="M6 205 C70 156 132 202 194 160 C256 118 318 154 376 104" fill="none" stroke="var(--accent)" stroke-opacity=".28" stroke-width="1"/>
    <circle class="hero-pebble" cx="110" cy="164" r="17"/>
    <circle class="hero-pebble" cx="236" cy="128" r="12"/>
    <circle class="hero-pebble" cx="310" cy="100" r="22"/>
    <circle class="hero-pebble fill" cx="110" cy="164" r="4"/>
    <circle class="hero-pebble fill" cx="236" cy="128" r="3"/>
    <circle class="hero-pebble fill" cx="310" cy="100" r="5"/>
    <path d="M42 92 C72 72 96 100 124 82" fill="none" stroke="var(--ink)" stroke-opacity=".12" stroke-width="1" stroke-dasharray="2 5"/>
  </svg><span class="hero-caption">A RIVER OF DAYS</span>`;
}

function renderRibbon() {
  const sorted = sortEntries(state.entries, 'asc');
  if (!sorted.length) return '';
  const first = dateFromKey(sorted[0].date);
  const last = dateFromKey(sorted.at(-1).date);
  if (!first || !last) return '';
  const months = [];
  let cursor = new Date(first.getFullYear(), first.getMonth(), 1);
  const end = new Date(last.getFullYear(), last.getMonth(), 1);
  while (cursor <= end) {
    months.push({ year: cursor.getFullYear(), month: cursor.getMonth() + 1, count: 0 });
    cursor = new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1);
  }
  for (const entry of state.entries) {
    const found = months.find((item) => item.year === Number(entry.date.slice(0, 4)) && item.month === Number(entry.date.slice(5, 7)));
    if (found) found.count += 1;
  }
  const max = Math.max(1, ...months.map((item) => item.count));
  const width = 900;
  const left = 38;
  const right = 18;
  const baseY = 132;
  const step = months.length > 1 ? (width - left - right) / (months.length - 1) : 0;
  const points = months.map((item, index) => {
    const x = left + index * step;
    const y = baseY - 22 - (item.count / max) * 56;
    return { ...item, x, y, index };
  });
  let flow = '';
  points.forEach((point, index) => {
    if (index === 0) flow += `M ${point.x.toFixed(1)} ${point.y.toFixed(1)}`;
    else {
      const previous = points[index - 1];
      const midX = (previous.x + point.x) / 2;
      flow += ` C ${midX.toFixed(1)} ${previous.y.toFixed(1)} ${midX.toFixed(1)} ${point.y.toFixed(1)} ${point.x.toFixed(1)} ${point.y.toFixed(1)}`;
    }
  });
  const area = `${flow} L ${points.at(-1).x.toFixed(1)} 145 L ${points[0].x.toFixed(1)} 145 Z`;
  const bars = points.map((point) => {
    const height = point.count ? 12 + Math.min(point.count, 7) * 7 : 3;
    const label = `${point.year}年${point.month}月`;
    return `<g class="ribbon-month" data-action="ribbon-month" data-year="${point.year}" data-month="${point.month}" tabindex="0" role="button" aria-label="${label}，${point.count} 段记忆">
      <rect class="ribbon-bar" x="${(point.x - 2.6).toFixed(1)}" y="${(baseY - height).toFixed(1)}" width="5.2" height="${height}" rx="2.6"></rect>
      <title>${label} · ${point.count} 段</title>
    </g>`;
  }).join('');
  const years = [];
  let lastYear = null;
  for (const point of points) {
    if (point.year !== lastYear) {
      years.push(`<text class="ribbon-year" x="${point.x.toFixed(1)}" y="158">${point.year}</text>`);
      lastYear = point.year;
    }
  }
  return `<section class="panel river-ribbon">
    <div class="river-ribbon-head">
      <div><h2>记忆长河</h2><p>${formatDateCN(state.stats.first)} — ${formatDateCN(state.stats.last)} · 每个刻度是一个月，点一下可以回到那段日子。</p></div>
      <div class="ribbon-legend"><i></i><span>记忆密度</span></div>
    </div>
    <div class="ribbon-wrap"><svg class="ribbon-svg" viewBox="0 0 900 166" role="group" aria-label="记忆长河，按月份显示记忆数量">
      <path class="ribbon-flow-2" d="M ${left} 146 C 240 126, 420 156, ${width - right} 132" opacity=".55"></path>
      <path class="ribbon-flow" d="${flow}" fill="none"></path>
      <path d="${area}" fill="var(--accent)" opacity=".07"></path>
      ${bars}
      ${years.join('')}
      <line x1="${left}" y1="145" x2="${width - right}" y2="145" stroke="var(--edge)" stroke-width="1"></line>
    </svg></div>
  </section>`;
}

function renderMemoryRow(entry) {
  return `<article class="memory-row" data-open="${escapeAttr(entry.id)}" tabindex="0" role="button" aria-label="打开 ${escapeAttr(entry.title)}">
    <div class="memory-date"><strong>${Number(entry.date.slice(8, 10))}</strong><span>${Number(entry.date.slice(5, 7))}月 · ${weekdayCN(entry.date)}</span></div>
    <div class="memory-copy">
      <div class="memory-title">${escapeHtml(entry.title)}</div>
      <p class="memory-excerpt">${escapeHtml(truncate(entry.body, 130))}</p>
      <div class="memory-meta">${entry.place ? `<span>${icon('location')} ${escapeHtml(entry.place)}</span>` : ''}${entry.tags.slice(0, 2).map((tag) => `<span class="tag">${escapeHtml(tag)}</span>`).join('')}${sourceChip(entry)}</div>
    </div>
    <div class="memory-side">
      <span class="memory-time">${escapeHtml(entry.time || '')}</span>
      <button class="fav-btn" type="button" data-action="favorite" data-id="${escapeAttr(entry.id)}" aria-pressed="${entry.favorite}" aria-label="${entry.favorite ? '取消收藏' : '收藏'} ${escapeAttr(entry.title)}">${icon(entry.favorite ? 'bookmark' : 'bookmark')}</button>
    </div>
  </article>`;
}

function renderOnThisDay(items, now) {
  if (!items.length) {
    return `<article class="panel quote-panel"><p class="eyebrow">ON THIS DAY</p><p class="quote-text quiet">今天没有旧年的回声。<br>日子还在往前走。</p><div class="quote-source"><span>${formatDateCN(now, { withWeekday: true })}</span><span>${icon('calendar')}</span></div></article>`;
  }
  const primary = items[0];
  return `<article class="panel quote-panel">
    <p class="eyebrow">ON THIS DAY · ${formatDateCN(primary.date)}</p>
    <div class="quote-text">${escapeHtml(truncate(primary.body, 150))}</div>
    <div class="quote-source"><span>${escapeHtml(primary.title)}${primary.place ? ` · ${escapeHtml(primary.place)}` : ''}</span><span>${items.length} 段回声</span></div>
    <div class="quote-actions">
      <button class="btn small" type="button" data-open="${escapeAttr(primary.id)}">重读这一天</button>
      ${items[1] ? `<button class="btn small ghost" type="button" data-open="${escapeAttr(items[1].id)}">另一段</button>` : ''}
    </div>
  </article>`;
}

function renderForgotten(entry) {
  if (!entry) return '';
  return `<article class="panel quiet-card">
    <div class="quiet-title">${icon('reunion')} 久未重读</div>
    <p>${escapeHtml(truncate(entry.body, 120))}</p>
    <div class="quiet-meta">${formatDateCN(entry.date)} · ${escapeHtml(entry.title)}</div>
    <div class="quote-actions"><button class="btn small ghost" type="button" data-open="${escapeAttr(entry.id)}">打开</button><button class="btn small ghost" type="button" data-action="forgotten-next">换一条</button></div>
  </article>`;
}

function renderMemoryStatus() {
  const source = state.memorySource === 'demo' ? '示例副本' : state.memorySource === 'import' ? '导入副本' : state.memorySource === 'local' ? '本机副本' : '还没有';
  const account = state.preview
    ? '演示模式未连接'
    : state.account.offline
      ? '暂时离线'
      : state.account.loadedCore
        ? '已连接'
        : '正在核对';
  return `<article class="panel status-panel">
    <div class="status-head"><h2>这份副本</h2>${icon('shield')}</div>
    <div class="status-row"><span class="status-dot"></span><span class="status-name">本地读取</span><span class="status-value">${escapeHtml(source)}</span></div>
    <div class="status-row"><span class="status-dot ${account === '暂时离线' ? 'warn' : ''}"></span><span class="status-name">账号服务</span><span class="status-value">${escapeHtml(account)}</span></div>
    <div class="status-row"><span class="status-dot muted"></span><span class="status-name">账号服务器中的日记</span><span class="status-value">不保存</span></div>
    <div class="status-row"><span class="status-dot muted"></span><span class="status-name">跨设备副本</span><span class="status-value">由原生 App 管理</span></div>
    <div class="status-row"><span class="status-dot muted"></span><span class="status-name">模型调用</span><span class="status-value">0 次</span></div>
    <p class="fine-print">这份控制台不会把正文、地点或标签发到账号服务。导入副本只在当前标签页里使用。</p>
    <div class="form-actions" style="margin-top:10px"><button class="btn tiny ghost" type="button" data-action="import">导入另一份</button><button class="btn tiny ghost" type="button" data-action="clear-memory">清除本机副本</button></div>
  </article>`;
}

function renderUnderstandingMini(item) {
  const countEvidence = item.evidenceIds?.length || 0;
  return `<article class="panel understanding-mini">
    <div class="u-label">${icon('understanding')} AI 暂定解释 · 待你确认</div>
    <blockquote>${escapeHtml(item.statement)}</blockquote>
    <div class="u-foot"><span>${countEvidence} 条依据 · ${escapeHtml(item.scope || '范围未标注')}</span><span class="mini-actions"><button class="btn tiny ghost" type="button" data-action="confirm-understanding" data-id="${escapeAttr(item.id)}">像</button><button class="btn tiny ghost" type="button" data-action="correct-understanding" data-id="${escapeAttr(item.id)}">不像</button></span></div>
  </article>`;
}

/* ---------- river ---------- */

function renderRiver() {
  const filtered = filteredEntries();
  const active = activeFilterChips();
  const years = [...new Set(state.entries.map((entry) => entry.date.slice(0, 4)))].sort().reverse();
  return `${renderPreviewBanner()}
  <div class="view-head">
    <div><p class="eyebrow">THE LONG RIVER</p><h1>长河</h1><p class="view-sub">从原话、日期和地点里找回过去。这里不替你总结，只把入口放好。</p></div>
    <div class="view-head-actions"><button class="btn ghost small" type="button" data-action="open-import">${icon('export')} 导入副本</button></div>
  </div>
  <div class="filter-bar panel">
    <label class="filter-search">${icon('search')}<input id="river-search" type="search" value="${escapeAttr(state.filters.query)}" placeholder="搜索一句话、一个人、一个地方…" autocomplete="off" aria-label="搜索记忆"></label>
    <span class="select-wrap"><select id="river-year" aria-label="按年份筛选"><option value="all">全部年份</option>${years.map((year) => `<option value="${year}" ${state.filters.year === year ? 'selected' : ''}>${year} 年</option>`).join('')}</select>${icon('chevron-down')}</span>
    <span class="select-wrap"><select id="river-kind" aria-label="按类型筛选"><option value="all">全部类型</option>${Object.entries(KIND_LABELS).map(([kind, label]) => `<option value="${kind}" ${state.filters.kind === kind ? 'selected' : ''}>${label}</option>`).join('')}</select>${icon('chevron-down')}</span>
    <button class="chip-toggle" type="button" data-action="toggle-favorites-filter" aria-pressed="${state.filters.favorite}">${icon('bookmark')} 只看收藏</button>
    <button class="chip-toggle" id="filter-clear-btn" type="button" data-action="filter-clear" ${active.length ? '' : 'hidden'}>${icon('close')} 清空筛选</button>
  </div>
  <div id="active-filters" class="active-filters">${active.map((chip) => `<span class="active-filter">${escapeHtml(chip.label)}<button type="button" data-action="filter-remove" data-filter="${escapeAttr(chip.key)}" data-value="${escapeAttr(chip.value ?? '')}" aria-label="移除筛选 ${escapeAttr(chip.label)}">${icon('close')}</button></span>`).join('')}</div>
  <div id="timeline-summary" class="hint-row" style="margin-top:13px">${renderTimelineSummary(filtered)}</div>
  <div id="timeline-results" class="timeline">${renderTimelineResults(filtered)}</div>
  `;
}

function filteredEntries() {
  return filterEntries(state.entries, {
    ...state.filters,
    collectionId: state.filters.collection,
    now: new Date(),
  });
}

function activeFilterChips() {
  const chips = [];
  if (state.filters.query.trim()) chips.push({ key: 'query', label: `搜索：${state.filters.query.trim()}`, value: state.filters.query });
  if (state.filters.year !== 'all') chips.push({ key: 'year', label: `${state.filters.year} 年`, value: state.filters.year });
  if (state.filters.kind !== 'all') chips.push({ key: 'kind', label: KIND_LABELS[state.filters.kind] || state.filters.kind, value: state.filters.kind });
  if (state.filters.favorite) chips.push({ key: 'favorite', label: '只看收藏', value: '1' });
  if (state.filters.tag) chips.push({ key: 'tag', label: `标签：${state.filters.tag}`, value: state.filters.tag });
  if (state.filters.place) chips.push({ key: 'place', label: `地点：${state.filters.place}`, value: state.filters.place });
  if (state.filters.collection === 'favorites') chips.push({ key: 'collection', label: '我的收藏', value: 'favorites' });
  else if (state.filters.collection) {
    const collection = state.collections.find((item) => item.id === state.filters.collection);
    chips.push({ key: 'collection', label: `合集：${collection?.title || '未知合集'}`, value: state.filters.collection });
  }
  if (state.filters.day) chips.push({ key: 'day', label: formatDateCN(state.filters.day), value: state.filters.day });
  return chips;
}

function renderTimelineSummary(filtered) {
  const bits = [`${count(filtered.length)} 段`];
  if (state.filters.query.trim()) bits.push(`搜索「${escapeHtml(state.filters.query.trim())}」`);
  if (state.filters.collection === 'favorites') bits.push('我的收藏');
  else if (state.filters.collection) {
    const collection = state.collections.find((item) => item.id === state.filters.collection);
    bits.push(collection ? `合集「${escapeHtml(collection.title)}」` : '一个合集');
  }
  if (state.filters.tag) bits.push(`#${escapeHtml(state.filters.tag)}`);
  if (state.filters.place) bits.push(escapeHtml(state.filters.place));
  if (state.filters.day) bits.push(formatDateCN(state.filters.day));
  else if (state.filters.year !== 'all') bits.push(`${state.filters.year} 年`);
  if (filtered.length) {
    const sorted = [...filtered].sort((a, b) => a.date.localeCompare(b.date));
    bits.push(`${formatDateCN(sorted[0].date)} — ${formatDateCN(sorted.at(-1).date)}`);
  }
  bits.push('按时间倒序');
  return bits.map((bit) => `<span>${bit}</span>`).join('<span class="muted">·</span>');
}

function renderTimelineResults(filtered) {
  if (!filtered.length) {
    return `<div class="empty-state timeline-empty"><div class="empty-icon">${icon('search')}</div><h2>这条支流暂时没有水</h2><p>没有找到符合当前条件的记忆。可以少一个筛选条件，或者回到全部长河。</p><div class="empty-actions"><button class="btn" type="button" data-action="filter-clear">清空筛选</button><button class="btn ghost" type="button" data-action="import">导入更多副本</button></div></div>`;
  }
  const visible = filtered.slice(0, state.timelineLimit);
  const groups = groupByMonth(visible);
  const terms = queryTerms(state.filters.query, new Date());
  const html = groups.map((group) => `<section class="month-group">
    <div class="month-head"><h2>${group.label}</h2><span class="month-count">${group.entries.length}</span></div>
    <div class="timeline-list">${group.entries.map((entry) => renderMemoryCard(entry, terms)).join('')}</div>
  </section>`).join('');
  const more = filtered.length > state.timelineLimit
    ? `<div class="load-more"><button class="btn ghost" type="button" data-action="load-more">再看 ${Math.min(30, filtered.length - state.timelineLimit)} 段</button></div>`
    : '';
  return html + more;
}

function renderMemoryCard(entry, terms = []) {
  const excerpt = truncate(entry.body, 240);
  return `<article class="panel memory-card" data-open="${escapeAttr(entry.id)}" tabindex="0" role="button" aria-label="打开 ${escapeAttr(entry.title)}">
    <div class="memory-date"><strong>${Number(entry.date.slice(8, 10))}</strong><span>${Number(entry.date.slice(5, 7))}月 · ${weekdayCN(entry.date)}</span></div>
    <div class="memory-copy">
      <h3>${highlightHtml(entry.title, terms)}</h3>
      <p class="memory-excerpt">${highlightHtml(excerpt, terms)}</p>
      <div class="memory-meta">
        ${entry.place ? `<span>${icon('location')} ${escapeHtml(entry.place)}</span>` : ''}
        ${entry.tags.slice(0, 3).map((tag) => `<span class="tag">${escapeHtml(tag)}</span>`).join('')}
        ${sourceChip(entry)}
        ${entry.time ? `<span class="mono">${escapeHtml(entry.time)}</span>` : ''}
      </div>
    </div>
    <div class="memory-side">
      <span class="memory-kind">${icon(KIND_ICONS[entry.kind] || 'journal')}</span>
      <button class="fav-btn" type="button" data-action="favorite" data-id="${escapeAttr(entry.id)}" aria-pressed="${entry.favorite}" aria-label="${entry.favorite ? '取消收藏' : '收藏'} ${escapeAttr(entry.title)}">${icon('bookmark')}</button>
    </div>
  </article>`;
}

function updateTimelineResults() {
  const filtered = filteredEntries();
  const results = $('#timeline-results');
  if (results) results.innerHTML = renderTimelineResults(filtered);
  const summary = $('#timeline-summary');
  if (summary) summary.innerHTML = renderTimelineSummary(filtered);
  const active = activeFilterChips();
  const chips = $('#active-filters');
  if (chips) chips.innerHTML = active.map((chip) => `<span class="active-filter">${escapeHtml(chip.label)}<button type="button" data-action="filter-remove" data-filter="${escapeAttr(chip.key)}" data-value="${escapeAttr(chip.value ?? '')}" aria-label="移除筛选 ${escapeAttr(chip.label)}">${icon('close')}</button></span>`).join('');
  const clearButton = $('#filter-clear-btn');
  if (clearButton) clearButton.hidden = active.length === 0;
}

function clearFilters() {
  state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: '', collection: '', day: '' };
}

/* ---------- collections ---------- */

function renderCollections() {
  const favorites = state.entries.filter((entry) => entry.favorite);
  const tags = tagSummary(state.entries);
  const collections = state.collections.map((collection, index) => {
    const entries = collectionEntries(state.entries, collection);
    return { ...collection, entries, index };
  }).filter((collection) => collection.entries.length);
  return `${renderPreviewBanner()}
  <div class="view-head">
    <div><p class="eyebrow">CHAPTERS & KEEPERS</p><h1>合集与章节</h1><p class="view-sub">把散落的日子收成几段可以回头看的章节。收藏是你亲手放下的书签，不参与任何评分。</p></div>
    <div class="view-head-actions"><button class="btn ghost small" type="button" data-action="import">${icon('export')} 导入副本</button></div>
  </div>
  ${collections.length ? `<div class="collection-grid">${collections.map((collection) => renderCollectionCard(collection)).join('')}</div>` : `<div class="empty-state"><div class="empty-icon">${icon('chapter')}</div><h2>还没有章节</h2><p>章节来自你导入的记忆副本。你也可以在原生 App 中整理一段日子，再导出新的副本。</p><div class="empty-actions"><button class="btn" type="button" data-action="import">导入带章节的副本</button><a class="btn ghost" href="https://flowriver.xyz/#download">打开客户端 ↗</a></div></div>`}
  <section class="section">
    <div class="section-head"><h2>我的收藏</h2><span class="section-note">${favorites.length} 段 · 只保存在这个浏览器</span></div>
    ${favorites.length ? `<div class="favorites-panel panel panel-pad"><div class="favorite-list">${favorites.slice(0, 8).map((entry) => `<div class="favorite-item" data-open="${escapeAttr(entry.id)}" tabindex="0" role="button"><div class="favorite-title">${escapeHtml(entry.title)}</div><div class="favorite-quote">${escapeHtml(truncate(entry.body, 100))}</div><div class="favorite-meta">${formatDateCN(entry.date)} · ${escapeHtml(entry.place || '没有地点')}</div></div>`).join('')}</div></div>` : `<div class="empty-state"><div class="empty-icon">${icon('bookmark')}</div><h2>还没有收藏</h2><p>在长河里点一下书签，句子就会留在这里。收藏只写入当前浏览器，不会同步到账号服务。</p><div class="empty-actions"><a class="btn" href="#/river">去长河看看</a></div></div>`}
  </section>
  <section class="section">
    <div class="section-head"><h2>主题</h2><span class="section-note">从你自己的文字里长出来</span></div>
    <div class="tag-cloud">${tags.map((tag) => `<button class="tag-pill" type="button" data-action="filter-tag" data-tag="${escapeAttr(tag.name)}">${escapeHtml(tag.name)} <b>${tag.count}</b></button>`).join('') || '<span class="muted small">还没有主题标签。</span>'}</div>
  </section>
  `;
}

function renderCollectionCard(collection) {
  const first = collection.entries.at(-1);
  const last = collection.entries[0];
  return `<article class="panel collection-card" data-collection="${escapeAttr(collection.id)}" tabindex="0" role="button" aria-label="打开合集 ${escapeAttr(collection.title)}">
    <span class="collection-index">CHAPTER ${String(collection.index + 1).padStart(2, '0')}</span>
    <h2>${escapeHtml(collection.title)}</h2>
    <p>${escapeHtml(collection.description || '一段还在长出来的日子。')}</p>
    <div class="collection-foot"><span>${formatDateCN(first.date)} — ${formatDateCN(last.date)} · ${collection.entries.length} 段</span>${icon('forward')}</div>
  </article>`;
}

/* ---------- places ---------- */

function renderPlaces() {
  const places = placeSummary(state.entries);
  if (!places.length) {
    return `${renderPreviewBanner()}
    <div class="view-head"><div><p class="eyebrow">PLACES WITHIN</p><h1>地点里的我</h1><p class="view-sub">地点只从记忆副本里的名字读取，不打开定位，也不画路线。</p></div></div>
    <div class="empty-state"><div class="empty-icon">${icon('map')}</div><h2>还没有地点</h2><p>当你在记忆里写下一个地方，它会在这里出现。网页不会向你要位置权限。</p><div class="empty-actions"><button class="btn" type="button" data-action="import">导入带地点的副本</button><a class="btn ghost" href="#/river">回到长河</a></div></div>`;
  }
  if (!state.selectedPlace || !places.some((place) => place.name === state.selectedPlace)) state.selectedPlace = places[0].name;
  const selected = places.find((place) => place.name === state.selectedPlace) || places[0];
  const positions = mapPositions(places.length);
  const dots = places.map((place, index) => {
    const point = positions[index];
    const radius = 5 + Math.min(place.count, 5);
    return `<g class="place-dot ${place.name === selected.name ? 'active' : ''}" data-place="${escapeAttr(place.name)}" tabindex="0" role="button" aria-label="${escapeAttr(place.name)}，${place.count} 段记忆">
      <title>${escapeHtml(place.name)} · ${place.count} 段记忆</title>
      <circle class="dot-hit" cx="${point.x}" cy="${point.y}" r="${radius + 10}" fill="transparent"></circle>
      <circle class="dot-halo" cx="${point.x}" cy="${point.y}" r="${radius + 6}"></circle>
      <circle class="dot-main" cx="${point.x}" cy="${point.y}" r="${radius}"></circle>
      ${place.name === selected.name ? `<text class="dot-label" x="${point.x + radius + 6}" y="${point.y + 3}">${escapeHtml(place.name)}</text>` : ''}
    </g>`;
  }).join('');
  return `${renderPreviewBanner()}
  <div class="view-head">
    <div><p class="eyebrow">PLACES WITHIN</p><h1>地点里的我</h1><p class="view-sub">在同一个地方，遇见这次、上次和那次的自己。地图是按名字生成的抽象位置，不是真实坐标。</p></div>
    <div class="view-head-actions"><span class="tag">${places.length} 个地点</span></div>
  </div>
  <div class="places-layout">
    <section class="panel map-panel">
      <div class="place-map">
        <svg viewBox="0 0 600 360" role="group" aria-label="按记忆里的地点生成的抽象地图">
          <path class="map-river-fill" d="M-20 255 C90 220 120 270 210 230 C300 190 330 235 420 190 C500 150 540 170 620 120 L620 360 L-20 360 Z"></path>
          <path class="map-river" d="M-20 250 C90 215 120 265 210 225 C300 185 330 230 420 185 C500 145 540 165 620 115"></path>
          <path class="map-contour" d="M60 60 C120 30 180 45 220 78 C255 106 230 142 180 150 C120 160 70 130 60 100 Z"></path>
          <path class="map-contour" d="M390 50 C460 25 535 50 560 95 C580 132 535 165 475 157 C405 147 360 90 390 50 Z"></path>
          <path class="map-contour" d="M80 255 C140 235 200 250 215 292 C228 330 170 348 118 335 C62 321 45 279 80 255 Z"></path>
          <path class="map-contour" d="M360 245 C430 220 510 240 525 285 C538 326 472 348 415 336 C355 323 320 272 360 245 Z"></path>
          <path class="map-contour" d="M250 120 C290 105 330 115 340 140 C350 166 318 184 285 178 C250 171 228 137 250 120 Z"></path>
          ${dots}
        </svg>
      </div>
      <div class="map-note"><span>抽象地图 · 按地点名称生成</span><span>${icon('shield')} 不读取定位</span></div>
      <div class="place-list">${places.map((place) => `<div class="place-row ${place.name === selected.name ? 'active' : ''}" data-place="${escapeAttr(place.name)}" tabindex="0" role="button"><span class="place-line" style="--tone: var(--tone-${escapeAttr(place.tone || 'sea')});"></span><span class="place-name">${escapeHtml(place.name)}</span><span class="place-count">${place.count}</span></div>`).join('')}</div>
    </section>
    <aside class="panel place-detail">
      <p class="place-kicker">YOU WERE HERE</p>
      <h2>${escapeHtml(selected.name)}</h2>
      <p class="place-range">${formatDateCN(selected.first.date)} 第一次 · ${formatDateCN(selected.last.date)} 最近 · ${selected.count} 段</p>
      <div class="place-quote">${escapeHtml(truncate(selected.last.body, 150))}</div>
      <div class="place-memories">${selected.entries.slice(0, 6).map((entry) => `<div class="place-memory" data-open="${escapeAttr(entry.id)}" tabindex="0" role="button"><time>${Number(entry.date.slice(5, 7))}月${Number(entry.date.slice(8, 10))}日</time><span class="place-memory-title">${escapeHtml(entry.title)}</span></div>`).join('')}</div>
      <div class="detail-actions"><button class="btn small ghost" type="button" data-action="filter-place" data-place="${escapeAttr(selected.name)}">在长河里看全部</button><button class="btn small ghost" type="button" data-action="import">导入更多副本</button></div>
      <p class="fine-print" style="margin-top:14px">地点名称来自你的副本。原始坐标、路线和“人生第一次”不会被这个页面推断或展示。</p>
    </aside>
  </div>
  `;
}

function mapPositions(length) {
  const fixed = [
    [118, 104], [268, 76], [420, 100], [510, 158], [445, 260], [300, 278],
    [158, 238], [210, 158], [342, 176], [492, 74], [82, 296], [535, 278],
    [350, 316], [220, 326], [462, 198],
  ];
  return Array.from({ length }, (_, index) => {
    const [x, y] = fixed[index % fixed.length];
    return { x: x + (index >= fixed.length ? 7 : 0), y: y + (index >= fixed.length ? 5 : 0) };
  });
}

/* ---------- understanding ---------- */

function effectiveUnderstandings() {
  return state.understandings.map((item) => {
    const override = state.understandingOverrides[item.id] || {};
    return { ...item, status: override.status ?? item.status, correction: override.correction ?? item.correction };
  });
}

function renderUnderstanding() {
  const items = effectiveUnderstandings();
  const pending = items.filter((item) => item.status === 'pending');
  const confirmed = items.filter((item) => item.status === 'confirmed');
  const rejected = items.filter((item) => item.status === 'rejected');
  const entryMap = new Map(state.entries.map((entry) => [entry.id, entry]));
  return `${renderPreviewBanner()}
  <div class="view-head">
    <div><p class="eyebrow">RIVER'S UNDERSTANDING</p><h1>River 的理解</h1><p class="view-sub">不是结论，是暂定的解释。每一张卡都可以被确认、改写或撤销；你说了算。</p></div>
    <div class="view-head-actions"><span class="tag ${pending.length ? 'warn' : 'ok'}">${pending.length} 条待确认</span></div>
  </div>
  <section class="panel understanding-intro">
    <h2>River 先摊开依据，再说话。</h2>
    <p>这些理解来自你在记忆里写下的片段。它们不是人格评分，也不是在替你解释情绪。确认只影响这张卡；要让某个理解以后继续适用，需要你在原生 App 里明确设置。</p>
    <div class="intent-row"><span class="tag">先有依据</span><span class="tag">可改写</span><span class="tag">可撤销</span><span class="tag">不自动升级为长期规则</span></div>
  </section>
  ${items.length ? '' : `<div class="empty-state" style="margin-top:20px"><div class="empty-icon">${icon('understanding')}</div><h2>还没有理解卡</h2><p>当副本里出现足够多互相独立的依据，River 才会提出暂定理解。你也可以先浏览长河，看看哪些日子值得回头。</p><div class="empty-actions"><a class="btn" href="#/river">去长河</a><button class="btn ghost" type="button" data-action="import">导入带理解的副本</button></div></div>`}
  ${pending.length ? `<section class="section"><div class="section-head"><h2>待你确认</h2><span class="section-note">${pending.length} 张 · 不处理也不会催</span></div><div class="u-grid">${pending.map((item) => renderUnderstandingCard(item, entryMap)).join('')}</div></section>` : ''}
  ${confirmed.length ? `<section class="section"><div class="section-head"><h2>你确认过的</h2><span class="section-note">${confirmed.length} 张</span></div><div class="u-grid">${confirmed.map((item) => renderUnderstandingCard(item, entryMap)).join('')}</div></section>` : ''}
  ${rejected.length ? `<section class="section"><div class="section-head"><h2>你纠正过的</h2><span class="section-note">${rejected.length} 张 · 原文和依据仍在</span></div><div class="u-grid">${rejected.map((item) => renderUnderstandingCard(item, entryMap)).join('')}</div></section>` : ''}
  `;
}

function renderUnderstandingCard(item, entryMap) {
  const evidence = (item.evidenceIds || []).map((id) => entryMap.get(id)).filter(Boolean);
  const canConfirm = item.status === 'pending';
  const canRevoke = item.status === 'confirmed';
  const statusTag = item.status === 'pending'
    ? '<span class="tag warn">待确认</span>'
    : item.status === 'confirmed'
      ? '<span class="tag ok">已确认</span>'
      : '<span class="tag">已纠正</span>';
  return `<article class="panel u-card ${escapeAttr(item.status)}">
    <div class="u-top"><div class="u-tags"><span class="tag accent">AI 暂定解释</span>${statusTag}<span class="tag">${escapeHtml({ rhythm: '生活节奏', pattern: '重复出现', habit: '习惯', season: '季节' }[item.kind] || '理解')}</span></div><span class="u-source">River 的理解卡</span></div>
    <div class="u-statement">${escapeHtml(item.statement)}</div>
    <div class="u-scope">${escapeHtml(item.scope || '适用范围未标注')}</div>
    ${evidence.length ? `<div class="u-evidence"><span class="u-evidence-label">依据 · ${evidence.length} 段原话</span>${evidence.map((entry) => `<button class="evidence-row" type="button" data-open="${escapeAttr(entry.id)}"><time>${formatDateCN(entry.date, { withYear: false })}</time><span>${escapeHtml(entry.title)} · ${escapeHtml(truncate(entry.body, 42))}</span></button>`).join('')}</div>` : '<p class="fine-print" style="margin-top:13px">这张卡没有可读的依据。暂时不要据此下结论。</p>'}
    ${item.correction ? `<div class="u-correction"><strong>你的纠正：</strong>${escapeHtml(item.correction)}</div>` : ''}
    <div class="u-actions">
      ${canConfirm ? `<button class="btn small" type="button" data-action="confirm-understanding" data-id="${escapeAttr(item.id)}">${icon('success')} 像</button><button class="btn small ghost" type="button" data-action="correct-understanding" data-id="${escapeAttr(item.id)}">${icon('edit')} 不像，改一下</button>` : ''}
      ${canRevoke ? `<button class="btn small ghost" type="button" data-action="revoke-understanding" data-id="${escapeAttr(item.id)}">撤销确认</button>` : ''}
      ${item.status === 'rejected' ? `<button class="btn small ghost" type="button" data-action="reopen-understanding" data-id="${escapeAttr(item.id)}">再看看</button>` : ''}
      <a class="btn small ghost" href="#/ask">${icon('chat')} 继续问</a>
    </div>
    <div class="u-footnote">${icon('info')} 这张卡不会因为一次确认变成适用于所有日子的规则；也不会使用模型自报的置信度。</div>
  </article>`;
}

/* ---------- ask ---------- */

function initialAskMessage() {
  return {
    role: 'river',
    kind: 'greeting',
    text: state.entries.length
      ? `想问我哪一段过去？我会只在这份 ${count(state.entries.length)} 段记忆副本里查找，引用原话和日期。`
      : '还没有可检索的记忆副本。导入一份由河流日记导出的副本后，我会只在你的浏览器里查找。',
  };
}

function askMessages() {
  if (!state.ask.messages.length) state.ask.messages = [initialAskMessage()];
  return state.ask.messages;
}

function renderAsk() {
  const messages = askMessages();
  const suggestions = [
    '去年秋天我在做什么？',
    '什么时候开始跑步的？',
    '哪些日子提到过厨房？',
    '最近让我开心的小事',
  ];
  return `${renderPreviewBanner()}
  <div class="view-head">
    <div><p class="eyebrow">ASK RIVER · LOCAL RETRIEVAL</p><h1>问 River</h1><p class="view-sub">先在本机副本里找原话，再回答你。它不调用模型，不编造原因，也不把问题发出去。</p></div>
    <div class="view-head-actions"><span class="tag ok">${icon('shield')} 未上传</span></div>
  </div>
  <div class="ask-layout">
    <section class="panel chat-panel">
      <div class="chat-scroll" id="chat-scroll">${messages.map((message) => renderAskMessage(message)).join('')}</div>
      <form class="chat-compose" id="ask-form" data-form="ask">
        <textarea id="ask-input" rows="1" maxlength="500" placeholder="问一件过去的事，比如「去年秋天我在做什么？」" aria-label="问 River 一个关于过去的问题"></textarea>
        <button class="send-btn" type="submit" aria-label="发送问题">${icon('send')}</button>
      </form>
      <div class="chat-foot"><span>${icon('shield')} 本机检索 · 未调用模型</span><span>Enter 发送 · Shift + Enter 换行</span></div>
    </section>
    <aside class="ask-aside">
      <section class="panel">
        <h2>可以这样问</h2>
        <p>时间、地点、一个人，或一句你还记得的话。</p>
        <div class="suggestion-list">${suggestions.map((text) => `<button class="suggestion" type="button" data-action="ask-suggestion" data-question="${escapeAttr(text)}">${escapeHtml(text)}</button>`).join('')}</div>
      </section>
      <section class="panel">
        <h2>检索范围</h2>
        <div class="scope-list">
          <label class="scope-option"><input type="radio" name="ask-scope" value="all" ${state.ask.scope === 'all' ? 'checked' : ''}> 全部副本</label>
          <label class="scope-option"><input type="radio" name="ask-scope" value="favorites" ${state.ask.scope === 'favorites' ? 'checked' : ''}> 只看收藏</label>
          <label class="scope-option"><input type="radio" name="ask-scope" value="year" ${state.ask.scope === 'year' ? 'checked' : ''}> 今年</label>
        </div>
        <p class="fine-print" style="margin-top:9px">范围只影响这次查找；不会改变你的收藏或账号设置。</p>
      </section>
      <section class="panel">
        <h2>River 不会做什么</h2>
        <div class="ask-boundaries">
          <div class="ask-boundary">${icon('success')} 不会把一次记录说成长期性格</div>
          <div class="ask-boundary">${icon('success')} 不会在原文之外补上原因</div>
          <div class="ask-boundary">${icon('success')} 不会把问题或正文上传</div>
          <div class="ask-boundary">${icon('success')} 不会诊断情绪或健康</div>
        </div>
      </section>
    </aside>
  </div>
  `;
}

function renderAskMessage(message) {
  if (message.role === 'user') {
    return `<div class="message user"><div class="message-body">${escapeHtml(message.text)}</div></div>`;
  }
  if (message.kind === 'greeting') {
    return `<div class="message river"><div class="message-avatar">${icon('river')}</div><div class="message-body"><p>${escapeHtml(message.text)}</p><div class="message-note">River · 本机检索 · 只读副本</div></div></div>`;
  }
  const answer = message.answer;
  if (!answer) return '';
  const findings = answer.findings || [];
  return `<div class="message river"><div class="message-avatar">${icon('river')}</div><div class="message-body">
    <div class="answer-block">
      <p class="answer-intro">${escapeHtml(answer.intro)}</p>
      ${findings.map((finding) => `<article class="answer-finding"><div class="finding-head"><strong>${escapeHtml(finding.title)}</strong><time>${escapeHtml(finding.dateLabel)}</time></div><blockquote>${escapeHtml(finding.quote)}</blockquote><button class="finding-link" type="button" data-open="${escapeAttr(finding.entry.id)}">打开这段记忆 →</button></article>`).join('')}
      ${answer.closing ? `<p class="answer-closing">${escapeHtml(answer.closing)}</p>` : ''}
      ${answer.suggestions?.length ? `<div class="answer-suggestions">${answer.suggestions.map((suggestion) => `<button class="answer-suggestion" type="button" data-action="ask-suggestion" data-question="${escapeAttr(suggestion)}">${escapeHtml(suggestion)}</button>`).join('')}</div>` : ''}
      <div class="answer-meta"><span class="tag">${escapeHtml(answer.note || '本机检索 · 未调用模型')}</span>${findings.length ? `<span class="tag">${findings.length} 条引用</span>` : ''}</div>
    </div>
    <div class="message-note">River · 本机检索 · 只读副本</div>
  </div></div>`;
}

function scopedEntriesForAsk() {
  if (state.ask.scope === 'favorites') return state.entries.filter((entry) => entry.favorite);
  if (state.ask.scope === 'year') {
    const year = String(new Date().getFullYear());
    return state.entries.filter((entry) => entry.date.startsWith(year));
  }
  return state.entries;
}

function submitAsk(text) {
  const question = String(text ?? '').trim();
  if (!question) return;
  state.ask.messages.push({ role: 'user', text: question });
  const scoped = scopedEntriesForAsk();
  const answer = answerFromMemory(scoped, question, { now: new Date() });
  state.ask.messages.push({ role: 'river', kind: 'answer', answer });
  if (state.ask.messages.length > 18) state.ask.messages = state.ask.messages.slice(-18);
  const view = $('#chat-scroll');
  if (view) {
    view.innerHTML = state.ask.messages.map((message) => renderAskMessage(message)).join('');
    view.scrollTop = view.scrollHeight;
  }
  const input = $('#ask-input');
  if (input) { input.value = ''; input.style.height = ''; input.focus(); }
}

/* ---------- account ---------- */

async function renderAccountRoute(sub, token, { focus = false, standalone = false } = {}) {
  const section = ACCOUNT_SECTIONS.includes(sub) ? sub : 'overview';
  const cloudStandalone = standalone || (section === 'cloud' && !standalone);
  if (section === 'cloud' && !standalone) {
    await renderAccountRoute('cloud', token, { focus, standalone: true });
    return;
  }
  if (state.preview) {
    setView(cloudStandalone ? renderCloudPreview() : renderAccountPreview(section));
    document.title = cloudStandalone ? '云空间 · 河流日记' : '账号与设置 · 河流日记';
    if (focus) focusHeading();
    return;
  }
  if (!state.account.client) {
    setView(cloudStandalone ? renderCloudPreview() : renderAccountPreview(section));
    return;
  }
  if (!state.account.loadedCore) {
    setView(cloudStandalone ? renderCloudSkeleton() : renderAccountSkeleton(section));
    document.title = cloudStandalone ? '云空间 · 河流日记' : '账号与设置 · 河流日记';
    if (!state.account.coreLoading) {
      state.account.loadingCore = true;
      loadAccountCore().catch((error) => {
        if (error instanceof AuthRequiredError || error instanceof AuthExpiredError) {
          redirectToLogin();
          throw error;
        }
        if (error instanceof AccountSwitchedError) { location.reload(); throw error; }
        state.account.offline = true;
        state.account.error = error instanceof TypeError || error?.name === 'AbortError'
          ? '账号服务暂时离线；记忆副本仍可浏览。'
          : (error.message || '账号服务暂时不可用。');
      }).finally(() => { state.account.loadingCore = false; });
    }
    try { await state.account.coreLoading; } catch { /* rendered below */ }
    if (token !== renderToken) return;
  }
  if (state.account.error && !state.account.loadedCore) {
    setView(cloudStandalone ? renderCloudError() : renderAccountError(section));
    return;
  }
  try {
    await ensureAccountSection(section);
  } catch (error) {
    if (error instanceof AuthRequiredError || error instanceof AuthExpiredError) {
      redirectToLogin();
      return;
    }
    if (error instanceof AccountSwitchedError) { location.reload(); return; }
    state.account.error = error instanceof TypeError || error?.name === 'AbortError'
      ? '网络连接中断，账号记录没有读取完成。'
      : (error.message || '账号记录没有读取完成。');
  }
  if (token !== renderToken) return;
  setView(cloudStandalone ? renderCloudStandaloneView() : renderAccountView(section));
  document.title = cloudStandalone ? '云空间 · 河流日记' : '账号与设置 · 河流日记';
  if (focus) focusHeading();
  if (focus) window.scrollTo({ top: 0, behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
}

function loadAccountCore() {
  if (state.account.coreLoading) return state.account.coreLoading;
  const client = state.account.client;
  if (!client) return Promise.reject(new AuthRequiredError());
  const job = (async () => {
    const [me, rights, devices, password] = await Promise.all([
      client.get('/me'),
      client.get('/me/entitlements'),
      client.get('/me/devices'),
      client.get('/me/password'),
    ]);
    state.account.me = me;
    state.account.identities = me.identities || [];
    state.account.entitlements = rights.entitlements || [];
    state.account.devices = devices.devices || [];
    state.account.password = password;
    state.account.loadedCore = true;
    state.account.error = '';
    state.account.offline = false;
    updateShellIdentity();
    if (state.route.space === 'home') refreshView();
    return me;
  })();
  state.account.coreLoading = job;
  state.account.loadingCore = true;
  job.catch(() => {}).finally(() => {
    state.account.coreLoading = null;
    state.account.loadingCore = false;
  });
  return job;
}

async function ensureAccountSection(section) {
  if (section === 'overview' || section === 'preferences' || section === 'security') return;
  if (state.account.sectionLoaded[section]) return;
  const client = state.account.client;
  if (!client) return;
  if (state.account.sectionLoading[section]) return state.account.sectionLoading[section];
  const job = (async () => {
    if (section === 'devices') {
      const [devices, sessions] = await Promise.all([client.get('/me/devices'), client.get('/me/sessions')]);
      state.account.devices = devices.devices || [];
      state.account.sessions = sessions.sessions || [];
    }
    if (section === 'entitlements') {
      const data = await client.get('/me/redemptions');
      state.account.redemptions = data.redemptions || [];
    }
    if (section === 'activity') {
      const data = await client.get('/me/activity');
      state.account.activity = data.events || [];
    }
    if (section === 'feedback') {
      const data = await client.get('/me/feedback');
      state.account.feedback = data.messages || [];
    }
    if (section === 'cloud') {
      await loadCloudMeta(true);
    }
    state.account.sectionLoaded[section] = true;
  })().finally(() => { state.account.sectionLoading[section] = null; });
  state.account.sectionLoading[section] = job;
  return job;
}

async function loadCloudMeta(force = false) {
  const client = state.account.client;
  if (!client) throw new AuthRequiredError();
  if (!force && state.cloud.meta) return state.cloud.meta;
  if (state.cloud.loading) return state.cloud.loading;
  const job = (async () => {
    const data = await client.get('/me/memory-mirror/meta');
    state.cloud.meta = data?.exists ? data : { exists: false };
    state.cloud.error = '';
    return state.cloud.meta;
  })().finally(() => { state.cloud.loading = null; });
  state.cloud.loading = job;
  return job;
}

function formatBytes(value) {
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes < 0) return '—';
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB'];
  let size = bytes / 1024;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) { size /= 1024; index += 1; }
  return `${size.toFixed(size >= 10 ? 0 : 1)} ${units[index]}`;
}

function accountProfile() {
  const me = state.account.me;
  const emailValue = accountEmail();
  const name = emailValue.split('@')[0] || '记录者';
  return {
    name,
    email: emailValue || '已登录',
    initial: initials(name),
    status: accountStatusLabel(me?.user?.status),
    id: me?.user?.id || '',
    terms: me?.user?.terms_version || '待核对',
    privacy: me?.user?.privacy_version || '待核对',
    pending: me?.pending_security_changes || [],
  };
}

function renderAccountTabs(section) {
  const labels = [
    ['overview', '概览'], ['devices', '设备与会话'], ['entitlements', '权益与兑换'],
    ['security', '登录安全'], ['activity', '安全活动'], ['feedback', '反馈与回复'], ['preferences', '资料与偏好'],
  ];
  return `<nav class="account-tabs panel" aria-label="账号子栏目">${labels.map(([key, label]) => `<a class="account-tab" href="#/account/${key}" ${key === section ? 'aria-current="page"' : ''}>${label}</a>`).join('')}</nav>`;
}

function renderAccountView(section) {
  const profile = accountProfile();
  const pendingBanner = profile.pending.length
    ? `<div class="banner">有敏感变更正在等待安全日志确认。你可以在「登录安全」里核对。</div>`
    : '';
  const error = state.account.error ? `<div class="banner bad">${escapeHtml(state.account.error)}</div>` : '';
  return `${renderPreviewBanner()}
  <div class="account">
    <div class="view-head">
      <div><p class="eyebrow">ACCOUNT & PRIVACY</p><h1>账号与设置</h1><p class="view-sub">身份、设备、权益与反馈在这里。记忆默认只在本机；只有你主动开启的云空间会单独保存密文。</p></div>
      <div class="view-head-actions"><button class="btn ghost small" type="button" data-action="refresh-account">${icon('refresh')} 刷新账号</button><a class="btn small ghost" href="#/home">${icon('back')} 回首页</a></div>
    </div>
    ${pendingBanner}${error}
    ${renderAccountTabs(section)}
    <div id="account-content">${renderAccountSection(section, profile)}</div>
  </div>
  `;
}

function renderAccountSection(section, profile) {
  if (!state.account.loadedCore) return `<div class="loading-line"><span class="spinner"></span> 正在读取账号资料…</div>`;
  switch (section) {
    case 'devices': return renderAccountDevices();
    case 'entitlements': return renderAccountEntitlements();
    case 'security': return renderAccountSecurity();
    case 'activity': return renderAccountActivity();
    case 'feedback': return renderAccountFeedback();
    case 'preferences': return renderAccountPreferences();
    case 'cloud': return renderAccountCloud();
    default: return renderAccountOverview(profile);
  }
}

function renderAccountSkeleton(section) {
  return `<div class="account"><div class="view-head"><div><p class="eyebrow">ACCOUNT & PRIVACY</p><h1>账号与设置</h1><p class="view-sub">身份、设备、权益与反馈在这里。记忆默认只在本机；只有你主动开启的云空间会单独保存密文。</p></div></div>${renderAccountTabs(section)}<div class="panel panel-pad"><div class="loading-line"><span class="spinner"></span> 正在核对账号…</div><div class="skeleton" style="height:84px;margin-top:12px"></div><div class="skeleton" style="height:120px;margin-top:12px"></div></div></div>`;
}

function renderAccountError(section) {
  return `<div class="account"><div class="view-head"><div><p class="eyebrow">ACCOUNT & PRIVACY</p><h1>账号与设置</h1></div></div>${renderAccountTabs(section)}<div class="empty-state"><div class="empty-icon">${icon('cloud')}</div><h2>账号服务暂时没有回应</h2><p>${escapeHtml(state.account.error || '账号记录没有读取完成。')} 记忆副本仍可浏览；账号操作可以稍后重试。</p><div class="empty-actions"><button class="btn" type="button" data-action="refresh-account">重试</button><a class="btn ghost" href="#/home">回记忆首页</a><button class="btn ghost" type="button" data-action="logout">退出登录</button></div></div></div>`;
}

function renderCloudStandaloneView() {
  const error = state.account.error ? `<div class="banner bad">${escapeHtml(state.account.error)}</div>` : '';
  return `${renderPreviewBanner()}
  <div class="account cloud-standalone">
    <div class="view-head">
      <div><p class="eyebrow">CLOUD SPACE · END-TO-END ENCRYPTED</p><h1>云空间</h1><p class="view-sub">一份手动更新的只读记忆副本。加密在本机完成，服务器只保存密文和摘要元数据；没有口令，任何人都打不开。</p></div>
      <div class="view-head-actions"><a class="btn ghost small" href="#/account/preferences">${icon('account')} 账号与设置</a><a class="btn ghost small" href="#/home">${icon('back')} 回首页</a></div>
    </div>
    ${error}
    <div id="cloud-content">${renderAccountCloud()}</div>
  </div>`;
}

function renderCloudPreview() {
  return `${renderPreviewBanner()}
  <div class="account cloud-standalone">
    <div class="view-head"><div><p class="eyebrow">CLOUD SPACE</p><h1>云空间</h1><p class="view-sub">端到端加密的只读副本，手动上传，不自动同步。</p></div><div class="view-head-actions"><a class="btn ghost small" href="#/home">${icon('back')} 回首页</a></div></div>
    <div class="panel preview-account"><div class="empty-icon">${icon('cloud')}</div><h2>登录后打开云空间</h2><p>云空间属于你的账号，但服务器只保存密文。登录后可以上传本机副本，或在另一台设备下载并用同一口令解密。</p><div class="empty-actions"><a class="btn primary" href="${LOGIN_URL}">去登录</a><a class="btn ghost" href="#/home">回到记忆首页</a></div><div class="fine-print" style="margin-top:18px">演示模式不会发起账号请求，也不会把记忆副本传到任何地方。</div></div>
  </div>`;
}

function renderCloudSkeleton() {
  return `<div class="account cloud-standalone"><div class="view-head"><div><p class="eyebrow">CLOUD SPACE</p><h1>云空间</h1><p class="view-sub">端到端加密的只读副本，手动上传，不自动同步。</p></div></div><div class="panel panel-pad"><div class="loading-line"><span class="spinner"></span> 正在读取云空间状态…</div><div class="skeleton" style="height:84px;margin-top:12px"></div><div class="skeleton" style="height:120px;margin-top:12px"></div></div></div>`;
}

function renderCloudError() {
  return `<div class="account cloud-standalone"><div class="view-head"><div><p class="eyebrow">CLOUD SPACE</p><h1>云空间</h1></div></div><div class="empty-state"><div class="empty-icon">${icon('cloud')}</div><h2>云空间暂时没有回应</h2><p>${escapeHtml(state.account.error || '账号记录没有读取完成。')} 本机记忆仍可浏览；可以稍后重试。</p><div class="empty-actions"><button class="btn" type="button" data-action="refresh-cloud">重试</button><a class="btn ghost" href="#/home">回记忆首页</a></div></div></div>`;
}

function renderProfileCard(profile) {
  return `<section class="panel profile-card">
    <span class="profile-avatar">${escapeHtml(profile.initial)}</span>
    <div class="profile-main"><h2>${escapeHtml(profile.name)}</h2><p class="profile-email">${escapeHtml(profile.email)}</p><div class="profile-meta"><span class="tag ${profile.status === '正常' ? 'ok' : 'warn'}">${escapeHtml(profile.status)}</span><span class="tag">${state.account.entitlements.some((item) => item.active) ? 'River 高级权益' : '普通账号'}</span></div></div>
    <div class="profile-side"><span class="tag">账号 ID</span><span class="mono small">${escapeHtml(profile.id || '待核对')}</span><button class="copy-btn" type="button" data-action="copy-id">复制</button></div>
  </section>`;
}

function renderAccountOverview(profile) {
  const devices = state.account.devices || [];
  const entitlements = state.account.entitlements || [];
  return `${renderProfileCard(profile)}
  <div class="metric-grid" style="margin-top:16px">
    <article class="metric"><span>已读取设备</span><strong>${count(devices.length)}</strong><small>不含未登录设备</small></article>
    <article class="metric"><span>当前权益</span><strong>${entitlements.some((item) => item.active) ? '有效' : '普通'}</strong><small>权益跟着账号</small></article>
    <article class="metric"><span>登录密码</span><strong>${state.account.password?.password_enabled ? '已设置' : '未设置'}</strong><small>验证码始终可用</small></article>
    <article class="metric"><span>待确认变化</span><strong>${count(profile.pending.length)}</strong><small>敏感变更需安全日志</small></article>
  </div>
  <div class="account-grid">
    <article class="panel account-panel"><h2>账号名片</h2><div class="facts">
      <div class="fact-row"><span class="fact-label">账号 ID</span><span class="fact-value mono">${escapeHtml(profile.id || '待核对')}<button class="copy-btn" type="button" data-action="copy-id">复制</button></span></div>
      <div class="fact-row"><span class="fact-label">账号状态</span><span class="fact-value">${escapeHtml(profile.status)}</span></div>
      <div class="fact-row"><span class="fact-label">账号条款</span><span class="fact-value">${escapeHtml(profile.terms)}</span></div>
      <div class="fact-row"><span class="fact-label">隐私版本</span><span class="fact-value">${escapeHtml(profile.privacy)}</span></div>
    </div><div class="form-actions"><button class="btn small ghost" type="button" data-action="export-account">${icon('download')} 下载账号资料</button></div></article>
    <article class="panel account-panel"><h2>登录身份</h2><p class="panel-desc">已验证的邮箱用于验证码登录、找回密码和账号通知。</p><div class="facts">${(state.account.identities || []).map((identity) => `<div class="fact-row"><span class="fact-label">${identity.provider === 'email' ? '邮箱' : 'Apple'}</span><span class="fact-value">${escapeHtml(identity.email || 'Apple 登录身份')} <span class="tag ${identity.status === 'active' ? 'ok' : ''}">${identity.status === 'active' ? '已验证' : '已撤销'}</span></span></div>`).join('') || '<div class="fact-row"><span class="fact-label">登录身份</span><span class="fact-value">未发现</span></div>'}</div></article>
    <article class="panel account-panel"><h2>当前权益</h2><p class="panel-desc">换设备后使用同一账号登录即可核对。</p><div style="margin-top:10px">${renderEntitlementRows()}</div><div class="form-actions"><a class="btn small ghost" href="#/account/entitlements">兑换与记录 →</a></div></article>
    <article class="panel account-panel"><h2>数据与记忆</h2><p class="panel-desc">默认只在本机；云空间是你可以自行开启的加密快照。</p><div class="facts"><div class="fact-row"><span class="fact-label">本机副本</span><span class="fact-value">${escapeHtml(memorySourceText())}</span></div><div class="fact-row"><span class="fact-label">日记正文</span><span class="fact-value">默认不上传</span></div><div class="fact-row"><span class="fact-label">云空间</span><span class="fact-value">${state.cloud.meta ? (state.cloud.meta.exists ? `加密副本 v${escapeHtml(String(state.cloud.meta.revision))}` : '未开启') : '可自行开启'} <a class="text-link" href="#/cloud">管理 →</a></span></div><div class="fact-row"><span class="fact-label">模型调用</span><span class="fact-value">0 次</span></div></div><div class="form-actions"><button class="btn small ghost" type="button" data-action="import">${icon('export')} 导入副本</button>${state.entries.length ? `<button class="btn small ghost" type="button" data-action="clear-memory">清除本机副本</button>` : ''}</div></article>
  </div>
  <div class="banner" style="margin-top:16px">${icon('shield')} 默认情况下，日记正文、健康、位置与 AI 对话不会上传。只有你在「云空间」里主动开启并确认后，客户端才会在本机加密并上传密文；服务器无法解密，也不会保存口令。</div>`;
}

function memorySourceText() {
  if (state.memorySource === 'demo') return '示例副本';
  if (state.memorySource === 'import') return state.importMeta?.name ? `导入 · ${state.importMeta.name}` : '导入副本';
  if (state.memorySource === 'local') return '本机副本';
  if (state.memorySource === 'cloud') return '加密云副本';
  return '还没有';
}

function renderEntitlementRows() {
  const entitlements = state.account.entitlements || [];
  if (!entitlements.length) return '<p class="fine-print">当前没有权益记录。有激活码时可以兑换。</p>';
  return entitlements.map((item) => `<div class="entitlement-row"><div><strong>${escapeHtml(productLabel(item.product_code))}</strong><small>${item.permanent ? '永久有效' : `到期 ${escapeHtml(formatDateTime(item.expires_at))}`}</small></div><span class="tag ${item.active ? 'ok' : ''}">${item.active ? '当前有效' : '未生效'}</span></div>`).join('');
}

function renderAccountDevices() {
  const devices = state.account.devices || [];
  const sessions = state.account.sessions || [];
  const filter = state.account.deviceFilter || 'all';
  const filtered = devices.filter((item) => filter === 'all' || (filter === 'revoked' ? item.revoked : !item.revoked));
  const current = (item) => item.id === state.account.client?.session?.device?.id || item.client_instance_id === state.account.client?.session?.client_instance_id;
  return `<div class="view-head" style="margin-bottom:16px"><div><h2 style="font-size:22px">熟悉的作用域</h2><p class="view-sub">最近活动来自账号请求记录，不能据此判断设备是否在线。</p></div><div class="view-head-actions"><span class="select-wrap"><select id="account-device-filter" aria-label="筛选设备"><option value="all" ${filter === 'all' ? 'selected' : ''}>全部设备</option><option value="active" ${filter === 'active' ? 'selected' : ''}>未撤销</option><option value="revoked" ${filter === 'revoked' ? 'selected' : ''}>已撤销</option></select>${icon('chevron-down')}</span></div></div>
  <article class="panel account-panel"><div class="panel-head"><h2>你的设备</h2><span class="panel-sub">最近 100 台</span></div>
    <div class="device-grid">${filtered.map((item) => {
      const isCurrent = current(item);
      const platform = item.platform === 'ios' ? 'iPhone / iPad' : item.platform === 'macos' ? 'Mac' : '网页 / 其他';
      return `<article class="device-card"><div class="device-head"><span class="tag ${item.revoked ? '' : isCurrent ? 'accent' : 'ok'}">${item.revoked ? '已撤销' : isCurrent ? '本设备' : '未撤销'}</span>${icon(item.platform === 'ios' ? 'phone' : item.platform === 'macos' ? 'desktop' : 'cloud')}</div><h3>${escapeHtml(item.display_name || platform)}</h3><p>${escapeHtml(platform)} · 最近活动 ${escapeHtml(formatDateTime(item.last_seen_at))}</p><small class="mono">登记于 ${escapeHtml(formatDateTime(item.created_at))}</small>${item.revoked ? '' : `<div class="device-actions"><button class="btn tiny ghost" type="button" data-action="revoke-device" data-id="${escapeAttr(item.id)}">撤销设备登录</button></div>`}</article>`;
    }).join('') || '<p class="fine-print">暂时没有设备记录。</p>'}</div>
  </article>
  <article class="panel account-panel" style="margin-top:16px"><div class="panel-head"><h2>登录会话</h2><span class="panel-sub">最近 200 条</span></div>
    ${sessions.length ? sessions.map((item) => `<div class="record-row"><div><strong>${escapeHtml(item.device_name || item.platform || '登录设备')} <span class="tag ${item.current ? 'accent' : item.active ? 'ok' : ''}">${item.current ? '当前会话' : item.active ? '有效' : '已失效'}</span></strong><small>登录 ${escapeHtml(formatDateTime(item.created_at))} · 最近活动 ${escapeHtml(formatDateTime(item.last_seen_at))}</small><small>空闲到期 ${escapeHtml(formatDateTime(item.idle_expires_at))}</small></div>${item.active ? `<button class="btn tiny ghost" type="button" data-action="revoke-session" data-id="${escapeAttr(item.id)}">撤销会话</button>` : ''}</div>`).join('') : '<p class="fine-print">暂无登录会话记录。</p>'}
  </article>`;
}

function renderAccountEntitlements() {
  return `<div class="account-grid">
    <article class="panel account-panel"><h2>当前权益</h2><p class="panel-desc">权益绑定账号，不绑定设备。</p><div style="margin-top:10px">${renderEntitlementRows()}</div></article>
    <article class="panel account-panel"><h2>兑换激活码</h2><p class="panel-desc">兑换后会绑定当前账号，请核对后再确认。</p><form class="form" data-form="redeem"><label class="field"><span>激活码 · 12–40 位</span><input id="redeem-code" autocomplete="off" minlength="12" maxlength="40" placeholder="输入完整激活码" required></label><div class="form-actions"><button class="btn primary" type="submit" data-action="redeem-submit">核对并兑换</button></div><p class="status-line" id="redeem-status" role="status"></p></form></article>
  </div>
  <article class="panel account-panel" style="margin-top:16px"><h2>最近 100 条兑换记录</h2><div style="margin-top:8px">${(state.account.redemptions || []).length ? state.account.redemptions.map((item) => `<div class="record-row"><div><strong>${escapeHtml(productLabel(item.product_code))}</strong><small>兑换 ${escapeHtml(formatDateTime(item.granted_at))} · 激活码尾号 ${escapeHtml(item.code_suffix)}</small><small>${item.expires_at ? `授予至 ${escapeHtml(formatDateTime(item.expires_at))}` : '授予永久权益'}</small></div></div>`).join('') : '<p class="fine-print">还没有兑换记录。</p>'}</div></article>`;
}

function renderAccountSecurity() {
  const password = state.account.password;
  const emailValue = accountEmail();
  const left = Math.max(0, Math.ceil((state.account.pwAfter - Date.now()) / 1000));
  const pwButtonDisabled = left > 0 || !emailValue;
  return `<div class="account-grid">
    <article class="panel account-panel"><div class="panel-head"><h2>登录密码</h2><span class="tag ${password?.password_enabled ? 'ok' : ''}">${password?.password_enabled ? '已设置' : '未设置'}</span></div><p class="panel-desc">验证码登录始终可用。密码是另一种回到 River 的方式。</p><p class="fine-print" style="margin-top:9px">使用已验证邮箱的 8 位验证码设置或修改密码。完成后旧密码、旧改密验证码和其他设备的旧会话都会失效，当前浏览器会重新登录。</p><div class="form-actions"><button class="btn" type="button" data-action="password-start" id="pw-start-btn" ${pwButtonDisabled ? 'disabled' : ''}>${left > 0 ? `${left}s 后可重发` : state.account.pwChallenge ? '重新获取验证邮件' : '获取验证邮件'}</button></div>
      <form class="form" data-form="password" ${state.account.pwChallenge ? '' : 'hidden'} novalidate>
        <label class="field"><span>8 位邮箱验证码</span><input id="pw-code" inputmode="numeric" maxlength="8" autocomplete="one-time-code"></label>
        <div class="field-grid"><label class="field"><span>新的登录密码</span><input id="pw-new" type="password" autocomplete="new-password"><small class="form-hint">15–128 个字符，支持空格与长短语。</small></label><label class="field"><span>再次输入新密码</span><input id="pw-confirm" type="password" autocomplete="new-password"></label></div>
        <label class="checkbox-label"><input type="checkbox" id="pw-visible"> 显示新密码</label>
        <div class="form-actions"><button class="btn primary" type="submit">保存新密码</button><button class="btn ghost" type="button" data-action="password-cancel">取消修改</button></div>
        <p class="status-line" id="pw-status-line" role="status"></p>
      </form>
      <p class="status-line" id="pw-start-status" role="status"></p>
    </article>
    <article class="panel account-panel danger-zone"><h2>账号注销</h2><p class="panel-desc">注销会删除服务器上的身份、设备与权益。此操作不可恢复，需要邮箱确认，并等待安全日志确认。请先处理仍需使用的权益。</p><div class="form-actions"><button class="btn small danger ghost" type="button" data-action="delete-start">申请注销账号</button></div>
      ${state.account.deletionChallenge ? `<form class="form" data-form="deletion" novalidate><label class="field"><span>8 位注销确认验证码</span><input id="del-code" inputmode="numeric" autocomplete="one-time-code" maxlength="8"></label><label class="field"><span>输入「注销账号」确认</span><input id="del-text" autocomplete="off"></label><div class="form-actions"><button class="btn danger solid" type="submit">确认申请注销</button><button class="btn ghost" type="button" data-action="delete-cancel">先不注销</button></div><p class="status-line" id="del-status-line" role="status"></p></form>` : '<p class="status-line" id="del-status-line" role="status"></p>'}
    </article>
  </div>`;
}

function renderAccountActivity() {
  const events = state.account.activity || [];
  return `<article class="panel account-panel"><h2>最近的安全活动</h2><p class="panel-desc">来自账号请求记录，不包含你的日记和生活记录。</p><div class="activity-list">${events.length ? events.map((item) => `<div class="activity-row"><span>${escapeHtml(eventLabel(item.kind))}</span><time>${escapeHtml(formatDateTime(item.created_at))}</time></div>`).join('') : '<p class="fine-print">暂时没有安全活动记录。</p>'}</div></article>`;
}

function renderAccountFeedback() {
  return `<div class="account-grid">
    <article class="panel account-panel"><h2>提交反馈</h2><p class="panel-desc">这里保留你从个人后台提交的反馈与回复。官网的匿名反馈不会自动归入账号。</p><form class="form" data-form="feedback"><label class="field"><span>主题</span><input id="feedback-subject" maxlength="200" placeholder="例如：同步体验、界面建议"></label><label class="field"><span>想说的话 · 5–4000 个字符</span><textarea id="feedback-body" rows="5" maxlength="4000" required placeholder="描述遇到的问题或你的想法。请勿填写密码、API 密钥或日记正文。"></textarea></label><div class="form-actions"><button class="btn primary" type="submit">提交反馈</button></div><p class="status-line" id="feedback-status" role="status"></p></form></article>
    <article class="panel account-panel"><h2>最近 100 条反馈</h2><div style="margin-top:8px">${(state.account.feedback || []).length ? state.account.feedback.map((item) => `<article class="record-row"><div><strong>${escapeHtml(item.subject || '我的反馈')} <span class="tag ${item.status === 'replied' ? 'ok' : ''}">${escapeHtml(FEEDBACK_STATUS[item.status] || '处理中')}</span></strong><small>${escapeHtml(formatDateTime(item.created_at))}</small><p class="record-copy">${escapeHtml(item.body)}</p>${item.reply_body ? `<div class="reply-copy"><strong>River 回复</strong><small>${escapeHtml(formatDateTime(item.replied_at))}</small><p class="record-copy">${escapeHtml(item.reply_body)}</p></div>` : ''}</div></article>`).join('') : '<p class="fine-print">还没有从个人后台提交的反馈。</p>'}</div></article>
  </div>`;
}

function renderAccountPreferences() {
  return `<div class="account-grid">
    <article class="panel account-panel"><h2>阅读外观</h2><p class="panel-desc">偏好保存在当前浏览器。</p><div class="pref-theme-grid">${THEMES.map((theme) => `<button class="pref-theme" type="button" data-theme-choice="${theme.id}" aria-pressed="${state.theme === theme.id}"><span class="theme-swatch ${theme.id}"></span><strong>${theme.name}</strong><small>${theme.detail}</small></button>`).join('')}</div></article>
    <article class="panel account-panel"><h2>账号资料副本</h2><p class="panel-desc">下载账号 ID、登录身份、设备记录与权益。文件不含登录令牌、密码、日记、位置或健康数据。</p><div class="form-actions"><button class="btn" type="button" data-action="export-account">${icon('download')} 下载账号资料 JSON</button></div></article>
    <article class="panel account-panel"><h2>记忆副本</h2><p class="panel-desc">${escapeHtml(memorySourceText())}。副本只读，不会反向覆盖原生资料。</p><div class="form-actions"><button class="btn small" type="button" data-action="import">${icon('export')} 导入副本</button>${state.entries.length ? `<button class="btn small ghost" type="button" data-action="clear-memory">清除本机副本</button>` : ''}</div><p class="fine-print" style="margin-top:10px">清除只影响这个标签页，不删除原生 App 或加密副本中的记忆。</p></article>
    <article class="panel account-panel"><h2>云空间</h2><p class="panel-desc">端到端加密的可选快照。服务器只保存密文；需要时在其他设备输入同一口令。</p><div class="form-actions"><a class="btn small ghost" href="#/cloud">${state.cloud.meta?.exists ? '管理云副本' : '云空间'} →</a></div></article>
    <article class="panel account-panel"><h2>继续你的记录</h2><p class="panel-desc">生活记录在原生客户端中查看。网页控制台管理账号与只读副本。</p><div class="form-actions"><a class="btn small ghost" href="https://flowriver.xyz/#download">下载 / 更新客户端 ↗</a><a class="btn small ghost" href="https://flowriver.xyz/">回到官网</a><button class="btn small danger ghost" type="button" data-action="logout">退出登录</button></div></article>
  </div>`;
}

function renderAccountCloud() {
  const meta = state.cloud.meta;
  const hasCloud = Boolean(meta?.exists);
  const hasLocal = state.entries.length > 0;
  const summary = meta?.summary || {};
  const status = hasCloud
    ? `<span class="tag ok">${icon('lock')} 已保存 v${escapeHtml(String(meta.revision))}</span>`
    : `<span class="tag">${icon('cloud')} 未开启</span>`;
  const facts = hasCloud ? `<div class="cloud-facts">
    <div><span>副本版本</span><strong>v${escapeHtml(String(meta.revision))}</strong></div>
    <div><span>密文大小</span><strong>${formatBytes(meta.size_bytes)}</strong></div>
    <div><span>内容摘要</span><strong>${count(Number(summary.entries) || 0)} 段 · ${count(Number(summary.days) || 0)} 天</strong></div>
    <div><span>健康数据</span><strong>${summary.includes_health ? '已包含（本次同意）' : '未包含'}</strong></div>
    <div><span>最近更新</span><strong>${escapeHtml(formatDateTime(meta.updated_at))}</strong></div>
  </div>` : '';
  const uploadCard = hasLocal ? `<article class="panel account-panel">
    <div class="panel-head"><h2>${hasCloud ? '更新云副本' : '上传到云空间'}</h2><span class="panel-sub">${count(state.entries.length)} 段 · 只读快照</span></div>
    <p class="panel-desc">${hasCloud ? '用当前这份副本替换云空间里的版本。其他设备需要同一口令才能打开新副本。' : '先在浏览器里加密，再把密文交给账号服务。服务器不会收到正文或口令。'}</p>
    <form class="form cloud-form" data-form="cloud-upload" novalidate>
      <label class="field"><span>云端口令 · 至少 ${CLOUD_MIN_PASSPHRASE} 个字符</span><input id="cloud-upload-passphrase" type="password" minlength="12" maxlength="128" autocomplete="new-password" spellcheck="false" autocapitalize="off" placeholder="至少 12 个字符" required><small class="form-hint">不会上传、不会保存。请用只有你知道、但另一台设备也能输入的长短语。</small></label>
      <label class="field"><span>再次输入口令</span><input id="cloud-upload-confirm" type="password" minlength="12" maxlength="128" autocomplete="new-password" spellcheck="false" autocapitalize="off" required></label>
      <label class="checkbox-label"><input type="checkbox" id="cloud-upload-consent" required> 我理解：服务器只保存密文；口令丢失后，这份云副本无法恢复。</label>
      <label class="checkbox-label"><input type="checkbox" id="cloud-upload-health"> 本次上传包含健康摘要（睡眠、步数、训练）。默认关闭；服务器仍只看到密文。</label>
      ${hasCloud ? '<p class="fine-print">覆盖会替换旧密文。如果换了口令，其他设备必须改用新口令。</p>' : ''}
      <div class="form-actions"><button class="btn primary" type="submit">${icon('key')} ${hasCloud ? '加密并更新' : '加密并上传'}</button></div>
      <p class="status-line" id="cloud-upload-status" role="status"></p>
    </form>
  </article>` : `<article class="panel account-panel">
    <div class="panel-head"><h2>先把副本带到这里</h2><span class="tag">还没有本机副本</span></div>
    <p class="panel-desc">上传的是当前标签页里的只读副本。请先导入一份 JSON 副本；Mac/iPhone 的网页控制台副本入口已加入源码，若当前安装版本没有，请更新到包含该入口的构建。</p>
    <div class="form-actions"><button class="btn" type="button" data-action="import">${icon('export')} 导入记忆副本</button></div>
  </article>`;
  const downloadCard = hasCloud ? `<article class="panel account-panel">
    <div class="panel-head"><h2>在另一台设备查看</h2><span class="tag accent">需要同一口令</span></div>
    <p class="panel-desc">下载 v${escapeHtml(String(meta.revision))} 的密文，在本机解密后载入。解密后的副本只存在当前标签页。</p>
    <form class="form cloud-form" data-form="cloud-download" novalidate>
      <label class="field"><span>云端口令</span><input id="cloud-download-passphrase" type="password" minlength="12" maxlength="128" autocomplete="current-password" spellcheck="false" autocapitalize="off" required></label>
      <div class="form-actions"><button class="btn" type="submit">${icon('download')} 下载并解密</button><button class="btn ghost" type="button" data-action="refresh-cloud">${icon('refresh')} 刷新状态</button></div>
      <p class="status-line" id="cloud-download-status" role="status"></p>
    </form>
    <div class="cloud-actions"><button class="btn tiny danger ghost" type="button" data-action="delete-cloud">删除云副本</button></div>
  </article>` : `<article class="panel account-panel">
    <div class="panel-head"><h2>多端查看</h2><span class="tag">等待第一次上传</span></div>
    <p class="panel-desc">上传后，在另一台设备登录同一账号，进入「账号与设置 → 云空间」，输入同一口令即可下载并解密。</p>
    <div class="cloud-steps">
      <div><span>01</span><strong>本机副本</strong><p>导入或写下一段记忆。</p></div>
      <div><span>02</span><strong>本机加密</strong><p>设置至少 12 个字符的口令。</p></div>
      <div><span>03</span><strong>另一台设备</strong><p>下载密文，用同一口令打开。</p></div>
    </div>
  </article>`;
  return `<section class="cloud-hero panel">
    <span class="cloud-mark">${icon('cloud')}</span>
    <div class="cloud-copy"><p class="eyebrow">OPTIONAL · END-TO-END ENCRYPTED</p><h2>云空间</h2><p>把一份只读记忆副本加密后放进云空间。服务器只保存密文和同步元数据，换设备登录同一账号后可以取回。</p></div>
    ${status}
  </section>
  ${facts}
  <div class="banner cloud-boundary">${icon('shield')} 口令不会上传，也不会保存在服务器。加密在本机完成；如果忘记口令，云副本无法恢复，服务端也不能替你重置。</div>
  <div class="account-grid cloud-grid">${uploadCard}${downloadCard}</div>
  <p class="fine-print" style="margin-top:16px">云空间是手动快照，不会自动同步。更新本机副本后，需要再次上传；其他设备需要重新下载。账号注销会一并删除云副本。</p>`;
}

function renderAccountPreview(section) {
  return `<div class="account"><div class="view-head"><div><p class="eyebrow">ACCOUNT & PRIVACY</p><h1>账号与设置</h1><p class="view-sub">账号服务管理身份、设备、权益与反馈；登录后还可以主动开启端到端加密云空间。</p></div></div>${renderAccountTabs(section)}<div class="panel preview-account"><div class="empty-icon">${icon('account')}</div><h2>登录后管理账号</h2><p>当前是演示模式。登录后可以查看设备与会话、兑换权益、修改密码、核对安全活动、提交反馈，并自行开启端到端加密云空间。</p><div class="empty-actions"><a class="btn primary" href="${escapeAttr(LOGIN_URL)}">去登录</a><a class="btn ghost" href="#/home">回到记忆首页</a></div><div class="fine-print" style="margin-top:18px">演示模式不会发起账号请求。记忆副本仍只在这个标签页里。</div></div></div>`;
}

/* ---------- dialogs: command / detail / import / correction ---------- */

function openCommand() {
  const existing = $('#command-dialog');
  if (existing?.open) { $('#command-input')?.focus(); return; }
  state.command.query = '';
  state.command.active = 0;
  const input = $('#command-input');
  if (input) input.value = '';
  renderCommandResults();
  const dialog = $('#command-dialog');
  if (!dialog) return;
  dialog.showModal();
  requestAnimationFrame(() => input?.focus());
}

function buildCommandItems() {
  const query = state.command.query.trim();
  const items = [];
  const routes = [
    ['home', '记忆首页', '今天与最近', 'river'],
    ['river', '长河', '全部记忆', 'timeline'],
    ['collections', '合集与章节', '章节与收藏', 'chapter'],
    ['places', '地点里的我', '地点与日子', 'map'],
    ['understanding', 'River 的理解', '待确认与已确认', 'understanding'],
    ['ask', '问 River', '本机检索', 'chat'],
    ['cloud', '云空间', '端到端加密副本', 'cloud'],
    ['account', '账号与设置', '身份、设备与权益', 'account'],
  ];
  const actions = [
    ['import', '导入记忆副本', '选择本地 JSON 文件', 'export'],
    ['cycle-theme', '切换外观', `当前：${THEMES.find((theme) => theme.id === state.theme)?.name}`, 'appearance'],
    ['privacy', '数据边界', '记忆与账号各归各处', 'shield'],
  ];
  if (!state.preview) actions.push(['open-cloud', '云空间', '从加密云副本恢复', 'cloud']);
  const match = (text) => !query || text.includes(query);
  for (const [key, title, sub, iconName] of actions) {
    if (match(title) || match(sub)) items.push({ type: 'action', key, title, sub, iconName });
  }
  for (const [space, title, sub, iconName] of routes) {
    if (match(title) || match(sub)) items.push({ type: 'route', key: space, title, sub, iconName });
  }
  if (query) {
    const { results } = searchEntries(state.entries, query, { now: new Date() });
    for (const { entry } of results.slice(0, 7)) {
      items.push({
        type: 'memory', key: entry.id, title: entry.title, iconName: KIND_ICONS[entry.kind] || 'journal',
        sub: `${formatDateCN(entry.date)}${entry.place ? ` · ${entry.place}` : ''}`,
      });
    }
  } else {
    for (const entry of sortEntries(state.entries, 'desc').slice(0, 4)) {
      items.push({ type: 'memory', key: entry.id, title: entry.title, iconName: KIND_ICONS[entry.kind] || 'journal', sub: `${relativeDayCN(entry.date)} · ${truncate(entry.body, 36)}` });
    }
  }
  return items;
}

function renderCommandResults() {
  const items = buildCommandItems();
  state.command.items = items;
  if (state.command.active >= items.length) state.command.active = Math.max(0, items.length - 1);
  const container = $('#command-results');
  if (!container) return;
  if (!items.length) {
    container.innerHTML = '<div class="command-empty">没有找到匹配的记忆或入口。</div>';
    return;
  }
  let previousType = null;
  container.innerHTML = items.map((item, index) => {
    const group = item.type === previousType ? '' : `<div class="command-group-label">${{ action: '操作', route: '跳转', memory: '记忆' }[item.type]}</div>`;
    previousType = item.type;
    return `${group}<button class="command-result" type="button" role="option" id="cmd-${index}" data-command-index="${index}" aria-selected="${index === state.command.active}"><span class="command-icon">${icon(item.iconName)}</span><span class="command-copy"><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(item.sub || '')}</small></span><span class="command-hint">${item.type === 'memory' ? '打开' : '↵'}</span></button>`;
  }).join('');
  paintCommandSelection();
}

function paintCommandSelection() {
  $$('[data-command-index]').forEach((element) => {
    element.setAttribute('aria-selected', String(Number(element.dataset.commandIndex) === state.command.active));
  });
  const input = $('#command-input');
  if (input) input.setAttribute('aria-activedescendant', `cmd-${state.command.active}`);
}

function handleCommandKey(event) {
  if (event.key === 'Escape') {
    event.preventDefault();
    $('#command-dialog')?.close();
    return;
  }
  if (!state.command.items.length) {
    if (event.key === 'Enter') event.preventDefault();
    return;
  }
  if (event.key === 'ArrowDown') {
    event.preventDefault();
    state.command.active = (state.command.active + 1) % state.command.items.length;
    paintCommandSelection();
    $(`#cmd-${state.command.active}`)?.scrollIntoView({ block: 'nearest' });
  } else if (event.key === 'ArrowUp') {
    event.preventDefault();
    state.command.active = (state.command.active - 1 + state.command.items.length) % state.command.items.length;
    paintCommandSelection();
    $(`#cmd-${state.command.active}`)?.scrollIntoView({ block: 'nearest' });
  } else if (event.key === 'Enter') {
    event.preventDefault();
    activateCommand(state.command.active);
  }
}

function activateCommand(index) {
  const item = state.command.items[index];
  if (!item) return;
  $('#command-dialog')?.close();
  if (item.type === 'route') { navigate(item.key); return; }
  if (item.type === 'memory') { openMemory(item.key); return; }
  if (item.type === 'action') {
    if (item.key === 'import') openImport();
    if (item.key === 'open-cloud') { navigate('cloud'); return; }
    if (item.key === 'cycle-theme') cycleTheme();
    if (item.key === 'privacy') openPrivacy();
  }
}

function openMemory(id) {
  const entry = state.entries.find((item) => item.id === id);
  if (!entry) return;
  state.detailId = entry.id;
  const body = String(entry.body || '').split(/\n{2,}/).map((paragraph) => `<p>${escapeHtml(paragraph).replace(/\n/g, '<br>')}</p>`).join('');
  const related = relatedEntries(state.entries, entry, 4);
  const facts = entry.facts?.length ? `<div class="detail-facts"><h2>当天还留下</h2><ul>${entry.facts.map((fact) => `<li>${escapeHtml(fact)}</li>`).join('')}</ul></div>` : '';
  const el = $('#memory-dialog-body');
  if (!el) return;
  el.innerHTML = `<article class="memory-detail">
    <div class="detail-date"><span>${escapeHtml(formatDateCN(entry.date, { withWeekday: true }))}</span><span>·</span><span>${escapeHtml(entry.time || '时间未记录')}</span>${entry.weather ? `<span>·</span><span>${escapeHtml(entry.weather)}</span>` : ''}</div>
    <h1 id="memory-dialog-title">${escapeHtml(entry.title)}</h1>
    <div class="detail-meta">${entry.place ? `<span class="tag">${icon('location')} ${escapeHtml(entry.place)}</span>` : ''}<span class="tag">${escapeHtml(KIND_LABELS[entry.kind] || '记忆')}</span><span class="tag">${escapeHtml(entry.source.label)}</span>${entry.favorite ? `<span class="tag accent">${icon('bookmark')} 已收藏</span>` : ''}</div>
    <div class="detail-body">${body || '<p class="muted">这段记忆没有正文。</p>'}</div>
    ${facts}
    ${entry.tags.length ? `<div class="detail-tags chip-row">${entry.tags.map((tag) => `<span class="tag">${escapeHtml(tag)}</span>`).join('')}</div>` : ''}
    <div class="detail-actions"><button class="btn small" type="button" data-detail-action="favorite">${icon('bookmark')} ${entry.favorite ? '取消收藏' : '收藏'}</button><button class="btn small ghost" type="button" data-detail-action="copy">${icon('copy')} 复制原话</button><button class="btn small ghost" type="button" data-detail-action="day">${icon('calendar')} 回到那天</button></div>
    ${related.length ? `<div class="detail-related"><h2>相关的日子</h2><div class="related-list">${related.map((item) => `<button class="related-item" type="button" data-open="${escapeAttr(item.id)}"><time>${formatDateCN(item.date, { withYear: false })}</time><span>${escapeHtml(item.title)}</span></button>`).join('')}</div></div>` : ''}
    <p class="detail-note">${state.memorySource === 'demo' ? '这是合成的演示记忆。' : state.memorySource === 'cloud' ? '这是从加密云副本解密出的只读副本；服务器只保存密文。修改请在原生 App 中完成。' : '这是只读副本。修改请在原生 App 中完成；默认不会上传。'} ${state.memorySource === 'local' ? '本机副本只在这个标签页里。' : ''}</p>
  </article>`;
  const dialog = $('#memory-dialog');
  if (dialog && !dialog.open) dialog.showModal();
}

function handleDetailAction(button) {
  const current = state.entries.find((item) => item.id === state.detailId);
  if (!current) return;
  if (button.dataset.detailAction === 'favorite') {
    toggleFavorite(current.id);
    openMemory(current.id);
  }
  if (button.dataset.detailAction === 'copy') {
    copyText(`${current.title}\n\n${current.body}\n\n—— ${formatDateCN(current.date)} · 河流日记`).then((ok) => {
      if (!ok) { toast('复制没有完成，请手动选择文字。', 'bad'); return; }
      const previous = button.innerHTML;
      button.innerHTML = `${icon('success')} 已复制`;
      setTimeout(() => { button.innerHTML = previous; }, 1600);
    });
  }
  if (button.dataset.detailAction === 'day') {
    $('#memory-dialog')?.close();
    state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: '', collection: '', day: current.date };
    navigate('river');
  }
}

function openImport() {
  const dialog = $('#import-dialog');
  if (dialog?.open) return;
  state.importCandidate = null;
  const report = $('#import-report');
  if (report) { report.hidden = true; report.innerHTML = ''; }
  const confirm = $('#import-confirm');
  if (confirm) confirm.disabled = true;
  const input = $('#import-file');
  if (input) input.value = '';
  $('#import-dialog')?.showModal();
}

async function inspectImportFile(file) {
  const report = $('#import-report');
  const confirm = $('#import-confirm');
  if (!report || !confirm) return;
  state.importCandidate = null;
  confirm.disabled = true;
  report.hidden = false;
  if (file.size > MAX_IMPORT_BYTES) {
    report.innerHTML = `<p class="report-error">文件超过 25 MB。请先在原生 App 中缩小导出范围。</p>`;
    return;
  }
  report.innerHTML = '<div class="loading-line" style="padding:4px 0"><span class="spinner"></span> 正在本机解析…</div>';
  try {
    const text = await file.text();
    const payload = JSON.parse(text);
    const archive = normalizeArchive(payload, { now: new Date(), sourceLabel: file.name });
    if (!archive.ok) {
      report.innerHTML = `<p class="report-error">${escapeHtml(archive.error)}</p>`;
      return;
    }
    state.importCandidate = { archive, file };
    const stats = buildStats(archive.entries);
    report.innerHTML = `<strong>${escapeHtml(file.name)}</strong><div>${count(stats.count)} 段记忆 · ${count(stats.dayCount)} 天${stats.places.length ? ` · ${stats.places.length} 个地点` : ''}</div><div class="muted" style="margin-top:4px">${escapeHtml(stats.rangeLabel)}</div>${archive.collections.length ? `<div class="muted" style="margin-top:4px">${archive.collections.length} 个章节 · ${archive.understandings.length} 张理解卡</div>` : ''}${archive.warnings.length ? `<div class="report-warning">${archive.warnings.map((warning) => escapeHtml(warning)).join('<br>')}</div>` : ''}<div class="fine-print" style="margin-top:7px">${state.preview ? '解析完成。演示模式下只保留在内存，刷新后会回到示例。' : '解析完成。确认后只写入当前标签页的会话存储，关闭标签页后不再保留。'}</div>`;
    confirm.disabled = false;
  } catch (error) {
    report.innerHTML = `<p class="report-error">${error instanceof SyntaxError ? '这不是有效的 JSON 文件。' : '文件没有读取完成。'}</p>`;
  }
}

function confirmImport() {
  if (!state.importCandidate) return;
  const { archive, file } = state.importCandidate;
  applyArchive(archive, { source: 'import', persist: true, meta: { name: file.name, importedAt: new Date().toISOString() } });
  state.importCandidate = null;
  $('#import-dialog')?.close();
  toast(`已载入 ${count(archive.entries.length)} 段记忆。只在这个标签页里。`, 'ok');
  navigate('home');
}

function openCorrection(id) {
  const item = effectiveUnderstandings().find((understanding) => understanding.id === id);
  if (!item) return;
  state.correctionId = id;
  $('#correction-text').value = '';
  $('#correction-quote').textContent = `River 现在说的是：「${item.statement}」`;
  $('#correction-status').textContent = '';
  $('#correction-dialog')?.showModal();
  requestAnimationFrame(() => $('#correction-text')?.focus());
}

function submitCorrection(event) {
  event.preventDefault();
  if (event.submitter?.value === 'cancel') { $('#correction-dialog')?.close(); return; }
  const text = $('#correction-text')?.value.trim() || '';
  if (!text) {
    $('#correction-status').textContent = '写下更接近的说法，River 才知道哪里不对。';
    return;
  }
  if (!state.correctionId) return;
  state.understandingOverrides[state.correctionId] = { status: 'rejected', correction: text };
  persistUnderstandingOverrides();
  $('#correction-dialog')?.close();
  pendingBadge();
  toast('已记下你的纠正。只影响这张理解卡。', 'ok');
  if (state.route.space === 'understanding') refreshView();
}

function openPrivacy() {
  const dialog = $('#privacy-dialog');
  if (dialog?.open) return;
  dialog?.showModal();
}

function confirmAction({ title, description, confirmLabel = '确认', danger = false }) {
  const dialog = $('#action-dialog');
  const confirm = $('#action-confirm');
  if (!dialog) return Promise.resolve(false);
  if (dialog.open) dialog.close();
  $('#action-title').textContent = title;
  $('#action-description').textContent = description || '';
  confirm.textContent = confirmLabel;
  confirm.classList.toggle('danger', danger);
  confirm.classList.toggle('primary', !danger);
  dialog.returnValue = '';
  dialog.showModal();
  return new Promise((resolve) => { state.dialogResolve = resolve; });
}

function resolveActionDialog() {
  const resolve = state.dialogResolve;
  state.dialogResolve = null;
  const dialog = $('#action-dialog');
  resolve?.(dialog?.returnValue === 'confirm');
}

/* ---------- memory helpers ---------- */

function toggleFavorite(id) {
  const entry = state.entries.find((item) => item.id === id);
  if (!entry) return;
  const next = !entry.favorite;
  entry.favorite = next;
  state.favoriteOverrides[id] = next;
  if (!state.preview) writeLocal(FAVORITES_KEY, state.favoriteOverrides);
  state.stats = buildStats(state.entries);
  toast(next ? '已加入收藏。只保存在这个浏览器。' : '已取消收藏。');
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      const ok = document.execCommand('copy');
      area.remove();
      return ok;
    } catch { return false; }
  }
}

function downloadJson(filename, payload) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function toast(message, tone = '') {
  const element = $('#toast');
  if (!element) return;
  element.hidden = false;
  element.textContent = message;
  element.className = `toast ${tone}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { element.hidden = true; }, 3800);
}

/* ---------- events ---------- */

function handleGlobalClick(event) {
  const close = event.target.closest('[data-close-dialog]');
  if (close) { close.closest('dialog')?.close(); return; }
  const action = event.target.closest('[data-action]');
  if (action) {
    handleAction(action, event);
    return;
  }
  const open = event.target.closest('[data-open]');
  if (open) {
    event.preventDefault();
    openMemory(open.dataset.open);
    return;
  }
  const collection = event.target.closest('[data-collection]');
  if (collection) {
    state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: '', collection: collection.dataset.collection, day: '' };
    navigate('river');
    return;
  }
  const place = event.target.closest('[data-place]');
  if (place) {
    state.selectedPlace = place.dataset.place;
    if (state.route.space === 'places') refreshView();
    return;
  }
  const themeChoice = event.target.closest('[data-theme-choice]');
  if (themeChoice) {
    applyTheme(themeChoice.dataset.themeChoice);
    if (state.route.space === 'account') refreshView();
  }
}

async function handleAction(element, event) {
  const action = element.dataset.action;
  if (action === 'favorite') {
    event.stopPropagation();
    toggleFavorite(element.dataset.id);
    if (state.route.space === 'home' || state.route.space === 'river' || state.route.space === 'collections') refreshView();
    return;
  }
  if (action === 'import' || action === 'open-import') { openImport(); return; }
  if (action === 'open-cloud') { navigate('account', 'cloud'); return; }
  if (action === 'privacy') { openPrivacy(); return; }
  if (action === 'exit-preview') { location.assign(LOGIN_URL); return; }
  if (action === 'demo') {
    const archive = normalizeArchive(buildDemoArchive(new Date()), { now: new Date(), sourceLabel: '示例记忆 · 合成内容' });
    if (archive.ok) {
      applyArchive(archive, { source: 'demo', persist: false });
      state.forgottenSeed = 0;
      navigate('home');
      toast('已载入示例记忆。它们只在本页，不会写入账号。');
    }
    return;
  }
  if (action === 'clear-memory') {
    const ok = await confirmAction({
      title: '清除这个标签页里的副本？',
      description: state.preview
        ? '只会清除当前页面的演示副本；同一标签页里的真实副本不会被删除。'
        : '只会清除当前浏览器里的只读副本。原生 App、加密备份和账号资料不会被删除。',
      confirmLabel: '清除副本',
      danger: true,
    });
    if (!ok) return;
    clearArchive();
    toast(state.preview ? '演示副本已清除；真实副本未受影响。' : '本机副本已清除。');
    navigate('home');
    return;
  }
  if (action === 'forgotten-next') {
    state.forgottenSeed += 1;
    refreshView();
    return;
  }
  if (action === 'ribbon-month') {
    state.filters = { query: '', year: String(element.dataset.year), kind: 'all', favorite: false, tag: '', place: '', collection: '', day: '' };
    navigate('river');
    return;
  }
  if (action === 'toggle-favorites-filter') {
    state.filters.favorite = !state.filters.favorite;
    refreshView();
    return;
  }
  if (action === 'filter-clear') {
    clearFilters();
    refreshView();
    return;
  }
  if (action === 'filter-remove') {
    removeFilter(element.dataset.filter);
    refreshView();
    return;
  }
  if (action === 'filter-tag') {
    state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: element.dataset.tag, place: '', collection: '', day: '' };
    navigate('river');
    return;
  }
  if (action === 'filter-place') {
    state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: element.dataset.place, collection: '', day: '' };
    navigate('river');
    return;
  }
  if (action === 'load-more') {
    state.timelineLimit += 30;
    refreshView();
    return;
  }
  if (action === 'confirm-understanding') {
    const item = effectiveUnderstandings().find((understanding) => understanding.id === element.dataset.id);
    if (!item) return;
    state.understandingOverrides[item.id] = { status: 'confirmed', correction: item.correction || '' };
    persistUnderstandingOverrides();
    pendingBadge();
    toast('已确认为「像」。只影响这张卡，不会自动变成长期规则。', 'ok');
    refreshView();
    return;
  }
  if (action === 'correct-understanding') { openCorrection(element.dataset.id); return; }
  if (action === 'revoke-understanding') {
    const item = effectiveUnderstandings().find((understanding) => understanding.id === element.dataset.id);
    if (!item) return;
    state.understandingOverrides[item.id] = { status: 'pending', correction: item.correction || '' };
    persistUnderstandingOverrides();
    pendingBadge();
    toast('已撤销确认。这张卡回到待确认。');
    refreshView();
    return;
  }
  if (action === 'reopen-understanding') {
    const item = effectiveUnderstandings().find((understanding) => understanding.id === element.dataset.id);
    if (!item) return;
    state.understandingOverrides[item.id] = { status: 'pending', correction: '' };
    persistUnderstandingOverrides();
    pendingBadge();
    refreshView();
    return;
  }
  if (action === 'ask-suggestion') {
    const question = element.dataset.question || '';
    const input = $('#ask-input');
    if (input) { input.value = question; input.focus(); }
    submitAsk(question);
    return;
  }
  if (action === 'refresh-account') {
    resetAccountData();
    renderAccountRoute(state.route.sub, ++renderToken, { focus: false });
    return;
  }
  if (action === 'copy-id') {
    const id = state.account.me?.user?.id;
    if (!id) { toast('账号资料尚未读取完成。', 'bad'); return; }
    const ok = await copyText(id);
    toast(ok ? '账号 ID 已复制。' : '复制没有完成。', ok ? 'ok' : 'bad');
    return;
  }
  if (action === 'export-account') { exportAccount(); return; }
  if (action === 'refresh-cloud') { await refreshCloud(element); return; }
  if (action === 'delete-cloud') { await deleteCloudMirror(element); return; }
  if (action === 'logout') { await logoutAccount(element); return; }
  if (action === 'revoke-device') { await revokeDevice(element); return; }
  if (action === 'revoke-session') { await revokeSession(element); return; }
  if (action === 'redeem-submit') { /* handled by form submit */ return; }
  if (action === 'password-start') { await startPasswordReset(element); return; }
  if (action === 'password-cancel') {
    state.account.pwChallenge = null;
    state.account.pwKey = newKey();
    refreshView();
    return;
  }
  if (action === 'delete-start') { await startAccountDeletion(element); return; }
  if (action === 'delete-cancel') {
    state.account.deletionChallenge = null;
    state.account.deletionProof = null;
    refreshView();
    return;
  }
}

function removeFilter(key) {
  if (key === 'favorite') state.filters.favorite = false;
  else if (key === 'collection') state.filters.collection = '';
  else if (key === 'query') state.filters.query = '';
  else if (key === 'day') state.filters.day = '';
  else if (key === 'tag' || key === 'place') state.filters[key] = '';
  else state.filters[key] = 'all';
}

function handleGlobalSubmit(event) {
  const form = event.target;
  if (form.id === 'ask-form') {
    event.preventDefault();
    submitAsk($('#ask-input')?.value || '');
    return;
  }
  if (form.id === 'correction-form') return;
  const kind = form.dataset.form;
  if (!kind) return;
  event.preventDefault();
  if (kind === 'redeem') submitRedeem(form);
  if (kind === 'feedback') submitFeedback(form);
  if (kind === 'password') submitPassword(form);
  if (kind === 'deletion') submitDeletion(form);
  if (kind === 'cloud-upload') submitCloudUpload(form);
  if (kind === 'cloud-download') submitCloudDownload(form);
}

function handleGlobalInput(event) {
  const target = event.target;
  if (target.id === 'river-search') {
    state.filters.query = target.value;
    clearTimeout(filterTimer);
    filterTimer = setTimeout(updateTimelineResults, 160);
    return;
  }
  if (['feedback-subject', 'feedback-body'].includes(target.id)) state.account.feedbackKey = newKey();
  if (target.id === 'redeem-code') state.account.redeemKey = newKey();
  if (['pw-code', 'pw-new', 'pw-confirm'].includes(target.id)) state.account.pwKey = newKey();
  if (['del-code', 'del-text'].includes(target.id)) { state.account.deletionVerifyKey = newKey(); state.account.deletionProof = null; }
  if (target.id === 'ask-input') {
    target.style.height = 'auto';
    target.style.height = `${Math.min(130, target.scrollHeight)}px`;
  }
}

function handleGlobalChange(event) {
  const target = event.target;
  if (target.id === 'river-year') { state.filters.year = target.value; updateTimelineResults(); }
  if (target.id === 'river-kind') { state.filters.kind = target.value; updateTimelineResults(); }
  if (target.id === 'account-device-filter') { state.account.deviceFilter = target.value; refreshView(); }
  if (target.name === 'ask-scope') { state.ask.scope = target.value; }
  if (target.id === 'pw-visible') {
    ['pw-new', 'pw-confirm'].forEach((id) => { const input = $(`#${id}`); if (input) input.type = target.checked ? 'text' : 'password'; });
  }
}

function handleGlobalKeydown(event) {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault();
    openCommand();
    return;
  }
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName) || event.target.isContentEditable;
  if (event.key === '/' && !typing) {
    event.preventDefault();
    openCommand();
    return;
  }
  if (event.key === 'Enter' && event.target.id === 'ask-input' && !event.shiftKey) {
    event.preventDefault();
    submitAsk(event.target.value);
    return;
  }
  if (event.target.closest('button, a, input, textarea, select')) return;
  const svgAction = event.target.closest('[data-action]');
  if (svgAction && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault();
    handleAction(svgAction, event);
    return;
  }
  const card = event.target.closest('[data-open][role="button"], [data-place][role="button"], [data-collection][role="button"]');
  if (card && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault();
    if (card.dataset.open) openMemory(card.dataset.open);
    else if (card.dataset.place) { state.selectedPlace = card.dataset.place; refreshView(); }
    else if (card.dataset.collection) {
      state.filters = { query: '', year: 'all', kind: 'all', favorite: false, tag: '', place: '', collection: card.dataset.collection, day: '' };
      navigate('river');
    }
  }
}

/* ---------- account actions ---------- */

async function refreshCloud(button) {
  await withBusy(button, async () => {
    await loadCloudMeta(true);
    state.account.sectionLoaded.cloud = true;
    refreshView();
    toast('云空间状态已刷新。', 'ok');
  }, '云空间状态没有刷新，请重试。');
}

async function deleteCloudMirror(button) {
  const meta = state.cloud.meta;
  if (!meta?.exists) { await refreshCloud(button); return; }
  const ok = await confirmAction({
    title: '删除云空间里的加密副本？',
    description: `会删除 v${meta.revision} 的密文和同步元数据。本机副本、原生 App 与账号资料不受影响。`,
    confirmLabel: '删除云副本',
    danger: true,
  });
  if (!ok) return;
  await withBusy(button, async () => {
    const response = await state.account.client.api('DELETE', '/me/memory-mirror', undefined, null, false, {
      'If-Match': `"${meta.revision}"`,
    }, 30000);
    if (response.status === 204) {
      state.cloud.meta = { exists: false };
      state.account.sectionLoaded.cloud = true;
      refreshView();
      toast('云副本已删除。', 'ok');
      return;
    }
    if (response.status === 412) await loadCloudMeta(true);
    throw new Error(errorText(response, '云副本没有删除，请刷新后重试。'));
  }, '云副本没有删除，请重试。');
}

async function submitCloudUpload(form) {
  const passphrase = $('#cloud-upload-passphrase')?.value ?? '';
  const confirmation = $('#cloud-upload-confirm')?.value ?? '';
  const consent = Boolean($('#cloud-upload-consent')?.checked);
  const includeHealth = Boolean($('#cloud-upload-health')?.checked);
  const button = form.querySelector('button[type="submit"]');
  const fail = (message) => setStatus('cloud-upload-status', message, true);
  if (!state.entries.length) return fail('还没有本机副本。请先导入或写下一段记忆。');
  const policy = validateCloudPassphrase(passphrase);
  if (policy) return fail(policy);
  if (passphrase !== confirmation) return fail('两次输入的口令不一致。');
  if (!consent) return fail('请先确认你理解口令丢失的后果。');
  const client = state.account.client;
  if (!client) return fail('需要先登录账号。');
  if (includeHealth) {
    const ok = await confirmAction({
      title: '确认把健康摘要放进本次云副本？',
      description: '睡眠、步数和训练摘要会先在本机加密再上传。服务器仍然只看到密文，但拿到口令的人可以看到这些健康摘要。关闭此项后再上传即可撤回。',
      confirmLabel: '包含健康数据并继续',
      danger: true,
    });
    if (!ok) return;
  }
  await withBusy(button, async () => {
    const current = await loadCloudMeta(true);
    if (current?.exists) {
      const ok = await confirmAction({
        title: '用当前副本覆盖云空间？',
        description: `云空间已有 v${current.revision}。覆盖后旧密文会被替换；如果这次换了口令，其他设备必须使用新口令。`,
        confirmLabel: '加密并覆盖',
        danger: true,
      });
      if (!ok) return;
    }
    setStatus('cloud-upload-status', '正在本机加密…');
    const envelope = await buildCloudEnvelope({
      ...state.archive,
      understandings: effectiveUnderstandings(),
    }, passphrase, { includeHealth });
    setStatus('cloud-upload-status', '正在上传密文…');
    const headers = current?.exists ? { 'If-Match': `"${current.revision}"` } : { 'If-None-Match': '*' };
    const response = await client.api('PUT', '/me/memory-mirror', envelope, null, false, headers, 60000);
    if (!response.ok) {
      if (response.status === 409 || response.status === 412) await loadCloudMeta(true);
      throw new Error(errorText(response, '云空间没有更新，请刷新后重试。'));
    }
    state.cloud.meta = response.data?.exists ? response.data : { ...envelope, exists: true };
    state.account.sectionLoaded.cloud = true;
    form.reset();
    refreshView();
    toast(`已加密上传 v${response.data?.revision ?? 1}。另一台设备输入同一口令即可下载。`, 'ok');
  }, '云空间没有更新，请重试。', 'cloud-upload-status');
}

async function submitCloudDownload(form) {
  const passphrase = $('#cloud-download-passphrase')?.value ?? '';
  const button = form.querySelector('button[type="submit"]');
  const policy = validateCloudPassphrase(passphrase);
  if (policy) { setStatus('cloud-download-status', policy, true); return; }
  const client = state.account.client;
  if (!client) { setStatus('cloud-download-status', '需要先登录账号。', true); return; }
  if (state.entries.length) {
    const ok = await confirmAction({
      title: '载入云副本并替换本机？',
      description: '解密后的云副本会替换当前标签页里的只读副本；当前未上传的本机副本不会自动合并。',
      confirmLabel: '载入云副本',
    });
    if (!ok) return;
  }
  await withBusy(button, async () => {
    setStatus('cloud-download-status', '正在下载密文…');
    const envelope = await client.get('/me/memory-mirror', 60000);
    setStatus('cloud-download-status', '正在本机解密…');
    const payload = await decryptCloudEnvelope(envelope, passphrase);
    const archive = normalizeArchive(payload, {
      now: new Date(),
      sourceLabel: `加密云副本 v${envelope.revision}`,
    });
    if (!archive.ok) throw new Error('云副本的内容格式无法识别。');
    applyArchive(archive, {
      source: 'cloud',
      persist: true,
      meta: { name: `加密云副本 v${envelope.revision}`, cloud: true, revision: envelope.revision },
    });
    state.account.sectionLoaded.cloud = true;
    toast('云副本已在本机解密并载入。', 'ok');
    navigate('home');
  }, '云副本没有载入，请重试。', 'cloud-download-status');
}


function persistUnderstandingOverrides() {
  if (!state.preview) writeSession(UNDERSTANDING_KEY, state.understandingOverrides);
}

function clearLocalSession() {
  state.account.client?.store.clear();
  if (state.account.client) state.account.client.session = null;
}

function resetAccountData() {
  state.account.loadedCore = false;
  state.account.sectionLoaded = {};
  state.account.sectionLoading = {};
  state.account.error = '';
  state.account.offline = false;
  state.cloud = { meta: null, loading: null, error: '' };
}

async function logoutAccount(button) {
  const client = state.account.client;
  if (!client) return;
  await withBusy(button, async () => {
    await client.logout();
    location.assign(LOGIN_URL);
  }, '退出登录没有完成，请重试。');
}

async function revokeDevice(button) {
  const id = button.dataset.id;
  const device = state.account.devices.find((item) => item.id === id);
  if (!device) return;
  const isCurrent = id === state.account.client?.session?.device?.id || device.client_instance_id === state.account.client?.session?.client_instance_id;
  const ok = await confirmAction({
    title: '撤销这台设备的登录？',
    description: `这台设备的全部登录会话会失效，本机日记会保留。${isCurrent ? '当前浏览器也会退出登录。' : ''}`,
    confirmLabel: '撤销设备',
    danger: true,
  });
  if (!ok) return;
  await withBusy(button, async () => {
    const response = await state.account.client.api('POST', `/me/devices/${id}/revoke`);
    if (response.status !== 204) throw new Error(errorText(response, '撤销没有完成，请重试。'));
    if (isCurrent) { clearLocalSession(); location.assign(LOGIN_URL); return; }
    state.account.sectionLoaded.devices = false;
    await ensureAccountSection('devices');
    refreshView();
    toast('已撤销该设备的登录。', 'ok');
  }, '撤销没有完成，请重试。');
}

async function revokeSession(button) {
  const id = button.dataset.id;
  const session = state.account.sessions.find((item) => item.id === id);
  if (!session) return;
  const ok = await confirmAction({
    title: '撤销这次登录？',
    description: session.current ? '当前浏览器会退出，需要重新登录。' : '该次登录会失效，其他会话保持可用。',
    confirmLabel: '撤销会话',
    danger: true,
  });
  if (!ok) return;
  await withBusy(button, async () => {
    const response = await state.account.client.api('POST', `/me/sessions/${id}/revoke`);
    if (response.status !== 204) throw new Error(errorText(response, '会话没有撤销，请重试。'));
    if (session.current) { clearLocalSession(); location.assign(LOGIN_URL); return; }
    state.account.sectionLoaded.devices = false;
    await ensureAccountSection('devices');
    refreshView();
    toast('已撤销这次登录。', 'ok');
  }, '会话没有撤销，请重试。');
}

async function startPasswordReset(button) {
  if (!state.account.client) return;
  if (Date.now() < state.account.pwAfter) return;
  const address = accountEmail();
  if (!address) {
    setStatus('pw-start-status', '需要已验证的邮箱才能设置密码。', true);
    return;
  }
  await withBusy(button, async () => {
    const response = await state.account.client.request('POST', '/auth/password/reset/start', { email: address });
    if (response.status !== 202 || !response.data?.challenge_id) throw new Error(errorText(response, '验证码没有发送，请重试。'));
    state.account.pwChallenge = response.data.challenge_id;
    state.account.pwKey = newKey();
    state.account.pwAfter = Date.now() + 60000;
    refreshView();
    toast(`验证邮件已请求，请查看 ${address} 的收件箱与垃圾邮件。验证码 10 分钟内有效。`, 'ok');
    requestAnimationFrame(() => $('#pw-code')?.focus());
  }, '验证码没有发送，请重试。', 'pw-start-status');
}

async function submitPassword(form) {
  if (!state.account.pwChallenge) {
    setStatus('pw-status-line', '请先获取验证邮件。', true);
    return;
  }
  const code = $('#pw-code')?.value || '';
  const password = ($('#pw-new')?.value || '').normalize('NFC');
  const confirmation = ($('#pw-confirm')?.value || '').normalize('NFC');
  if (code.length !== 8) { setStatus('pw-status-line', '请填写 8 位验证码。', true); return; }
  if ([...password].length < 15 || [...password].length > 128 || new TextEncoder().encode(password).length > 512 || !password.trim()) {
    setStatus('pw-status-line', '请使用 15–128 个字符的密码，支持空格。', true);
    return;
  }
  if (password !== confirmation) { setStatus('pw-status-line', '两次输入的密码不一致。', true); return; }
  const client = state.account.client;
  const button = form.querySelector('button[type="submit"]');
  await withBusy(button, async () => {
    const response = await client.request('POST', '/auth/password/reset/complete', {
      challenge_id: state.account.pwChallenge,
      code,
      new_password: password,
      client_instance_id: client.session?.client_instance_id,
      platform: 'other',
      device_name: '网页 · 记忆控制台',
    }, { 'Idempotency-Key': state.account.pwKey });
    if (!response.ok || !response.data?.access_token) throw new Error(errorText(response, '密码尚未更新，请重试。'));
    const accepted = acceptSessionPayload(response.data, client.session);
    client.store.write(accepted);
    client.session = accepted;
    state.account.pwChallenge = null;
    state.account.pwAfter = 0;
    ['pw-new', 'pw-confirm', 'pw-code'].forEach((id) => { const input = $(`#${id}`); if (input) input.value = ''; });
    resetAccountData();
    await loadAccountCore();
    refreshView();
    toast('密码已更新。所有旧会话已失效，当前浏览器已重新登录。', 'ok');
  }, '密码尚未更新，请重试。', 'pw-status-line');
}

async function startAccountDeletion(button) {
  const ok = await confirmAction({
    title: '申请注销账号？',
    description: '服务器上的账号、登录身份、设备与权益将被删除。继续会发送邮箱确认验证码；此时还不会删除账号。',
    confirmLabel: '发送确认验证码',
    danger: true,
  });
  if (!ok) return;
  await withBusy(button, async () => {
    const response = await state.account.client.api('POST', '/me/reauth/email/start', {});
    if (response.status !== 202 || !response.data?.challenge_id) throw new Error(errorText(response, '无法发起注销确认。'));
    state.account.deletionChallenge = response.data.challenge_id;
    state.account.deletionProof = null;
    state.account.deletionVerifyKey = newKey();
    state.account.deletionKey = newKey();
    refreshView();
    toast('验证码已请求，5 分钟内有效。', 'ok');
  }, '无法发起注销确认。');
}

async function submitDeletion(form) {
  const code = $('#del-code')?.value || '';
  const text = $('#del-text')?.value || '';
  if (!state.account.deletionChallenge || code.length !== 8 || text !== '注销账号') {
    setStatus('del-status-line', '请填写 8 位验证码，并输入「注销账号」。', true);
    return;
  }
  const ok = await confirmAction({
    title: '确认申请永久注销？',
    description: '注销不可恢复。确认后会提交服务器请求，等待安全日志确认后执行。',
    confirmLabel: '确认申请注销',
    danger: true,
  });
  if (!ok) return;
  const button = form.querySelector('button[type="submit"]');
  await withBusy(button, async () => {
    if (!state.account.deletionProof) {
      const proof = await state.account.client.api('POST', '/me/reauth/email/verify', {
        challenge_id: state.account.deletionChallenge,
        code,
        purpose: 'account_delete',
      }, state.account.deletionVerifyKey);
      if (!proof.ok) throw new Error(errorText(proof, '邮箱验证未通过。'));
      state.account.deletionProof = proof.data.reauth_token;
    }
    const response = await state.account.client.api('POST', '/me/deletion', { reauth_token: state.account.deletionProof }, state.account.deletionKey);
    if (response.status !== 202) throw new Error(errorText(response, '注销尚未完成；数据保持原状，请稍后重试。'));
    state.account.deletionChallenge = null;
    state.account.deletionProof = null;
    refreshView();
    toast('注销申请已提交，等待安全日志确认后执行。', 'ok');
  }, '注销尚未完成；数据保持原状，请稍后重试。', 'del-status-line');
}

async function submitRedeem(form) {
  const code = $('#redeem-code')?.value.trim() || '';
  if (code.length < 12 || code.length > 40) {
    setStatus('redeem-status', '请输入 12–40 位完整激活码。', true);
    return;
  }
  const ok = await confirmAction({
    title: '将激活码兑换到当前账号？',
    description: `确认账号：${accountEmail() || state.account.me?.user?.id}。激活码兑换后不能转给其他账号。`,
    confirmLabel: '兑换',
  });
  if (!ok) return;
  const button = form.querySelector('button[type="submit"]');
  await withBusy(button, async () => {
    const response = await state.account.client.api('POST', '/me/activation-codes/redeem', { code }, state.account.redeemKey);
    if (!response.ok) throw new Error(errorText(response, response.status === 422 ? '激活码无效、过期或已兑换。' : '兑换未完成，请重试。'));
    state.account.redeemKey = newKey();
    $('#redeem-code').value = '';
    resetAccountData();
    await loadAccountCore();
    state.account.sectionLoaded.entitlements = false;
    await ensureAccountSection('entitlements');
    refreshView();
    setStatus('redeem-status', '兑换成功，权益已经更新。');
    toast('兑换成功，权益已经更新。', 'ok');
  }, '兑换未完成，请重试。', 'redeem-status');
}

async function submitFeedback(form) {
  const subject = $('#feedback-subject')?.value.trim() || '';
  const body = $('#feedback-body')?.value.trim() || '';
  if ([...body].length < 5 || [...body].length > 4000) {
    setStatus('feedback-status', '请填写 5–4000 个字符的反馈。', true);
    return;
  }
  const button = form.querySelector('button[type="submit"]');
  await withBusy(button, async () => {
    const response = await state.account.client.api('POST', '/me/feedback', { subject, body }, state.account.feedbackKey);
    if (!response.ok) throw new Error(errorText(response, '反馈尚未提交，请重试。'));
    state.account.feedbackKey = newKey();
    $('#feedback-subject').value = '';
    $('#feedback-body').value = '';
    state.account.sectionLoaded.feedback = false;
    await ensureAccountSection('feedback');
    refreshView();
    toast('反馈已收到，可以在下方查看进度。', 'ok');
  }, '反馈尚未提交，内容已保留，请重试。', 'feedback-status');
}

function exportAccount() {
  if (!state.account.me) { toast('账号资料尚未读取完成。', 'bad'); return; }
  const payload = {
    exported_at: new Date().toISOString(),
    account: state.account.me.user,
    identities: state.account.me.identities,
    devices: state.account.devices,
    entitlements: state.account.entitlements,
  };
  downloadJson(`River-account-${new Date().toISOString().slice(0, 10)}.json`, payload);
  toast('账号资料已下载，文件不含密码或登录令牌。', 'ok');
}

async function withBusy(button, action, fallback, statusId = '') {
  if (!button) return;
  if (button.disabled) return;
  const form = button.closest?.('form');
  const controls = form ? [...form.querySelectorAll('input,textarea,select,button')].map((element) => ({ element, disabled: element.disabled })) : [];
  controls.forEach(({ element }) => { element.disabled = true; });
  button.disabled = true;
  button.setAttribute('aria-busy', 'true');
  try {
    await action();
  } catch (error) {
    if (error instanceof AuthRequiredError || error instanceof AuthExpiredError) { redirectToLogin(); return; }
    if (error instanceof AccountSwitchedError) { location.reload(); return; }
    const message = error.name === 'AbortError'
      ? '请求超时，内容已保留，可以重试。'
      : error.name === 'TypeError'
        ? '网络连接中断，内容已保留，请检查网络后重试。'
        : (error.message || fallback);
    if (statusId && $(`#${statusId}`)) setStatus(statusId, message, true);
    else toast(message, 'bad');
  } finally {
    controls.forEach(({ element, disabled }) => { element.disabled = disabled; });
    button.disabled = false;
    button.removeAttribute('aria-busy');
  }
}

function setStatus(id, message, bad = false) {
  const element = $(`#${id}`);
  if (!element) { toast(message, bad ? 'bad' : ''); return; }
  element.textContent = message;
  element.className = `status-line${bad ? ' bad' : ' ok'}`;
}

function tickPasswordButton() {
  const button = $('#pw-start-btn');
  if (!button) return;
  if (button.getAttribute('aria-busy') === 'true') return;
  const left = Math.max(0, Math.ceil((state.account.pwAfter - Date.now()) / 1000));
  if (left > 0) {
    button.disabled = true;
    button.textContent = `${left}s 后可重发`;
  } else if (state.account.pwChallenge) {
    button.disabled = false;
    button.textContent = '重新获取验证邮件';
  } else {
    button.disabled = !accountEmail();
    button.textContent = '获取验证邮件';
  }
}

/* ---------- start ---------- */

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
else init();

/* River MemoryOS console — local, dependency-free memory core.
 *
 * This module never performs I/O.  It turns a user-selected memory mirror into a
 * predictable in-memory shape, then provides the read-only browsing, search and
 * extractive answering used by the console.  Nothing here sends data anywhere.
 */

export const MIRROR_FORMAT = 'river.memory-mirror';
export const MIRROR_VERSION = 1;
export const MAX_IMPORT_BYTES = 25 * 1024 * 1024;

const KINDS = new Set(['journal', 'auto', 'note', 'photo', 'place', 'milestone']);
const SOURCE_LABELS = {
  user: '手写',
  auto: '自动日记',
  voice: '语音速记',
  photo: '照片',
  system: '系统整理',
  import: '导入副本',
};
const TONES = ['sea', 'moss', 'clay', 'dusk', 'rose', 'sand'];

const QUESTION_FILLERS = [
  '你还记得', '你记得', '还记得', '记得吗', '记得', '帮我找', '帮我', '请帮我',
  '找一找', '找一下', '找找', '查一下', '看看', '告诉我', '和我说说', '说说',
  '在做什么', '做什么', '做了什么', '干什么', '发生过什么', '有哪些', '是什么', '怎么样',
  '为什么', '有没有', '什么时候', '从什么时候', '第一次', '最早', '开始', '后来',
  '完全不存在', '不存在', '一段', '记忆里', '提到过', '提到', '查找', '搜索', '找到',
  '日子', '时候', '一天', '事情', '那次', '那天', '当时', '最近', '这段时间', '这些年', '我', '我的', '我们',
  '你', '吗', '呢', '吧', '呀', '啊', '的', '了', '在', '和', '与', '关于', '一下',
];

const CJK = /[\u3400-\u9fff]/;
const PUNCT = /[，。！？、；：""''（）()\[\]{}《》〈〉…—－\-·,\.!\?;:'"\/\\|@#$%^&*+=~`<>]/g;

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
const asArray = (value) => Array.isArray(value) ? value : [];

export function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[character]));
}

export function hashString(value) {
  let hash = 2166136261;
  const text = String(value ?? '');
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(36);
}

export function dateKey(value) {
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    const year = value.getFullYear();
    const month = String(value.getMonth() + 1).padStart(2, '0');
    const day = String(value.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }
  const match = String(value ?? '').match(/(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})/);
  if (!match) return '';
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return '';
  const probe = new Date(year, month - 1, day);
  if (probe.getFullYear() !== year || probe.getMonth() !== month - 1 || probe.getDate() !== day) return '';
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

export function dateFromKey(key) {
  const normalized = dateKey(key);
  if (!normalized) return null;
  const [year, month, day] = normalized.split('-').map(Number);
  return new Date(year, month - 1, day);
}

export function addDays(date, amount) {
  const next = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  next.setDate(next.getDate() + amount);
  return next;
}

export function todayKey(now = new Date()) {
  return dateKey(now);
}

export function timeKey(value) {
  const match = String(value ?? '').match(/(\d{1,2}):(\d{2})/);
  if (!match) return '';
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour > 23 || minute > 59) return '';
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

export function weekdayCN(value) {
  const date = typeof value === 'string' ? dateFromKey(value) : value;
  if (!date) return '';
  return ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][date.getDay()];
}

export function formatDateCN(value, options = {}) {
  const key = dateKey(value);
  if (!key) return '日期未知';
  const date = dateFromKey(key);
  const { withYear = true, withWeekday = false, monthOnly = false } = options;
  if (monthOnly) return `${date.getMonth() + 1}月`;
  const base = withYear
    ? `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`
    : `${date.getMonth() + 1}月${date.getDate()}日`;
  return withWeekday ? `${base} ${weekdayCN(date)}` : base;
}

export function relativeDayCN(value, now = new Date()) {
  const key = dateKey(value);
  if (!key) return '';
  const target = dateFromKey(key);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const diff = Math.round((today - target) / 86400000);
  if (diff === 0) return '今天';
  if (diff === 1) return '昨天';
  if (diff === 2) return '前天';
  if (diff > 2 && diff < 30) return `${diff} 天前`;
  if (diff < 0) return '将来';
  return formatDateCN(key, { withYear: target.getFullYear() !== today.getFullYear() });
}

export function monthKey(value) {
  const key = dateKey(value);
  return key ? key.slice(0, 7) : '';
}

export function monthLabel(key) {
  const match = String(key ?? '').match(/^(\d{4})-(\d{2})$/);
  return match ? `${match[1]}年${Number(match[2])}月` : '时间未定';
}

export function truncate(text, max = 160) {
  const value = String(text ?? '').replace(/\s+/g, ' ').trim();
  if ([...value].length <= max) return value;
  return `${[...value].slice(0, max).join('')}…`;
}

function normalizeTags(value) {
  const seen = new Set();
  const tags = [];
  for (const item of asArray(value)) {
    const tag = String(item ?? '').replace(/^#/, '').trim();
    if (!tag || tag.length > 24 || seen.has(tag)) continue;
    seen.add(tag);
    tags.push(tag);
    if (tags.length >= 8) break;
  }
  return tags;
}

function normalizeStringList(value) {
  return asArray(value)
    .map((item) => String(item ?? '').trim())
    .filter(Boolean)
    .slice(0, 24);
}

function normalizePlace(raw) {
  const value = raw?.place ?? raw?.place_name ?? raw?.location ?? '';
  if (typeof value === 'object' && value) return String(value.name ?? value.title ?? '').trim();
  return String(value ?? '').trim();
}

function flattenLegacyFacts(raw) {
  const facts = [];
  for (const group of asArray(raw?.did)) {
    if (Array.isArray(group?.items)) facts.push(...group.items);
    else if (typeof group?.items === 'string') facts.push(group.items);
  }
  for (const memo of asArray(raw?.memos)) {
    if (typeof memo === 'string' && memo.trim()) facts.push(memo.trim());
  }
  return normalizeStringList(facts);
}

function legacyBody(raw) {
  const parts = [];
  const thoughts = asArray(raw?.thoughts).map((item) => String(item ?? '').trim()).filter(Boolean);
  if (thoughts.length) parts.push(thoughts.join('\n\n'));
  for (const key of ['overview', 'daily', 'screen_note', 'browse_note', 'plan']) {
    const value = String(raw?.[key] ?? '').trim();
    if (value && !parts.includes(value)) parts.push(value);
  }
  return parts.join('\n\n');
}

function inferKind(raw) {
  const kind = String(raw?.kind ?? '').trim();
  if (KINDS.has(kind)) return kind;
  if (raw?.daily || raw?.screen_apps || raw?.screen_note) return 'auto';
  if (raw?.photo || raw?.image) return 'photo';
  if (raw?.place && !raw?.thoughts) return 'place';
  return 'journal';
}

function inferSource(raw, kind) {
  const source = raw?.source;
  if (typeof source === 'object' && source) {
    const type = SOURCE_LABELS[source.type] ? source.type : 'import';
    return { type, label: String(source.label ?? SOURCE_LABELS[type]).slice(0, 24) };
  }
  const type = String(source ?? '').trim();
  if (SOURCE_LABELS[type]) return { type, label: SOURCE_LABELS[type] };
  if (kind === 'auto') return { type: 'auto', label: SOURCE_LABELS.auto };
  if (kind === 'photo') return { type: 'photo', label: SOURCE_LABELS.photo };
  return { type: 'user', label: SOURCE_LABELS.user };
}

export function normalizeEntry(raw, index = 0) {
  if (!raw || typeof raw !== 'object') return null;
  const occurred = raw.occurred_at ?? raw.occurredAt ?? raw.date ?? raw.created_at;
  const key = dateKey(occurred);
  if (!key) return null;
  const kind = inferKind(raw);
  const title = String(raw.title ?? raw.subject ?? '').trim() || truncate(legacyBody(raw) || '无题', 32);
  const body = String(raw.body ?? raw.text ?? raw.content ?? '').trim() || legacyBody(raw);
  if (!title && !body) return null;
  const facts = normalizeStringList(raw.facts).length ? normalizeStringList(raw.facts) : flattenLegacyFacts(raw);
  const place = normalizePlace(raw);
  const tags = normalizeTags(raw.tags ?? raw.labels);
  const source = inferSource(raw, kind);
  const idSeed = raw.id ?? raw.page_id ?? `${key}|${title}|${body}`;
  const explicitId = typeof raw.id === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(raw.id) ? raw.id : '';
  const id = explicitId || `m_${hashString(idSeed)}`;
  const tone = TONES.includes(raw.tone) ? raw.tone : TONES[Number.parseInt(hashString(id).slice(0, 4), 36) % TONES.length];
  return {
    id,
    date: key,
    time: timeKey(raw.time ?? occurred),
    kind,
    title,
    body,
    facts,
    tags,
    place,
    mood: String(raw.mood ?? raw.feeling ?? '').trim().slice(0, 24),
    source,
    favorite: Boolean(raw.favorite),
    collectionIds: normalizeStringList(raw.collectionIds ?? raw.collections),
    tone,
    imageTone: String(raw.imageTone ?? tone),
    weather: String(raw.weather ?? '').trim().slice(0, 12),
    importedIndex: index,
  };
}

function normalizePersona(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const name = String(raw.name ?? '').trim().slice(0, 40);
  if (!name) return null;
  return { name, line: String(raw.line ?? raw.tagline ?? '').trim().slice(0, 120) };
}

function normalizeCollection(raw, index = 0) {
  if (!raw || typeof raw !== 'object') return null;
  const title = String(raw.title ?? raw.name ?? '').trim();
  if (!title) return null;
  return {
    id: String(raw.id ?? `c_${hashString(title + index)}`),
    title: title.slice(0, 60),
    description: String(raw.description ?? raw.summary ?? '').trim().slice(0, 240),
    entryIds: normalizeStringList(raw.entryIds ?? raw.entry_ids),
    tone: TONES.includes(raw.tone) ? raw.tone : TONES[index % TONES.length],
    start: dateKey(raw.start ?? raw.start_date) || '',
    end: dateKey(raw.end ?? raw.end_date) || '',
  };
}

function normalizeUnderstanding(raw, index = 0) {
  if (!raw || typeof raw !== 'object') return null;
  const statement = String(raw.statement ?? raw.text ?? raw.title ?? '').trim();
  if (!statement) return null;
  return {
    id: String(raw.id ?? `u_${hashString(statement + index)}`),
    statement: statement.slice(0, 280),
    evidenceIds: normalizeStringList(raw.evidenceIds ?? raw.evidence_ids),
    scope: String(raw.scope ?? raw.range ?? '尚未标注范围').trim().slice(0, 80),
    status: ['pending', 'confirmed', 'rejected'].includes(raw.status) ? raw.status : 'pending',
    kind: String(raw.kind ?? 'pattern').trim().slice(0, 24),
    correction: String(raw.correction ?? '').trim().slice(0, 280),
  };
}

export function normalizeArchive(payload, options = {}) {
  const { now = new Date(), sourceLabel = '本地记忆副本' } = options;
  const root = payload && typeof payload === 'object' && payload.data && typeof payload.data === 'object'
    ? payload.data
    : payload;
  const rawEntries = Array.isArray(root) ? root : asArray(root?.entries);
  if (!rawEntries.length) {
    return {
      ok: false,
      error: '没有找到可读取的记忆。请选择由河流日记导出的记忆副本（JSON）。',
      entries: [], collections: [], understandings: [], persona: null, skipped: 0, warnings: [], sourceLabel,
    };
  }
  const entries = [];
  let skipped = 0;
  const warnings = [];
  rawEntries.forEach((raw, index) => {
    const entry = normalizeEntry(raw, index);
    if (entry) entries.push(entry);
    else skipped += 1;
  });
  if (!entries.length) {
    return {
      ok: false,
      error: '文件里的记忆缺少可识别的日期或正文，没有导入任何内容。',
      entries: [], collections: [], understandings: [], persona: null, skipped, warnings, sourceLabel,
    };
  }
  entries.sort((a, b) => (a.date + (a.time || '00:00')).localeCompare(b.date + (b.time || '00:00')));
  const collections = asArray(root?.collections).map(normalizeCollection).filter(Boolean);
  const understandings = asArray(root?.understandings).map(normalizeUnderstanding).filter(Boolean);
  if (skipped) warnings.push(`${skipped} 条记录缺少有效日期，已跳过。`);
  if (Number(root?.version) > MIRROR_VERSION) warnings.push('副本版本高于当前控制台，未识别的字段会被忽略。');
  const future = entries.filter((entry) => entry.date > todayKey(now)).length;
  if (future) warnings.push(`${future} 条记录的日期在今天之后，已按原样保留。`);
  return {
    ok: true,
    format: String(root?.format ?? MIRROR_FORMAT),
    version: Number(root?.version ?? MIRROR_VERSION),
    exportedAt: String(root?.exported_at ?? root?.exportedAt ?? ''),
    persona: normalizePersona(root?.persona),
    entries,
    collections,
    understandings,
    skipped,
    warnings,
    sourceLabel,
  };
}

export function buildStats(entries) {
  const sorted = [...entries].sort((a, b) => a.date.localeCompare(b.date));
  const days = new Set(sorted.map((entry) => entry.date));
  const places = new Map();
  const tags = new Map();
  const sources = new Map();
  let favorites = 0;
  for (const entry of sorted) {
    if (entry.favorite) favorites += 1;
    if (entry.place) {
      const current = places.get(entry.place) ?? { name: entry.place, count: 0, first: entry.date, last: entry.date };
      current.count += 1;
      if (entry.date < current.first) current.first = entry.date;
      if (entry.date > current.last) current.last = entry.date;
      places.set(entry.place, current);
    }
    for (const tag of entry.tags) tags.set(tag, (tags.get(tag) ?? 0) + 1);
    const label = entry.source?.label ?? '记录';
    sources.set(label, (sources.get(label) ?? 0) + 1);
  }
  const first = sorted[0]?.date ?? '';
  const last = sorted.at(-1)?.date ?? '';
  return {
    count: sorted.length,
    dayCount: days.size,
    first,
    last,
    favorites,
    places: [...places.values()].sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)),
    tags: [...tags.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)),
    sources: [...sources.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count),
    rangeLabel: first ? `${formatDateCN(first, { withYear: true })} — ${formatDateCN(last, { withYear: true })}` : '还没有记忆',
  };
}

export function sortEntries(entries, direction = 'desc') {
  const factor = direction === 'asc' ? 1 : -1;
  return [...entries].sort((a, b) => {
    const left = `${a.date} ${a.time || '00:00'}`;
    const right = `${b.date} ${b.time || '00:00'}`;
    return left.localeCompare(right) * factor;
  });
}

export function groupByMonth(entries) {
  const groups = new Map();
  for (const entry of sortEntries(entries, 'desc')) {
    const key = monthKey(entry.date);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(entry);
  }
  return [...groups.entries()].map(([key, list]) => ({
    key,
    year: Number(key.slice(0, 4)),
    month: Number(key.slice(5, 7)),
    label: monthLabel(key),
    entries: list,
  }));
}

export function groupByDay(entries) {
  const groups = new Map();
  for (const entry of sortEntries(entries, 'desc')) {
    if (!groups.has(entry.date)) groups.set(entry.date, []);
    groups.get(entry.date).push(entry);
  }
  return [...groups.entries()].map(([key, list]) => ({ key, label: formatDateCN(key, { withWeekday: true }), entries: list }));
}

function inRange(key, start, end) {
  if (start && key < start) return false;
  if (end && key > end) return false;
  return true;
}

export function parseDateIntent(query, now = new Date()) {
  const q = String(query ?? '');
  const year = now.getFullYear();
  const month = now.getMonth() + 1;
  const day = now.getDate();
  const make = (startY, startM, startD, endY, endM, endD, label, matched) => ({
    start: dateKey(new Date(startY, startM - 1, startD)),
    end: dateKey(new Date(endY, endM - 1, endD)),
    label,
    matched,
  });
  const endOfMonth = (y, m) => new Date(y, m, 0).getDate();

  if (/今天/.test(q)) return make(year, month, day, year, month, day, '今天', '今天');
  if (/昨天/.test(q)) {
    const d = addDays(now, -1);
    return make(d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getFullYear(), d.getMonth() + 1, d.getDate(), '昨天', '昨天');
  }
  if (/前天/.test(q)) {
    const d = addDays(now, -2);
    return make(d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getFullYear(), d.getMonth() + 1, d.getDate(), '前天', '前天');
  }

  let match = q.match(/(\d{4})\s*年(?:\s*(\d{1,2})\s*月)?/);
  if (match) {
    const y = Number(match[1]);
    if (match[2]) {
      const m = clamp(Number(match[2]), 1, 12);
      return make(y, m, 1, y, m, endOfMonth(y, m), `${y}年${m}月`, match[0]);
    }
    return make(y, 1, 1, y, 12, 31, `${y}年`, match[0]);
  }

  match = q.match(/(\d{1,2})\s*月(?:份)?/);
  if (match) {
    const m = clamp(Number(match[1]), 1, 12);
    const y = m > month ? year - 1 : year;
    return make(y, m, 1, y, m, endOfMonth(y, m), `${y}年${m}月`, match[0]);
  }

  const seasonMatch = q.match(/(去年|前年|今年)?\s*(春天|夏天|秋天|冬天)/);
  if (seasonMatch) {
    const relative = seasonMatch[1] || '';
    let y = year;
    if (relative === '去年') y -= 1;
    if (relative === '前年') y -= 2;
    const season = seasonMatch[2];
    if (!relative) {
      if (season === '春天' && month < 3) y -= 1;
      if (season === '夏天' && month < 6) y -= 1;
      if (season === '秋天' && month < 9) y -= 1;
      if (season === '冬天' && month >= 3 && month < 12) y -= 1;
    }
    if (season === '春天') return make(y, 3, 1, y, 5, 31, `${y}年春天`, seasonMatch[0]);
    if (season === '夏天') return make(y, 6, 1, y, 8, 31, `${y}年夏天`, seasonMatch[0]);
    if (season === '秋天') return make(y, 9, 1, y, 11, 30, `${y}年秋天`, seasonMatch[0]);
    return make(y, 12, 1, y + 1, 2, 29, `${y}年冬天`, seasonMatch[0]);
  }

  match = q.match(/(去年|前年|今年)/);
  if (match) {
    const y = match[1] === '去年' ? year - 1 : match[1] === '前年' ? year - 2 : year;
    return make(y, 1, 1, y, 12, 31, `${y}年`, match[0]);
  }

  match = q.match(/最近\s*(一周|一个月|半年|一年|几天)/);
  if (match) {
    const span = { '一周': 7, '一个月': 30, '半年': 183, '一年': 365, '几天': 7 }[match[1]] ?? 30;
    const start = addDays(now, -span);
    return make(start.getFullYear(), start.getMonth() + 1, start.getDate(), year, month, day, `最近${match[1]}`, match[0]);
  }

  return null;
}

function removeMatched(query, matched) {
  return matched ? query.replace(matched, ' ') : query;
}

export function queryTerms(query, now = new Date()) {
  const intent = parseDateIntent(query, now);
  return extractTerms(removeMatched(String(query ?? ''), intent?.matched ?? ''));
}

export function extractTerms(query) {
  let cleaned = String(query ?? '').toLowerCase().replace(PUNCT, ' ');
  for (const filler of QUESTION_FILLERS) cleaned = cleaned.split(filler).join(' ');
  const chunks = cleaned.split(/\s+/).map((chunk) => chunk.trim()).filter(Boolean);
  const terms = [];
  for (const chunk of chunks) {
    if (chunk.length < 2) continue;
    if (CJK.test(chunk)) {
      terms.push(chunk);
      if (chunk.length >= 4) {
        for (let index = 0; index <= chunk.length - 2; index += 1) terms.push(chunk.slice(index, index + 2));
      }
    } else {
      terms.push(chunk);
    }
  }
  return [...new Set(terms)].filter((term) => term.length >= 2).slice(0, 12);
}

function entryHaystack(entry) {
  return {
    title: entry.title.toLowerCase(),
    body: entry.body.toLowerCase(),
    tags: entry.tags.join(' ').toLowerCase(),
    place: entry.place.toLowerCase(),
    mood: entry.mood.toLowerCase(),
  };
}

function scoreEntry(entry, terms, phrase) {
  const hay = entryHaystack(entry);
  let score = 0;
  let matched = 0;
  for (const term of terms) {
    let hit = 0;
    if (hay.title.includes(term)) hit += 8;
    if (hay.tags.includes(term)) hit += 6;
    if (hay.place.includes(term)) hit += 4;
    if (hay.mood.includes(term)) hit += 2;
    if (hay.body.includes(term)) hit += 2;
    if (hit) matched += 1;
    score += hit;
  }
  if (phrase && (hay.body.includes(phrase) || hay.title.includes(phrase))) score += 10;
  if (entry.favorite) score += 1;
  return { score, matched };
}

export function searchEntries(entries, query, options = {}) {
  const { now = new Date(), favoritesOnly = false } = options;
  const rawQuery = String(query ?? '').trim();
  const intent = parseDateIntent(rawQuery, now);
  const withoutDate = removeMatched(rawQuery, intent?.matched ?? '');
  const terms = extractTerms(withoutDate);
  const phrase = withoutDate.replace(PUNCT, ' ').trim();
  const base = entries.filter((entry) => (!intent || inRange(entry.date, intent.start, intent.end)) && (!favoritesOnly || entry.favorite));
  const scored = base.map((entry) => {
    const { score, matched } = scoreEntry(entry, terms, terms.length > 1 ? phrase : '');
    return { entry, score, matched };
  }).filter((item) => terms.length === 0 || item.matched > 0);
  scored.sort((a, b) => b.score - a.score || b.entry.date.localeCompare(a.entry.date));
  return { intent, terms, results: scored };
}

export function filterEntries(entries, filters = {}) {
  const {
    query = '', year = 'all', month = 'all', kind = 'all', favorite = false,
    tag = '', place = '', collectionId = '', day = '', now = new Date(),
  } = filters;
  let result = [...entries];
  if (day) result = result.filter((entry) => entry.date === String(day));
  else if (year !== 'all') result = result.filter((entry) => entry.date.startsWith(String(year)));
  if (month !== 'all') result = result.filter((entry) => entry.date.slice(5, 7) === String(month).padStart(2, '0'));
  if (kind !== 'all') result = result.filter((entry) => entry.kind === kind);
  if (favorite) result = result.filter((entry) => entry.favorite);
  if (tag) result = result.filter((entry) => entry.tags.includes(tag));
  if (place) result = result.filter((entry) => entry.place === place);
  if (collectionId === 'favorites') result = result.filter((entry) => entry.favorite);
  else if (collectionId) {
    result = result.filter((entry) => entry.collectionIds.includes(collectionId));
  }
  if (String(query).trim()) {
    const { results } = searchEntries(result, query, { now, favoritesOnly: false });
    return results.map((item) => item.entry);
  }
  return sortEntries(result, 'desc');
}

export function onThisDay(entries, now = new Date()) {
  const month = now.getMonth() + 1;
  const day = now.getDate();
  return sortEntries(entries.filter((entry) => {
    const date = dateFromKey(entry.date);
    return date && date.getMonth() + 1 === month && date.getDate() === day && date.getFullYear() < now.getFullYear();
  }), 'desc');
}

export function forgottenEntry(entries, now = new Date(), seed = 0) {
  const cutoff = dateKey(addDays(now, -180));
  const candidates = entries.filter((entry) => entry.date <= cutoff && !entry.favorite);
  if (!candidates.length) return null;
  const sorted = sortEntries(candidates, 'asc');
  return sorted[Math.abs(seed) % sorted.length];
}

export function relatedEntries(entries, target, limit = 4) {
  if (!target) return [];
  return entries
    .filter((entry) => entry.id !== target.id)
    .map((entry) => {
      let score = 0;
      if (entry.place && entry.place === target.place) score += 4;
      for (const tag of entry.tags) if (target.tags.includes(tag)) score += 3;
      if (entry.collectionIds.some((id) => target.collectionIds.includes(id))) score += 2;
      const distance = Math.abs((dateFromKey(entry.date)?.getTime() ?? 0) - (dateFromKey(target.date)?.getTime() ?? 0)) / 86400000;
      if (distance < 30) score += 1;
      return { entry, score };
    })
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score || b.entry.date.localeCompare(a.entry.date))
    .slice(0, limit)
    .map((item) => item.entry);
}

export function placeSummary(entries) {
  const map = new Map();
  for (const entry of entries) {
    if (!entry.place) continue;
    if (!map.has(entry.place)) map.set(entry.place, []);
    map.get(entry.place).push(entry);
  }
  return [...map.entries()].map(([name, list]) => {
    const sorted = sortEntries(list, 'asc');
    return {
      name,
      count: sorted.length,
      first: sorted[0],
      last: sorted.at(-1),
      entries: sortEntries(list, 'desc'),
      tone: sorted[0].tone,
    };
  }).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
}

export function tagSummary(entries) {
  const map = new Map();
  for (const entry of entries) for (const tag of entry.tags) map.set(tag, (map.get(tag) ?? 0) + 1);
  return [...map.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
}

export function collectionEntries(entries, collection) {
  if (!collection) return [];
  const ids = new Set(collection.entryIds);
  const selected = entries.filter((entry) => ids.has(entry.id) || entry.collectionIds.includes(collection.id));
  return sortEntries(selected, 'desc');
}

export function excerptAround(text, terms = [], max = 180) {
  const value = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (!value) return '';
  const lower = value.toLowerCase();
  let index = -1;
  for (const term of terms) {
    const found = lower.indexOf(String(term).toLowerCase());
    if (found >= 0 && (index < 0 || found < index)) index = found;
  }
  if (index < 0) return truncate(value, max);
  const start = Math.max(0, index - Math.floor(max / 3));
  const end = Math.min(value.length, start + max);
  return `${start > 0 ? '…' : ''}${value.slice(start, end)}${end < value.length ? '…' : ''}`;
}

export function highlightHtml(text, terms = []) {
  const escaped = escapeHtml(text);
  const unique = [...new Set(terms.map((term) => String(term).trim()).filter((term) => term.length >= 2))]
    .sort((a, b) => b.length - a.length)
    .slice(0, 8);
  if (!unique.length) return escaped;
  const pattern = unique.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
  return escaped.replace(new RegExp(`(${pattern})`, 'gi'), '<mark>$1</mark>');
}

export function answerFromMemory(entries, query, options = {}) {
  const { now = new Date(), favoritesOnly = false } = options;
  const text = String(query ?? '').trim();
  if (!text) {
    return {
      ok: false,
      reason: 'empty',
      intro: '问一件过去的事，比如一个地点、一段日子，或一句你还记得的话。',
      findings: [],
      citations: [],
      note: '本机检索 · 未调用模型',
    };
  }
  if (!entries.length) {
    return {
      ok: false,
      reason: 'no-data',
      intro: '还没有可检索的记忆副本。导入一份由河流日记导出的副本后，我会只在你的浏览器里查找。',
      findings: [],
      citations: [],
      note: '本机检索 · 未调用模型',
    };
  }
  const { intent, terms, results } = searchEntries(entries, text, { now, favoritesOnly });
  const earliest = /第一次|最早|什么时候|从什么时候|开始/.test(text);
  let ranked = results;
  if (earliest) ranked = [...results].sort((a, b) => a.entry.date.localeCompare(b.entry.date));
  if (/最近|这段时间/.test(text) && !earliest) ranked = [...results].sort((a, b) => b.entry.date.localeCompare(a.entry.date));
  const selected = ranked.slice(0, 4);
  const displayQuery = truncate(text, 28);
  const findings = selected.map(({ entry }) => ({
    id: entry.id,
    date: entry.date,
    dateLabel: formatDateCN(entry.date, { withWeekday: true }),
    title: entry.title,
    quote: excerptAround(entry.body, terms, 210),
    place: entry.place,
    entry,
  }));
  if (!findings.length) {
    return {
      ok: false,
      reason: 'no-match',
      query: text,
      intent,
      terms,
      intro: `在已导入的 ${entries.length} 段记忆里，没有找到与「${displayQuery}」相符的原话。`,
      findings: [],
      citations: [],
      suggestions: [
        '换一个更具体的地点，比如「西湖」或「厨房」',
        '改用月份或季节，比如「去年秋天」',
        '少用一两句描述，只留一个关键词',
      ],
      note: '本机检索 · 未调用模型',
    };
  }
  let intro;
  if (earliest) {
    intro = `关于「${displayQuery}」，我能找到的最早一段记录在 ${formatDateCN(findings[0].date)}。`;
  } else if (intent && !terms.length) {
    intro = `在${intent.label}，你留下了 ${results.length} 段记忆。这里是其中最近的 ${findings.length} 段。`;
  } else if (intent) {
    intro = `我在${intent.label}的记忆里找到 ${results.length} 段相关记录，下面引用其中 ${findings.length} 段原话。`;
  } else {
    intro = `我在已导入的 ${entries.length} 段记忆里找到 ${results.length} 段相关记录，下面引用其中 ${findings.length} 段原话。`;
  }
  return {
    ok: true,
    intro,
    intent,
    terms,
    findings,
    citations: findings.map((finding) => ({
      id: finding.entry.id,
      label: `${formatDateCN(finding.date)} · ${finding.title}`,
    })),
    closing: '这些是你当时写下的原话。River 没有替它们补上原因，也不把一次记录当成结论。',
    note: '本机检索 · 未调用模型 · 未上传',
  };
}

export function importReport(archive) {
  if (!archive?.ok) return '';
  const stats = buildStats(archive.entries);
  const parts = [`${stats.count} 段记忆`, `${stats.dayCount} 天`];
  if (stats.places.length) parts.push(`${stats.places.length} 个地点`);
  const warning = archive.warnings.length ? `；${archive.warnings[0]}` : '';
  return `${parts.join(' · ')}${warning}`;
}

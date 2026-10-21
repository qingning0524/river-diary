import test from 'node:test';
import assert from 'node:assert/strict';
import {
  answerFromMemory, buildStats, collectionEntries, dateKey, filterEntries, forgottenEntry,
  groupByMonth, highlightHtml, importReport, normalizeArchive, normalizeEntry, onThisDay,
  parseDateIntent, placeSummary, queryTerms, relatedEntries, searchEntries, tagSummary,
} from '../assets/memory-core.js';
import { buildDemoArchive } from '../assets/demo-data.js';

const NOW = new Date(2026, 9, 20, 12, 0, 0);
const archive = normalizeArchive(buildDemoArchive(NOW), { now: NOW });

test('normalizes the synthetic mirror without losing stable ids or relations', () => {
  assert.equal(archive.ok, true);
  assert.equal(archive.entries.length, 49);
  assert.equal(archive.collections.length, 8);
  assert.equal(archive.understandings.length, 4);
  assert.equal(archive.skipped, 0);
  assert.equal(archive.persona.name, '林岸');
  assert.equal(archive.entries[0].id, 'd32');
  assert.ok(archive.entries.every((entry, index) => index === 0 || entry.date >= archive.entries[index - 1].date));
  const collection = archive.collections.find((item) => item.id === 'c2');
  assert.ok(collection.entryIds.includes('d24'));
  const evidence = archive.understandings.find((item) => item.id === 'u2');
  assert.deepEqual(evidence.evidenceIds, ['d09', 'd24', 'd35', 'd40']);
});

test('maps a legacy data.json entry into body, facts and source', () => {
  const legacy = normalizeArchive({
    entries: [{
      page_id: 'legacy-page', date: '2026-01-02', title: '旧快照', daily: '屏幕 4.2h',
      thoughts: ['今天把书桌清理了一遍。'], overview: '一段自动整理。',
      did: [{ items: ['整理抽屉', '丢掉旧票根'] }], tags: ['整理', '家'], mood: '安静',
    }],
  }, { now: NOW });
  assert.equal(legacy.ok, true);
  const entry = legacy.entries[0];
  assert.equal(entry.date, '2026-01-02');
  assert.match(entry.body, /书桌/);
  assert.match(entry.body, /自动整理/);
  assert.deepEqual(entry.facts, ['整理抽屉', '丢掉旧票根']);
  assert.deepEqual(entry.tags, ['整理', '家']);
  assert.equal(entry.source.type, 'auto');
});

test('rejects empty and invalid archives without inventing entries', () => {
  assert.equal(normalizeArchive({ entries: [] }).ok, false);
  assert.equal(normalizeArchive({ entries: [{ title: '没有日期' }] }).ok, false);
  const mixed = normalizeArchive({ entries: [{ date: '不是日期', body: 'x' }, { date: '2026-02-02', body: '可以读' }] }, { now: NOW });
  assert.equal(mixed.ok, true);
  assert.equal(mixed.entries.length, 1);
  assert.equal(mixed.skipped, 1);
  assert.match(mixed.warnings[0], /1 条/);
});

test('date keys reject impossible dates and accept leap day', () => {
  assert.equal(dateKey('2024-02-29'), '2024-02-29');
  assert.equal(dateKey('2023-02-29'), '');
  assert.equal(dateKey('2026年10月20日'), '2026-10-20');
  assert.equal(dateKey('not a date'), '');
});

test('entry normalization clamps tags and keeps an explicit safe id', () => {
  const entry = normalizeEntry({
    id: 'stable-id', date: '2026-03-04', title: '标题', body: '正文',
    tags: Array.from({ length: 12 }, (_, index) => `标签${index}`),
  });
  assert.equal(entry.id, 'stable-id');
  assert.equal(entry.tags.length, 8);
  assert.equal(entry.kind, 'journal');
  assert.equal(entry.source.label, '手写');
});

test('stats describe days, places, tags and favourites without a score', () => {
  const stats = buildStats(archive.entries);
  assert.equal(stats.count, 49);
  assert.equal(stats.dayCount, 49);
  assert.equal(stats.places.length, 16);
  assert.ok(stats.favorites >= 9);
  assert.equal(stats.first, '2021-03-01');
  assert.equal(stats.last, '2026-10-20');
  assert.ok(stats.tags.some((tag) => tag.name === '跑步' && tag.count === 5));
  assert.equal('score' in stats, false);
});

test('month grouping is newest first and labels months in Chinese', () => {
  const groups = groupByMonth(archive.entries);
  assert.equal(groups[0].key, '2026-10');
  assert.equal(groups[0].label, '2026年10月');
  assert.equal(groups.at(-1).key, '2021-03');
});

test('filters cover day, year, favourite, tag, place and collection', () => {
  assert.equal(filterEntries(archive.entries, { day: '2026-10-20' }).length, 1);
  assert.equal(filterEntries(archive.entries, { year: '2025' }).length, 9);
  assert.ok(filterEntries(archive.entries, { favorite: true }).every((entry) => entry.favorite));
  assert.ok(filterEntries(archive.entries, { tag: '跑步' }).every((entry) => entry.tags.includes('跑步')));
  assert.ok(filterEntries(archive.entries, { place: '杭州·西湖' }).every((entry) => entry.place === '杭州·西湖'));
  const c2 = archive.collections.find((item) => item.id === 'c2');
  const entries = collectionEntries(archive.entries, c2);
  assert.ok(entries.length >= 4);
  assert.ok(entries.every((entry) => entry.collectionIds.includes('c2') || c2.entryIds.includes(entry.id)));
});

test('date intent understands last autumn, year-month and recent spans', () => {
  const autumn = parseDateIntent('去年秋天在上海做什么', NOW);
  assert.equal(autumn.label, '2025年秋天');
  assert.equal(autumn.start, '2025-09-01');
  assert.equal(autumn.end, '2025-11-30');
  const exact = parseDateIntent('2024年10月', NOW);
  assert.equal(exact.start, '2024-10-01');
  assert.equal(exact.end, '2024-10-31');
  const recent = parseDateIntent('最近一个月', NOW);
  assert.equal(recent.label, '最近一个月');
});

test('search removes question filler and finds the Shanghai trip', () => {
  const { results } = searchEntries(archive.entries, '我去年秋天在上海做什么', { now: NOW });
  assert.equal(results.length, 1);
  assert.equal(results[0].entry.title, '去上海出了一天差');
  assert.deepEqual(queryTerms('去年秋天在上海做什么', NOW), ['上海']);
});

test('search ranks the running thread and answer can take the earliest mention', () => {
  const { results } = searchEntries(archive.entries, '跑步', { now: NOW });
  assert.equal(results.length, 5);
  const answer = answerFromMemory(archive.entries, '什么时候开始跑步', { now: NOW });
  assert.equal(answer.ok, true);
  assert.equal(answer.findings[0].date, '2024-09-12');
  assert.equal(answer.findings[0].title, '开始跑步的第一天');
  assert.match(answer.intro, /最早/);
});

test('answers stay extractive and honest when nothing matches or there is no data', () => {
  const none = answerFromMemory(archive.entries, '完全不存在的一段记忆', { now: NOW });
  assert.equal(none.ok, false);
  assert.equal(none.reason, 'no-match');
  assert.ok(none.suggestions.length >= 2);
  const empty = answerFromMemory([], '跑步', { now: NOW });
  assert.equal(empty.ok, false);
  assert.equal(empty.reason, 'no-data');
  assert.match(empty.intro, /还没有/);
  const answer = answerFromMemory(archive.entries, '厨房', { now: NOW });
  assert.equal(answer.ok, true);
  assert.match(answer.note, /未调用模型/);
  assert.ok(answer.findings.every((finding) => finding.quote.length > 0));
});

test('on this day only returns previous years and forgotten finds an older unstarred entry', () => {
  const items = onThisDay(archive.entries, NOW);
  assert.deepEqual(items.map((entry) => entry.title), ['在武康路走了一个下午', '第一次在会上介绍自己的方案']);
  const old = forgottenEntry(archive.entries, NOW, 2);
  assert.ok(old);
  assert.equal(old.favorite, false);
  assert.ok(old.date < '2026-04-20');
});

test('places, tags and related memories keep their provenance', () => {
  const places = placeSummary(archive.entries);
  assert.equal(places[0].name, '家');
  assert.ok(places[0].count >= 10);
  const tags = tagSummary(archive.entries);
  assert.equal(tags[0].name, '家人');
  const target = archive.entries.find((entry) => entry.id === 'd24');
  const related = relatedEntries(archive.entries, target);
  assert.ok(related.length > 0);
  assert.ok(related.every((entry) => entry.id !== target.id));
});

test('highlight escapes content before marking query terms', () => {
  const html = highlightHtml('<script>跑步</script> 与 跑步', ['跑步']);
  assert.ok(!html.includes('<script>'));
  assert.ok(html.includes('&lt;script&gt;'));
  assert.equal((html.match(/<mark>/g) || []).length, 2);
});

test('import report states what was read without claiming a full library', () => {
  const report = importReport(archive);
  assert.match(report, /49 段记忆/);
  assert.match(report, /49 天/);
  assert.match(report, /16 个地点/);
  assert.doesNotMatch(report, /全部|完整历史/);
});

test('normalizes a device context entry without losing its source', () => {
  const result = normalizeArchive({
    format: 'river.memory-mirror',
    version: 1,
    entries: [{
      id: 'context-device-a-2026-10-21',
      occurred_at: '2026-10-21T12:00:00',
      kind: 'context',
      title: 'Mac 的一天',
      body: '浏览：3 次访问 · example.com\n\n备忘录：2 条',
      facts: ['窗边 · 去河边走走。'],
      tags: ['设备上下文', 'Mac'],
      source: { type: 'context', label: 'Mac 上下文' },
    }],
  }, { now: NOW });
  assert.equal(result.ok, true);
  assert.equal(result.entries.length, 1);
  assert.equal(result.entries[0].kind, 'context');
  assert.equal(result.entries[0].source.type, 'context');
  assert.equal(result.entries[0].source.label, 'Mac 上下文');
  assert.match(result.entries[0].body, /example\.com/);
});

test('maps mirror v2 device contexts into read-only cards', () => {
  const result = normalizeArchive({
    format: 'river.memory-mirror',
    version: 2,
    entries: [{
      id: 'diary-1', occurred_at: '2026-10-21T08:00:00', kind: 'journal',
      title: '早上', body: '去河边走走。',
    }],
    contexts: [{
      deviceID: 'device-a', deviceName: 'Mac', day: '2026-10-21',
      sections: [{
        kind: 'notes', title: '备忘录', summary: '2 条',
        items: [{ title: '窗边', detail: '去河边走走。' }, { title: '清单' }],
      }],
    }],
  }, { now: NOW });
  assert.equal(result.ok, true);
  assert.equal(result.version, 2);
  assert.equal(result.entries.length, 2);
  const context = result.entries.find((entry) => entry.kind === 'context');
  assert.ok(context);
  assert.equal(context.title, 'Mac 的一天');
  assert.equal(context.source.label, 'Mac 上下文');
  assert.match(context.body, /窗边/);
  assert.match(context.body, /去河边走走/);
});

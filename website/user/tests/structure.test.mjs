import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = dirname(fileURLToPath(new URL('../index.html', import.meta.url)));
const read = (path) => readFileSync(join(ROOT, path), 'utf8');
const html = read('index.html');
const css = read('assets/style.css');
const app = read('assets/app.js');
const sprite = read('assets/glyphs.svg');
const demo = read('assets/demo-data.js');

test('the console is a complete accessible document without inline scripts', () => {
  assert.match(html, /<html lang="zh-CN"/);
  assert.match(html, /<meta name="viewport"/);
  assert.match(html, /<meta name="referrer" content="no-referrer">/);
  assert.match(html, /class="skip-link"/);
  assert.match(html, /<main id="main"/);
  assert.equal((html.match(/<main\b/g) || []).length, 1);
  assert.equal((html.match(/<h1\b/g) || []).length, 0, 'page headings are rendered by the view controller');
  assert.match(html, /<nav class="mobile-tabs"/);
  assert.match(html, /aria-live="polite"/);
  assert.match(html, /<script type="module" src="\/assets\/app\.js\?v=20261020-webexport"><\/script>/);
  const inlineScripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)]
    .filter((match) => match[1].trim().length > 0);
  assert.deepEqual(inlineScripts, []);
});

test('all local asset references exist and no third-party runtime is loaded', () => {
  const references = [...html.matchAll(/(?:href|src)="(\/assets\/[^"]+)"/g)].map((match) => match[1].split(/[?#]/)[0]);
  assert.ok(references.length >= 2);
  for (const reference of new Set(references)) {
    const path = join(ROOT, reference.replace(/^\//, ''));
    assert.equal(existsSync(path), true, `${reference} should exist`);
    assert.ok(statSync(path).size > 0);
  }
  assert.doesNotMatch(html, /<script[^>]+https?:\/\//);
  assert.doesNotMatch(html, /<link[^>]+fonts\.googleapis/);
  assert.doesNotMatch(css, /@import\s+url\(/);
});

test('the visual system exposes three appearances and soft/inset materials', () => {
  assert.match(css, /\[data-theme="soft"\]/);
  assert.match(css, /\[data-theme="journal"\]/);
  assert.match(css, /\[data-theme="night"\]/);
  assert.match(css, /--raised:/);
  assert.match(css, /--inset:/);
  assert.match(css, /--radius: 24px/);
  assert.match(css, /prefers-reduced-motion: reduce/);
  assert.match(css, /focus-visible/);
  assert.match(css, /@media \(max-width: 900px\)/);
  assert.match(css, /@media \(max-width: 620px\)/);
});

test('River Glyph v2 is reused as a local sprite with theme-aware strokes', () => {
  const symbols = [...sprite.matchAll(/<symbol id="i-([a-z0-9-]+)"/g)].map((match) => match[1]);
  assert.ok(symbols.length >= 80);
  assert.equal(new Set(symbols).size, symbols.length);
  assert.ok(symbols.includes('river'));
  assert.ok(symbols.includes('understanding'));
  assert.match(sprite, /currentColor/);
  assert.match(sprite, /var\(--glyph-accent, currentColor\)/);
  assert.ok(app.includes('#i-'));
  assert.ok(html.includes('id="i-river"'));
  assert.ok(html.includes('id="i-understanding"'));
});

test('memory stays local unless the user explicitly enables an encrypted cloud mirror', () => {
  assert.match(app, /ARCHIVE_KEY = 'river\.console\.archive\.v1'/);
  assert.match(app, /sessionStorage\.setItem/);
  assert.doesNotMatch(app, /navigator\.geolocation/);
  assert.doesNotMatch(app, /\bfetch\s*\(/, 'network transport lives in account-core.js only');
  assert.doesNotMatch(app, /localStorage\.setItem\(ARCHIVE_KEY/);
  assert.match(read('assets/account-core.js'), /API_BASE = '\/v1'/);
  assert.match(app, /buildCloudEnvelope/);
  assert.match(app, /If-None-Match/);
  assert.match(app, /cloud-upload-consent/);
  const cloud = read('assets/cloud-core.js');
  assert.match(cloud, /AES-GCM/);
  assert.match(cloud, /PBKDF2-SHA-256/);
  assert.match(cloud, /CLOUD_MIN_PASSPHRASE/);
  assert.doesNotMatch(cloud, /\bfetch\s*\(/);
  assert.equal(existsSync(join(ROOT, 'assets/cloud-core.js')), true);
});

test('the demo is clearly synthetic and never reads the repository snapshot', () => {
  assert.match(demo, /demo: true/);
  assert.match(demo, /lin\.an@example\.com/);
  assert.doesNotMatch(demo, /data\/data\.json/);
  assert.doesNotMatch(demo, /data\/ios-user-data\.json/);
  assert.match(demo, /合成|invented/);
});

test('the shell exposes the seven intended spaces and account subsections', () => {
  for (const space of ['home', 'river', 'collections', 'places', 'understanding', 'ask', 'account']) {
    assert.match(html, new RegExp(`data-space="${space}"`), `missing navigation for ${space}`);
  }
  for (const label of ['记忆首页', '长河', '合集', '地点', '理解', '问 River', '账号与设置']) {
    assert.match(html, new RegExp(label));
  }
  for (const section of ['overview', 'devices', 'entitlements', 'security', 'activity', 'feedback', 'preferences', 'cloud']) {
    assert.match(app, new RegExp(`'${section}'`), `missing account section ${section}`);
  }
});

test('dialogs and form controls preserve keyboard and failure paths', () => {
  for (const id of ['command-dialog', 'memory-dialog', 'import-dialog', 'action-dialog', 'privacy-dialog', 'correction-dialog']) {
    assert.match(html, new RegExp(`id="${id}"`), `missing dialog ${id}`);
  }
  assert.match(html, /aria-label="关闭记忆详情"/);
  assert.match(html, /id="import-file"[^>]+accept="application\/json,\.json"/);
  assert.match(app, /Idempotency-Key/);
  assert.match(app, /内容已保留/);
  assert.match(app, /prefersReducedMotion/);
  assert.doesNotMatch(html, /composer-dialog/, 'the read-only console has no local note editor');
  assert.doesNotMatch(app, /data-action="compose"/);
});

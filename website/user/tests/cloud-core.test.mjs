import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  CLOUD_CIPHER_NAME, CLOUD_FORMAT, CLOUD_ITERATIONS, CLOUD_KDF_NAME, CloudError,
  base64ToBytes, buildCloudEnvelope, bytesToBase64, cloudArchiveSummary,
  decryptCloudEnvelope, validateCloudPassphrase,
} from '../assets/cloud-core.js';

const archive = {
  format: 'river.memory-mirror',
  version: 1,
  persona: { name: '林岸', line: '把日子留成河。' },
  entries: [
    { id: 'e1', date: '2026-10-19', title: '早上的水', body: '烧水的时候想起你。', place: '厨房', kind: 'journal', time: '07:20' },
    { id: 'e2', date: '2026-10-19', title: '沿河走', body: '风从桥下过来。', place: '河边', kind: 'journal', time: '18:10' },
    { id: 'e3', date: '2026-10-20', title: '一页书', body: '读到一句很慢的话。', place: '', kind: 'note', time: '22:00' },
  ],
  collections: [{ id: 'c1', title: '秋天' }],
  understandings: [{ id: 'u1', statement: '你常在水边停下来。' }],
};

const fast = { iterations: 100000, now: new Date('2026-10-20T00:00:00Z') };

test('cloud envelope round-trips the mirror without exposing plaintext', async () => {
  const envelope = await buildCloudEnvelope(archive, 'correct horse battery', fast);
  assert.equal(envelope.format, CLOUD_FORMAT);
  assert.equal(envelope.version, 1);
  assert.equal(envelope.kdf.name, CLOUD_KDF_NAME);
  assert.equal(envelope.kdf.iterations, 100000);
  assert.equal(envelope.cipher.name, CLOUD_CIPHER_NAME);
  assert.equal(envelope.summary.entries, 3);
  assert.equal(envelope.summary.days, 2);
  assert.equal(envelope.summary.places, 2);
  assert.equal(envelope.summary.collections, 1);
  assert.equal(envelope.summary.understandings, 1);
  assert.ok(envelope.ciphertext.length > 80);
  assert.ok(!envelope.ciphertext.includes('烧水'));
  assert.ok(!JSON.stringify(envelope).includes('烧水'));
  const decrypted = await decryptCloudEnvelope(envelope, 'correct horse battery');
  assert.equal(decrypted.entries.length, 3);
  assert.equal(decrypted.entries[0].body, '烧水的时候想起你。');
  assert.equal(decrypted.persona.name, '林岸');
  assert.deepEqual(decrypted.collections, archive.collections);
  assert.deepEqual(decrypted.understandings, archive.understandings);
});

test('wrong passphrase and tampering fail closed', async () => {
  const envelope = await buildCloudEnvelope(archive, 'correct horse battery', fast);
  await assert.rejects(() => decryptCloudEnvelope(envelope, 'wrong horse battery'), (error) => {
    assert.ok(error instanceof CloudError);
    assert.equal(error.code, 'bad_passphrase');
    return true;
  });
  const tampered = { ...envelope, ciphertext: bytesToBase64(new Uint8Array(64)) };
  await assert.rejects(() => decryptCloudEnvelope(tampered, 'correct horse battery'), { code: 'bad_passphrase' });
});

test('passphrase policy and base64 helpers are strict', async () => {
  assert.match(validateCloudPassphrase('short'), /至少/);
  assert.match(validateCloudPassphrase('            '), /空格/);
  assert.equal(validateCloudPassphrase('correct horse battery'), '');
  assert.equal(validateCloudPassphrase('四个汉字四个汉字四个汉字四'), '', '12 code points are enough');
  await assert.rejects(() => buildCloudEnvelope(archive, 'short'), { code: 'passphrase_policy' });
  const bytes = new Uint8Array([0, 1, 2, 127, 128, 255]);
  assert.deepEqual([...base64ToBytes(bytesToBase64(bytes))], [...bytes]);
  assert.deepEqual(cloudArchiveSummary({ entries: [] }), {
    entries: 0, days: 0, places: 0, collections: 0, understandings: 0, first: '', last: '', includes_health: false,
  });
  assert.equal(CLOUD_ITERATIONS, 600000);
});

test('cloud payload carries mirror v2 contexts', async () => {
  const withContext = {
    ...archive,
    version: 2,
    contexts: [{
      deviceID: 'device-a', deviceName: 'Mac', day: '2026-10-20',
      sections: [{ kind: 'notes', title: '备忘录', summary: '1 条',
        items: [{ title: '窗边', detail: '去河边走走。' }] }],
    }],
  };
  const envelope = await buildCloudEnvelope(withContext, 'correct horse battery', fast);
  const decrypted = await decryptCloudEnvelope(envelope, 'correct horse battery');
  assert.equal(decrypted.version, 2);
  assert.equal(decrypted.contexts.length, 1);
  assert.equal(decrypted.contexts[0].deviceName, 'Mac');
  assert.equal(decrypted.contexts[0].sections[0].items[0].title, '窗边');
});


test('health sections are excluded unless this upload explicitly opts in', async () => {
  const withHealth = {
    ...archive,
    version: 2,
    contexts: [
      {
        deviceID: 'device-iphone', deviceName: 'iPhone', day: '2026-10-21',
        sections: [
          { kind: 'notes', title: '备忘录', summary: '1 条', items: [{ title: '买水' }] },
          { kind: 'health', title: '睡眠', summary: '7.2 小时' },
          { kind: 'workout', title: '活动', summary: '8,412 步' },
        ],
      },
      {
        deviceID: 'device-iphone', deviceName: 'iPhone', day: '2026-10-22',
        sections: [{ kind: 'stateOfMind', title: '心情', summary: '平静' }],
      },
    ],
  };
  const defaultEnvelope = await buildCloudEnvelope(withHealth, 'correct horse battery', fast);
  assert.equal(defaultEnvelope.summary.includes_health, false);
  assert.ok(!JSON.stringify(defaultEnvelope).includes('7.2 小时'));
  const defaultPayload = await decryptCloudEnvelope(defaultEnvelope, 'correct horse battery');
  assert.equal(defaultPayload.contexts.length, 1, 'health-only context should be dropped');
  assert.deepEqual(defaultPayload.contexts[0].sections.map((section) => section.kind), ['notes']);

  const consented = await buildCloudEnvelope(withHealth, 'correct horse battery', { ...fast, includeHealth: true });
  assert.equal(consented.summary.includes_health, true);
  const consentedPayload = await decryptCloudEnvelope(consented, 'correct horse battery');
  assert.equal(consentedPayload.contexts.length, 2);
  assert.deepEqual(consentedPayload.contexts[0].sections.map((section) => section.kind), ['notes', 'health', 'workout']);
});


test('decrypts an envelope produced by the native Swift core', async () => {
  const fixture = JSON.parse(readFileSync(new URL(
    '../../../Packages/RiverDiaryCore/Tests/RiverDiaryCoreTests/Fixtures/swift-cloud-envelope.json',
    import.meta.url,
  )));
  const payload = await decryptCloudEnvelope(fixture, 'correct horse battery');
  assert.equal(payload.format, 'river.memory-mirror');
  assert.equal(payload.entries.length, 1);
  assert.equal(payload.entries[0].title, 'Mac 上的句子');
  assert.equal(payload.entries[0].body, '从 Swift 端加密的一句话。');
  await assert.rejects(() => decryptCloudEnvelope(fixture, 'wrong horse battery'), { code: 'bad_passphrase' });
});

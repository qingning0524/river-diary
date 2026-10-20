import test from 'node:test';
import assert from 'node:assert/strict';
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
    entries: 0, days: 0, places: 0, collections: 0, understandings: 0, first: '', last: '',
  });
  assert.equal(CLOUD_ITERATIONS, 600000);
});

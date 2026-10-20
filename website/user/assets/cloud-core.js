/* End-to-end encrypted cloud mirror primitives.
 *
 * Plaintext memory never leaves this module. The account service receives only
 * an AES-GCM envelope plus public KDF parameters; the passphrase is never sent
 * or stored. Losing the passphrase makes the cloud copy unrecoverable.
 */

export const CLOUD_FORMAT = 'river.cloud-mirror';
export const CLOUD_VERSION = 1;
export const CLOUD_KDF_NAME = 'PBKDF2-SHA-256';
export const CLOUD_CIPHER_NAME = 'AES-GCM-256';
export const CLOUD_ITERATIONS = 600000;
export const CLOUD_MIN_ITERATIONS = 100000;
export const CLOUD_MAX_ITERATIONS = 2000000;
export const CLOUD_MAX_CIPHERTEXT_BYTES = 8 * 1024 * 1024;
export const CLOUD_MIN_PASSPHRASE = 12;
export const CLOUD_MAX_PASSPHRASE = 128;

const CONTEXT = new TextEncoder().encode('river.cloud-mirror:v1');
const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class CloudError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'CloudError';
    this.code = code;
  }
}

export function validateCloudPassphrase(value) {
  const length = Array.from(String(value ?? '')).length;
  if (length < CLOUD_MIN_PASSPHRASE) return `云端口令至少 ${CLOUD_MIN_PASSPHRASE} 个字符。`;
  if (length > CLOUD_MAX_PASSPHRASE) return `云端口令不能超过 ${CLOUD_MAX_PASSPHRASE} 个字符。`;
  if (!String(value ?? '').trim()) return '云端口令不能全是空格。';
  return '';
}

export function bytesToBase64(bytes) {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function base64ToBytes(value) {
  const binary = atob(String(value ?? ''));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function cloudArchiveSummary(archive) {
  const entries = Array.isArray(archive?.entries) ? archive.entries : [];
  const days = new Set();
  const places = new Set();
  for (const entry of entries) {
    const date = String(entry?.date ?? '').slice(0, 10);
    if (/^\d{4}-\d{2}-\d{2}$/.test(date)) days.add(date);
    const place = String(entry?.place ?? '').trim();
    if (place) places.add(place);
  }
  const dates = [...days].sort();
  return {
    entries: entries.length,
    days: days.size,
    places: places.size,
    collections: Array.isArray(archive?.collections) ? archive.collections.length : 0,
    understandings: Array.isArray(archive?.understandings) ? archive.understandings.length : 0,
    first: dates[0] || '',
    last: dates.at(-1) || '',
  };
}

function cloudPayload(archive, now) {
  return {
    format: 'river.memory-mirror',
    version: 1,
    exported_at: now.toISOString(),
    persona: archive?.persona ?? null,
    entries: Array.isArray(archive?.entries) ? archive.entries : [],
    collections: Array.isArray(archive?.collections) ? archive.collections : [],
    understandings: Array.isArray(archive?.understandings) ? archive.understandings : [],
  };
}

async function deriveCloudKey(passphrase, salt, iterations, subtle) {
  const material = await subtle.importKey('raw', encoder.encode(String(passphrase).normalize('NFC')), 'PBKDF2', false, ['deriveKey']);
  return subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

function requireSubtle(subtle) {
  if (!subtle) throw new CloudError('crypto_unavailable', '这个浏览器不支持 Web Crypto，无法加密云副本。');
  return subtle;
}

export async function buildCloudEnvelope(archive, passphrase, options = {}) {
  const problem = validateCloudPassphrase(passphrase);
  if (problem) throw new CloudError('passphrase_policy', problem);
  const subtle = requireSubtle(options.subtle ?? globalThis.crypto?.subtle);
  const cryptoRef = options.cryptoRef ?? globalThis.crypto;
  if (!cryptoRef?.getRandomValues) throw new CloudError('crypto_unavailable', '这个浏览器无法生成安全随机数。');
  const iterations = options.iterations ?? CLOUD_ITERATIONS;
  if (!Number.isInteger(iterations) || iterations < CLOUD_MIN_ITERATIONS || iterations > CLOUD_MAX_ITERATIONS) {
    throw new CloudError('invalid_options', '加密参数无效。');
  }
  const now = options.now instanceof Date ? options.now : new Date(options.now ?? Date.now());
  const salt = cryptoRef.getRandomValues(new Uint8Array(16));
  const iv = cryptoRef.getRandomValues(new Uint8Array(12));
  const plaintext = encoder.encode(JSON.stringify(cloudPayload(archive, now)));
  const key = await deriveCloudKey(passphrase, salt, iterations, subtle);
  const encrypted = await subtle.encrypt({ name: 'AES-GCM', iv, additionalData: CONTEXT }, key, plaintext);
  const ciphertext = new Uint8Array(encrypted);
  if (ciphertext.length > CLOUD_MAX_CIPHERTEXT_BYTES) {
    throw new CloudError('too_large', '加密后的云副本超过 8 MB，请先精简这份副本。');
  }
  return {
    format: CLOUD_FORMAT,
    version: CLOUD_VERSION,
    kdf: { name: CLOUD_KDF_NAME, iterations, salt: bytesToBase64(salt) },
    cipher: { name: CLOUD_CIPHER_NAME, iv: bytesToBase64(iv) },
    ciphertext: bytesToBase64(ciphertext),
    client_updated_at: now.toISOString(),
    summary: cloudArchiveSummary(archive),
  };
}

export async function decryptCloudEnvelope(envelope, passphrase, options = {}) {
  const problem = validateCloudPassphrase(passphrase);
  if (problem) throw new CloudError('passphrase_policy', problem);
  if (!envelope || envelope.format !== CLOUD_FORMAT || envelope.version !== CLOUD_VERSION ||
      envelope.kdf?.name !== CLOUD_KDF_NAME || envelope.cipher?.name !== CLOUD_CIPHER_NAME) {
    throw new CloudError('bad_payload', '这不是河流日记的云副本。');
  }
  const iterations = Number(envelope.kdf.iterations);
  if (!Number.isInteger(iterations) || iterations < CLOUD_MIN_ITERATIONS || iterations > CLOUD_MAX_ITERATIONS) {
    throw new CloudError('bad_payload', '云副本的加密参数无法识别。');
  }
  let salt;
  let iv;
  let ciphertext;
  try {
    salt = base64ToBytes(envelope.kdf.salt);
    iv = base64ToBytes(envelope.cipher.iv);
    ciphertext = base64ToBytes(envelope.ciphertext);
  } catch {
    throw new CloudError('bad_payload', '云副本的数据不完整。');
  }
  if (salt.length !== 16 || iv.length !== 12 || !ciphertext.length || ciphertext.length > CLOUD_MAX_CIPHERTEXT_BYTES) {
    throw new CloudError('bad_payload', '云副本的数据不完整。');
  }
  const subtle = requireSubtle(options.subtle ?? globalThis.crypto?.subtle);
  try {
    const key = await deriveCloudKey(passphrase, salt, iterations, subtle);
    const decrypted = await subtle.decrypt({ name: 'AES-GCM', iv, additionalData: CONTEXT }, key, ciphertext);
    const payload = JSON.parse(decoder.decode(decrypted));
    if (payload?.format !== 'river.memory-mirror' || payload.version !== 1) {
      throw new CloudError('bad_payload', '云副本的内容格式无法识别。');
    }
    return payload;
  } catch (error) {
    if (error instanceof CloudError) throw error;
    throw new CloudError('bad_passphrase', '口令不正确，或云副本已损坏。');
  }
}

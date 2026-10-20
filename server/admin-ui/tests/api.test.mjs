import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'

const source = ts.transpileModule(readFileSync(new URL('../src/api.ts', import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText
const { api, APIError } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
globalThis.document = { cookie: '__Host-flowriver-admin-csrf=csrf-fixture' }
globalThis.window = { setTimeout, clearTimeout }

test('API sends CSRF for writes and rejects a successful HTML gateway response', async () => {
 const previous = globalThis.fetch
 try {
  globalThis.fetch = async (url, options) => {
   assert.equal(url, '/admin-api/v1/test')
   assert.equal(options.headers.get('X-CSRF-Token'), 'csrf-fixture')
   assert.equal(options.headers.get('Idempotency-Key'), 'same-request')
   assert.equal(options.credentials, 'same-origin')
   return new Response('<html>maintenance</html>', { status: 200, headers: { 'Content-Type': 'text/html' } })
  }
  await assert.rejects(api.post('/test', { value: 'fixture' }, 'same-request'), (error) => error instanceof APIError && error.code === 'invalid_response')
 } finally { globalThis.fetch = previous }
})

test('Hung API request times out and a caller cancellation remains a cancellation', async () => {
 const previous = globalThis.fetch
 const originalTimer = window.setTimeout
 try {
  window.setTimeout = (fn, delay) => setTimeout(fn, delay === 30_000 ? 10 : delay)
  globalThis.fetch = (_url, options) => new Promise((_resolve, reject) => {
   if (options.signal.aborted) reject(new DOMException('cancelled', 'AbortError'))
   else options.signal.addEventListener('abort', () => reject(new DOMException('cancelled', 'AbortError')), { once: true })
  })
  await assert.rejects(api.get('/test'), { name: 'TimeoutError' })
  const controller = new AbortController()
  const request = api.get('/test', controller.signal)
  controller.abort()
  await assert.rejects(request, { name: 'AbortError' })
 } finally { globalThis.fetch = previous; window.setTimeout = originalTimer }
})

test('Installer upload reports progress, preserves CSRF and supports cancellation', async () => {
 const previous = globalThis.XMLHttpRequest
 let instance
 class TestXHR {
  upload = {}; headers = {}; status = 201; responseText = '{"id":"fixture"}'
  constructor() { instance = this }
  open(method, path) { this.method = method; this.path = path }
  setRequestHeader(key, value) { this.headers[key] = value }
  getResponseHeader() { return 'fixture-request' }
  send(body) { this.body = body }
  abort() { this.onabort?.() }
 }
 try {
  globalThis.XMLHttpRequest = TestXHR
  const progress = []
  const form = new FormData()
  const request = api.postForm('/downloads', form, { onProgress: (value) => progress.push(value) })
  assert.equal(instance.headers['X-CSRF-Token'], 'csrf-fixture')
  assert.equal(instance.timeout, 600_000)
  instance.upload.onprogress({ lengthComputable: true, loaded: 5, total: 10 })
  instance.onload()
  assert.deepEqual(await request, { id: 'fixture' })
  assert.deepEqual(progress, [50])
  const controller = new AbortController()
  const cancelled = api.postForm('/downloads', form, { signal: controller.signal })
  controller.abort()
  await assert.rejects(cancelled, { name: 'AbortError' })
 } finally { globalThis.XMLHttpRequest = previous }
})

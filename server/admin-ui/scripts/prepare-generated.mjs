import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const output = fileURLToPath(new URL('../../internal/adminui/generated/', import.meta.url))
rmSync(output, { recursive: true, force: true })
mkdirSync(output, { recursive: true })
writeFileSync(new URL('../../internal/adminui/generated/.gitkeep', import.meta.url), '\n')

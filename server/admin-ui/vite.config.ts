import { fileURLToPath } from 'node:url'
import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vite'

const outputDirectory = fileURLToPath(new URL('../internal/adminui/generated/', import.meta.url))

export default defineConfig({
  plugins: [vue()],
  base: '/',
  server: {
    port: 5173,
    proxy: {
      '/admin-api': {
        target: 'http://127.0.0.1:8081',
        changeOrigin: true,
        headers: { origin: 'http://127.0.0.1:5173' },
      },
    },
  },
  build: {
    outDir: outputDirectory,
    emptyOutDir: false,
    sourcemap: false,
    assetsDir: 'assets',
  },
})

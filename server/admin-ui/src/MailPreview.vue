<script setup lang="ts">
import { ref, watch } from 'vue'
import type { FormattedMail } from './mail'
const props = defineProps<{ formatted?: Partial<FormattedMail> | null; legacyBody?: string; legacy?: boolean }>()
const showText = ref(false)
watch(() => props.formatted, () => { showText.value = false })
</script>
<template>
  <div class="mail-preview-controls" v-if="!legacy && formatted?.view"><span>品牌格式 · HTML / 纯文本双版本</span><button class="text-button" type="button" @click="showText = !showText">{{ showText ? '返回品牌预览' : '查看纯文本版本' }}</button></div>
  <pre v-if="legacy || showText" class="mail-plain-preview">{{ legacy ? legacyBody : formatted?.text }}</pre>
  <article v-else-if="formatted?.view" class="mail-preview-document" aria-label="品牌邮件预览">
    <header class="mail-brand-header"><span class="mail-brand-icon">F</span><div><strong>河流日记</strong><small>RIVER DIARY</small></div><span class="mail-brand-name">FlowRiver</span></header>
    <section class="mail-preview-content">
      <p class="mail-kind">{{ formatted.view.label }}</p><h2>{{ formatted.view.title }}</h2><p class="mail-reference">参考编号 {{ formatted.view.reference }}</p>
      <p class="mail-greeting">{{ formatted.view.greeting }}</p>
      <template v-for="(block, index) in formatted.view.blocks" :key="index"><h3 v-if="block.kind === 'heading'">{{ block.text }}</h3><ul v-else-if="block.kind === 'list'"><li v-for="(item, n) in block.items" :key="n">{{ item }}</li></ul><p v-else class="mail-paragraph">{{ block.text }}</p></template>
      <aside v-if="formatted.view.original_subject || formatted.view.original_body" class="mail-original"><strong>原始主题</strong><p>{{ formatted.view.original_subject }}</p><small>{{ formatted.view.original_date }}</small><p v-if="formatted.view.original_body" class="mail-paragraph">{{ formatted.view.original_body }}</p></aside>
      <p class="mail-signature"><strong>{{ formatted.view.signature }}</strong><br><small>{{ formatted.view.date }}</small></p>
    </section>
    <footer class="mail-brand-footer"><p>直接回复此邮件即可联系我们。</p><span>flowriver.xyz · {{ formatted.view.support_email }}</span><p class="mail-footer-caption">FlowRiver · 河流日记<br>记录是起点，理解是下一步。</p></footer>
  </article>
</template>
<style scoped>
.mail-preview-controls{display:flex;justify-content:space-between;gap:12px;align-items:center;margin:16px 0;color:var(--muted);font-size:12px;flex-wrap:wrap}
.mail-preview-document{--mail-ink:#263b49;--mail-muted:#8a98a1;--mail-accent:#48677a;--mail-line:#e8ecee;--mail-surface:#fff;--mail-soft:#f8fafb;background:var(--mail-surface);color:var(--mail-ink);border:1px solid var(--mail-line);border-radius:20px;overflow:hidden;max-width:620px;margin:auto;line-height:1.85;box-shadow:0 8px 30px rgb(20 40 50 / 6%);text-align:left}
.mail-brand-header{display:flex;align-items:center;gap:11px;padding:28px 36px;border-bottom:1px solid var(--mail-line)}.mail-brand-icon{display:grid;place-items:center;background:var(--mail-accent);color:var(--mail-surface);width:36px;height:36px;border-radius:11px;font-size:18px;font-weight:700}.mail-brand-header strong{display:block;font-size:17px}.mail-brand-header small{display:block;font-size:10px;letter-spacing:2px;line-height:1.5;color:var(--mail-muted)}.mail-brand-name{margin-left:auto;font-size:11px;color:var(--mail-muted)}
.mail-preview-content{padding:30px 36px}.mail-kind{font-size:10px;letter-spacing:1.8px;color:var(--mail-accent);margin:0}.mail-preview-content h2{font-size:28px;line-height:1.35;color:var(--mail-ink);margin:12px 0;letter-spacing:-.7px}.mail-reference{font-size:11px;color:var(--mail-muted);margin:0 0 28px}.mail-greeting{margin:0 0 20px;font-size:15px}.mail-paragraph{white-space:pre-line;font-size:15px;overflow-wrap:anywhere;margin:0 0 18px;color:var(--mail-ink)}.mail-preview-content h3{font-size:17px;margin:24px 0 10px}.mail-preview-content ul{padding-left:22px;margin:12px 0 20px;font-size:15px}.mail-preview-content li{margin:6px 0}.mail-original{padding:18px 20px;background:var(--mail-soft);border-left:3px solid var(--mail-line);border-radius:0 10px 10px 0;font-size:12px;color:var(--mail-muted);margin-top:24px}.mail-original p{margin:3px 0}.mail-original .mail-paragraph{font-size:12px;color:var(--mail-muted);margin-top:10px}.mail-signature{margin:28px 0 0;font-size:13px;color:var(--mail-accent)}.mail-signature small{font-size:11px;color:var(--mail-muted)}
.mail-brand-footer{padding:22px 36px;background:var(--mail-soft);border-top:1px solid var(--mail-line);font-size:11px;color:var(--mail-muted)}.mail-brand-footer p{margin:0}.mail-brand-footer span{color:var(--mail-accent)}.mail-footer-caption{font-size:10px;margin-top:13px!important}.mail-plain-preview{white-space:pre-wrap;overflow-wrap:anywhere;border:1px solid var(--line);border-radius:12px;padding:20px;background:var(--surface-soft);color:var(--text);font:14px/1.8 inherit;max-height:65vh;overflow:auto}
@media(max-width:600px){.mail-brand-header,.mail-preview-content,.mail-brand-footer{padding:24px}.mail-preview-content h2{font-size:25px}}
</style>

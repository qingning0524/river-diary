export type MailTemplateID = 'support_reply' | 'product_update' | 'account_notice'
export interface MailBodyBlock { kind: 'paragraph' | 'heading' | 'list'; text?: string; lines?: string[]; items?: string[] }
export interface MailView {
  template: MailTemplateID; label: string; title: string; subject: string; greeting: string;
  blocks: MailBodyBlock[]; reference: string; date: string; signature: string; support_email: string;
  original_subject?: string; original_body?: string; original_date?: string;
}
export interface FormattedMail { view: MailView; html: string; text: string }
export interface MailPreviewResponse { to: string; subject: string; formatted: FormattedMail; threaded: boolean }
export interface OutboundDetail {
  id: string; recipient: string; subject: string; body: string; status: string; legacy: boolean;
  formatted: Partial<FormattedMail>; created_at: string; sent_at: string | null; created_by: string;
}
export const mailTemplates: { id: MailTemplateID; label: string }[] = [
  { id: 'support_reply', label: '支持回复' }, { id: 'product_update', label: '产品通知' }, { id: 'account_notice', label: '账号通知' },
]
export const mailSnippets = [
  { id: 'information', label: '请补充信息', body: '感谢您向我们反馈。为更准确地确认问题，请补充以下信息：\n\n- 设备型号和系统版本\n- 当前河流日记版本\n- 出现问题的操作步骤或截图\n\n收到补充信息后，我们会继续核查。您可以直接回复这封邮件。' },
  { id: 'investigating', label: '正在核查', body: '感谢您的反馈。我们正在核查相关问题。\n\n如有进一步的排查结果，我们会通过本邮件会话同步给您。您也可以直接回复这封邮件，补充相关信息。' },
  { id: 'guidance', label: '进一步排查', body: '感谢您的来信。为方便继续排查，您可以先尝试以下操作：\n\n- 记录当前版本和设备信息\n- 重新打开应用，观察问题是否仍会出现\n- 回复本邮件，补充具体的复现步骤\n\n如果问题持续存在，我们会继续核查。' },
]

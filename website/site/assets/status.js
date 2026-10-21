(() => {
  const accountText = document.getElementById('account-status');
  const accountDot = document.getElementById('account-dot');
  const downloadText = document.getElementById('download-status');
  const downloadDot = document.getElementById('download-dot');
  const readyText = document.getElementById('ready-status');
  const readyDot = document.getElementById('ready-dot');
  const checkedAt = document.getElementById('checked-at');
  const list = document.querySelector('.status-list');

  const set = (text, dot, message, state) => {
    if (text) text.textContent = message;
    if (dot) dot.dataset.state = state;
  };

  const fetchJSON = (url) => fetch(url, {
    cache: 'no-store',
    headers: { Accept: 'application/json' },
  }).then((response) => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  });

  const age = (seconds) => {
    if (!Number.isFinite(seconds) || seconds < 60) return `${Math.max(0, Math.round(seconds || 0))} 秒`;
    return `${Math.round(seconds / 60)} 分钟`;
  };

  const renderReady = (data) => {
    if (!data || typeof data.mail_failures_5m !== 'number' || typeof data.outbox_unfinished !== 'number') {
      set(readyText, readyDot, '健康检查未提供邮件队列指标', 'warn');
      return;
    }
    if (data.status === 'ready') {
      set(readyText, readyDot, '邮件队列正常', 'ok');
      return;
    }
    if (data.status === 'degraded') {
      const details = [];
      if (data.mail_failures_5m > 0) details.push(`5 分钟失败 ${data.mail_failures_5m} 次`);
      if (data.outbox_unfinished > 0) details.push(`最老未完成 ${age(data.outbox_oldest_unfinished_seconds)}`);
      set(readyText, readyDot, details.length ? `已降级：${details.join('，')}` : '已降级', 'warn');
      return;
    }
    set(readyText, readyDot, '健康检查返回未知状态', 'warn');
  };

  Promise.allSettled([
    fetchJSON('/v1/site-status'),
    fetchJSON('/health/ready'),
  ]).then(([siteResult, readyResult]) => {
    let checked = null;
    if (siteResult.status === 'fulfilled') {
      const data = siteResult.value || {};
      const mac = data.downloads ? data.downloads.macos : null;
      set(accountText, accountDot, '可响应', 'ok');
      if (mac && mac.version) {
        set(downloadText, downloadDot, `macOS ${mac.version} 可下载`, 'ok');
      } else {
        set(downloadText, downloadDot, '当前没有已开放的下载', 'ok');
      }
      if (data.updated_at) {
        const when = new Date(data.updated_at);
        if (!Number.isNaN(when.getTime())) checked = when;
      }
    } else {
      set(accountText, accountDot, '暂时无法获取（可能网络或服务异常）', 'error');
      set(downloadText, downloadDot, '随账号 API 一起检查', 'error');
    }

    if (readyResult.status === 'fulfilled') {
      renderReady(readyResult.value);
      const when = readyResult.value && readyResult.value.checked_at ? new Date(readyResult.value.checked_at) : null;
      if (when && !Number.isNaN(when.getTime()) && (!checked || when > checked)) checked = when;
    } else {
      set(readyText, readyDot, '暂时无法获取（可能网络或服务异常）', 'error');
    }

    if (checkedAt) {
      checkedAt.textContent = checked
        ? `最近检查：${checked.toLocaleString('zh-CN', { hour12: false })}`
        : '最近检查：获取失败';
    }
  }).finally(() => {
    if (list) list.setAttribute('aria-busy', 'false');
  });
})();

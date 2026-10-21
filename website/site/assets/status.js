(() => {
  const accountText = document.getElementById('account-status');
  const accountDot = document.getElementById('account-dot');
  const downloadText = document.getElementById('download-status');
  const downloadDot = document.getElementById('download-dot');
  const checkedAt = document.getElementById('checked-at');
  const list = document.querySelector('.status-list');

  const set = (text, dot, message, state) => {
    if (text) text.textContent = message;
    if (dot) dot.dataset.state = state;
  };

  fetch('/v1/site-status', { cache: 'no-store', headers: { Accept: 'application/json' } })
    .then((response) => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    })
    .then((data) => {
      const mac = data && data.downloads ? data.downloads.macos : null;
      set(accountText, accountDot, '可响应', 'ok');
      if (mac && mac.version) {
        set(downloadText, downloadDot, `macOS ${mac.version} 可下载`, 'ok');
      } else {
        set(downloadText, downloadDot, '当前没有已开放的下载', 'ok');
      }
      const when = data && data.updated_at ? new Date(data.updated_at) : new Date();
      if (checkedAt && !Number.isNaN(when.getTime())) {
        checkedAt.textContent = `最近检查：${when.toLocaleString('zh-CN', { hour12: false })}`;
      }
    })
    .catch(() => {
      set(accountText, accountDot, '暂时无法获取（可能网络或服务异常）', 'error');
      set(downloadText, downloadDot, '随账号 API 一起检查', 'error');
      if (checkedAt) checkedAt.textContent = '最近检查：获取失败';
    })
    .finally(() => {
      if (list) list.setAttribute('aria-busy', 'false');
    });
})();

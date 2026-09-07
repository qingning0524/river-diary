'use strict';

function healthValue(entry, key) {
  var health = entry && entry.ios_health;
  var value = health ? health[key] : null;
  return value == null || value === '' || isNaN(Number(value)) ? null : Number(value);
}

function healthAverage(entries, key) {
  var values = entries.map(function(entry) { return healthValue(entry, key); }).filter(function(v) { return v != null; });
  return values.length ? values.reduce(function(a, b) { return a + b; }, 0) / values.length : null;
}

function healthDelta(current, previous) {
  if (current == null || previous == null || previous === 0) return null;
  return Math.round((current - previous) / previous * 100);
}

function periodSummary(days) {
  var rated = days.filter(function(entry) { return entry.score != null; });
  var score = rated.length ? rated.reduce(function(a, b) { return a + b.score; }, 0) / rated.length : null;
  return {
    days: days.length,
    score: score == null ? null : Math.round(score * 10) / 10,
    screen: days.reduce(function(a, b) { return a + screenTotal(b); }, 0),
    steps: days.reduce(function(a, b) { return a + (healthValue(b, 'steps') || 0); }, 0),
    sleep: healthAverage(days, 'sleep_hours')
  };
}

function renderPeriodCompare() {
  var el = document.getElementById('periodCompare');
  if (!el) return;
  var current = periodSummary(ENTRIES.slice(-7));
  var previous = periodSummary(ENTRIES.slice(-14, -7));
  var rows = [
    { label: '近 7 天心情', value: current.score == null ? '—' : current.score + '/100', delta: healthDelta(current.score, previous.score) },
    { label: '近 7 天屏幕', value: fmtMin(current.screen), delta: healthDelta(current.screen, previous.screen), inverse: true },
    { label: '近 7 天步数', value: current.steps ? current.steps.toLocaleString() : '—', delta: healthDelta(current.steps, previous.steps) },
    { label: '近 7 天睡眠', value: current.sleep == null ? '—' : current.sleep.toFixed(1) + 'h', delta: healthDelta(current.sleep, previous.sleep) }
  ];
  el.innerHTML = rows.map(function(row) {
    var positive = row.inverse ? row.delta < 0 : row.delta > 0;
    var negative = row.inverse ? row.delta > 0 : row.delta < 0;
    var delta = row.delta == null ? '' : (positive ? '<em class="up">▲ ' + Math.abs(row.delta) + '%</em>' : negative ? '<em class="down">▼ ' + Math.abs(row.delta) + '%</em>' : '<em>—</em>');
    return '<div class="pcard"><span>' + row.label + '</span><b class="num">' + row.value + '</b>' + delta + '</div>';
  }).join('');
}

function renderHealth() {
  var chips = document.getElementById('healthChips');
  var scroll = document.getElementById('healthScroll');
  var stats = document.getElementById('healthStats');
  var note = document.getElementById('healthNote');
  if (!chips || !scroll) return;
  var tt = document.getElementById('healthTooltip');
  var withHealth = ENTRIES.filter(function(entry) { return entry.ios_health; });
  if (!withHealth.length) {
    chips.innerHTML = '';
    scroll.innerHTML = '<div class="empty" style="margin:24px 0">还没有健康数据；iOS 端接入 HealthKit 后会自动汇入这里。</div>';
    if (stats) stats.innerHTML = '';
    if (note) note.textContent = '';
    return;
  }

  var sleep = healthAverage(ENTRIES, 'sleep_hours');
  var steps = healthAverage(ENTRIES, 'steps');
  var energy = healthAverage(ENTRIES, 'active_energy_kcal');
  chips.innerHTML = [
    { label: '平均睡眠', value: sleep == null ? '—' : sleep.toFixed(1) + 'h', pct: sleep == null ? 0 : Math.min(100, sleep / 9 * 100), col: '#2F6FDE' },
    { label: '平均步数', value: steps == null ? '—' : Math.round(steps).toLocaleString(), pct: steps == null ? 0 : Math.min(100, steps / 10000 * 100), col: '#3E9B6C' },
    { label: '平均活动能量', value: energy == null ? '—' : Math.round(energy) + 'kcal', pct: energy == null ? 0 : Math.min(100, energy / 500 * 100), col: '#F5A04C' }
  ].map(function(item) {
    return '<div class="mo"><div class="mo-label">' + item.label + '</div><div class="mo-val num">' + item.value + '</div><div class="mo-bar"><div class="mo-fill" style="width:' + item.pct + '%;background:' + item.col + '"></div></div></div>';
  }).join('');

  var H = 250, PADL = 38, PADR = 14, PADT = 16, PADB = 26;
  var chartEntries = withHealth.slice();
  var W = Math.max(chartEntries.length * 46 + 80, 640);
  var iw = W - PADL - PADR, ih = H - PADT - PADB;
  var step = chartEntries.length > 1 ? iw / (chartEntries.length - 1) : iw;
  var maxSteps = Math.max.apply(null, chartEntries.map(function(e) { return healthValue(e, 'steps') || 0; })) || 1;
  var maxSleep = 10;
  var g = '';
  for (var i = 0; i <= 4; i++) {
    var y = PADT + ih - (i / 4) * ih;
    g += '<line x1="' + PADL + '" y1="' + y + '" x2="' + (W - PADR) + '" y2="' + y + '" style="stroke:var(--line)"/>' +
      '<text x="' + (PADL - 8) + '" y="' + (y + 3.5) + '" font-size="9.5" text-anchor="end" style="fill:var(--ink-3)">' + Math.round(maxSteps * i / 4) + '</text>';
  }
  var sleepPts = [];
  chartEntries.forEach(function(entry, index) {
    var x = PADL + index * step;
    var v = healthValue(entry, 'steps') || 0;
    var h = Math.max(1, v / maxSteps * ih);
    var col = entry.date === state.date ? 'currentColor' : '#3E9B6C';
    g += '<rect x="' + (x - 8) + '" y="' + (PADT + ih - h) + '" width="16" height="' + h + '" rx="3" fill="' + col + '" opacity="' + (entry.date === state.date ? 1 : .72) + '" data-d="' + entry.date + '"/>';
    g += '<text x="' + x + '" y="' + (H - 8) + '" font-size="9.5" text-anchor="middle" style="fill:' + (entry.date === state.date ? 'currentColor' : 'var(--ink-3)') + '">' + fmtD(entry.date) + '</text>';
    var sleepValue = healthValue(entry, 'sleep_hours');
    if (sleepValue != null) sleepPts.push({ x: x, y: PADT + ih - Math.min(sleepValue, maxSleep) / maxSleep * ih, v: sleepValue });
  });
  if (sleepPts.length > 1) {
    g += '<path d="' + smoothPath(sleepPts) + '" fill="none" stroke="#2F6FDE" stroke-width="2.2" stroke-linecap="round" stroke-dasharray="4 4"/>';
    g += '<text x="' + (PADL + 6) + '" y="' + (PADT + 12) + '" font-size="10" style="fill:#2F6FDE">蓝虚线：睡眠小时</text>';
  }
  scroll.innerHTML = '<svg width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="步数柱状图和睡眠趋势">' + g + '</svg>';
  scroll.appendChild(tt);

  if (tt) {
    scroll.querySelectorAll('[data-d]').forEach(function(node) {
      node.addEventListener('mouseenter', function() {
        var entry = BYDATE[node.getAttribute('data-d')];
        if (!entry) return;
        var sleepValue = healthValue(entry, 'sleep_hours');
        var stepsValue = healthValue(entry, 'steps');
        tt.innerHTML = '<b>' + fmtFull(entry.date) + ' ' + fmtW(entry.date) + '</b>' +
          '<div class="r"><span>步数</span><i>' + (stepsValue == null ? '—' : stepsValue.toLocaleString()) + '</i></div>' +
          '<div class="r"><span>睡眠</span><i>' + (sleepValue == null ? '—' : sleepValue + 'h') + '</i></div>' +
          '<div class="r"><span>心情</span><i>' + (entry.score == null ? '待评分' : entry.score) + '</i></div>';
        tt.style.opacity = 1;
        var cx = parseFloat(node.getAttribute('x')) + parseFloat(node.getAttribute('width')) / 2;
        tt.style.left = Math.min(Math.max(cx, 10), Math.max(10, scroll.scrollWidth - tt.offsetWidth - 10)) + 'px';
        tt.style.top = '8px';
      });
      node.addEventListener('mouseleave', function() { tt.style.opacity = 0; });
      node.addEventListener('click', function() { setDate(node.getAttribute('data-d'), false); });
    });
  }
  if (stats) {
    stats.innerHTML = '<div class="cs"><div class="cs-num num">' + withHealth.length + '</div><div class="cs-label">健康记录天</div></div>' +
      '<div class="cs"><div class="cs-num num">' + (sleep == null ? '—' : sleep.toFixed(1) + 'h') + '</div><div class="cs-label">平均睡眠</div></div>' +
      '<div class="cs"><div class="cs-num num">' + (steps == null ? '—' : Math.round(steps).toLocaleString()) + '</div><div class="cs-label">平均步数</div></div>';
  }
  if (note) note.textContent = '绿柱=步数' + (sleep == null ? ' · 睡眠暂无数据' : ' · 蓝虚线=睡眠') + ' · 点击柱子查看当天';
}

function renderDataQuality() {
  var el = document.getElementById('dataQualityAna');
  if (!el) return;
  if (!ENTRIES.length) {
    el.innerHTML = '<div class="empty">暂无数据</div>';
    return;
  }
  var missingScores = ENTRIES.filter(function(entry) { return entry.score == null; }).length;
  var missingOverview = ENTRIES.filter(function(entry) { return !entry.overview || String(entry.overview).trim() === ''; }).length;
  var missingPlan = ENTRIES.filter(function(entry) { return !entry.plan || String(entry.plan).trim() === ''; }).length;
  var criticalCount = missingScores + missingOverview;
  var quality = { status: criticalCount === 0 && missingPlan === 0 ? 'good' : (criticalCount <= 3 ? 'warning' : 'needs_attention') };
  var statusText = quality.status === 'good' ? '健康' : quality.status === 'warning' ? '可优化' : '需补录';
  var statusColor = quality.status === 'good' ? '#3E9B6C' : quality.status === 'warning' ? '#A9740A' : '#D1453D';
  var rows = [
    ['缺心情', missingScores],
    ['缺日记', missingOverview],
    ['缺计划', missingPlan]
  ];
  el.innerHTML = '<div class="quality-head" style="color:' + statusColor + '">状态：' + statusText + '</div>' +
    rows.map(function(row) {
      return '<div class="quality-row"><span>' + row[0] + '</span><b>' + row[1] + '</b></div>';
    }).join('') +
    '<div class="quality-foot">' + (criticalCount ? '先补心情和日记概览，计划可以慢慢跟进。' : missingPlan ? '心情和概览完整；有空再补计划即可。' : '记录完整度很好。') + '</div>';
}

function pearson(pairs) {
  if (pairs.length < 3) return null;
  var n = pairs.length;
  var mx = pairs.reduce(function(a, p) { return a + p[0]; }, 0) / n;
  var my = pairs.reduce(function(a, p) { return a + p[1]; }, 0) / n;
  var sx = pairs.reduce(function(a, p) { return a + Math.pow(p[0] - mx, 2); }, 0);
  var sy = pairs.reduce(function(a, p) { return a + Math.pow(p[1] - my, 2); }, 0);
  var cov = pairs.reduce(function(a, p) { return a + (p[0] - mx) * (p[1] - my); }, 0);
  return sx > 0 && sy > 0 ? cov / Math.sqrt(sx * sy) : null;
}

function renderCorrelations() {
  var el = document.getElementById('correlationAna');
  if (!el) return;
  var scored = ENTRIES.filter(function(entry) { return entry.score != null; });
  var series = [
    { key: 'screen', label: '屏幕时间', pairs: scored.map(function(e) { return [screenTotal(e), e.score]; }), inverse: true },
    { key: 'steps', label: '步数', pairs: scored.map(function(e) { return [healthValue(e, 'steps'), e.score]; }) },
    { key: 'sleep', label: '睡眠', pairs: scored.map(function(e) { return [healthValue(e, 'sleep_hours'), e.score]; }) }
  ];
  var rows = series.map(function(item) {
    var value = pearson(item.pairs.filter(function(pair) { return pair[0] != null && pair[1] != null; }));
    if (value == null) return '';
    var strength = Math.abs(value) >= .5 ? '明显' : Math.abs(value) >= .2 ? '弱相关' : '基本独立';
    var direction = value >= 0 ? '正相关' : '负相关';
    if (item.inverse && value < 0) direction = '屏幕越少，心情越高';
    else if (item.inverse) direction = '屏幕越多，心情越高';
    else direction = (value >= 0 ? '越高越积极' : '越高心情越低');
    return '<div class="corr-row"><span>' + item.label + '</span><b class="num">' + value.toFixed(2) + '</b><em>' + strength + ' · ' + direction + '</em></div>';
  }).join('');
  el.innerHTML = (rows || '<div class="empty">样本不足，暂无法计算。</div>') +
    '<div class="quality-foot">相关只是线索，不是因果；样本越多越稳定。</div>';
}

function downloadBlob(content, filename, type) {
  var blob = new Blob([content], { type: type });
  var url = URL.createObjectURL(blob);
  var link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
  toast('已导出 ' + filename);
}

function exportJson() {
  downloadBlob(JSON.stringify(DATA, null, 2), 'river-diary-' + (state.date || TODAY) + '.json', 'application/json');
}

function exportCsv() {
  var head = ['日期', '星期', '心情', '精力', '专注', '产出', '综合', '成长', '屏幕分钟', '浏览次数', '步数', '睡眠小时', '概览', '明日计划'];
  var rows = ENTRIES.map(function(entry) {
    var metrics = entry.metrics || {};
    var health = entry.ios_health || {};
    return [entry.date, fmtW(entry.date), entry.score, metrics.energy, metrics.focus, metrics.output, metrics.overall, metrics.growth, screenTotal(entry), browseTotal(entry), health.steps, health.sleep_hours, entry.overview, entry.plan];
  });
  var csv = [head].concat(rows).map(function(row) {
    return row.map(function(value) {
      var text = value == null ? '' : String(value);
      return '"' + text.replace(/"/g, '""') + '"';
    }).join(',');
  }).join('\n');
  downloadBlob('\uFEFF' + csv, 'river-diary-' + (state.date || TODAY) + '.csv', 'text/csv;charset=utf-8');
}

(function(){
    /* ===== 10. 5 指标移到独立卡（移到 detailCard 下方） ===== */
  // 不重排 DOM：在 detailCard 后插入 metrics-card
  // 注意：metrics-card 不在 detailCard 内，独立 busy 标志
  var _metricsBusy = false;
  function paintMetricsCard(){
    if(_metricsBusy) return;
    _metricsBusy = true;
    try{
      var existing = document.getElementById('metricsCard');
      if(existing) existing.remove();
      var dcEl = document.getElementById('detailCard');
      if(!dcEl) return;
      var e = BYDATE[state.date];
      if(!e) return;
      var m = e.metrics || {};
      // 从 BYDATE 直接读 stMin/browseTotal/wCnt/lCnt（用全局 screenTotal / browseTotal 函数）
      var screenMin = (typeof screenTotal === 'function') ? screenTotal(e) : 0;
      var browseT = (typeof browseTotal === 'function') ? browseTotal(e) : 0;
      var didW = 0, didL = 0;
      (e.did||[]).forEach(function(g){ if({work:1,study:1,env:1,self:1}[g.cat]) didW++; else didL++; });
      // 用全局 fmtMin（已存在）

      var items = [
        {k:'mood', label:'心情', v:e.score, col:'#E85D4E'},
        {k:'energy', label:'精力', v:m.energy, col:'#F5A04C', basis: m.energy_basis},
        {k:'focus', label:'专注', v:m.focus, col:'#7CB342', basis: m.focus_basis},
        {k:'output', label:'产出', v:m.output, col:'#5B9BD5', basis: m.output_basis},
        {k:'overall', label:'综合', v:m.overall, col:'#5B4BD8'}
      ];
      var card = document.createElement('section');
      card.id = 'metricsCard';
      card.className = 'metrics-card';
      card.innerHTML = '<div class="ph"><h3>📊 今日指标</h3><button type="button" class="mini-link" id="scoreHelp">? 看评分说明</button></div>'
        + '<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:12px">'
        + items.map(function(it){
          var val = it.v == null ? '—' : it.v;
          // 修复：心情分如果是 AI 推断，在数值下加小标识
          var aiTag = (it.k === 'mood' && e.score_source === 'ai') ? '<span class="ai-tag">AI 推断</span>' : '';
          return '<div class="mi-cell" style="border:1px solid var(--line);background:var(--card-2)">'
            + '<div class="lab" style="color:var(--ink-2)"><span class="d" style="background:'+it.col+';width:8px;height:8px;border-radius:50%;display:inline-block"></span>'+it.label+'</div>'
            + '<div class="val" style="color:var(--ink);font-weight:650;font-variant-numeric:tabular-nums">'
            + ( (it.k==='mood'||it.k==='overall')
                ? val+(it.v==null?'':'<em style="font-size:11px;color:var(--ink-3);font-weight:500;margin-left:2px">/100</em>')
                : (it.v==null
                    ? '—'
                    : bandLabel(it.v)+'<em style="font-size:12px;color:var(--ink-2);font-weight:500;margin-left:4px;font-style:normal">'+it.v+'</em>') )
            + '</div>'
            + aiTag
            + ( (it.k==='energy'||it.k==='focus'||it.k==='output')
                ? '<div class="basis" style="font-size:10.5px;color:var(--ink-3);line-height:1.5;margin-top:3px">'+bandLabel(it.v)+(it.basis?' · '+esc(it.basis):'')+'</div>'
                : (it.basis ? '<div class="basis" style="font-size:10.5px;color:var(--ink-3);line-height:1.5;margin-top:3px">'+esc(it.basis)+'</div>' : '') )
            + '</div>';
        }).join('')
        + '</div>'
        + '<div class="daily-row">'
        + '<span class="dr-item"><b>📱</b> 屏幕 <em>'+fmtMin(screenMin)+'</em></span>'
        + '<span class="dr-sep">·</span>'
        + '<span class="dr-item"><b>🌐</b> 浏览 <em>'+browseT+'</em></span>'
        + '<span class="dr-sep">·</span>'
        + '<span class="dr-item"><b>✅</b> 事项 <em>'+didW+'/'+didL+'</em></span>'
        + '<span class="dr-sep">·</span>'
        + '<span class="dr-item"><b>📈</b> '+(e.daily||'—')+'</span>'
        + '</div>';
      dcEl.parentNode.insertBefore(card, dcEl.nextSibling);
      var scoreHelpButton = card.querySelector('#scoreHelp');
      if(scoreHelpButton) scoreHelpButton.onclick = openScoreHelp;
      // detail-right 现在只放「今日塔罗」，不再与 daily-row 重复 3 个小指标，故不再隐藏
    }catch(err){}
    setTimeout(function(){ _metricsBusy = false; }, 50);
  }
  // 用独立 setInterval 监听日期变化（避免受 detailObs 限制）
  setInterval(function(){
    if(window._lastMetricsDate !== state.date){
      window._lastMetricsDate = state.date;
      paintMetricsCard();
    }
  }, 200);
  setTimeout(paintMetricsCard, 200);
  window.paintMetricsCard = paintMetricsCard;
})();

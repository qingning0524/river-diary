(function(){
    /* ===== 9. ⌘K 命令面板 ===== */
  var cmdkOverlay = document.getElementById('cmdkOverlay');
  var cmdkInput = document.getElementById('cmdkInput');
  var cmdkList = document.getElementById('cmdkList');
  var cmdkResults = []; // 当前过滤结果
  var cmdkIdx = 0;
  function openCmdk(){
    if(!cmdkOverlay) return;
    window._cmdkFocus = document.activeElement;
    cmdkOverlay.classList.add('show');
    refreshOverlayLock();
    cmdkInput.value = '';
    cmdkIdx = 0;
    renderCmdk('');
    setTimeout(function(){ cmdkInput.focus(); }, 50);
  }
  function closeCmdk(){
    cmdkOverlay && cmdkOverlay.classList.remove('show');
    refreshOverlayLock();
    var back = window._cmdkFocus; if(back && back.focus) back.focus(); window._cmdkFocus = null;
  }
  function renderCmdk(q){
    cmdkResults = buildCmdkResults(q);
    if(!cmdkResults.length){
      cmdkList.innerHTML = '<div class="cmdk-empty">没找到匹配项</div>';
      return;
    }
    cmdkList.innerHTML = cmdkResults.map(function(r, i){
      return '<div class="cmdk-item'+(i===cmdkIdx?' on':'')+'" data-i="'+i+'">'
        + '<span class="em">'+r.em+'</span>'
        + '<span class="main"><b>'+esc(r.title)+'</b><i>'+esc(r.sub||'')+'</i></span>'
        + (r.hint ? '<span class="hint">'+esc(r.hint)+'</span>' : '')
        + '</div>';
    }).join('');
    Array.prototype.forEach.call(cmdkList.querySelectorAll('.cmdk-item'), function(n){
      n.addEventListener('click', function(){ executeCmdk(parseInt(n.dataset.i, 10)); });
    });
  }
  function buildCmdkResults(q){
    var out = [];
    var ql = (q||'').toLowerCase().trim();
    function hit(text){ return !ql || String(text||'').toLowerCase().indexOf(ql) > -1; }
    // 静态命令
    var cmds = [
      {em:'🏠', title:'回到顶部', sub:'滚动到页面顶部', hint:'top', act: function(){ window.scrollTo({top:0, behavior:'smooth'}); }},
      {em:'📅', title:'跳到最新日记', sub:'今天的最新一篇', hint:'最新', act: function(){ setDate(latestDate(), false); }},
      {em:'◐', title:'切换深色/浅色', sub:'按 D 也行', hint:'D', act: function(){ var tb=document.getElementById('themeBtn'); if(tb) tb.click(); }},
      {em:'🔒', title:'切换演示模式', sub:'隐藏/显示好友姓名', hint:'隐私', act: function(){ var pb=document.getElementById('privacyBtn'); if(pb) pb.click(); }},
      {em:'🌊', title:'打开情绪河流图', sub:'跳转到可视化图', hint:'河流', act: function(){ scrollToId('riverCard'); }},
      {em:'🏃', title:'查看健康恢复', sub:'睡眠与步数趋势', hint:'健康', act: function(){ state.dtab='health'; renderDataPanel(); scrollToId('dataSecTitle'); }},
      {em:'🩺', title:'查看数据体检', sub:'缺失记录一览', hint:'体检', act: function(){ state.dtab='law'; renderDataPanel(); scrollToId('dataSecTitle'); }},
      {em:'📅', title:'打开月度回顾', sub:'按月统计与热力图', hint:'回顾', act: function(){ state.dtab='review'; renderDataPanel(); scrollToId('dataSecTitle'); }},
      {em:'📤', title:'导出 JSON 备份', sub:'包含全部日记数据', hint:'导出', act: function(){ exportJson(); }},
      {em:'❓', title:'打开功能指南', sub:'快捷键和本地修改说明', hint:'帮助', act: function(){ if(window.openHelpModal) window.openHelpModal(); }}
    ];
    out = out.concat(cmds.filter(function(cmd){ return hit(cmd.title + ' ' + cmd.sub + ' ' + cmd.hint); }));
    // 标签快速跳转
    var tagSet = {};
    var tagCount = 0;
    for(var i=0;i<ENTRIES.length;i++){
      (ENTRIES[i].tags||[]).forEach(function(t){ tagSet[t] = (tagSet[t]||0)+1; });
    }
    Object.keys(tagSet).forEach(function(t){
      if(tagCount < 8 && (!ql || t.toLowerCase().indexOf(ql)>=0)){
        out.push({em:'🏷', title:'#'+t, sub:tagSet[t]+' 条日记', hint:'标签', act: function(){
          // 通过 filter 模拟点击
          var sel=document.getElementById('tagFilter'); if(sel){ sel.value=t; sel.dispatchEvent(new Event('change')); }
          scrollToId('historySecTitle');
        }});
        tagCount++;
      }
    });
    // 日记搜索（限制 8 条避免列表过长）
    if(ql){
      var hits = [];
      for(var j=0;j<ENTRIES.length;j++){
        var e = ENTRIES[j];
        var hay = ((e.title||'')+' '+(e.overview||'')+' '+(e.mood||'')+' '+(e.thoughts||'')+' '+(e.tags||[]).join(' ')+' '+fmtFull(e.date)+' '+fmtW(e.date)+' '+e.date).toLowerCase();
        if(hay.indexOf(ql)>=0) hits.push(e);
        if(hits.length>=8) break;
      }
      // 标记分组
      hits.forEach(function(e){
        out.push({em:'📝', title:(e.title||fmtFull(e.date))+' · '+(e.score==null?'待评':e.score), sub:fmtFull(e.date)+' · '+(e.overview||'').slice(0,40), hint:stageOf(e), _group:'日记', act: function(){
          setDate(e.date, false);
          setTimeout(function(){ scrollToId('detailCard'); }, 60);
        }});
      });
    }
    // 修复：限制总结果数（之前不限制，36 条全显，列表过长）
    return out.slice(0, 30);
  }
  function executeCmdk(i){
    var r = cmdkResults[i];
    if(!r) return;
    closeCmdk();
    setTimeout(r.act, 50);
  }
  if(cmdkOverlay){
    document.addEventListener('keydown', function(ev){
      // ⌘K / Ctrl+K 打开
      if((ev.metaKey || ev.ctrlKey) && ev.key === 'k'){
        ev.preventDefault();
        if(cmdkOverlay.classList.contains('show')) closeCmdk(); else openCmdk();
      }
      if(ev.key === 'Escape' && cmdkOverlay.classList.contains('show')){ closeCmdk(); return; }
      if(!cmdkOverlay.classList.contains('show')) return;
      if(ev.key === 'Tab'){ trapDialogFocus(cmdkOverlay, ev); }
      // 上下选择 + 回车
      if(ev.key === 'ArrowDown'){ ev.preventDefault(); cmdkIdx = Math.min(cmdkResults.length-1, cmdkIdx+1); renderCmdk(cmdkInput.value); }
      if(ev.key === 'ArrowUp'){ ev.preventDefault(); cmdkIdx = Math.max(0, cmdkIdx-1); renderCmdk(cmdkInput.value); }
      if(ev.key === 'Enter'){ ev.preventDefault(); executeCmdk(cmdkIdx); }
    });
    cmdkInput.addEventListener('input', function(){ cmdkIdx = 0; renderCmdk(cmdkInput.value); });
    cmdkOverlay.addEventListener('click', function(ev){ if(ev.target === cmdkOverlay) closeCmdk(); });
  }

    // 包装 ⌘K 也支持点击搜索框
  if(document.getElementById('searchInput')){
    // 修复：之前是 focus 立即抢焦点到 ⌘K，用户输入被打断
    // 改为：点击搜索框时打开 ⌘K 面板（搜索框只是入口），同时不立即抢焦点
    // 让用户用 ⌘K 面板进行搜索；原搜索框保留作为 ⌘K 提示入口
    var searchInput = document.getElementById('searchInput');
    searchInput.setAttribute('readonly', 'readonly'); // 防止真输入
    searchInput.addEventListener('focus', function(ev){
      ev.preventDefault();
      openCmdk();
      searchInput.blur();
    });
    searchInput.addEventListener('click', function(ev){
      ev.preventDefault();
      openCmdk();
    });
  }
})();

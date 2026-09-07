(function(){
    /* ===== 17. 诗词：fcount 区右侧加个 ⌘K 提示 ===== */
  // 已经在 placeholder 里加了 "⌘K" 提示

  /* ===== 顶部 ⌘K 快捷键提示加到 brand ===== */
  var brand = document.querySelector('.top-brand');
  if(brand){ brand.title = '快捷键：← → 切日期 · ⌘K 搜索 · D 切深色 · 点击 logo 回顶部'; }

  /* ===== 7. logo 河流流动效 + 回顶部 ===== */
  var logo = document.getElementById('logoRiver');
  if(logo){
    logo.addEventListener('click', function(){
      logo.classList.remove('flow');
      // 强制 reflow 重启动画
      void logo.offsetWidth;
      logo.classList.add('flow');
      setTimeout(function(){
        // 顺滑回到顶部
        window.scrollTo({top:0, behavior:'smooth'});
      }, 280);
      setTimeout(function(){
        logo.classList.remove('flow');
      }, 1300);
    });
  }

  /* ===== 4. 历史卡周/月分桶角标（用独立 busy 标志） ===== */
  // 修复：之前用 _v3Busy（detailObs 用的），会互相阻塞——如果 detailObs 正在跑，paintDcWeek 被 skip
  // 现在用独立的 _dcWeekBusy
  var _dcWeekBusy = false;
  function paintDcWeek(){
    if(_dcWeekBusy) return;
    _dcWeekBusy = true;
    try{
      var grid = document.getElementById('historyGrid');
      if(!grid) return;
      var dcs = grid.querySelectorAll('.dc');
      if(!dcs.length) return;
      var today = new Date(TODAY);
      dcs.forEach(function(dc, i){
        if(dc.querySelector('.dc-period')) return; // 已画过
        var dateStr = dc.dataset.d;
        if(!dateStr) return;
        var d = new Date(dateStr);
        if(isNaN(d.getTime())) return;
        var daysAgo = Math.floor((today - d) / (1000*60*60*24));
        var period = daysAgo < 7 ? 'week' : 'month';
        var badge = document.createElement('span');
        badge.className = 'dc-period dc-period-' + period;
        badge.title = daysAgo < 7 ? '本周' : '本月';
        dc.appendChild(badge);
      });
    }catch(err){}
    setTimeout(function(){ _dcWeekBusy = false; }, 50);
  }
  var gridObs = new MutationObserver(paintDcWeek);
  setTimeout(function(){
    var grid = document.getElementById('historyGrid');
    if(grid) gridObs.observe(grid, {childList: true, subtree: false});
    paintDcWeek();
  }, 200);
  // 当筛选条件变化（renderHistory）时，旧的 .dc 会被 replaceWith，dcPeriod 也消失
  // gridObs 的 childList: true 会自动触发 paintDcWeek —— OK

  // beforeunload 清理（防御性）
  window.addEventListener('beforeunload', function(){
    if(_dcWeekBusy === false) _dcWeekBusy = true; // 阻止后续 paintDcWeek
    if(gridObs) gridObs.disconnect();
  });
})();

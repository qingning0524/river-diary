(function(){
    /* ===== 17. 每日诗词印章卡片 ===== */
  // 用 dataset 记原始诗，避免被注入后的 DOM 污染 textContent
  // 注意：poem-stamp 操作的是 #footerPoem，不与 detailCard 互斥
  // 因此不用 _v3Busy 保护（否则切日期时诗不更新）
  var _poemBusy = false;
  function paintPoemStamp(){
    if(_poemBusy) return;
    _poemBusy = true;
    try{
      var f = document.getElementById('footerPoem');
      if(!f) return;
      var original = f.dataset.originalPoem || f.textContent.trim();
      if(!original) return;
      if(f.dataset.originalPoem) original = f.dataset.originalPoem;
      else f.dataset.originalPoem = original;
      var date = state.date || TODAY;
      // 避免重复渲染：如果已有的 sign 文本包含当前日期，跳过
      if(f.querySelector('.poem-stamp') && f.querySelector('.sign').textContent.indexOf(fmtFull(date)) > 0) return;
      f.innerHTML = '';
      var stamp = document.createElement('div');
      stamp.className = 'poem-stamp';
      // 修复：DATA.poem 是全局字段（没有 per-date 诗），切日期时诗内容不变
      // 修法：在签名前加"今日诗"标识（state.date != today 时特别标注）
      var isToday = state.date === TODAY;
      var signText = isToday
        ? '— '+esc(fmtFull(date))+' · 今日诗'
        : '— '+esc(fmtFull(date))+' · 选自今日诗';
      stamp.innerHTML = '<div class="body">'
        + '<div class="text">'+esc(original)+'</div>'
        + '<div class="sign">'+signText+'</div>'
        + '</div>'
        + '<div class="stamp">情绪<br>河流<em>·记·</em></div>';
      f.appendChild(stamp);
    }catch(err){}
    setTimeout(function(){ _poemBusy = false; }, 50);
  }
  setTimeout(paintPoemStamp, 300);
  // 切日期时也刷新（用一次轮询，但只触发一次）
  var _poemLastDate = null;
  setInterval(function(){
    if(_poemLastDate !== state.date){
      _poemLastDate = state.date;
      paintPoemStamp();
    }
  }, 600);

})();

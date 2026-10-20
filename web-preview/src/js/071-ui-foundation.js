(function(){
    /* ============ V3 美化层 ============ */

  // 工具：View Transitions API 包装器
  // 修复：之前 setDate / dnav-btn 的 VT 包装都是注释（line 1618-1628），完全失效
  // 现在用 _v3Wrap 统一包裹所有需要"切换有动画"的渲染调用
  // ⚠️ 修复 BUG：_v3Wrap 原来只在本 IIFE 内可见（function 声明是局部变量），
  //    而全局 setDate()（line 180）与 renderDiary()（line 500/506）都要调用它，
  //    导致 dnav-btn 切换页签时抛 "ReferenceError: _v3Wrap is not defined"，切页签完全失效。
  //    修法：把它挂到 window 上，全局调用点才能拿到。
  var _vtSupported = typeof document.startViewTransition === 'function';
  function _v3Wrap(fn){
    if(!_vtSupported || window.matchMedia('(prefers-reduced-motion: reduce)').matches){
      fn();
      return;
    }
    // startViewTransition 的回调必须同步修改 DOM（否则 VT 不工作）
    // 防御：若回调抛错，回退到直接渲染，绝不让页面卡在某次 transition 的中间态（白屏）
    try{
      document.startViewTransition(function(){
        fn();
      });
    }catch(err){
      try{ fn(); }catch(e2){ console.error('render error:', e2); }
    }
  }
  window._v3Wrap = _v3Wrap;

  /* ===== 工具：stages 颜色、emoji 映射 ===== */
  var STAGE_COLORS = {'低谷':'#E85D4E','回升':'#F5A04C','平稳':'#D4A017','积极':'#7CB342','饱满':'#5B9BD5'};
  var STAGE_EMOJI = {'低谷':'🥺','回升':'🌤','平稳':'😐','积极':'😊','饱满':'🤩'};
  function stageOf(e){ return e && e.stage ? e.stage.label : '平稳'; }
  function emojiOf(e){ return STAGE_EMOJI[stageOf(e)] || '😐'; }
  function colorOf(label){ return STAGE_COLORS[label] || '#5B4BD8'; }
  // 计算连续天数（从最新一天往前推，断一天就停）
  function calcStreak(){
    if(!ENTRIES.length) return 0;
    var n = 0;
    var prev = null;
    for(var i = ENTRIES.length - 1; i >= 0; i--){
      var d = ENTRIES[i].date;
      if(prev){
        var a = new Date(prev+'T00:00:00'), b = new Date(d+'T00:00:00');
        var diff = Math.round((a - b) / 86400000);
        if(diff === 1) n++;
        else break;
      } else {
        n = 1;
      }
      prev = d;
    }
    return n;
  }
  window._v3Wrap = _v3Wrap;
  window.stageOf = stageOf;
  window.emojiOf = emojiOf;
  window.colorOf = colorOf;
  window.calcStreak = calcStreak;
})();

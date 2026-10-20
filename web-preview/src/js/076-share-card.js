(function(){
    /* ===== 18. 分享图生成（1080×1920 Canvas） ===== */
  var imgShareBtn = document.getElementById('imgShareBtn');
  var shareResult = document.getElementById('shareResult');
  var shareImg = document.getElementById('shareImg');
  function openShareResult(dataUrl){
    if(!shareResult) return;
    window._shareResultFocus = document.activeElement;
    shareImg.src = dataUrl;
    shareResult.classList.add('show');
    refreshOverlayLock();
    var close = document.getElementById('shareCloseBtn'); if(close) close.focus();
  }
  function closeShareResult(){
    if(!shareResult || !shareResult.classList.contains('show')) return;
    shareResult.classList.remove('show');
    refreshOverlayLock();
    var back = window._shareResultFocus;
    if(back && back.focus) back.focus();
    window._shareResultFocus = null;
  }
  if(shareResult){
    document.getElementById('shareCloseBtn').addEventListener('click', closeShareResult);
    shareResult.addEventListener('click', function(ev){ if(ev.target === shareResult) closeShareResult(); });
    document.addEventListener('keydown', function(ev){
      if(!shareResult.classList.contains('show')) return;
      if(ev.key === 'Escape') closeShareResult();
      if(ev.key === 'Tab') trapDialogFocus(shareResult, ev);
    });
  }
  function drawShareCard(){
    var e = BYDATE[state.date];
    if(!e){ alert('没有当前日记可分享'); return; }
    // 等待字体加载
    var fontsReady = (document.fonts && document.fonts.ready) ? document.fonts.ready : Promise.resolve();
    fontsReady.then(function(){
      var W = 1080, H = 1920;
      var c = document.createElement('canvas');
      c.width = W; c.height = H;
      var ctx = c.getContext('2d');
      // 背景渐变（暖调奶白，不再偏紫）
      var bg = ctx.createLinearGradient(0, 0, W, H);
      bg.addColorStop(0, '#FAF7F2');
      bg.addColorStop(0.5, '#FDFBF7');
      bg.addColorStop(1, '#F5F0E8');
      ctx.fillStyle = bg; ctx.fillRect(0, 0, W, H);
      // 装饰光晕（极淡——再小就完全看不见了，给点"水彩"感不染主色）
      var glow1 = ctx.createRadialGradient(W*0.15, H*0.1, 0, W*0.15, H*0.1, 350);
      glow1.addColorStop(0, 'rgba(91,75,216,0.04)');
      glow1.addColorStop(1, 'rgba(91,75,216,0)');
      ctx.fillStyle = glow1; ctx.fillRect(0, 0, W, H);
      var glow2 = ctx.createRadialGradient(W*0.9, H*0.95, 0, W*0.9, H*0.95, 300);
      glow2.addColorStop(0, 'rgba(224,111,149,0.04)');
      glow2.addColorStop(1, 'rgba(224,111,149,0)');
      ctx.fillStyle = glow2; ctx.fillRect(0, 0, W, H);
      // 顶部 logo
      ctx.save();
      var lx = 80, ly = 80, lr = 36;
      var lg = ctx.createLinearGradient(lx, ly, lx+lr*2, ly+lr*2);
      lg.addColorStop(0, '#5B4BD8'); lg.addColorStop(1, '#E06F95');
      ctx.fillStyle = lg;
      roundRect(ctx, lx, ly, lr*2, lr*2, 18); ctx.fill();
      ctx.strokeStyle = 'rgba(255,255,255,0.7)'; ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(lx+12, ly+lr+4);
      ctx.bezierCurveTo(lx+lr*0.5, ly+lr*0.4, lx+lr*0.8, ly+lr*1.4, lx+lr*1.4, ly+lr*0.6);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(lx+12, ly+lr+18);
      ctx.bezierCurveTo(lx+lr*0.5, ly+lr+10, lx+lr*0.8, ly+lr*1.8, lx+lr*1.4, ly+lr+12);
      ctx.stroke();
      ctx.restore();
      // 标题（加多平台 fallback：Hiragino Sans GB / Microsoft YaHei / Source Han Sans SC）
      ctx.fillStyle = '#17202B';
      ctx.font = '700 44px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", "Noto Sans CJK SC", sans-serif';
      ctx.textBaseline = 'top';
      ctx.fillText('情绪河流', 80, 90);
      ctx.fillStyle = '#7D8A99';
      ctx.font = '500 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", "Noto Sans CJK SC", sans-serif';
      ctx.fillText('每日自动记录', 80, 140);
      // 日期 + emoji（修复重叠：emoji 在右上，日期在 emoji 下方左侧）
      var emoji = emojiOf(e);
      ctx.font = '88px -apple-system, "Apple Color Emoji", "Segoe UI Emoji", sans-serif';
      ctx.textAlign = 'right';
      ctx.fillText(emoji, W-80, 90);
      ctx.fillStyle = '#5F6D7A';
      ctx.font = '600 26px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif';
      ctx.fillText(fmtFull(e.date), W-80, 200);
      ctx.textAlign = 'left';
      // 大心情分数（修复：/100 移到与心情数字基线对齐）
      ctx.fillStyle = '#7D8A99';
      ctx.font = '700 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif';
      ctx.fillText('心情', 80, 280);
      var stCol = colorOf(stageOf(e));
      ctx.fillStyle = stCol;
      ctx.font = '200 220px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif';
      ctx.fillText((e.score==null?'—':e.score), 80, 310);
      // /100 用 textBaseline='bottom' 与心情数字底部对齐
      // 修复 Vision 反馈：之前 y=530 偏下，改为 y=500 紧贴 220px 数字底部
      ctx.fillStyle = '#9AA3AE';
      ctx.font = '500 40px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.textBaseline = 'bottom';
      ctx.fillText('/100', 320, 500);
      ctx.textBaseline = 'top';
      // 阶段 chip
      var stLabel = stageOf(e);
      var chipW = ctx.measureText(stLabel).width + 60;
      var chipH = 60;
      var chipX = 80, chipY = 580;
      ctx.fillStyle = stCol + '26';
      roundRect(ctx, chipX, chipY, chipW, chipH, 30); ctx.fill();
      ctx.fillStyle = stCol;
      ctx.font = '700 28px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.textBaseline = 'middle';
      ctx.fillText(stLabel, chipX+30, chipY+chipH/2);
      ctx.textBaseline = 'top';
      // 5 指标行
      var m = e.metrics || {};
      var metrics = [
        {k:'精力', v:m.energy, col:'#F5A04C'},
        {k:'专注', v:m.focus, col:'#7CB342'},
        {k:'产出', v:m.output, col:'#5B9BD5'},
        {k:'成长', v:m.growth, col:'#A78BFA'}
      ];
      var my0 = 720;
      var mw = (W - 160) / 4;
      metrics.forEach(function(it, i){
        var x = 80 + i*mw;
        // 卡片
        ctx.fillStyle = 'rgba(255,255,255,0.7)';
        roundRect(ctx, x+8, my0, mw-16, 140, 16); ctx.fill();
        ctx.strokeStyle = 'rgba(23,32,43,0.08)';
        ctx.lineWidth = 1;
        roundRect(ctx, x+8, my0, mw-16, 140, 16); ctx.stroke();
        ctx.fillStyle = it.col;
        ctx.beginPath(); ctx.arc(x+30, my0+30, 8, 0, Math.PI*2); ctx.fill();
        ctx.fillStyle = '#5F6D7A';
        ctx.font = '700 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
        ctx.fillText(it.k, x+50, my0+18);
        ctx.fillStyle = '#17202B';
        ctx.font = '600 50px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif';
        ctx.textBaseline = 'alphabetic';
        // 数字靠左，/100 紧贴数字右侧 12px（修复重叠：之前 +8 太近，黏在一起）
        ctx.fillText((it.v==null?'—':it.v), x+18, my0+95);
        ctx.font = '500 50px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif';
        var numW = ctx.measureText(String(it.v==null?'—':it.v)).width;
        ctx.fillStyle = '#7D8A99';
        ctx.font = '500 20px -apple-system, sans-serif';
        ctx.textBaseline = 'alphabetic';
        // /100 baseline 与数字 baseline 对齐（同 y），间距 12px
        ctx.fillText('/100', x+18+numW+12, my0+95);
        ctx.textBaseline = 'top';
      });
      // 7 天 sparkline
      var idx = idxOf(e.date);
      var last7 = ENTRIES.slice(Math.max(0, idx-6), idx+1);
      var sy0 = 920, sw = W - 160, sh = 180;
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      roundRect(ctx, 80, sy0, sw, sh, 20); ctx.fill();
      ctx.strokeStyle = 'rgba(23,32,43,0.08)';
      roundRect(ctx, 80, sy0, sw, sh, 20); ctx.stroke();
      ctx.fillStyle = '#5F6D7A';
      ctx.font = '700 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.fillText('最近 7 天心情', 110, sy0+22);
      var barW = (sw - 80) / last7.length;
      last7.forEach(function(x, i){
        var px = 110 + i*barW;
        var ph = x.score==null ? 8 : Math.max(8, (x.score/100)*(sh-80));
        var c = x.score==null ? '#E6EBF1' : colorOf(stageOf(x));
        ctx.fillStyle = c;
        var isLast = i === last7.length - 1;
        roundRect(ctx, px+4, sy0+sh-12-ph, barW-12, ph, 4); ctx.fill();
        if(isLast){
          ctx.strokeStyle = '#17202B'; ctx.lineWidth = 2.5;
          roundRect(ctx, px+4, sy0+sh-12-ph, barW-12, ph, 4); ctx.stroke();
        }
      });
      // 诗词印章
      var poem = (DATA && DATA.poem) || '每日一句诗词';
      var py0 = 1140;
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      roundRect(ctx, 80, py0, sw, 240, 20); ctx.fill();
      ctx.strokeStyle = 'rgba(23,32,43,0.08)';
      roundRect(ctx, 80, py0, sw, 240, 20); ctx.stroke();
      // 诗词用衬线字体（修复：加多平台 fallback——之前只有 Songti SC/STSong，在 Windows/Linux 浏览器会缺字）
      // font 链：Source Han Serif SC（开源跨平台）→ SimSun（Windows）→ Songti SC（Mac）→ STSong → serif
      ctx.fillStyle = '#17202B';
      ctx.font = '600 36px "Source Han Serif SC", "Noto Serif CJK SC", "Songti SC", "STSong", "SimSun", Georgia, serif';
      wrapText(ctx, poem, 130, py0+50, sw-280, 52);
      // 印章（修复：字号太小看不清，'·记·'改 22px，'情绪河流'加粗大字号）
      var sx = W-180, sy = py0+90, sr = 64;
      var sg = ctx.createLinearGradient(sx-sr, sy-sr, sx+sr, sy+sr);
      sg.addColorStop(0, '#C8362F'); sg.addColorStop(1, '#8B1A1A');
      ctx.save();
      ctx.translate(sx, sy);
      ctx.rotate(-6 * Math.PI / 180);
      ctx.fillStyle = sg;
      roundRect(ctx, -sr, -sr, sr*2, sr*2, 12); ctx.fill();
      // 印章边框细线
      ctx.strokeStyle = 'rgba(255,230,225,0.4)';
      ctx.lineWidth = 2;
      roundRect(ctx, -sr+8, -sr+8, sr*2-16, sr*2-16, 8); ctx.stroke();
      ctx.fillStyle = '#FCE8E5';
      ctx.font = '900 28px "STSong", "Songti SC", "SimSun", "Source Han Serif SC", serif';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText('情绪河流', 0, -10);
      ctx.font = '600 20px "STSong", "SimSun", "Source Han Serif SC", serif';
      ctx.fillText('·  记  ·', 0, 22);
      ctx.textAlign = 'left'; ctx.textBaseline = 'top';
      ctx.restore();
      // 签名
      ctx.fillStyle = '#7D8A99';
      ctx.font = '500 20px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.fillText('—  '+fmtFull(e.date)+' · 情绪河流', 130, py0+200);
      // 底部水印
      ctx.fillStyle = '#7D8A99';
      ctx.font = '500 22px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('🌊 情绪河流 · 每日自动记录', W/2, H-80);
      // 导出
      try{
        var dataUrl = c.toDataURL('image/png');
        openShareResult(dataUrl);
        window._lastShareDataUrl = dataUrl;
      }catch(err){
        alert('生成失败：' + err.message);
      }
    });
  }
  function roundRect(ctx, x, y, w, h, r){
    if(typeof r === 'number') r = {tl:r, tr:r, br:r, bl:r};
    ctx.beginPath();
    ctx.moveTo(x + r.tl, y);
    ctx.lineTo(x + w - r.tr, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r.tr);
    ctx.lineTo(x + w, y + h - r.br);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r.br, y + h);
    ctx.lineTo(x + r.bl, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r.bl);
    ctx.lineTo(x, y + r.tl);
    ctx.quadraticCurveTo(x, y, x + r.tl, y);
    ctx.closePath();
  }
  function wrapText(ctx, text, x, y, maxW, lh){
    var chars = text.split('');
    var line = '';
    var yy = y;
    for(var i=0;i<chars.length;i++){
      var t = line + chars[i];
      if(ctx.measureText(t).width > maxW && line){
        ctx.fillText(line, x, yy);
        line = chars[i];
        yy += lh;
      } else {
        line = t;
      }
    }
    if(line) ctx.fillText(line, x, yy);
  }
  if(imgShareBtn) imgShareBtn.addEventListener('click', drawShareCard);
  // 分享图操作
  var dl = document.getElementById('shareDownloadBtn');
  if(dl) dl.addEventListener('click', function(){
    if(!window._lastShareDataUrl) return;
    var a = document.createElement('a');
    a.href = window._lastShareDataUrl;
    a.download = '情绪河流-'+(state.date || TODAY)+'.png';
    a.click();
  });
  var cp = document.getElementById('shareCopyBtn');
  if(cp) cp.addEventListener('click', function(){
    if(!window._lastShareDataUrl) return;
    // 复制到剪贴板：先 fetch 成 blob
    fetch(window._lastShareDataUrl).then(r=>r.blob()).then(function(blob){
      try{
        var item = new ClipboardItem({'image/png': blob});
        navigator.clipboard.write([item]).then(function(){
          cp.textContent = '已复制 ✓';
          setTimeout(function(){ cp.textContent = '复制到剪贴板'; }, 1500);
        });
      }catch(err){
        alert('当前浏览器不支持复制图片，请用下载');
      }
    });
  });
})();

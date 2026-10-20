
var riverAnimated = false;
/* ================= 渲染：情绪河流 ================= */
function renderRiver(){
  var wrap = $('riverWrap'), svg = $('riverSvg'), tip = $('riverTip'), lg = $('riverLegend'), st = $('riverStats');
  if(!svg) return;
  if(!ENTRIES.length){ svg.innerHTML=''; st.innerHTML='暂无数据'; return; }

  // 阶段色图例
  var STG = {低谷:'#C9554A',回升:'#C9851E',平稳:'#B8941F',积极:'#5A8A4F',饱满:'#4A7CC4'};
  lg.innerHTML = ['低谷','回升','平稳','积极','饱满'].map(function(l){
    return '<span class="lg"><span class="sw" style="background:'+STG[l]+'"></span>'+l+'</span>';
  }).join('') + '<span class="lg"><span class="sw" style="background:#fff;border:1.5px dashed #C9CFD6"></span>待评分</span>';

  // —— 河流：像一条水，而不是一张走势图 ——
  var N = ENTRIES.length;
  var H = 200, W = Math.max(N*48+84, 1080);
  var PADL = 40, PADR = 30, PADT = 34, PADB = 38;
  var iw = W-PADL-PADR, ih = H-PADT-PADB, step = N>1 ? iw/(N-1) : iw;
  var baseline = PADT + ih;

  // 每天采样：评分越高越往上（null=未评分，断流不拖底）
  var pts = ENTRIES.map(function(e,i){
    return { x: PADL + i*step,
             y: (e.score==null)? null : (baseline - (e.score/100)*ih), e:e };
  });
  var valid = pts.filter(function(p){ return p.y!=null; });

  var reduced = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  var g = '<defs>'
      + '<linearGradient id="rgWater" gradientUnits="userSpaceOnUse" x1="0" y1="'+PADT+'" x2="0" y2="'+baseline+'">'
      + '<stop offset="0" stop-opacity="0.48"/>'
      + '<stop offset="0.4" stop-opacity="0.18"/>'
      + '<stop offset="1" stop-opacity="0.04"/>'
      + '</linearGradient>'
      + '<linearGradient id="rgFlow" gradientUnits="userSpaceOnUse" x1="0" y1="'+PADT+'" x2="0" y2="'+baseline+'">'
      + '<stop offset="0" stop-opacity="0"/>'
      + '<stop offset="0.14" stop-opacity="0.4"/>'
      + '<stop offset="0.45" stop-opacity="0.06"/>'
      + '<stop offset="1" stop-opacity="0"/>'
      + '</linearGradient></defs>';

  // —— 一支蜿蜒、随身心情涨落、向"今天"汇流的河 ——
  var H = 220, padT = 30, padB = 34, ihV = H - padT - padB, midY = padT + ihV*0.54;
  function centreY(x){ var u=(x-PADL)/Math.max(iw,1); return midY + 13*Math.sin(u*6.2831853*1.6) + 7*Math.sin(u*6.2831853*3.1+1.2); }
  function halfW(x, score){ var t=(x-PADL)/Math.max(iw,1); var m=(score==null?0:score)/100; return Math.min(50, Math.max(14, 14 + 26*m + 8*t)); }
  function seg(a){ var s=''; for(var i=0;i<a.length-1;i++){ var cx=(a[i].x+a[i+1].x)/2; s+=' C'+cx+','+a[i].y+' '+cx+','+a[i+1].y+' '+a[i+1].x+','+a[i+1].y; } return s; }

  var rated = pts.filter(function(p){ return p.e.score != null; });
  if(rated.length){
    var cT = rated.map(function(p){ return {x:p.x, y:centreY(p.x) - halfW(p.x, p.e.score)}; });
    var cB = rated.map(function(p){ return {x:p.x, y:centreY(p.x) + halfW(p.x, p.e.score)}; });
    var cM = rated.map(function(p){ return {x:p.x, y:centreY(p.x)}; });
    var dTop = 'M'+cT[0].x+','+cT[0].y + seg(cT);
    var dBot = 'M'+cB[0].x+','+cB[0].y + seg(cB);
    var dMid = 'M'+cM[0].x+','+cM[0].y + seg(cM);
    var body = dTop + ' L'+cB[cB.length-1].x+','+cB[cB.length-1].y + seg(cB.slice().reverse()) + ' Z';
    g += '<path d="'+body+'" fill="url(#rgWater)"/>';        // 河身：心情越好越丰盈
    g += '<path d="'+dTop+'" fill="none" class="river-glow"/>';  // 水面受光
    g += '<path d="'+dTop+'" fill="none" class="river-surface"/>';// 近岸水线
    g += '<path d="'+dMid+'" fill="none" class="river-flow"/>';   // 水流：沿河心向下游漂移
    g += '<path d="'+dBot+'" fill="none" class="river-shore"/>';  // 远岸的影
  }
  // 回放按钮（第一次绑定）
  var rpb = document.getElementById('riverPlayBtn');
  if(rpb && !rpb._rp){ rpb._rp = 1; rpb.onclick = function(){ openRiverReplay(); }; }

  // —— 每一天，都是河上一颗被水记住的石子 ——
  var minR = 3.5, maxR = 8.5;
  pts.forEach(function(p,i){
    var isSel = (p.e.date === state.date);
    var isTodayNow = (p.e.date === (window.TODAY||''));
    var yy = centreY(p.x), hw = halfW(p.x, p.e.score);
    var r = p.e.score==null ? 3.5 : Math.round(minR + (p.e.metrics.overall!=null?p.e.metrics.overall:50)/100*(maxR-minR));
    var col = p.e.stage ? (STG[p.e.stage.label]||'#A39888') : '#A39888';
    if(p.e.score==null){
      g += '<circle cx="'+p.x+'" cy="'+yy+'" r="'+r+'" fill="var(--card)" stroke="#C9CFD6" stroke-width="1.6" stroke-dasharray="3 2" data-d="'+p.e.date+'" style="cursor:pointer"/>';
    } else {
      if(isSel){
        g += '<circle class="ripple on" cx="'+p.x+'" cy="'+yy+'" r="'+(r+7)+'" fill="none" style="pointer-events:none"/>';
        g += '<circle class="ripple on" cx="'+p.x+'" cy="'+yy+'" r="'+(r+12)+'" fill="none" opacity=".5" style="pointer-events:none"/>';
      } else {
        g += '<circle class="ripple" cx="'+p.x+'" cy="'+yy+'" r="'+(r+3)+'" fill="none" style="pointer-events:none"/>';
      }
      g += '<circle cx="'+p.x+'" cy="'+yy+'" r="'+r+'" fill="'+col+'" opacity="'+(isSel?1:(isTodayNow?0.96:0.9))+'"'
         + (isSel?' data-sel="1" stroke="var(--card)" stroke-width="2"':'')+' data-d="'+p.e.date+'" class="drop" style="cursor:pointer;transition:all .18s"/>';
      g += '<circle cx="'+(p.x - r*0.32)+'" cy="'+(yy - r*0.34)+'" r="'+Math.max(1.1, r*0.22)+'" fill="rgba(255,255,255,.5)" style="pointer-events:none"/>';
      if(isTodayNow){
        g += '<text class="rf-flag" x="'+p.x+'" y="'+(yy - r - 8)+'" text-anchor="middle">今</text>';
      }
    }
    // 日期：只用选中 + 今天，轻轻落在那一小段河的下方
    if(isSel || isTodayNow){
      g += '<text class="rf-date'+(isSel?' on':'')+'" x="'+p.x+'" y="'+(yy + hw + 16)+'" text-anchor="middle">'+p.e.date.slice(5)+'</text>';
    }
  });

  svg.setAttribute('width', W);
  svg.setAttribute('height', H);
  svg.setAttribute('viewBox','0 0 '+W+' '+H);
  svg.setAttribute('role','img');
  svg.setAttribute('aria-label','情绪河流：连续 '+N+' 天的心情曲线');
  svg.innerHTML = g;
  if(wrap && tip) wrap.appendChild(tip);
  if(wrap && tip && !wrap._tipScrollBound){
    wrap._tipScrollBound = true;
    wrap.addEventListener('scroll', function(){ tip.style.opacity = 0; }, { passive: true });
  }

  // 悬浮
  svg.querySelectorAll('circle[data-d]').forEach(function(el){
    el.addEventListener('mouseenter', function(){
      var d = el.getAttribute('data-d'), e = BYDATE[d]; if(!e) return;
      tip.innerHTML = '<b>'+e.date.slice(5)+' · '+fmtW(e.date)+' · '+e.stage.label+'</b>'
        +'<div class="row"><span>心情</span><i>'+(e.score==null?'待评分':e.score)+(e.score_source==='ai'?'（AI推断）':'')+'</i></div>'
        +'<div class="row"><span>综合</span><i>'+(e.metrics.overall==null?'—':e.metrics.overall)+'</i></div>'
        +'<div class="row"><span>成长</span><i>'+(e.metrics.growth==null?'—':e.metrics.growth)+'</i></div>'
        +'<div class="row"><span>屏幕</span><i>'+fmtMin(screenTotal(e))+'</i></div>';
      tip.style.opacity = 1;
      var cx = parseFloat(el.getAttribute('cx'));
      tip.style.left = Math.min(Math.max(cx - 60, 10), Math.max(10, W - tip.offsetWidth - 10)) + 'px';
      tip.style.top = Math.max(6, parseFloat(el.getAttribute('cy')) - 78) + 'px';
    });
    el.addEventListener('mouseleave', function(){ tip.style.opacity=0; });
    el.addEventListener('click', function(){ setDate(el.getAttribute('data-d'), false); });
  });

  // 河流统计（未评分不计入均值/极值）
  var rated = ENTRIES.filter(function(x){ return x.score!=null; });
  var avg = rated.length ? +(rated.reduce(function(s,e){return s+e.score;},0)/rated.length).toFixed(1) : '—';
  var hi = rated.length ? rated.reduce(function(a,b){return b.score>a.score?b:a;}) : null;
  var lo = rated.length ? rated.reduce(function(a,b){return b.score<a.score?b:a;}) : null;
  st.innerHTML =
    '<span>📅 '+ENTRIES[0].date.slice(5)+' — '+ENTRIES[N-1].date.slice(5)+'</span>'
    +'<span>平均心情 '+(avg==='—'?'—':avg)
    + (hi?' · 高峰 '+hi.score+' ('+hi.date.slice(5)+')':'')
    + (lo?' · 低谷 '+lo.score+' ('+lo.date.slice(5)+')':'')
    + (N-rated.length ? ' · '+(N-rated.length)+' 天待评分' : '') + '</span>';

  // 首次加载动效：曲线绘制 + 节点依次弹出（尊重系统减弱动效设置）
  if(!riverAnimated){
    riverAnimated = true;
    if(!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches)){
      var lineP = svg.querySelector('path[fill="none"]');
      if(lineP && lineP.getTotalLength){
        var L = lineP.getTotalLength();
        lineP.style.strokeDasharray = L;
        lineP.style.strokeDashoffset = L;
        lineP.style.transition = 'stroke-dashoffset 1.5s cubic-bezier(.22,1,.36,1)';
        requestAnimationFrame(function(){ requestAnimationFrame(function(){ lineP.style.strokeDashoffset = 0; }); });
      }
      var areaP = svg.querySelector('path[fill^="url"]');
      if(areaP){ areaP.style.opacity = 0; areaP.style.transition = 'opacity 1s ease .5s';
        requestAnimationFrame(function(){ requestAnimationFrame(function(){ areaP.style.opacity = 1; }); }); }
      svg.querySelectorAll('circle[data-d]').forEach(function(c, i){
        c.style.opacity = 0;
        c.style.transition = 'opacity .4s ease '+(i*0.035)+'s';
        (function(el){ setTimeout(function(){ el.style.opacity = el.getAttribute('data-sel')==='1' ? 1 : .85; }, 60); })(c);
      });
    }
  }
}

/* ================= 渲染：今日详情 ================= */

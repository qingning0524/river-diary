
function refreshOverlayLock(extraOverlay){
  var overlayIds = ['scoreModal', 'cmdkOverlay', 'replay', 'shareResult'];
  var locked = overlayIds.some(function(id){
    var el = document.getElementById(id);
    return el && el.classList.contains('show');
  }) || !!(extraOverlay && extraOverlay.classList.contains('show'));
  document.body.style.overflow = locked ? 'hidden' : '';
}

/* ================= 评分说明弹窗 ================= */
function openScoreHelp(){
  var ov = $('scoreModal'); if(!ov) return;
  window._scoreHelpFocus = document.activeElement;
  ov.classList.add('show');
  refreshOverlayLock();
  var close = $('scoreModalClose'); if(close) close.focus();
}
function closeScoreHelp(){
  var ov = $('scoreModal');
  if(!ov || !ov.classList.contains('show')) return;
  ov.classList.remove('show');
  refreshOverlayLock();
  var back = window._scoreHelpFocus; if(back && back.focus) back.focus(); window._scoreHelpFocus = null;
}
var scoreModalEl = $('scoreModal');
if(scoreModalEl){
  scoreModalEl.addEventListener('keydown', function(ev){ if(ev.key === 'Tab') trapDialogFocus(scoreModalEl, ev); });
}

/* ================= 渲染：社交情绪（微信私聊聚合） ================= */
function renderSocial(){
  var chips = $('socialChips'), scroll = $('socialScroll'), stats = $('socialStats'), note = $('socialNote');
  if(!chips || !scroll) return;
  var soc = DATA.social || {};
  var dates = Object.keys(soc).sort();
  if(!dates.length){
    chips.innerHTML='';
    scroll.innerHTML='<div class="empty" style="margin:14px 0">暂无社交数据（微信统计每日 22:35 自动采集）</div>';
    if(stats) stats.innerHTML='';
    if(note) note.textContent='';
    return;
  }
  var tt = $('socialTooltip');
  var todayS = soc[DATA.today] || soc[dates[dates.length-1]];
  var sc = todayS.social_score;
  var scColor = sc==null ? 'var(--ink-3)' : mColor(sc);

  chips.innerHTML = [
    '<div class="mo"><div class="mo-label">社交情绪分</div><div class="mo-val num" style="color:'+scColor+'">'+(sc!=null?sc:'—')+'<em>/100</em></div>'+
      '<div class="mo-bar"><div class="mo-fill" style="width:'+((sc!=null?sc:0)*10)+'%;background:'+scColor+'"></div></div></div>',
    '<div class="mo"><div class="mo-label">活跃会话</div><div class="mo-val num">'+todayS.active_convs+'<em>个</em></div></div>',
    '<div class="mo"><div class="mo-label">最近一天消息</div><div class="mo-val num">'+todayS.msgs_total+'<em>条</em></div>'+
      '<div class="mo-bar"><div class="mo-fill" style="width:'+Math.min(100,todayS.msgs_total/50*100)+'%;background:#5B9BD5"></div></div></div>',
    '<div class="mo"><div class="mo-label">深夜占比</div><div class="mo-val num">'+todayS.late_night_pct+'<em>%</em></div>'+
      '<div class="mo-bar"><div class="mo-fill" style="width:'+Math.min(100,todayS.late_night_pct)+'%;background:'+(todayS.late_night_pct>50?'#E85D4E':'#7CB342')+'"></div></div></div>',
    '<div class="mo"><div class="mo-label">回复延迟</div><div class="mo-val num">'+(todayS.reply_latency_min!=null?todayS.reply_latency_min:'—')+'<em>分</em></div></div>'
  ].join('');

  if(state.stab==='trend'){
    var W = Math.max(dates.length*64+70, 560), H=240, PADL=36, PADR=16, PADT=16, PADB=30;
    var iw=W-PADL-PADR, ih=H-PADT-PADB, step=dates.length>1?iw/(dates.length-1):iw;
    var maxM = Math.max.apply(null, dates.map(function(d){return soc[d].msgs_total;}))||1;
    var g='';
    for(var gy=0;gy<=4;gy++){
      var yy=PADT+ih-(gy/4)*ih;
      g+='<line x1="'+PADL+'" y1="'+yy+'" x2="'+(W-PADR)+'" y2="'+yy+'" style="stroke:var(--line)"/>';
      g+='<text x="'+(PADL-6)+'" y="'+(yy+3)+'" font-size="9" style="fill:var(--ink-3)" text-anchor="end">'+Math.round(maxM*gy/4)+'</text>';
    }
    var pts=dates.map(function(d,i){return {x:PADL+i*step,y:PADT+ih-(soc[d].msgs_total/maxM)*ih};});
    var area='M'+pts[0].x+','+pts[0].y;
    for(var i=0;i<pts.length-1;i++){var cx=(pts[i].x+pts[i+1].x)/2; area+=' C'+cx+','+pts[i].y+' '+cx+','+pts[i+1].y+' '+pts[i+1].x+','+pts[i+1].y;}
    area+=' L'+pts[pts.length-1].x+','+(PADT+ih)+' L'+pts[0].x+','+(PADT+ih)+' Z';
    g+='<path d="'+area+'" fill="rgba(91,155,213,.12)"/>';
    var line=area.slice(0,area.lastIndexOf(' L'));
    g+='<path d="'+line+'" fill="none" stroke="#5B9BD5" stroke-width="2.4" stroke-linecap="round"/>';
    var pts2=dates.map(function(d,i){return {x:PADL+i*step,y:PADT+ih-(soc[d].late_night_pct/100)*ih};});
    var lp='M'+pts2[0].x+','+pts2[0].y;
    for(var j=0;j<pts2.length-1;j++){var cx2=(pts2[j].x+pts2[j+1].x)/2; lp+=' C'+cx2+','+pts2[j].y+' '+cx2+','+pts2[j+1].y+' '+pts2[j+1].x+','+pts2[j+1].y;}
    g+='<path d="'+lp+'" fill="none" stroke="#E85D4E" stroke-width="1.8" stroke-dasharray="5 4" stroke-linecap="round" opacity=".8"/>';
    dates.forEach(function(d,i){
      var x=PADL+i*step;
      g+='<circle cx="'+x+'" cy="'+pts[i].y+'" r="4" style="fill:var(--card);cursor:pointer" stroke="#5B9BD5" stroke-width="2" data-d="'+d+'"/>';
      g+='<circle cx="'+x+'" cy="'+pts2[i].y+'" r="3" fill="#fff" stroke="#E85D4E" stroke-width="1.5" data-d="'+d+'" style="cursor:pointer"/>';
      g+='<text x="'+x+'" y="'+(H-10)+'" font-size="9.5" style="fill:'+(d===DATA.today?'currentColor':'var(--ink-3)')+'" text-anchor="middle" font-weight="600">'+d.slice(5)+'</text>';
      g+='<rect x="'+(x-step/2)+'" y="'+PADT+'" width="'+step+'" height="'+ih+'" fill="transparent" data-d="'+d+'" style="cursor:pointer"/>';
    });
    scroll.innerHTML='<svg width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'">'+g+'</svg>';
    scroll.appendChild(tt);
    if(!scroll._tipScrollBound){
      scroll._tipScrollBound = true;
      scroll.addEventListener('scroll', function(){ tt.style.opacity=0; }, {passive:true});
    }
    [].slice.call(scroll.querySelectorAll('[data-d]')).forEach(function(el){
      var d=el.getAttribute('data-d'), v=soc[d]; if(!v) return;
      el.addEventListener('mouseenter', function(){
        tt.innerHTML='<b>'+parseInt(d.slice(0,4),10)+'年'+parseInt(d.slice(5,7),10)+'月'+parseInt(d.slice(8),10)+'日</b>'+
          '<div class="r"><span>消息</span><i>'+v.msgs_total+'（我'+v.msgs_sent+'）</i></div>'+
          '<div class="r"><span>会话</span><i>'+v.active_convs+' 个</i></div>'+
          '<div class="r"><span>深夜</span><i>'+v.late_night_pct+'%</i></div>'+
          '<div class="r"><span>延迟</span><i>'+(v.reply_latency_min!=null?v.reply_latency_min+' 分':'—')+'</i></div>';
        tt.style.opacity=1;
        var c=parseFloat(el.getAttribute('cx'))||0;
        tt.style.left=Math.min(Math.max(c,10),Math.max(10,scroll.scrollWidth-tt.offsetWidth-10))+'px';
        tt.style.top='8px';
      });
      el.addEventListener('mouseleave', function(){ tt.style.opacity=0; });
      el.addEventListener('click', function(){ setDate(d,true); });
    });
    var tot=dates.reduce(function(s,d){return s+soc[d].msgs_total;},0);
    var avgLate=+(dates.reduce(function(s,d){return s+soc[d].late_night_pct;},0)/dates.length).toFixed(1);
    var maxD=dates.reduce(function(a,b){return soc[b].msgs_total>soc[a].msgs_total?b:a;});
    stats.innerHTML=
      '<div class="cs"><div class="cs-num num">'+dates.length+'</div><div class="cs-label">有记录天数</div></div>'+
      '<div class="cs"><div class="cs-num num">'+tot+'</div><div class="cs-label">累计消息</div></div>'+
      '<div class="cs"><div class="cs-num num">'+avgLate+'%</div><div class="cs-label">平均深夜占比</div></div>'+
      '<div class="cs"><div class="cs-num num">'+soc[maxD].msgs_total+'</div><div class="cs-label">最多 · '+maxD.slice(5)+'</div></div>';
    note.textContent='蓝=消息量 · 红虚线=深夜占比(23:00-06:00) · 点日期看当天日记';
  } else if(state.stab==='cats'){
    // 情绪分类：我发出的消息意图分布
    var cats = todayS.cats_pct || {};
    var order = ['积极分享','玩笑调侃','倾诉求助','抱怨吐槽','事务沟通','其他'];
    var CATCOLOR = {'积极分享':'#7CB342','玩笑调侃':'#5B9BD5','倾诉求助':'#F5A04C','抱怨吐槽':'#E85D4E','事务沟通':'#A79C8C','其他':'#D8D0C4'};
    var hasCats = order.some(function(k){ return cats[k]!=null; });
    if(!hasCats || todayS.classify_note){
      scroll.innerHTML='<div class="empty" style="margin:16px 0;max-width:520px">今天暂无情绪分类'+(todayS.classify_note?'（'+esc(todayS.classify_note)+'）':'')+'</div>';
      scroll.appendChild(tt); tt.style.opacity=0;
      stats.innerHTML=''; note.textContent='';
      return;
    }
    var rows = order.filter(function(k){ return cats[k]!=null; }).map(function(k){
      var v = cats[k], col = CATCOLOR[k]||'#A79C8C';
      return '<div class="stage-row"><span class="sdot" style="background:'+col+'"></span><span class="sname">'+k+'</span><span class="scnt">'+v+'%</span>'+
        '<div class="strack"><div class="sfill" style="width:'+Math.min(100,v)+'%;background:'+col+'"></div></div></div>';
    }).join('');
    var tones = todayS.tones || {};
    var toneHtml = ['正面','中性','负面'].map(function(t){
      var n = tones[t]||0;
      return '<span class="chip'+(t==='负面'?' hl':'')+'">'+t+' '+n+' 条</span>';
    }).join('');
    scroll.innerHTML =
      '<div style="display:flex;gap:22px;flex-wrap:wrap;align-items:flex-start">'+
        '<div style="flex:1;min-width:260px;max-width:420px">'+
          '<div class="an-title">我发出的消息 · 沟通意图</div>'+rows+
        '</div>'+
        '<div style="flex:1;min-width:220px;max-width:320px">'+
          '<div class="an-title">情绪倾向（'+((todayS.classified||0))+' 条已分类）</div>'+
          '<div class="chip-row">'+toneHtml+'</div>'+
          '<div style="margin-top:12px" class="mini-stats" style="grid-template-columns:1fr">'+
            '<div class="mini"><b class="num" style="color:'+scColor+'">'+(sc!=null?sc:'—')+'</b><span>社交情绪分 /100</span></div>'+
          '</div>'+
        '</div>'+
      '</div>';
    scroll.appendChild(tt); tt.style.opacity=0;
    stats.innerHTML='';
    note.textContent='情绪分=5+(积极+玩笑−倾诉−抱怨)×4，深夜>60%再−1；基于我发出的消息，原文不留存';
  } else {
    var rows=(todayS.top_convs||[]).map(function(c,i){
      var nm = state.privacy ? ('好友'+(i+1)) : c.name;
      return '<div class="dt-row"><span class="site">'+esc(nm)+'</span><em>我'+c.sent+' · 对方'+c.recv+'</em></div>';
    }).join('') || '<div class="empty">今日无私聊</div>';
    scroll.innerHTML='<div class="dt-list" style="max-width:520px">'+rows+'</div>';
    scroll.appendChild(tt);
    tt.style.opacity=0;
    stats.innerHTML='';
    note.textContent='仅私聊 · 按消息量 TOP'+(todayS.top_convs||[]).length+(state.privacy?' · 演示模式已隐藏姓名':'');
  }
}


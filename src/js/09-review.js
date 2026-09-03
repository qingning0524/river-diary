'use strict';

/* ================= 月度回顾 ================= */
function reviewMonths(){
  var months = {};
  ENTRIES.forEach(function(e){
    var m = e.date.slice(0,7);
    if(!months[m]) months[m] = [];
    months[m].push(e);
  });
  return Object.keys(months).sort();
}

function renderReview(){
  var panel = $('dReviewPanel'); if(!panel) return;
  var sel = $('reviewMonth');
  var months = reviewMonths();
  if(!months.length){ panel.innerHTML = '<div class="review-empty">暂无数据可回顾</div>'; return; }

  if(!state.reviewMonth || months.indexOf(state.reviewMonth)<0) state.reviewMonth = months[months.length-1];
  var cur = state.reviewMonth;
  sel.innerHTML = months.map(function(m){
    var label = m.slice(0,4)+' 年 '+parseInt(m.slice(5),10)+' 月';
    return '<option value="'+m+'"'+(m===cur?' selected':'')+'>'+label+'</option>';
  }).join('');
  sel.onchange = function(){ state.reviewMonth = sel.value; renderReview(); };

  var monthEntries = ENTRIES.filter(function(e){ return e.date.slice(0,7)===cur; });
  var rated = monthEntries.filter(function(e){ return e.score!=null; });
  var avgScore = rated.length ? +(rated.reduce(function(s,e){return s+e.score;},0)/rated.length).toFixed(1) : null;
  var best = rated.length ? rated.reduce(function(a,b){ return b.score>a.score?b:a; }) : null;
  var worst = rated.length ? rated.reduce(function(a,b){ return b.score<a.score?b:a; }) : null;
  var steps = monthEntries.reduce(function(s,e){ return s+(e.ios_health&&e.ios_health.steps||0); },0);
  var sleeps = monthEntries.filter(function(e){ return e.ios_health&&e.ios_health.sleep_hours!=null; });
  var avgSleep = sleeps.length ? +(sleeps.reduce(function(s,e){return s+e.ios_health.sleep_hours;},0)/sleeps.length).toFixed(1) : null;
  var screenTotal = monthEntries.reduce(function(s,e){ return s+(e.screen_h||0); },0);

  var statsEl = $('reviewStats');
  statsEl.innerHTML =
    '<div class="rv-stat"><div class="rv-num num">'+monthEntries.length+'</div><div class="rv-lb">记录天数</div></div>'+
    '<div class="rv-stat"><div class="rv-num num">'+(avgScore!=null?avgScore:'—')+'</div><div class="rv-lb">平均心情</div></div>'+
    '<div class="rv-stat"><div class="rv-num num">'+(avgSleep!=null?avgSleep:'—')+'</div><div class="rv-lb">平均睡眠/h</div></div>'+
    '<div class="rv-stat"><div class="rv-num num">'+(screenTotal?screenTotal.toFixed(1):'—')+'</div><div class="rv-lb">屏幕时间/h</div></div>'+
    '<div class="rv-stat"><div class="rv-num num">'+(steps?steps.toLocaleString():'—')+'</div><div class="rv-lb">总步数</div></div>';

  // 日历热力图
  var calEl = $('reviewCalendar');
  var first = new Date(cur+'-01T00:00:00');
  var daysInMonth = new Date(first.getFullYear(), first.getMonth()+1, 0).getDate();
  var startDow = (first.getDay()+6)%7; // 周一=0
  var dayMap = {};
  monthEntries.forEach(function(e){
    var d = parseInt(e.date.slice(8),10);
    dayMap[d] = e;
  });
  var html = '<div class="rv-cal-week">'+['一','二','三','四','五','六','日'].map(function(d){return '<span>'+d+'</span>';}).join('')+'</div>';
  html += '<div class="rv-cal-grid">';
  for(var i=0;i<startDow;i++) html += '<span class="rv-cal-cell empty"></span>';
  for(var d=1;d<=daysInMonth;d++){
    var e = dayMap[d];
    var cls = 'rv-cal-cell'+(e?' has':'');
    var bg = '';
    var title = d+' 日';
    if(e){
      if(e.score!=null){ bg = ' style="background:'+mColor(e.score)+'33;border-color:'+mColor(e.score)+'66"'; title += ' · 心情 '+e.score; }
      else { bg = ' style="background:var(--line)"'; }
      title += e.ios_health&&e.ios_health.steps ? ' · '+e.ios_health.steps.toLocaleString()+' 步' : '';
    }
    html += '<span class="'+cls+'"'+bg+' title="'+title+'">'+(e?'<b>'+d+'</b>':d)+'</span>';
  }
  html += '</div>';
  calEl.innerHTML = html;

  // 月度亮点
  var hiEl = $('reviewHighlights');
  var tips = [];
  if(best) tips.push('最好的一天是 <b>'+fmtD(best.date)+'</b>（心情 '+best.score+'）');
  if(worst && worst!==best) tips.push('最低的一天是 <b>'+fmtD(worst.date)+'</b>（心情 '+worst.score+'）');
  var mostSteps = monthEntries.filter(function(e){return e.ios_health&&e.ios_health.steps;}).sort(function(a,b){return (b.ios_health.steps||0)-(a.ios_health.steps||0);})[0];
  if(mostSteps) tips.push('步数最多是 <b>'+fmtD(mostSteps.date)+'</b>（'+mostSteps.ios_health.steps.toLocaleString()+' 步）');
  if(!tips.length) tips.push('这个月的数据还不够丰富，继续记录吧 🌊');
  hiEl.innerHTML = '<div class="rv-hl"><span class="rv-hl-icon">✨</span><div>'+tips.join('</div><div class="rv-hl"><span class="rv-hl-icon">·</span><div>')+'</div></div>';
}

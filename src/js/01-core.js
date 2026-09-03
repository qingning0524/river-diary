
'use strict';
/* ================= 数据 ================= */
if('scrollRestoration' in history){ history.scrollRestoration = 'manual'; }
var DATA = null;
var ENTRIES = [];
var BYDATE = {};
var TODAY = '';
var DATA_URL = 'data/data.json';

var METRICS = [
  {key:'mood',    label:'心情', color:'#7CB342'},
  {key:'energy',  label:'精力', color:'#D4A017'},
  {key:'focus',   label:'专注', color:'#F5A04C'},
  {key:'output',  label:'产出', color:'#5B9BD5'},
  {key:'overall', label:'综合', color:'currentColor'}
];
var STAGES = [
  {label:'低谷', color:'#E85D4E'}, {label:'回升', color:'#F5A04C'},
  {label:'平稳', color:'#D4A017'}, {label:'积极', color:'#7CB342'},
  {label:'饱满', color:'#5B9BD5'}
];
var WORK_CATS = {work:1, study:1, env:1, self:1};   // 计入「工作侧」的事项类别
var CAT_DISPLAY = {
  work:  {emoji:'💼', label:'工作项目'},
  study: {emoji:'📚', label:'学习研究'},
  env:   {emoji:'🛠', label:'环境效率'},
  fun:   {emoji:'🎬', label:'娱乐休息'},
  hobby: {emoji:'🎸', label:'兴趣爱好'},
  life:  {emoji:'🌸', label:'生活日常'},
  self:  {emoji:'🧘', label:'自我管理'}
};
var NOISE_KEYS = {screen:1, browse:1, hermes:1, workbuddy:1};   // 原始数据类目：展示模式下默认折叠

/* ================= 工具 ================= */
function $(id){ return document.getElementById(id); }
function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }
function trapDialogFocus(overlay, ev){
  var focusables = [].slice.call(overlay.querySelectorAll('a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'))
    .filter(function(el){ return el.getClientRects().length > 0; });
  if(!focusables.length){ ev.preventDefault(); return; }
  var first = focusables[0], last = focusables[focusables.length-1];
  if(ev.shiftKey && document.activeElement === first){ ev.preventDefault(); last.focus(); }
  else if(!ev.shiftKey && (document.activeElement === last || !overlay.contains(document.activeElement))){ ev.preventDefault(); first.focus(); }
}
function mdText(s){ // 转义 + 渲染 markdown 链接与粗体 + 保留换行
  if(!s) return '';
  s = esc(s);
  s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  s = s.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
  s = s.replace(/\n/g, '<br>');
  return s;
}
function fmtD(d){ return d ? d.slice(5,7)+'/'+d.slice(8,10) : ''; }
function scrollToId(id){
  var el = document.getElementById(id);
  if(!el) return;
  var header = document.querySelector('.top');
  var offset = header ? header.getBoundingClientRect().height + 12 : 74;
  var top = el.getBoundingClientRect().top + (window.scrollY || window.pageYOffset || 0) - offset;
  var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  window.scrollTo({ top: Math.max(0, top), behavior: reduced ? 'auto' : 'smooth' });
}
var WDN = ['周日','周一','周二','周三','周四','周五','周六'];
function wdOf(d){ try{ return new Date(d+'T00:00:00').getDay(); }catch(e){ return 0; } }

/* ============ 塔罗：由"今天所见所行"推一张牌（本地产出并缓存，离线可用，不反复取图） ============ */
var ARCANAS = [
  {n:'0',    en:'The Fool',       cn:'愚者',   c:'#8A6DE9', gl:'★', mean:'空白的新开始'},
  {n:'I',    en:'The Magician',   cn:'魔术师', c:'#E2623A', gl:'✦', mean:'把拥有的都点亮'},
  {n:'II',   en:'High Priestess', cn:'女祭司', c:'#4A8FDF', gl:'☽', mean:'答案在安静里'},
  {n:'III',  en:'The Empress',    cn:'女皇',   c:'#3E9B6C', gl:'✿', mean:'滋养与丰盛在生长'},
  {n:'IV',   en:'The Emperor',    cn:'皇帝',   c:'#B46A2B', gl:'♛', mean:'秩序与担当'},
  {n:'V',    en:'The Hierophant', cn:'教皇',   c:'#5B7FD4', gl:'⚶', mean:'向老师与规则借力'},
  {n:'VI',   en:'The Lovers',     cn:'恋人',   c:'#E05D8C', gl:'⚭', mean:'一次郑重的选择'},
  {n:'VII',  en:'The Chariot',    cn:'战车',   c:'#D0A72E', gl:'♈', mean:'勇敢地出发'},
  {n:'VIII', en:'Strength',       cn:'力量',   c:'#D9782E', gl:'♌', mean:'温柔地驯服内心'},
  {n:'IX',   en:'The Hermit',     cn:'隐士',   c:'#6E5CC0', gl:'◐', mean:'独自点一盏灯'},
  {n:'X',    en:'Wheel of Fortune', cn:'命运之轮', c:'#2E86D0', gl:'☸', mean:'转机正靠近'},
  {n:'XI',   en:'Justice',        cn:'正义',   c:'#6A8E3B', gl:'⚖', mean:'因果回到正轨'},
  {n:'XII',  en:'The Hanged Man', cn:'倒吊人', c:'#7E8AA8', gl:'☓', mean:'换个方向就不同'},
  {n:'XIII', en:'Death',          cn:'死神',   c:'#7A4A8E', gl:'✝', mean:'结束是新生的入口'},
  {n:'XIV',  en:'Temperance',     cn:'节制',   c:'#3E9BB0', gl:'⏚', mean:'调和，慢而稳'},
  {n:'XV',   en:'The Devil',      cn:'恶魔',   c:'#B5425A', gl:'⛓', mean:'欲望在拖住你'},
  {n:'XVI',  en:'The Tower',      cn:'高塔',   c:'#D06A3B', gl:'⚡', mean:'震一次，重建地基'},
  {n:'XVII', en:'The Star',       cn:'星星',   c:'#4E8BDD', gl:'✶', mean:'在平静里重新相信'},
  {n:'XVIII',en:'The Moon',       cn:'月亮',   c:'#8A8FC0', gl:'☾', mean:'看不清时别急着判断'},
  {n:'XIX',  en:'The Sun',        cn:'太阳',   c:'#E8A93D', gl:'☀', mean:'明亮，直接，有力量'},
  {n:'XX',   en:'Judgement',      cn:'审判',   c:'#C77A3B', gl:'☉', mean:'被听到了，可以醒了'},
  {n:'XXI',  en:'The World',      cn:'世界',   c:'#3E7B5A', gl:'✶', mean:'一段圆满，起身前行'}
];
var TAROT_CACHE = {};
function hashTarot(e){
  var s = (e.date||'')
    + (e.score==null?'':':'+e.score)
    + ((e.metrics&&e.metrics.growth==null)?'':(e.metrics?','+e.metrics.growth:''))
    + (e.stage?e.stage.label:'')
    + (e.overview||'')+(e.mood||'')+(e.plan||'')+((e.tags||[]).join(','));
  var h = 0; for(var i=0;i<s.length;i++){ h = (h*31 + s.charCodeAt(i)) >>> 0; }
  return h;
}
function tarotPick(e){
  var arc = ARCANAS[hashTarot(e) % ARCANAS.length];
  var dir = (e.score!=null && e.score<55) ? 'rev' : 'up';
  return { arc: arc, dir: dir, key: arc.n + (dir==='rev' ? 'R' : 'U') };
}
function buildTarot(e){
  var tp = tarotPick(e);
  if(TAROT_CACHE[tp.key]) return TAROT_CACHE[tp.key];
  var arc = tp.arc, dir = tp.dir;
  var html =
    '<div class="tcard'+(dir==='rev' ? ' rev' : '')+'" style="--tc:'+arc.c+'" title="'+esc(arc.en)+' · '+arc.mean+'">'
    +'<div class="tc-top"><span class="tc-num">'+arc.n+'</span><span class="tc-en">'+esc(arc.en.toUpperCase())+'</span></div>'
    +'<div class="tc-emblem">'+arc.gl+'</div>'
    +'<div class="tc-name">'+arc.cn+'</div>'
    +'<div class="tc-means">'+arc.mean+'</div>'
    +'<div class="tc-dir">'+(dir==='up'?'正位':'逆位')+'</div>'
    +'</div>';
  TAROT_CACHE[tp.key] = html;
  return html;
}
function fmtW(d){ return WDN[wdOf(d)]; }
function fmtFull(d){ if(!d) return ''; var t=d.split('-'); return parseInt(t[1],10)+'月'+parseInt(t[2],10)+'日'; }
function fmtMin(min){ if(!min) return '0m'; var h=Math.floor(min/60), m=Math.round(min%60); return (h? h+'h ':'') + (m? m+'m':''); }
function mColor(v){ return v>=70?'#7CB342':(v>=50?'#D4A017':(v>=30?'#F5A04C':'#E85D4E')); }
function idxOf(date){ for(var i=0;i<ENTRIES.length;i++) if(ENTRIES[i].date===date) return i; return -1; }
function prevEntry(date){ var i=idxOf(date); return i>0 ? ENTRIES[i-1] : null; }
function nextEntry(date){ var i=idxOf(date); return (i>=0 && i<ENTRIES.length-1) ? ENTRIES[i+1] : null; }
function screenTotal(e){ var s=0; (e.screen_apps||[]).forEach(function(a){ s+=a.min||0; }); return s || Math.round((e.screen_h||0)*60); }
function browseTotal(e){ var s=0; (e.browse_sites||[]).forEach(function(b){ s+=b.n||0; }); return s || (e.views||0); }
function cleanSiteName(site){
  return String(site==null?'':site)
    .replace(/^\[([^]]+)\]\([^)]*$/, '$1')
    .replace(/^https?:\/\//, '')
    .replace(/\/+$/, '');
}

/* ================= 随笔解读引擎（关键词情绪/主题分析） ================= */
var MEMO_LEX = {
  pos: ['开心','高兴','快乐','幸福','满足','轻松','平静','踏实','充实','希望','期待','振奋','治愈','温暖','舒服','顺利','突破','进步','好起来','欣慰','元气','热情','兴奋','畅快','释然','有劲','通透','投入','专注','成就感'],
  neg: ['疲惫','好累','太累','心累','焦虑','难过','伤心','痛苦','崩溃','失落','迷茫','孤独','害怕','恐惧','担心','烦躁','压力','失眠','哭','泪','痛','折磨','无奈','无助','麻木','空虚','低落','抑郁','煎熬','透支','沮丧','消沉','硬撑','挣扎','无力','困','昏睡','心慌','死心','无法投入','静不下','心乱','内耗','五味杂陈'],
  mixed: ['回忆','想念','思念','怀念','想起','失去','放下','和解','坚持','努力','振作','重新开始','成长','改变','接受','释怀','支撑','扛','熬','希望','期待'],
  themes: {
    '工作学习': ['工作','代码','开发','项目','学习','文档','客户','接单','创业','调研','效率','工具','AI','设计','脚本','发布','方案','需求','上线'],
    '娱乐': ['游戏','视频','刷','B站','番','剧','音乐','网易云','吉他','练琴','谱','电影','steam','暖雪','单曲','综艺'],
    '生活健康': ['出门','散步','睡觉','睡眠','失眠','吃饭','外卖','锻炼','身体','理发','公园','超市','休息','放假','作息','起床','煮'],
    '情感': ['回忆','想念','分手','感情','前任','失去','放下','思念','怀念','离开','错过','重逢'],
    '自我调整': ['复盘','反思','计划','目标','状态','心情','调整','自律','改变','成长','坚持','振作','重新开始']
  }
};
function memoHits(ws, t){ var n=0; for(var i=0;i<ws.length;i++){ var idx=t.indexOf(ws[i]); while(idx>-1){ n++; idx=t.indexOf(ws[i], idx+ws[i].length); } } return n; }
function escRe(s){ return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function memoParts(x){
  var s = String(x==null?'':x);
  var title = '', body = s;
  var m = s.match(/^(?:随笔|备忘录|小记|今日)?\s*「([^」]+)」\s*[:：]\s*/);
  if(m){ title = m[1]; body = s.slice(m[0].length); }
  if(title){
    var re = new RegExp('^\\s*' + escRe(title) + '[\\s\\n:：]*');
    body = body.replace(re, '');
  }
  return {title: title, body: body};
}
function memoCleanText(x){ return memoParts(x).body; }
function memoSummary(x, maxLen){
  var s = memoCleanText(x).replace(/\s+/g,' ').trim();
  var first = s.split(/[。！？!?；;\n…]+/)[0] || s;
  first = first.trim();
  if(first.length > (maxLen||56)) first = first.slice(0, (maxLen||56)) + '…';
  return first;
}
function memoKeySentences(t, maxN){
  var parts = t.replace(/[。！？!?；;\n…]+/g,'|').split('|').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>=6; });
  var scored = parts.map(function(s){
    var sc = (memoHits(MEMO_LEX.pos,s)+memoHits(MEMO_LEX.neg,s)+memoHits(MEMO_LEX.mixed,s))*3;
    Object.keys(MEMO_LEX.themes).forEach(function(k){ sc += memoHits(MEMO_LEX.themes[k],s); });
    sc += Math.min(s.length, 50)*0.08;
    return {s:s, sc:sc};
  }).sort(function(a,b){ return b.sc-a.sc; });
  return scored.slice(0, maxN).map(function(x){ return x.s; });
}
var NEG_PRE = ['没有','没能','未能','不再','不曾','无法','很难','再也','难有','找不到','缺乏','缺少','缺失'];
function sentiCount(list, t){
  var n=0, neg=0;
  var sents = t.split(/[。！？!?；;\n…，,]+/);
  list.forEach(function(w){
    sents.forEach(function(s){
      if(s.indexOf(w)>-1){
        var bad = NEG_PRE.some(function(np){ return s.indexOf(np)>-1; });
        if(bad) neg++; else n++;
      }
    });
  });
  return {n:n, neg:neg};
}
function tagScan(list, t, max){
  var m={};
  var sents = t.split(/[。！？!?；;\n…，,]+/);
  list.forEach(function(w){
    sents.forEach(function(s){
      if(s.indexOf(w)>-1){
        var bad = NEG_PRE.some(function(np){ return s.indexOf(np)>-1; });
        if(!bad) m[w]=(m[w]||0)+1;
      }
    });
  });
  return Object.keys(m).sort(function(a,b){ return m[b]-m[a]; }).slice(0,max);
}
function analyzeMemo(t){
  t = t||'';
  var posR = sentiCount(MEMO_LEX.pos, t), negR = sentiCount(MEMO_LEX.neg, t);
  var pos = posR.n + negR.neg, neg = negR.n + posR.neg;  // 被否定的积极词计为负面，反之亦然
  var tone = (pos>0 && neg>0) ? '复杂' : (neg>pos ? '低落' : (pos>0 ? '积极' : '平静'));
  var negTags = tagScan(MEMO_LEX.neg, t, 2), posTags = tagScan(MEMO_LEX.pos, t, 2);
  var tags = negTags.concat(posTags).slice(0,3);
  var themes = Object.keys(MEMO_LEX.themes).map(function(k){ return {k:k, n:memoHits(MEMO_LEX.themes[k], t)}; })
    .filter(function(x){ return x.n>0; }).sort(function(a,b){ return b.n-a.n; }).slice(0,3).map(function(x){ return x.k; });
  var energy = memoHits(['疲惫','好累','太累','心累','失眠','透支','熬','昏睡','困'], t)>0 ? '精力偏低'
    : (memoHits(['充实','精神','旺盛','兴奋','元气','有劲'], t)>0 ? '精力在线' : '');
  var interp;
  if(tone==='低落') interp = '今天的情绪基调偏低沉，文字里流露出「'+(negTags.join('、')||'疲惫与消耗')+'」的感觉；不过愿意把这些写下来，本身就是一种自我接住。';
  else if(tone==='积极') interp = '今天的状态在线，文字里有明显的积极能量——「'+(posTags.join('、')||'好状态')+'」，行动力和心气都在。';
  else if(tone==='复杂') interp = '情绪有明显的拉扯感：既有「'+(negTags[0]||'疲惫')+'」的低落，也有「'+(posTags[0]||'期待')+'」的期许，处在调整与坚持的中间态。';
  else interp = '情绪平稳，没有大的起伏，是一段安定的记录。';
  return {tone:tone, tags:tags, themes:themes, energy:energy, interp:interp, keys:memoKeySentences(t,2)};
}
function countUp(el, to, dur){
  if(!el || to==null) return;
  if(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches){ el.textContent = to; return; }
  var t0 = null, d = dur||420;
  function step(ts){
    if(!t0) t0 = ts;
    var p = Math.min(1, (ts-t0)/d), eased = 1 - Math.pow(1-p, 3);
    el.textContent = Math.round(to*eased);
    if(p<1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}
/**
 * 把 AI 读出的评分转成“粗分位”文字（诚实化，避免 0-100 假精确）
 */
function bandLabel(v){
  if(v==null) return '';
  if(v>=85) return '旺盛';
  if(v>=70) return '良好';
  if(v>=50) return '中等';
  if(v>=30) return '偏低';
  return '低谷';
}

/* ================= 状态 ================= */
var state = { date: null, dcat: 'overview', month: '', dtab: 'mood', tab: 'score', stab: 'trend', privacy: true, showMore: false, legend: {mood:true,energy:false,focus:false,output:false,overall:false}, q: '', stage: '', tag: '', cal: null, reviewMonth: null };

function latestDate(){ return ENTRIES.length ? ENTRIES[ENTRIES.length-1].date : null; }
function initState(){
  var m = location.hash.match(/date=(\d{4}-\d{2}-\d{2})/);
  if(m && BYDATE[m[1]]) state.date = m[1];
  else state.date = latestDate();
  var mt = location.hash.match(/tab=([a-z-]+)/);
  if(mt && ['overview','thoughts','memos','learn-work','fun-rest','health','plan','meta'].indexOf(mt[1])>-1) state.dcat = mt[1];
  var now = TODAY ? new Date(TODAY+'T00:00:00') : new Date();
  state.cal = { y: now.getFullYear(), m: now.getMonth() };
}
function setDate(d, scroll){
  if(!d || !BYDATE[d]) return;
  // 修复：之前这里没有 View Transition，日期切换是生硬的重渲染
  // 现在用 _v3Wrap 包裹 renderMain，让 hero/sparkline 平滑过渡
  if(state.date === d) return; // 没变化，不重渲染
  state.date = d;
  try{ history.replaceState(null,'','#date='+d+'&tab='+(state.dcat||'overview')); }catch(e){}
  if(typeof _v3Wrap === 'function'){
    _v3Wrap(function(){ renderMain(); });
  } else {
    renderMain();
  }
  if(scroll){ scrollToId('hero'); }
}
function applyFilters(){
  var q = state.q.trim().toLowerCase();
  return ENTRIES.filter(function(e){
    if(state.stage && e.stage.label !== state.stage) return false;
    if(state.tag && e.tags.indexOf(state.tag) < 0) return false;
    if(state.month && e.date.slice(0,7) !== state.month) return false;
    if(q){
      var hay = [e.date, e.title, e.daily, e.overview, e.mood, e.plan, e.workbuddy, e.status]
        .concat(e.thoughts||[]).concat(e.memos||[]).concat(e.hermes_logs||[])
        .concat((e.did||[]).map(function(g){ return g.sub+' '+g.items.join(' '); }))
        .join(' ').toLowerCase();
      if(hay.indexOf(q) < 0) return false;
    }
    return true;
  });
}

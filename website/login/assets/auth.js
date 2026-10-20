/* 河流日记 · 登录页逻辑
   会话通过 Domain=.flowriver.xyz 的首方 Cookie 与 user.flowriver.xyz 共享。 */
(function () {
  "use strict";

  var API = "/v1";
  var USER_HOME = "https://user.flowriver.xyz/";
  var SESSION_COOKIE = "fr_session";
  var flowRevision = 0;

  var appearance = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  var chosenTheme = null;
  try { chosenTheme = localStorage.getItem('flowriver.site.theme'); } catch (_) {}
  function applyAppearance(theme) {
    document.documentElement.dataset.theme = theme;
    var button = document.getElementById('login-theme');
    if (button) { button.textContent = theme === 'dark' ? '浅色' : '深色'; button.setAttribute('aria-label', theme === 'dark' ? '切换浅色外观' : '切换深色外观'); }
  }
  applyAppearance(chosenTheme === 'light' || chosenTheme === 'dark' ? chosenTheme : appearance && appearance.matches ? 'dark' : 'light');
  var themeControl = document.getElementById('login-theme');
  if (themeControl) themeControl.addEventListener('click', function () { chosenTheme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'; applyAppearance(chosenTheme); try { localStorage.setItem('flowriver.site.theme', chosenTheme); } catch (_) {} });
  if (appearance && appearance.addEventListener) appearance.addEventListener('change', function () { if (chosenTheme !== 'light' && chosenTheme !== 'dark') applyAppearance(appearance.matches ? 'dark' : 'light'); });

  /* ---------- 基础工具 ---------- */

  function $(id) { return document.getElementById(id); }

  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    var b = new Uint8Array(16);
    crypto.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var hex = Array.prototype.map.call(b, function (x) { return ("0" + x.toString(16)).slice(-2); }).join("");
    return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
  }

  // 每个资料 Profile 一个稳定实例标识(与服务端设备模型一致)
  function instanceId() {
    var key = "fr_web_instance";
    var v = null;
    try { v = localStorage.getItem(key); } catch (e) { /* ignore */ }
    if (!v) {
      v = uuid();
      try { localStorage.setItem(key, v); } catch (e) { /* ignore */ }
    }
    return v;
  }

  function deviceName() {
    var ua = navigator.userAgent;
    var browser = "网页";
    if (/Edg\//.test(ua)) browser = "网页 · Edge";
    else if (/Chrome\//.test(ua)) browser = "网页 · Chrome";
    else if (/Firefox\//.test(ua)) browser = "网页 · Firefox";
    else if (/Safari\//.test(ua)) browser = "网页 · Safari";
    if (/iPhone/.test(ua)) browser += " iOS"; else if (/Macintosh/.test(ua)) browser += " macOS"; else if (/Windows/.test(ua)) browser += " Windows";
    return browser.slice(0, 80);
  }

  // 幂等键:同一挑战的重试复用同一键;成功后清除
  function idemKey(scope, seed) {
    var key = "fr_idem_" + scope + "_" + seed;
    var v = null;
    try { v = sessionStorage.getItem(key); } catch (e) { /* ignore */ }
    if (!v) {
      v = uuid();
      try { sessionStorage.setItem(key, v); } catch (e) { /* ignore */ }
    }
    return { value: v, done: function () { try { sessionStorage.removeItem(key); } catch (e) { /* ignore */ } } };
  }

  /* ---------- 会话 Cookie(跨子域共享) ---------- */

  function setSession(data) {
    var payload = {
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      revoke_token: data.revoke_token,
      expires_in: data.expires_in,
      expires_at: Date.now() + Number(data.expires_in || 0) * 1000,
      client_instance_id: instanceId(),
      user: data.user || null,
      device: data.device || null
    };
    var raw = encodeURIComponent(JSON.stringify(payload));
    // 30 天上限;过期后由刷新流程或记忆控制台处理
    document.cookie = SESSION_COOKIE + "=" + raw + "; Domain=.flowriver.xyz; Path=/; Max-Age=" + 60 * 60 * 24 * 30 + "; Secure; SameSite=Lax";
  }

  function readSession() {
    var parts = document.cookie.split(/;\s*/);
    for (var i = 0; i < parts.length; i++) {
      var eq = parts[i].indexOf("=");
      if (eq < 0) continue;
      if (parts[i].slice(0, eq) === SESSION_COOKIE) {
        try { return JSON.parse(decodeURIComponent(parts[i].slice(eq + 1))); } catch (e) { return null; }
      }
    }
    return null;
  }

  /* ---------- 请求封装 ---------- */

  function post(path, body, extraHeaders) {
    var revision = flowRevision;
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, 20000);
    return fetch(API + path, { method: 'POST', signal: controller.signal, cache: 'no-store', headers: Object.assign({ 'Content-Type': 'application/json', Accept: 'application/json' }, extraHeaders || {}), body: JSON.stringify(body) })
      .then(function (res) { return res.text().then(function (text) { var data = null; try { data = text ? JSON.parse(text) : null; } catch (_) {} return { status: res.status, ok: res.ok, data: data, stale: revision !== flowRevision }; }); })
      .catch(function (error) { if (revision !== flowRevision) throw new DOMException('登录方式已切换', 'FlowChanged'); throw error; })
      .finally(function () { clearTimeout(timer); });
  }

  function friendly(status, code) {
    var map = {
      rate_limited: "操作太频繁了,请等一分钟再试。",
      invalid_request: "提交的内容有误,请检查后重试。",
      invalid_credentials: "邮箱或密码不正确。",
      idempotency_conflict: "登录内容发生变化，请再次提交当前内容。",
      idempotency_key_reused: "请求内容发生变化，请再次提交。",
      invalid_or_expired_challenge: "验证码无效或已过期，请重新获取。",
      challenge_expired: "验证码已过期,请重新发送。",
      too_many_attempts: "尝试次数过多,请重新获取验证码。",
      challenge_not_found: "验证码已失效,请重新发送。",
      email_provider_unavailable: "邮件服务暂时不可用,请稍后再试;若持续失败请联系 account@mail.flowriver.xyz。",
      terms_required: "需要先阅读并同意服务条款与隐私政策。",
      password_policy: "密码需为 15–128 个字符,不能包含邮箱地址或常见密码。",
      common_password_rejected: "这个密码太常见了,请换一个更长的短语。",
      weak_password: "密码需为 15–128 个字符,不能包含邮箱地址或常见密码。",
      temporarily_unavailable: "服务暂时不可用,请稍后再试。"
    };
    if (map[code]) return map[code];
    if (status === 429) return map.rate_limited;
    if (status === 0) return "网络连接失败,请检查网络后重试。";
    return "请求未完成(" + (code || status) + "),请稍后再试。";
  }

  /* ---------- UI ---------- */

  var statusEl = $("status");
  var statusTimer = null;

  function showStatus(kind, text, sticky) {
    statusEl.className = "status show " + kind;
    statusEl.textContent = text;
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    if (!sticky && kind !== "error") {
      statusTimer = setTimeout(function () { statusEl.className = "status"; }, 6000);
    }
  }

  var busyControls = new WeakMap();
  function busy(btn, on) {
    if (on) {
      var form = btn.closest ? btn.closest('form') : null;
      var controls = form ? Array.from(form.querySelectorAll('input,button,select')).map(function (el) { return { el: el, disabled: el.disabled }; }) : [];
      busyControls.set(btn, controls); controls.forEach(function (item) { item.el.disabled = true; });
      btn.dataset.label = btn.textContent; btn.disabled = true; btn.textContent = '处理中…';
    } else {
      var controls = busyControls.get(btn) || [];
      controls.forEach(function (item) { item.el.disabled = item.disabled; }); busyControls.delete(btn);
      btn.disabled = false; btn.textContent = btn.dataset.label || btn.textContent;
    }
  }

  var views = ["form-code-email", "form-code-verify", "form-password", "form-reset-email", "form-reset-complete"];

  function show(view) {
    views.forEach(function (v) { $(v).hidden = v !== view; });
    $("aux-password-entry").hidden = true;
    // 任何密码/reset 表单都展示返回入口
    if (view === "form-reset-email" || view === "form-reset-complete") {
      $("aux-password-entry").hidden = false;
    }
  }

  function selectTab(which) {
    flowRevision += 1;
    $("tab-code").setAttribute("aria-selected", which === "code" ? "true" : "false");
    $("tab-password").setAttribute("aria-selected", which === "password" ? "true" : "false");
    show(which === "code" ? "form-code-email" : "form-password");
  }

  $("tab-code").addEventListener("click", function () { selectTab("code"); });
  $("tab-password").addEventListener("click", function () { selectTab("password"); });

  Array.prototype.forEach.call(document.querySelectorAll("[data-back]"), function (b) {
    b.addEventListener("click", function () { selectTab("code"); });
  });

  /* ---------- 验证码登录 / 注册 ---------- */

  var pendingChallenge = null;
  var resendTimer = null;

  function startResendCountdown() {
    if (resendTimer) clearInterval(resendTimer);
    var btn = $("btn-resend");
    var n = 60;
    btn.disabled = true;
    $("resend-count").textContent = "（" + n + "s）";
    resendTimer = setInterval(function () {
      n -= 1;
      $("resend-count").textContent = "（" + n + "s）";
      if (n <= 0) { clearInterval(resendTimer); btn.disabled = false; $("resend-count").textContent = "";  }
    }, 1000);
  }

  function sendCode(email, isResend) {
    var btn = isResend ? $("btn-resend") : $("btn-send-code");
    if (btn.disabled) return;
    if (isResend) btn.disabled = true;
    else busy(btn, true);
    post("/auth/email/start", { email: email }).then(function (res) {
      if (res.stale) { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      if (!isResend) busy(btn, false); else btn.disabled = false;
      if (res.status === 202 && res.data && res.data.challenge_id) {
        pendingChallenge = res.data.challenge_id;
        $("code-email-echo").textContent = email;
        show("form-code-verify");
        $("code-input").value = "";
        $("code-input").focus();
        showStatus("info", "验证码已发送,请查收邮箱(注意垃圾箱)。", false);
        startResendCountdown();
      } else {
        showStatus("error", friendly(res.status, res.data && res.data.error), true);
      }
    }).catch(function (error) {
      if (error && error.name === "FlowChanged") { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      if (!isResend) busy(btn, false); else btn.disabled = false;
      showStatus("error", friendly(0), true);
    });
  }

  $("form-code-email").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var email = $("code-email").value.trim();
    if (!email || email.indexOf("@") < 1) { showStatus("error", "请输入有效的邮箱地址。", true); return; }
    sendCode(email, false);
  });

  $("btn-resend").addEventListener("click", function () {
    var email = $("code-email").value.trim();
    if (email) sendCode(email, true);
  });

  $("form-code-verify").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var code = $("code-input").value.replace(/\D/g, "");
    if (code.length !== 8) { showStatus("error", "请输入 8 位数字验证码。", true); return; }
    if (!$("agree-check").checked) { showStatus("error", "请先阅读并同意服务条款与隐私政策。", true); return; }
    if (!pendingChallenge) { show("form-code-email"); return; }
    var btn = $("btn-verify");
    if (btn.disabled) return;
    busy(btn, true);
    var idem = idemKey("verify", pendingChallenge);
    post("/auth/email/verify", {
      challenge_id: pendingChallenge,
      code: code,
      client_instance_id: instanceId(),
      platform: "other",
      device_name: deviceName(),
      accept_terms: true
    }, { "Idempotency-Key": idem.value }).then(function (res) {
      if (res.stale) { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      if (res.ok && res.data && res.data.access_token) {
        idem.done();
        setSession(res.data);
        showStatus("ok", res.data.created ? "账号已创建,正在进入记忆控制台…" : "登录成功,正在进入记忆控制台…", true);
        setTimeout(function () { window.location.href = USER_HOME; }, 600);
      } else {
        busy(btn, false);
        if (res.data && /expired|not_found/i.test(String(res.data.error || ""))) { pendingChallenge = null; show("form-code-email"); }
        showStatus("error", friendly(res.status, res.data && res.data.error), true);
      }
    }).catch(function (error) {
      if (error && error.name === "FlowChanged") { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      busy(btn, false);
      showStatus("error", friendly(0), true);
    });
  });

  /* ---------- 密码登录 ---------- */

  $("form-password").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var email = $("pw-email").value.trim();
    var password = $("pw-input").value;
    if (!email || !password) { showStatus("error", "请输入邮箱与密码。", true); return; }
    var btn = $("btn-pw-login");
    if (btn.disabled) return;
    busy(btn, true);
    var idem = idemKey("pwlogin", email);
    post("/auth/password/login", {
      email: email,
      password: password,
      client_instance_id: instanceId(),
      platform: "other",
      device_name: deviceName()
    }, { "Idempotency-Key": idem.value }).then(function (res) {
      if (res.stale) { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      if (res.ok && res.data && res.data.access_token) {
        idem.done();
        setSession(res.data);
        showStatus("ok", "登录成功,正在进入记忆控制台…", true);
        setTimeout(function () { window.location.href = USER_HOME; }, 600);
      } else {
        busy(btn, false);
        if (res.status >= 400 && res.status < 500 && res.status !== 429) idem.done();
        showStatus("error", friendly(res.status, res.data && res.data.error), true);
      }
    }).catch(function (error) {
      if (error && error.name === "FlowChanged") { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      busy(btn, false);
      showStatus("error", friendly(0), true);
    });
  });

  /* ---------- 找回 / 设置密码 ---------- */

  var resetChallenge = null;

  $("btn-forgot").addEventListener("click", function () {
    flowRevision += 1;
    show("form-reset-email");
    $("reset-email").value = $("pw-email").value.trim();
    statusEl.className = "status";
  });

  $("form-reset-email").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var email = $("reset-email").value.trim();
    if (!email || email.indexOf("@") < 1) { showStatus("error", "请输入有效的邮箱地址。", true); return; }
    var btn = $("btn-reset-send");
    if (btn.disabled) return;
    busy(btn, true);
    post("/auth/password/reset/start", { email: email }).then(function (res) {
      if (res.stale) { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      busy(btn, false);
      if (res.status === 202 && res.data && res.data.challenge_id) {
        resetChallenge = res.data.challenge_id;
        show("form-reset-complete");
        $("reset-code").focus();
        showStatus("info", "验证码已发送,请查收邮箱(注意垃圾箱)。", false);
      } else {
        showStatus("error", friendly(res.status, res.data && res.data.error), true);
      }
    }).catch(function (error) {
      if (error && error.name === "FlowChanged") { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      busy(btn, false);
      showStatus("error", friendly(0), true);
    });
  });

  $("form-reset-complete").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var code = $("reset-code").value.replace(/\D/g, "");
    var pw = $("reset-password").value.normalize("NFC");
    if (code.length !== 8) { showStatus("error", "请输入 8 位数字验证码。", true); return; }
    if (Array.from(pw).length < 15 || Array.from(pw).length > 128 || new TextEncoder().encode(pw).length > 512 || !pw.trim()) { showStatus("error", "新密码需为 15–128 个字符(可包含空格的长短语)。", true); return; }
    if (!resetChallenge) { show("form-reset-email"); return; }
    var btn = $("btn-reset-complete");
    if (btn.disabled) return;
    busy(btn, true);
    var idem = idemKey("reset", resetChallenge);
    post("/auth/password/reset/complete", {
      challenge_id: resetChallenge,
      code: code,
      new_password: pw,
      client_instance_id: instanceId(),
      platform: "other",
      device_name: deviceName()
    }, { "Idempotency-Key": idem.value }).then(function (res) {
      if (res.stale) { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      if (res.ok && res.data && res.data.access_token) {
        idem.done();
        setSession(res.data);
        showStatus("ok", "密码已更新,正在进入记忆控制台…", true);
        setTimeout(function () { window.location.href = USER_HOME; }, 600);
      } else {
        busy(btn, false);
        if (res.status >= 400 && res.status < 500 && res.status !== 429) idem.done();
        showStatus("error", friendly(res.status, res.data && res.data.error), true);
      }
    }).catch(function (error) {
      if (error && error.name === "FlowChanged") { if (btn.id === "btn-resend") btn.disabled = false; else busy(btn, false); return; }
      busy(btn, false);
      showStatus("error", friendly(0), true);
    });
  });

  /* ---------- 入口 ---------- */

  (function init() {
    var s = readSession();
    if (s && s.access_token) {
      showStatus("info", "检测到已有登录会话,正在前往记忆控制台…", true);
      setTimeout(function () { window.location.href = USER_HOME; }, 400);
    }
  })();
})();

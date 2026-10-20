// 河流日记官网：真实服务状态、反馈、更新日志与无障碍导航工具。
(function () {
  "use strict";
  var root = document.documentElement;
  var themeKey = "flowriver.site.theme";
  var savedTheme = null;
  var systemTheme = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  try { savedTheme = localStorage.getItem(themeKey); } catch (_) { /* 存储受限时主题仍可切换。 */ }
  if (savedTheme !== "light" && savedTheme !== "dark") savedTheme = null;
  root.dataset.theme = savedTheme || (systemTheme && systemTheme.matches ? "dark" : "light");

  function ready() {
    var statusTimer;
    var toolStatus = document.querySelector("[data-tool-status]");
    function announce(message) {
      if (!toolStatus) return;
      window.clearTimeout(statusTimer);
      toolStatus.textContent = message;
      toolStatus.hidden = false;
      statusTimer = window.setTimeout(function () { toolStatus.hidden = true; }, 6000);
    }
    document.querySelectorAll("[data-year]").forEach(function (year) { year.textContent = String(new Date().getFullYear()); });

    var themeToggle = document.querySelector("[data-theme-toggle]");
    function updateTheme() {
      var dark = root.dataset.theme === "dark";
      if (themeToggle) {
        var label = dark ? "切换到浅色外观" : "切换到深色外观";
        themeToggle.hidden = false;
        themeToggle.setAttribute("aria-label", label);
        themeToggle.setAttribute("title", label);
        themeToggle.setAttribute("aria-pressed", String(dark));
      }
      var meta = document.querySelector('meta[name="theme-color"]');
      if (meta) meta.content = dark ? "#25262c" : "#f0eeeb";
    }
    updateTheme();
    if (themeToggle) themeToggle.addEventListener("click", function () {
      savedTheme = root.dataset.theme === "dark" ? "light" : "dark";
      root.dataset.theme = savedTheme;
      try { localStorage.setItem(themeKey, savedTheme); } catch (_) { /* 当前页面仍应用该外观。 */ }
      updateTheme();
    });
    if (systemTheme && systemTheme.addEventListener) systemTheme.addEventListener("change", function () {
      if (!savedTheme) { root.dataset.theme = systemTheme.matches ? "dark" : "light"; updateTheme(); }
    });
    window.addEventListener("storage", function (event) {
      if (event.key !== themeKey) return;
      savedTheme = event.newValue === "light" || event.newValue === "dark" ? event.newValue : null;
      root.dataset.theme = savedTheme || (systemTheme && systemTheme.matches ? "dark" : "light");
      updateTheme();
    });

    var fullscreenToggle = document.querySelector("[data-fullscreen-toggle]");
    function updateFullscreen() {
      if (!fullscreenToggle) return;
      var active = Boolean(document.fullscreenElement);
      var label = active ? "退出全屏" : "进入全屏";
      fullscreenToggle.setAttribute("aria-pressed", String(active));
      fullscreenToggle.setAttribute("aria-label", label);
      fullscreenToggle.setAttribute("title", label);
    }
    if (fullscreenToggle && document.fullscreenEnabled && root.requestFullscreen && document.exitFullscreen) {
      fullscreenToggle.hidden = false;
      fullscreenToggle.addEventListener("click", function () {
        try {
          var action = document.fullscreenElement ? document.exitFullscreen() : root.requestFullscreen();
          if (action && action.catch) action.catch(function () { announce("浏览器暂时无法切换全屏，请使用浏览器的全屏菜单。"); });
        } catch (_) { announce("浏览器暂时无法切换全屏，请使用浏览器的全屏菜单。"); }
      });
      document.addEventListener("fullscreenchange", updateFullscreen);
      updateFullscreen();
    }

    var navLinks = Array.from(document.querySelectorAll(".topnav [data-section]"));
    var sections = navLinks.map(function (link) { return document.getElementById(link.dataset.section); }).filter(Boolean);
    var scheduled = false;
    function updateNavigation() {
      scheduled = false;
      if (!sections.length) return;
      var offset = document.querySelector(".topbar").getBoundingClientRect().bottom + 45;
      var current = sections[0].id;
      sections.forEach(function (section) { if (section.getBoundingClientRect().top <= offset) current = section.id; });
      var pageBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 12;
      if (pageBottom) current = sections[sections.length - 1].id;
      navLinks.forEach(function (link) {
        var active = link.dataset.section === current;
        link.classList.toggle("active", active);
        if (active) link.setAttribute("aria-current", "location");
        else link.removeAttribute("aria-current");
      });
    }
    function scheduleNavigation() { if (!scheduled) { scheduled = true; window.requestAnimationFrame(updateNavigation); } }
    window.addEventListener("scroll", scheduleNavigation, { passive: true });
    window.addEventListener("resize", scheduleNavigation);
    updateNavigation();

    function requestJSON(url, options) {
      options = options || {};
      var controller = window.AbortController ? new AbortController() : null;
      var timer = controller ? window.setTimeout(function () { controller.abort(); }, 12000) : null;
      if (controller) options.signal = controller.signal;
      options.cache = "no-store";
      return fetch(url, options).then(function (response) {
        if (!response.ok) {
          var error = new Error("request_failed");
          error.status = response.status;
          error.retryAfter = response.headers.get("Retry-After");
          throw error;
        }
        return response.json();
      }).finally(function () { window.clearTimeout(timer); });
    }
    function safeHref(value) {
      if (typeof value !== "string" || !value.trim()) return null;
      try {
        var url = new URL(value, window.location.href);
        if (url.protocol !== "https:" && url.protocol !== "http:") return null;
        return url.href;
      } catch (_) { return null; }
    }

    // 只由当前服务状态开放安装包；停用、异常和无效元数据都撤销旧下载入口。
    var noticeBar = document.getElementById("notice-bar");
    var macosCard = document.getElementById("dl-macos-card");
    var releaseStatus = document.querySelector("[data-release-status]");
    var loadingSite = false;
    var currentDownload = null;
    function renderDownload(download, failed) {
      if (!macosCard) return;
      var valid = download && download.available === true && typeof download.filename === "string" &&
        /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(download.filename) && download.filename.indexOf("..") === -1 &&
        Number.isFinite(download.size_bytes) && download.size_bytes > 0 && /^[a-f0-9]{64}$/i.test(download.sha256 || "");
      currentDownload = valid ? download : null;
      macosCard.classList.toggle("maint", !valid);
      var pill = macosCard.querySelector("[data-dl-pill]");
      var desc = macosCard.querySelector("[data-dl-desc]");
      var actions = macosCard.querySelector("[data-dl-actions]");
      var meta = macosCard.querySelector("[data-dl-meta]");
      if (pill) {
        pill.className = "status-pill " + (valid ? "ok" : "warn");
        pill.textContent = valid ? "开放下载" : failed ? "暂时无法确认下载状态" : "下载暂未开放";
      }
      if (desc) desc.textContent = valid ? (download.note || "macOS 测试版已开放，请在安装前阅读版本说明。") :
        failed ? "暂时无法连接状态服务。请稍后刷新；确认当前版本可用后，这里会提供下载入口。" :
        (download && download.note || "macOS 客户端正在修复与验证，下载暂未开放。恢复后会在这里显示版本、安装包与 SHA-256。");
      if (actions) {
        actions.replaceChildren();
        if (valid) {
          var primary = document.createElement("a");
          primary.className = "btn";
          primary.href = "/downloads/" + encodeURIComponent(download.filename);
          primary.setAttribute("download", "");
          primary.dataset.liveDownload = "true";
          primary.textContent = "下载 .zip（" + (download.size_bytes / 1048576).toFixed(1) + " MB）";
          actions.appendChild(primary);
        } else {
          var disabled = document.createElement("span");
          disabled.className = "btn disabled";
          disabled.setAttribute("aria-disabled", "true");
          disabled.textContent = "下载暂未开放";
          actions.appendChild(disabled);
        }
        var retry = document.createElement("button");
        retry.className = "btn ghost";
        retry.type = "button";
        retry.dataset.siteStatusRetry = "true";
        retry.textContent = "刷新状态";
        actions.appendChild(retry);
      }
      if (meta) {
        meta.replaceChildren();
        if (valid) {
          var version = document.createElement("span");
          version.textContent = "版本 " + String(download.version || "未标注") + " · SHA-256";
          meta.appendChild(version);
          var hash = document.createElement("button");
          hash.type = "button";
          hash.className = "checksum-button";
          hash.dataset.copyChecksum = download.sha256;
          hash.title = "复制完整 SHA-256";
          hash.textContent = download.sha256;
          meta.appendChild(hash);
        } else meta.textContent = failed ? "状态读取失败 · 可刷新重试" : "恢复时间以当前公告与下载状态为准";
      }
      if (releaseStatus) releaseStatus.textContent = (valid ? "macOS 测试版已开放" : failed ? "macOS 下载状态待确认" : "macOS 下载暂未开放") + " · iOS 内测准备中";
    }
    function renderAnnouncements(items) {
      if (!noticeBar) return;
      var item = items.find(function (entry) { return entry && (entry.placement === "banner" || entry.placement === "both"); });
      noticeBar.hidden = !item;
      if (!item) return;
      var level = ["info", "warn", "critical"].indexOf(item.level) >= 0 ? item.level : "info";
      noticeBar.className = "notice-bar level-" + level;
      var text = noticeBar.querySelector("[data-notice-text]");
      var link = noticeBar.querySelector("[data-notice-link]");
      if (text) text.textContent = String(item.title || "公告") + (item.body ? " — " + item.body : "");
      if (link) {
        var href = safeHref(item.href);
        link.hidden = !href;
        if (href) { link.href = href; link.textContent = "查看详情"; }
        else link.removeAttribute("href");
      }
    }
    function refreshSiteStatus() {
      if (loadingSite || (!noticeBar && !macosCard)) return Promise.resolve();
      loadingSite = true;
      document.querySelectorAll("[data-site-status-retry]").forEach(function (button) { button.disabled = true; button.textContent = "读取中…"; });
      return requestJSON("/v1/site-status", { headers: { Accept: "application/json" } }).then(function (data) {
        if (!data || !Array.isArray(data.announcements) || !data.downloads || !data.downloads.macos) throw new Error("invalid_status");
        renderAnnouncements(data.announcements);
        renderDownload(data.downloads.macos, false);
      }).catch(function () {
        renderDownload(null, true);
        if (noticeBar) {
          noticeBar.hidden = false;
          noticeBar.className = "notice-bar level-warn";
          noticeBar.querySelector("[data-notice-text]").textContent = "暂时无法读取最新公告，下载状态可在下方刷新重试。";
          var link = noticeBar.querySelector("[data-notice-link]");
          link.hidden = false; link.href = "#download"; link.textContent = "查看状态";
        }
      }).finally(function () { loadingSite = false; scheduleNavigation(); });
    }
    if (macosCard) macosCard.addEventListener("click", function (event) {
      var retry = event.target.closest("[data-site-status-retry]");
      if (retry) { refreshSiteStatus(); return; }
      var checksum = event.target.closest("[data-copy-checksum]");
      if (checksum) {
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(checksum.dataset.copyChecksum)
          .then(function () { announce("已复制完整 SHA-256。"); })
          .catch(function () { announce("浏览器未允许复制，可选择页面上的完整 SHA-256 手动复制。"); });
        else announce("可选择页面上的完整 SHA-256 手动复制。");
      }
      var liveLink = event.target.closest("[data-live-download]");
      if (liveLink && (!currentDownload || loadingSite)) { event.preventDefault(); announce("正在确认下载状态，请稍后重试。"); }
    });
    refreshSiteStatus();
    if (macosCard || noticeBar) {
      window.setInterval(function () { if (!document.hidden) refreshSiteStatus(); }, 60000);
      document.addEventListener("visibilitychange", function () { if (!document.hidden) refreshSiteStatus(); });
    }

    // 保留既有历史作为离线回退，在线响应（包括空列表）始终为准。
    var timeline = document.getElementById("changelog-timeline");
    var changelogStatus = document.querySelector("[data-changelog-status]");
    var changelogToggle = document.querySelector("[data-changelog-toggle]");
    var historyExpanded = false;
    function limitHistory() {
      if (!timeline || !changelogToggle) return;
      var entries = timeline.querySelectorAll(".tl-entry");
      entries.forEach(function (entry, index) { entry.hidden = !historyExpanded && index >= 5; });
      changelogToggle.hidden = entries.length <= 5;
      changelogToggle.setAttribute("aria-expanded", String(historyExpanded));
      changelogToggle.textContent = historyExpanded ? "收起更早更新" : "查看更早更新（" + Math.max(0, entries.length - 5) + " 条）";
    }
    if (changelogToggle) changelogToggle.addEventListener("click", function () { historyExpanded = !historyExpanded; limitHistory(); });
    limitHistory();
    if (timeline) requestJSON("/v1/changelog", { headers: { Accept: "application/json" } }).then(function (data) {
      if (!data || !Array.isArray(data.entries)) throw new Error("invalid_changelog");
      var fragment = document.createDocumentFragment();
      data.entries.forEach(function (entry) {
        if (!entry || typeof entry.title !== "string") return;
        var article = document.createElement("article"); article.className = "tl-entry";
        var marker = document.createElement("div"); marker.className = "tl-marker";
        var dot = document.createElement("span"); dot.className = "tl-dot"; marker.appendChild(dot);
        var card = document.createElement("div"); card.className = "tl-card";
        var head = document.createElement("div"); head.className = "tl-head";
        var time = document.createElement("time"); time.textContent = String(entry.date || "");
        if (/^\d{4}-\d{2}-\d{2}$/.test(entry.date || "")) time.dateTime = entry.date;
        head.appendChild(time);
        if (entry.version_tag) { var tag = document.createElement("span"); tag.className = "tl-tag"; tag.textContent = entry.version_tag; head.appendChild(tag); }
        var title = document.createElement("h3"); title.textContent = entry.title;
        card.appendChild(head); card.appendChild(title);
        var lines = String(entry.body || "").split(/\r?\n/).filter(function (line) { return line.trim(); });
        if (lines.length) {
          var list = document.createElement("ul"); list.className = "tl-points";
          lines.forEach(function (line) { var point = document.createElement("li"); point.textContent = line.trim(); list.appendChild(point); });
          card.appendChild(list);
        }
        article.appendChild(marker); article.appendChild(card); fragment.appendChild(article);
      });
      timeline.replaceChildren(fragment);
      changelogStatus.textContent = timeline.children.length ? "已读取最新发布记录" : "暂无已发布的更新记录。";
      limitHistory();
    }).catch(function () { changelogStatus.textContent = "暂时无法读取最新更新，以下为已有历史记录。"; });

    // 反馈不会因服务错误清空；超时解除忙碌状态，以便继续编辑。
    var feedbackForm = document.getElementById("feedback-form");
    if (feedbackForm) {
      var submitting = false;
      var feedbackAttempt = null;
      feedbackForm.addEventListener("submit", function (event) {
        event.preventDefault();
        if (submitting || !feedbackForm.reportValidity()) return;
        var submit = document.getElementById("fb-submit");
        var notice = document.getElementById("fb-notice");
        var email = document.getElementById("fb-email").value.trim();
        var subjectInput = document.getElementById("fb-subject");
        var bodyInput = document.getElementById("fb-body");
        var subject = subjectInput.value.trim();
        var body = bodyInput.value.trim();
        if (Array.from(body).length < 5 || Array.from(body).length > 4000 || Array.from(subject).length > 200) {
          notice.className = "fb-notice err"; notice.textContent = "反馈内容需为 5–4000 字，主题不超过 200 字。"; bodyInput.focus(); return;
        }
        var fingerprint = JSON.stringify([email, subject, body]);
        if (!feedbackAttempt || feedbackAttempt.fingerprint !== fingerprint) feedbackAttempt = { fingerprint: fingerprint, key: crypto.randomUUID() };
        var attempt = feedbackAttempt;
        submitting = true; submit.disabled = true; submit.textContent = "发送中…";
        feedbackForm.setAttribute("aria-busy", "true");
        notice.className = "fb-notice"; notice.textContent = "正在发送…";
        requestJSON("/v1/feedback", {
          method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json", "Idempotency-Key": attempt.key },
          body: JSON.stringify({ contact_email: email, subject: subject, body: body })
        }).then(function () {
          if (feedbackAttempt === attempt) feedbackAttempt = null;
          notice.className = "fb-notice ok"; notice.textContent = "已收到，谢谢你的反馈！" + (email ? "回复会发送到你留下的邮箱。" : "");
          // 请求期间继续填写的新内容不会被前一条反馈的成功响应抹掉。
          if (bodyInput.value.trim() === body) bodyInput.value = "";
          if (subjectInput.value.trim() === subject) subjectInput.value = "";
        }).catch(function (error) {
          notice.className = "fb-notice err";
          notice.textContent = error.status === 429 ? "反馈发送频率已达上限，请稍后再试。内容已保留。" :
            error.status === 400 ? "请检查邮箱与反馈内容后重试。内容已保留。" :
            error.name === "AbortError" ? "发送超时，是否收到尚未确认。内容已保留，请稍后再试。" :
            "发送失败，内容已保留。请稍后再试，或写信到 account@mail.flowriver.xyz。";
        }).finally(function () {
          submitting = false; submit.disabled = false; submit.textContent = "发送反馈"; feedbackForm.removeAttribute("aria-busy");
        });
      });
    }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ready, { once: true });
  else ready();
})();

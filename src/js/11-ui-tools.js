'use strict';

(function() {
  function bindHelpModal() {
    var modal = document.getElementById('helpModal');
    var button = document.getElementById('helpBtn');
    var close = document.getElementById('helpModalClose');
    if (!modal) return;

    function openHelp() {
      window._helpFocus = document.activeElement;
      modal.classList.add('show');
      refreshOverlayLock();
      setTimeout(function() { if (close) close.focus(); }, 30);
    }
    function closeHelp() {
      modal.classList.remove('show');
      refreshOverlayLock();
      var back = window._helpFocus;
      if (back && back.focus) back.focus();
      window._helpFocus = null;
    }
    window.openHelpModal = openHelp;
    window.closeHelpModal = closeHelp;
    if (button) button.addEventListener('click', openHelp);
    if (close) close.addEventListener('click', closeHelp);
    modal.addEventListener('click', function(event) { if (event.target === modal) closeHelp(); });
    document.addEventListener('keydown', function(event) {
      if (!modal.classList.contains('show')) return;
      if (event.key === 'Escape') { event.preventDefault(); closeHelp(); }
      if (event.key === 'Tab') trapDialogFocus(modal, event);
    });
  }

  function enhanceCommands() {
    var search = document.getElementById('searchInput');
    if (search && search.getAttribute('readonly') !== 'readonly') {
      search.setAttribute('readonly', 'readonly');
      search.addEventListener('focus', function(event) {
        event.preventDefault();
        if (typeof openCmdk === 'function') { openCmdk(); search.blur(); }
      });
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function() { bindHelpModal(); enhanceCommands(); });
  else { bindHelpModal(); enhanceCommands(); }
})();

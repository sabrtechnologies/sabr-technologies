(function () {
  'use strict';
  async function json(url, options) {
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, 15000);
    try {
      var response = await fetch(url, Object.assign({}, options, {
        signal: controller.signal, cache: 'no-store', referrerPolicy: 'no-referrer'
      }));
      var data = await response.json();
      if (!response.ok) throw new Error(data.error || 'Request failed. Please try again.');
      return data;
    } finally { clearTimeout(timer); }
  }
  function safeURL(value, hosts) {
    try {
      var url = new URL(value);
      if (url.protocol !== 'https:' || url.username || url.password ||
          !hosts.includes(url.hostname) || (url.port && url.port !== '443')) return null;
      return url.href;
    } catch (_) { return null; }
  }
  async function copy(text, button) {
    try {
      if (!navigator.clipboard) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
    } catch (_) {
      button.textContent = 'Copy unavailable — select the key or command and copy it';
    }
  }
  window.SabrUI = {json: json, safeURL: safeURL, copy: copy};
})();

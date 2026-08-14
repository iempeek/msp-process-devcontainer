/**
 * Local-stack stand-in for https://manage-dev.mspprocess.com/kb-chat-widget.js
 *
 * WHY THIS EXISTS
 * ---------------
 * AlertManager.Web mounts a chat bubble by injecting a remote loader script
 * (src/ui/components/KbChatWidget/useKbChatWidget.ts -> appConfig.kbWidgetUrl).
 * The real loader, its /kb.html chat page and its /api/public-kb endpoints are
 * part of a SEPARATE hosted product - none of it exists in this repo, so the
 * local stack can never serve it. Left pointing at manage-dev, the bubble opens
 * an iframe to a remote host and shows the browser's own network-error page
 * (e.g. NS_ERROR_OFFLINE) whenever that host is unreachable.
 *
 * WHAT THIS DOES INSTEAD
 * ----------------------
 * Draws the same bottom-right bubble, but iframes the live chat widget we DO
 * run locally - AlertManager.LiveChatWidget on :3004, backed by
 * AlertManager.LiveChat.Api on :5033 and Pusher via the soketi sidecar on
 * :6001. It reimplements the postMessage resize protocol of that widget's own
 * loader (mspprocess-ui/Web/AlertManager.LiveChatWidget/script/index.js).
 *
 * This is a SUBSTITUTION, not an emulation: the real widget is an AI
 * knowledge-base assistant, this one is customer<->tech live chat. It exists so
 * "the chat bubble in the local app opens a working, fully-local chat" instead
 * of a dead remote frame.
 *
 * CONFIGURATION
 * -------------
 * The host page passes data-kb-token (from REACT_APP_KB_WIDGET_TOKEN, see
 * .devcontainer/local/frontend-settings/env.web). Locally that value is reused
 * to carry the LIVE CHAT widget code - a TripleDES blob of (tenantId,
 * resourceId) minted by
 * Core/AlertManager.Services/LiveChatServices/Helpers/CodeHelper.cs and
 * resolved against the LiveChatResources table by
 * LiveChatService.GetWidgetSettings. Set it via LOCAL_CHAT_WIDGET_CODE in
 * .devcontainer/.env; get a code by creating a Live Chat resource in the local
 * app and copying the code out of its generated embed snippet.
 *
 * With no code configured this logs one console notice and renders nothing -
 * deliberately quieter than a broken iframe.
 *
 * The element id below is `msp-kb-*` on purpose: useKbChatWidget's teardown
 * sweeps `[id^="msp-kb-"]` on logout / identity change, so the local frame is
 * cleaned up by the host app exactly like the real one.
 */
(function () {
  'use strict';

  var FRAME_ID = 'msp-kb-chat-widget';
  var COLLAPSED = 80;

  var scripts = document.querySelectorAll('script[data-kb-token]');
  var scriptTag = scripts[scripts.length - 1];
  if (!scriptTag) return;

  // Prevent double-init (mirrors the real loader's guard).
  if (document.getElementById(FRAME_ID)) return;

  var code = scriptTag.getAttribute('data-kb-token') || '';
  if (!code) {
    console.info(
      '[local kb-chat-widget] No live chat code configured - chat bubble not rendered. ' +
        'Create a Live Chat resource in the local app, then set LOCAL_CHAT_WIDGET_CODE ' +
        'in .devcontainer/.env and restart the frontend service.'
    );
    return;
  }

  // The browser loads this script from the host, so the widget origin is a host
  // URL too - :3004 is published by the frontend compose service.
  var widgetOrigin =
    scriptTag.getAttribute('data-local-widget-origin') ||
    window.location.protocol + '//' + window.location.hostname + ':3004';

  var iframe = document.createElement('iframe');
  iframe.id = FRAME_ID;
  iframe.src = widgetOrigin + '/?code=' + encodeURIComponent(code);
  iframe.title = 'MSP Process live chat (local stack)';
  iframe.style.cssText =
    'height:' + COLLAPSED + 'px;width:' + COLLAPSED + 'px;position:fixed;' +
    'right:10px;bottom:10px;z-index:9999;border:none;color-scheme:normal;';
  document.body.appendChild(iframe);

  // Resize protocol from the widget's own loader. Scoped with an addEventListener
  // + origin check rather than the loader's `window.onmessage =` assignment, so
  // this cannot clobber a message handler the host app already installed.
  window.addEventListener('message', function (e) {
    if (e.origin !== widgetOrigin) return;
    var data = e.data;
    if (!data || typeof data !== 'object') return;
    if (!('frameHeight' in data) || !('frameWidth' in data)) return;

    var frame = document.getElementById(FRAME_ID);
    if (!frame) return;
    frame.style.height = data.frameHeight + 30 + 'px';
    frame.style.width = data.frameWidth + 30 + 'px';
  });
})();

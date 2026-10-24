// The bridge between AKit (Swift, MapCanvasView.swift) and the Excalidraw canvas.
//
// JS → Swift: window.webkit.messageHandlers.kb.postMessage({type, ...})
//   ready        the canvas is mounted and its API is there
//   sceneLoaded  akitLoadScene put a scene on the canvas ({elements: count})
//   linkOpen     the user opened an element's link ({link, elementId, elementType}); Excalidraw's own
//                navigation is always prevented, AKit decides what the link means
//   problem      a script error or a Content-Security-Policy violation ({message})
//   save         the scene changed ({key, json}): ONE serializeAsJSON(…, "local") string, posted 800 ms
//                after the last change and only when its hash differs from the last one posted. AKit
//                writes these bytes as they are. Loading a scene hashes it without posting, so opening
//                a map never makes it dirty
// Swift → JS (callAsyncJavaScript):
//   akitLoadScene(json, key)  shows a .excalidraw file's text (key: the map id the saves carry); a
//                             change still waiting for its post is posted first; returns the element count
//   akitSerialize()      the scene as .excalidraw text (serializeAsJSON, "local")
//   akitTakeUnsaved()    a change still waiting for its post, now ({key, json}), or null; for AKit's flushes
//   akitSetViewMode(on)  view mode on or off (Edit in AKit)
//   akitPosts()          how many saves were handed to AKit (posts and akitTakeUnsaved)
//   akitDebugAddRectangle()  snapshots: adds one rectangle through the API, like a user would
//   akitDiagnostics()    what the page loaded, for snapshots and checks
//   akitClick(x, y)      snapshots: a pointer click at that page point (a web view takes no synthetic AppKit clicks)
// Options (window.akitOptions, set by AKit before this file runs):
//   viewMode     Excalidraw's viewModeEnabled at start: nothing can be edited, a click on a block opens its link
"use strict";

// Excalidraw loads its fonts and chunks from here (it appends "excalidraw-assets/…").
window.EXCALIDRAW_ASSET_PATH = new URL("vendor/", location.href).href;

(function () {
  const problems = [];

  function post(message) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kb;
    if (handler) handler.postMessage(message);
  }

  function problem(message) {
    problems.push(message);
    post({ type: "problem", message });
  }

  window.addEventListener("error", (event) => {
    problem("error: " + (event.message || (event.target && (event.target.src || event.target.href)) || "unknown"));
  }, true);
  window.addEventListener("unhandledrejection", (event) => problem("rejection: " + String(event.reason)));
  document.addEventListener("securitypolicyviolation", (event) => {
    problem("csp: " + event.violatedDirective + " blocked " + (event.blockedURI || "inline"));
  });

  let api = null;
  let viewMode = !!(window.akitOptions && window.akitOptions.viewMode);
  let render = null;

  // Saves: the key of the scene on the canvas, the hash of the last text handed to AKit, the
  // debounce timer and the count.
  let sceneKey = null;
  let lastHash = null;
  let timer = null;
  let posts = 0;
  let loading = false;
  // The viewport is still the one a load fitted to the content.
  let untouched = true;

  // cyrb53: a fast 53-bit string hash; enough to tell "changed" from "the same".
  function hash(text) {
    let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      h1 = Math.imul(h1 ^ c, 2654435761);
      h2 = Math.imul(h2 ^ c, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return 4294967296 * (2097151 & h2) + (h1 >>> 0);
  }

  function serialize() {
    return window.ExcalidrawLib.serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), "local");
  }

  // The scene's text when it differs from the last one handed to AKit (and marks it handed), else null.
  function unsaved() {
    clearTimeout(timer);
    timer = null;
    if (!api || sceneKey === null || loading) return null;
    const json = serialize();
    const value = hash(json);
    if (value === lastHash) return null;
    lastHash = value;
    posts += 1;
    return { key: sceneKey, json };
  }

  function changed() {
    if (loading || sceneKey === null) return;
    clearTimeout(timer);
    timer = setTimeout(() => {
      const save = unsaved();
      if (save) post({ type: "save", key: save.key, json: save.json });
    }, 800);
  }

  window.akitTakeUnsaved = function () { return unsaved(); };
  window.akitPosts = function () { return posts; };
  window.akitSetViewMode = function (on) {
    viewMode = !!on;
    if (render) render();
  };

  window.akitDebugAddRectangle = function () {
    const lib = window.ExcalidrawLib;
    const [rectangle] = lib.convertToExcalidrawElements([
      { type: "rectangle", id: "akit-debug-" + Date.now(), x: 0, y: 360, width: 160, height: 70, strokeColor: "#1971c2" },
    ]);
    api.updateScene({ elements: api.getSceneElementsIncludingDeleted().concat([rectangle]) });
    return api.getSceneElements().length;
  };

  window.akitLoadScene = function (json, key) {
    if (!api) throw new Error("The canvas is not ready yet.");
    // A change of the scene going away is handed over first, under its own key.
    if (timer) {
      const save = unsaved();
      if (save) post({ type: "save", key: save.key, json: save.json });
    }
    const lib = window.ExcalidrawLib;
    const data = lib.restore(JSON.parse(json), null, null);
    loading = true;
    api.updateScene({
      elements: data.elements,
      appState: { viewBackgroundColor: data.appState.viewBackgroundColor },
    });
    const files = Object.values(data.files || {});
    if (files.length) api.addFiles(files);
    if (api.history && api.history.clear) api.history.clear();
    api.scrollToContent(undefined, { fitToContent: true });
    // Opening never dirties (N4): the loaded scene's own serialization is the last one "posted".
    sceneKey = key === undefined ? null : key;
    untouched = true;
    lastHash = hash(serialize());
    clearTimeout(timer);
    timer = null;
    // Excalidraw applies the app state (the background) and reports the load's own changes after
    // this call returns: hash again once that has settled.
    setTimeout(() => {
      lastHash = hash(serialize());
      loading = false;
    }, 100);
    const count = api.getSceneElements().length;
    post({ type: "sceneLoaded", elements: count });
    return count;
  };

  window.akitSerialize = function () {
    if (!api) throw new Error("The canvas is not ready yet.");
    return serialize();
  };

  window.akitDiagnostics = async function () {
    await document.fonts.ready;
    return {
      resources: performance.getEntriesByType("resource").map((entry) => entry.name),
      fonts: Array.from(document.fonts).map((font) => font.family + " " + font.weight + " " + font.status),
      problems: problems.slice(),
      // Where each linked element's centre is on the page (CSS pixels from the top left).
      links: api ? api.getSceneElements().filter((element) => element.link).map((element) => {
        const point = window.ExcalidrawLib.sceneCoordsToViewportCoords(
          { sceneX: element.x + element.width / 2, sceneY: element.y + element.height / 2 }, api.getAppState());
        return element.id + " " + element.link + " at " + Math.round(point.x) + "," + Math.round(point.y);
      }) : [],
    };
  };

  // Snapshots: a click at a page point, as pointer events (a web view takes no synthetic AppKit clicks).
  window.akitClick = function (x, y) {
    const target = document.elementFromPoint(x, y);
    if (!target) return "nothing at " + x + "," + y;
    const options = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0,
      pointerId: 1, pointerType: "mouse", isPrimary: true };
    target.dispatchEvent(new PointerEvent("pointerdown", Object.assign({ buttons: 1 }, options)));
    target.dispatchEvent(new PointerEvent("pointerup", Object.assign({ buttons: 0 }, options)));
    return target.tagName.toLowerCase() + "." + target.className;
  };

  // View mode: a click (no drag) on an element with a link opens it. Excalidraw does this itself
  // only when the canvas is at least 730 px wide; below that it counts as a phone and opens links
  // only from the small link icon. Shapes win over arrows; the topmost element wins.
  let down = null;
  function linkAt(clientX, clientY) {
    const appState = api.getAppState();
    const point = window.ExcalidrawLib.viewportCoordsToSceneCoords({ clientX, clientY }, appState);
    const slack = 8 / appState.zoom.value;
    const hits = api.getSceneElements().filter((element) => element.link && !element.isDeleted
      && point.x >= Math.min(element.x, element.x + element.width) - slack
      && point.x <= Math.max(element.x, element.x + element.width) + slack
      && point.y >= Math.min(element.y, element.y + element.height) - slack
      && point.y <= Math.max(element.y, element.y + element.height) + slack).reverse();
    return hits.find((element) => element.type !== "arrow" && element.type !== "line") || hits[0] || null;
  }
  function watchViewModeClicks() {
    document.addEventListener("pointerdown", (event) => {
      down = event.button === 0 && event.target.classList.contains("excalidraw__canvas")
        ? { x: event.clientX, y: event.clientY, time: event.timeStamp } : null;
    }, true);
    document.addEventListener("pointerup", (event) => {
      const start = down;
      down = null;
      if (!viewMode || !api || !start || Math.hypot(event.clientX - start.x, event.clientY - start.y) > 4 || event.timeStamp - start.time > 600) return;
      const element = linkAt(event.clientX, event.clientY);
      if (element) post({ type: "linkOpen", link: element.link, elementId: element.id, elementType: element.type });
    }, true);
  }

  function mount() {
    const lib = window.ExcalidrawLib;
    if (!window.React || !window.ReactDOM || !lib) {
      problem("scripts missing: React " + !!window.React + ", ReactDOM " + !!window.ReactDOM + ", Excalidraw " + !!lib);
      return;
    }
    const lang = new URLSearchParams(location.search).get("lang") || "en";
    const h = window.React.createElement;
    const root = window.ReactDOM.createRoot(document.getElementById("root"));
    render = function () {
      const menu = viewMode
        ? h(lib.MainMenu, null, h(lib.MainMenu.DefaultItems.ToggleTheme))
        : h(lib.MainMenu, null,
          h(lib.MainMenu.DefaultItems.ClearCanvas),
          h(lib.MainMenu.DefaultItems.ToggleTheme),
          h(lib.MainMenu.DefaultItems.ChangeCanvasBackground));
      root.render(h(lib.Excalidraw, {
        langCode: lang,
        viewModeEnabled: viewMode,
        // No library and no collaboration: AKit is offline, and collaboration needs a server.
        UIOptions: {
          canvasActions: { loadScene: false, saveToActiveFile: false, export: false, saveAsImage: false },
          tools: { image: false },
        },
        excalidrawAPI: (value) => {
          if (api || !value) return;
          api = value;
          post({ type: "ready" });
        },
        onChange: changed,
        onLinkOpen: (element, event) => {
          event.preventDefault();
          // In view mode the click watcher above posts it (also on a narrow canvas).
          if (!viewMode) post({ type: "linkOpen", link: element.link, elementId: element.id, elementType: element.type });
        },
      }, menu));
    };
    render();
    watchViewModeClicks();
    // A map stays whole in view when its pane changes size (a note opens beside it): always in
    // view mode, in Edit until the user scrolls, zooms or touches the canvas.
    let refit = null;
    window.addEventListener("resize", () => {
      clearTimeout(refit);
      refit = setTimeout(() => { if (api && (viewMode || untouched)) api.scrollToContent(undefined, { fitToContent: true }); }, 150);
    });
    for (const type of ["pointerdown", "wheel"]) document.addEventListener(type, () => { untouched = false; }, true);
  }

  document.addEventListener("DOMContentLoaded", mount);
})();

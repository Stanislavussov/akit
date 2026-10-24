// The bridge between AKit (Swift, MapCanvasView.swift) and the Excalidraw canvas.
//
// JS → Swift: window.webkit.messageHandlers.kb.postMessage({type, ...})
//   ready        the canvas is mounted and its API is there
//   sceneLoaded  akitLoadScene put a scene on the canvas ({elements: count})
//   linkOpen     the user opened an element's link ({link, elementId, elementType}); Excalidraw's own
//                navigation is always prevented, AKit decides what the link means
//   problem      a script error or a Content-Security-Policy violation ({message})
// Swift → JS (callAsyncJavaScript):
//   akitLoadScene(json)  shows a .excalidraw file's text; returns the element count
//   akitSerialize()      the scene as .excalidraw text (serializeAsJSON, "local")
//   akitDiagnostics()    what the page loaded, for snapshots and checks
//   akitClick(x, y)      snapshots: a pointer click at that page point (a web view takes no synthetic AppKit clicks)
// Options (window.akitOptions, set by AKit before this file runs):
//   viewMode     Excalidraw's viewModeEnabled: nothing can be edited, a click on a block opens its link
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

  window.akitLoadScene = function (json) {
    if (!api) throw new Error("The canvas is not ready yet.");
    const lib = window.ExcalidrawLib;
    const data = lib.restore(JSON.parse(json), null, null);
    api.updateScene({
      elements: data.elements,
      appState: { viewBackgroundColor: data.appState.viewBackgroundColor },
    });
    const files = Object.values(data.files || {});
    if (files.length) api.addFiles(files);
    if (api.history && api.history.clear) api.history.clear();
    api.scrollToContent(undefined, { fitToContent: true });
    const count = api.getSceneElements().length;
    post({ type: "sceneLoaded", elements: count });
    return count;
  };

  window.akitSerialize = function () {
    if (!api) throw new Error("The canvas is not ready yet.");
    return window.ExcalidrawLib.serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), "local");
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
      if (!api || !start || Math.hypot(event.clientX - start.x, event.clientY - start.y) > 4 || event.timeStamp - start.time > 600) return;
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
    const viewMode = !!(window.akitOptions && window.akitOptions.viewMode);
    const h = window.React.createElement;
    const menu = viewMode
      ? h(lib.MainMenu, null, h(lib.MainMenu.DefaultItems.ToggleTheme))
      : h(lib.MainMenu, null,
        h(lib.MainMenu.DefaultItems.ClearCanvas),
        h(lib.MainMenu.DefaultItems.ToggleTheme),
        h(lib.MainMenu.DefaultItems.ChangeCanvasBackground));
    const app = h(lib.Excalidraw, {
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
      onLinkOpen: (element, event) => {
        event.preventDefault();
        // In view mode the click watcher above posts it (also on a narrow canvas).
        if (!viewMode) post({ type: "linkOpen", link: element.link, elementId: element.id, elementType: element.type });
      },
    }, menu);
    window.ReactDOM.createRoot(document.getElementById("root")).render(app);
    if (viewMode) {
      watchViewModeClicks();
      // A read-only map stays whole in view when its pane changes size (a note opens beside it).
      let refit = null;
      window.addEventListener("resize", () => {
        clearTimeout(refit);
        refit = setTimeout(() => { if (api) api.scrollToContent(undefined, { fitToContent: true }); }, 150);
      });
    }
  }

  document.addEventListener("DOMContentLoaded", mount);
})();

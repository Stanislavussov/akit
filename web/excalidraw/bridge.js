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
    };
  };

  function mount() {
    const lib = window.ExcalidrawLib;
    if (!window.React || !window.ReactDOM || !lib) {
      problem("scripts missing: React " + !!window.React + ", ReactDOM " + !!window.ReactDOM + ", Excalidraw " + !!lib);
      return;
    }
    const lang = new URLSearchParams(location.search).get("lang") || "en";
    const h = window.React.createElement;
    const menu = h(lib.MainMenu, null,
      h(lib.MainMenu.DefaultItems.ClearCanvas),
      h(lib.MainMenu.DefaultItems.ToggleTheme),
      h(lib.MainMenu.DefaultItems.ChangeCanvasBackground));
    const app = h(lib.Excalidraw, {
      langCode: lang,
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
        post({ type: "linkOpen", link: element.link, elementId: element.id, elementType: element.type });
      },
    }, menu);
    window.ReactDOM.createRoot(document.getElementById("root")).render(app);
  }

  document.addEventListener("DOMContentLoaded", mount);
})();

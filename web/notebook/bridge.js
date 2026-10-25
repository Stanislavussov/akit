// The bridge between AKit (Swift, NotebookEditorView.swift) and the notebook's editor (Crepe,
// vendor/editor.js, built from tools/notebook-editor/editor.js).
//
// JS → Swift: window.webkit.messageHandlers.nb.postMessage({type, ...})
//   ready      the page is loaded and akitLoad can be called
//   loaded     akitLoad put a tab in the editor ({key})
//   linkOpen   ⌘-click on a link or a [[link]] ({link}); the page never navigates, AKit decides
//   problem    a script error or a Content-Security-Policy violation ({message})
//   save       the tab changed ({key, text}): the editor's Markdown, posted 800 ms after the last
//              change and only when it differs from the last one posted. AKit writes these bytes as
//              they are. Loading a tab hashes its text without posting, so opening never writes
// JS → Swift with a reply: window.webkit.messageHandlers.nbUpload.postMessage({name, type, base64})
//              → the image's link (`assets/…`), saved by AKit in notebook/assets/
// Swift → JS (callAsyncJavaScript):
//   akitLoad(text, key)   shows a tab's text (key: the tab the saves carry); a change still waiting
//                         for its post is posted first
//   akitTakeUnsaved()     a change still waiting for its post, now ({key, text}), or null
//   akitToday(heading)    Today (NB7): the day's heading at the top, the cursor under it
//   akitPosts()           how many saves were handed to AKit
//   akitDiagnostics()     what the page loaded, for snapshots and checks
//   akitDebugTick(index)  snapshots: a click on the index-th check box
"use strict";

(function () {
  const problems = [];
  function post(message) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nb;
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

  let editor = null;
  let key = null;
  let lastHash = null;
  let timer = null;
  let posts = 0;
  let loading = Promise.resolve();

  function unsaved() {
    clearTimeout(timer);
    timer = null;
    if (!editor || key === null) return null;
    const text = editor.markdown();
    const value = hash(text);
    if (value === lastHash) return null;
    lastHash = value;
    posts += 1;
    return { key, text };
  }

  function changed() {
    clearTimeout(timer);
    timer = setTimeout(() => {
      const save = unsaved();
      if (save) post({ type: "save", key: save.key, text: save.text });
    }, 800);
  }

  function readBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(file);
    });
  }

  async function upload(file) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nbUpload;
    if (!handler) throw new Error("No AKit to save the image.");
    return await handler.postMessage({ name: file.name || "", type: file.type || "", base64: await readBase64(file) });
  }

  function imageURL(link) {
    if (/^[a-z][a-z0-9+.-]*:/i.test(link)) return link;
    return "akit-web://app/files/" + link.split("/").map(encodeURIComponent).join("/");
  }

  window.akitLoad = function (text, newKey) {
    const before = unsaved();
    if (before) post({ type: "save", key: before.key, text: before.text });
    loading = loading.then(async () => {
      if (editor) await editor.destroy();
      const root = document.getElementById("root");
      root.innerHTML = "";
      key = null;
      editor = await window.AKitEditor.create(root, text, {
        onChange: changed,
        onOpenLink: (link) => post({ type: "linkOpen", link }),
        upload,
        imageURL,
      });
      key = newKey;
      lastHash = hash(editor.markdown());
      window.scrollTo(0, 0);
      post({ type: "loaded", key });
    });
    return loading;
  };

  window.akitTakeUnsaved = function () { return unsaved(); };
  window.akitPosts = function () { return posts; };
  window.akitToday = async function (heading) {
    await loading;
    if (!editor) return false;
    const changedNow = editor.focusDay(heading);
    return changedNow;
  };

  window.akitDiagnostics = async function () {
    await loading;
    const sheets = Array.from(document.styleSheets).map((sheet) => sheet.href || "inline");
    return {
      problems,
      key,
      sheets,
      tasks: Array.from(document.querySelectorAll(".milkdown .label-wrapper .label")).map((node) => node.classList.contains("checked") ? "x" : node.classList.contains("unchecked") ? " " : null).filter(Boolean).join(""),
      images: Array.from(document.querySelectorAll(".milkdown img")).map((img) => img.getAttribute("src") + (img.complete && img.naturalWidth ? " loaded" : " not loaded")),
      wikilinks: Array.from(document.querySelectorAll(".akit-wikilink")).map((node) => node.getAttribute("data-link")),
      markdown: editor ? editor.markdown() : null,
    };
  };

  window.akitDebugTick = async function (index) {
    await loading;
    const boxes = document.querySelectorAll(".milkdown .label-wrapper .label.checked, .milkdown .label-wrapper .label.unchecked");
    const box = boxes[index];
    if (!box) return false;
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      box.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
    }
    return true;
  };

  post({ type: "ready" });
})();

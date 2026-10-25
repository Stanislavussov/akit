// The Notebook's editor (docs/design/notebook.md, NB3): Milkdown Crepe with the features AKit uses,
// and the fixes that keep a tab's Markdown close to what Obsidian and people write (spike 0):
// - `-` bullets and `---` rules (Crepe's defaults are `*` and `***`);
// - `[[links]]` unescaped (remark writes `\[\[`), shown as links, ⌘-click opens them;
// - frontmatter kept as it was, outside the editor (Crepe has no frontmatter node);
// - an image's alt text is Crepe's size ratio (`![1.00](…)`): written as `![](…)`;
// - an empty line (remark writes `<br />`) is left out.
// Built by tools/build-notebook-editor.sh into web/notebook/vendor/editor.js, which defines
// window.AKitEditor; web/notebook/bridge.js talks to AKit.
import { CrepeBuilder } from "@milkdown/crepe/builder";
import { blockEdit } from "@milkdown/crepe/feature/block-edit";
import { codeMirror } from "@milkdown/crepe/feature/code-mirror";
import { cursor } from "@milkdown/crepe/feature/cursor";
import { imageBlock } from "@milkdown/crepe/feature/image-block";
import { linkTooltip } from "@milkdown/crepe/feature/link-tooltip";
import { listItem } from "@milkdown/crepe/feature/list-item";
import { placeholder } from "@milkdown/crepe/feature/placeholder";
import { table } from "@milkdown/crepe/feature/table";
import { toolbar } from "@milkdown/crepe/feature/toolbar";
import { languages } from "@codemirror/language-data";
import { editorViewCtx, remarkStringifyOptionsCtx } from "@milkdown/kit/core";
import { $prose } from "@milkdown/kit/utils";
import { Plugin, PluginKey, TextSelection } from "@milkdown/kit/prose/state";
import { Decoration, DecorationSet } from "@milkdown/kit/prose/view";
import "@milkdown/crepe/theme/common/prosemirror.css";
import "@milkdown/crepe/theme/common/reset.css";
import "@milkdown/crepe/theme/common/block-edit.css";
import "@milkdown/crepe/theme/common/code-mirror.css";
import "@milkdown/crepe/theme/common/cursor.css";
import "@milkdown/crepe/theme/common/image-block.css";
import "@milkdown/crepe/theme/common/link-tooltip.css";
import "@milkdown/crepe/theme/common/list-item.css";
import "@milkdown/crepe/theme/common/placeholder.css";
import "@milkdown/crepe/theme/common/table.css";
import "@milkdown/crepe/theme/common/toolbar.css";

const WIKILINK = /\[\[([^\[\]\n]+)\]\]/g;

// Frontmatter at the very top: `---` … `---` and its line break.
export function splitFrontmatter(text) {
  const match = /^---\r?\n[\s\S]*?\r?\n---[ \t]*(\r?\n|$)/.exec(text);
  return match ? { front: match[0], body: text.slice(match[0].length) } : { front: "", body: text };
}

// What remark wrote, made back into what people write.
export function cleanMarkdown(markdown) {
  return markdown
    .replace(/\\\[\\\[([^\[\]\n]*?)\]\]/g, "[[$1]]")
    .replace(/!\[\d+(?:\.\d+)?\]\(/g, "![](")
    .replace(/^<br \/>\n\n?/, "")
    .replace(/\n<br \/>\n(?=\n|$)/g, "");
}

// [[links]] look like links; ⌘-click on one, or on a web link, asks AKit to open it.
function linkPlugin(onOpenLink) {
  const key = new PluginKey("akit-links");
  function decorations(doc) {
    const found = [];
    doc.descendants((node, pos) => {
      if (!node.isText) return;
      if (node.marks.some((mark) => mark.type.name === "inlineCode")) return;
      for (const match of node.text.matchAll(WIKILINK)) {
        found.push(Decoration.inline(pos + match.index, pos + match.index + match[0].length,
          { class: "akit-wikilink", "data-link": match[0], title: "⌘-click opens " + match[1] }));
      }
    });
    return DecorationSet.create(doc, found);
  }
  return $prose(() => new Plugin({
    key,
    state: {
      init: (_, state) => decorations(state.doc),
      apply: (tr, old) => (tr.docChanged ? decorations(tr.doc) : old),
    },
    props: {
      decorations: (state) => key.getState(state),
      handleClick(view, pos, event) {
        if (!event.metaKey) return false;
        const wiki = event.target.closest && event.target.closest(".akit-wikilink");
        if (wiki) {
          onOpenLink(wiki.getAttribute("data-link"));
          return true;
        }
        const anchor = event.target.closest && event.target.closest("a[href]");
        const mark = view.state.doc.resolve(pos).marks().find((m) => m.type.name === "link");
        const href = mark ? mark.attrs.href : anchor && anchor.getAttribute("href");
        if (href) {
          onOpenLink(href);
          return true;
        }
        return false;
      },
      // A plain click on a web link would navigate the page: AKit cancels that, ⌘-click opens it.
      handleDOMEvents: {
        click(view, event) {
          if (event.target.closest && event.target.closest("a[href]")) event.preventDefault();
          return false;
        },
      },
    },
  }));
}

// One editor on `root` with `markdown` (frontmatter included). Options:
//   onChange()            the document changed (not on load)
//   onOpenLink(link)      ⌘-click on a link or a [[link]]
//   upload(file)          a pasted or dropped image → Promise of its link (`assets/…`)
//   imageURL(link)        the URL that shows an image link
//   placeholder           the empty line's hint
// Returns { markdown(), destroy(), focusDay(heading), editor }.
export async function create(root, markdown, options) {
  const { front, body } = splitFrontmatter(markdown);
  const builder = new CrepeBuilder({ root, defaultValue: body });
  builder.editor.config((ctx) => {
    ctx.update(remarkStringifyOptionsCtx, (prev) => ({ ...prev, bullet: "-", rule: "-" }));
  });
  builder
    .addFeature(listItem)
    .addFeature(linkTooltip, { inputPlaceholder: "Paste a link, or type [[note]] in the text" })
    .addFeature(cursor)
    .addFeature(imageBlock, {
      onUpload: options.upload,
      inlineOnUpload: options.upload,
      blockOnUpload: options.upload,
      proxyDomURL: options.imageURL,
      blockUploadPlaceholderText: "Paste or drop an image, or paste its link",
      inlineUploadPlaceholderText: "or paste a link",
    })
    .addFeature(blockEdit)
    .addFeature(toolbar)
    .addFeature(placeholder, { text: options.placeholder || "Type / for blocks, [ ] for a task", mode: "block" })
    .addFeature(table)
    .addFeature(codeMirror, { languages });
  builder.editor.use(linkPlugin(options.onOpenLink));
  let ready = false;
  builder.on((listener) => {
    listener.markdownUpdated(() => {
      if (ready) options.onChange();
    });
  });
  await builder.create();
  ready = true;
  return {
    editor: builder.editor,
    markdown: () => front + cleanMarkdown(builder.getMarkdown()),
    setReadonly: (on) => builder.setReadonly(on),
    destroy: () => builder.destroy(),
    // Today (NB7): the heading of the day at the top (after a first `# Title`), made when missing,
    // with an empty line under it for the cursor. true when the document changed.
    focusDay(text) {
      const view = builder.editor.ctx.get(editorViewCtx);
      const { state } = view;
      const schema = state.schema;
      let found = null;
      state.doc.forEach((node, offset) => {
        if (found === null && node.type.name === "heading" && node.attrs.level === 2 && node.textContent.trim() === text) found = offset;
      });
      let tr = state.tr;
      let changed = false;
      if (found === null) {
        const first = state.doc.firstChild;
        const at = first && first.type.name === "heading" && first.attrs.level === 1 ? first.nodeSize : 0;
        const heading = schema.nodes.heading.create({ level: 2 }, schema.text(text));
        tr = tr.insert(at, [heading, schema.nodes.paragraph.create()]);
        found = at;
        changed = true;
      }
      const after = found + tr.doc.nodeAt(found).nodeSize;
      tr = tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(after + 1, tr.doc.content.size))));
      view.dispatch(tr.scrollIntoView());
      view.focus();
      return changed;
    },
  };
}

window.AKitEditor = { create, splitFrontmatter, cleanMarkdown };

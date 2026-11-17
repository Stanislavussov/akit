// Excerpt of @earendil-works/pi-coding-agent 1.0.4, dist/core/extensions/types.d.ts (MIT).
// Only the declarations the Flows runner uses, copied as they are; types from other Pi packages
// (pi-tui, pi-ai, typebox) that these members do not need are left out. See SOURCE.md.
declare module "@earendil-works/pi-coding-agent" {
    export interface ExtensionUIDialogOptions {
        /** AbortSignal to programmatically dismiss the dialog. */
        signal?: AbortSignal;
        /** Timeout in milliseconds. Dialog auto-dismisses with live countdown display. */
        timeout?: number;
    }
    /** Placement for extension widgets. */
    export type WidgetPlacement = "aboveEditor" | "belowEditor";
    /** Options for extension widgets. */
    export interface ExtensionWidgetOptions {
        /** Where the widget is rendered. Defaults to "aboveEditor". */
        placement?: WidgetPlacement;
    }
    export interface ExtensionUIContext {
        /** Show a selector and return the user's choice. */
        select(title: string, options: string[], opts?: ExtensionUIDialogOptions): Promise<string | undefined>;
        /** Show a confirmation dialog. */
        confirm(title: string, message: string, opts?: ExtensionUIDialogOptions): Promise<boolean>;
        /** Show a text input dialog. */
        input(title: string, placeholder?: string, opts?: ExtensionUIDialogOptions): Promise<string | undefined>;
        /** Show a notification to the user. */
        notify(message: string, type?: "info" | "warning" | "error"): void;
        /** Set status text in the footer/status bar. Pass undefined to clear. */
        setStatus(key: string, text: string | undefined): void;
        /** Set a widget to display above or below the editor. Accepts string array or component factory. */
        setWidget(key: string, content: string[] | undefined, options?: ExtensionWidgetOptions): void;
        editor(title: string, prefill?: string): Promise<string | undefined>;
    }
    export interface ExtensionContext {
        /** UI methods for user interaction */
        ui: ExtensionUIContext;
        /** Whether dialog-capable UI is available (true in TUI and RPC modes) */
        hasUI: boolean;
        /** Current working directory */
        cwd: string;
        /** The current abort signal, or undefined when the agent is not streaming. */
        signal: AbortSignal | undefined;
    }
    export interface ExtensionCommandContext extends ExtensionContext {
        /** Wait for the agent to finish streaming */
        waitForIdle(): Promise<void>;
    }
    export interface RegisteredCommand {
        name: string;
        description?: string;
        handler: (args: string, ctx: ExtensionCommandContext) => Promise<void>;
    }
    export interface SessionShutdownEvent {
        type: "session_shutdown";
        reason: "quit" | "reload" | "new" | "resume" | "fork";
    }
    /** Handler function type for events */
    export type ExtensionHandler<E, R = undefined> = (event: E, ctx: ExtensionContext) => Promise<R | void> | R | void;
    /** Tool definition for registerTool(). Excerpt: TypeBox's TSchema/Static are `object`/`any`, the
     * result is AgentToolResult's two required fields, render and loadout members left out. */
    export interface ToolDefinition {
        /** Tool name (used in LLM tool calls) */
        name: string;
        /** Human-readable label for UI */
        label: string;
        /** Description for LLM */
        description: string;
        /** Parameter schema (TypeBox) */
        parameters: object;
        /** Execute the tool. */
        execute(toolCallId: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, ctx: ExtensionContext): Promise<{
            content: { type: "text"; text: string }[];
            details: unknown;
        }>;
    }
    /** Excerpt: only CustomToolCallEvent of the union; the built-in tools' typed inputs are
     * structurally the same `toolName` + `input` record. */
    interface ToolCallEventBase {
        type: "tool_call";
        toolCallId: string;
        /** Set when another tool (for example a codemode script) issued this call. */
        parentToolCallId?: string;
    }
    export interface CustomToolCallEvent extends ToolCallEventBase {
        toolName: string;
        input: Record<string, unknown>;
    }
    export type ToolCallEvent = CustomToolCallEvent;
    export interface ToolCallEventResult {
        /** Block tool execution. To modify arguments, mutate `event.input` in place instead. */
        block?: boolean;
        reason?: string;
        /**
         * Hint that the agent should stop after the current tool batch when this call is blocked.
         * Early termination only happens when every finalized tool result in the batch sets this to true.
         */
        terminate?: boolean;
    }
    export interface ExtensionAPI {
        on(event: "session_shutdown", handler: ExtensionHandler<SessionShutdownEvent>): () => void;
        on(event: "tool_call", handler: ExtensionHandler<ToolCallEvent, ToolCallEventResult>): () => void;
        /** Register a custom command. */
        registerCommand(name: string, options: Omit<RegisteredCommand, "name">): void;
        registerTool(tool: ToolDefinition): void;
    }
}

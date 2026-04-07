import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

export function createSandboxServer() {
  const server = new McpServer({
    name: "SilbercueSwift",
    version: "3.6.2",
  });

  // SessionState
  server.tool("set_defaults", "Set, show, or clear session defaults for project, scheme, and simulator. These defaults are used when parameters are omitted from tool calls. Usually not needed — the server auto-detects from the environment. Use as escape hatch when auto-detection picks the wrong target.", { project: z.string().optional(), scheme: z.string().optional(), simulator: z.string().optional(), action: z.enum(["set","show","clear"]).optional() }, async () => ({ content: [] }));

  // BuildTools
  server.tool("build_sim", "Build an iOS app for simulator. Uses xcodebuild with optimized flags. Project, scheme, and simulator are auto-detected if omitted.", { project: z.string().optional(), scheme: z.string().optional(), simulator: z.string().optional(), configuration: z.string().optional() }, async () => ({ content: [] }));
  server.tool("build_run_sim", "Build, install, and launch an iOS app on a simulator in one call. Runs build, settings extraction, simulator boot, and Simulator.app in parallel for maximum speed. Equivalent to Xcode's Cmd+R. Project, scheme, and simulator are auto-detected if omitted.", { project: z.string().optional(), scheme: z.string().optional(), simulator: z.string().optional(), configuration: z.string().optional() }, async () => ({ content: [] }));
  server.tool("clean", "Clean Xcode build artifacts for a project/scheme. Project and scheme are auto-detected if omitted.", { project: z.string().optional(), scheme: z.string().optional() }, async () => ({ content: [] }));
  server.tool("discover_projects", "Find Xcode projects and workspaces in a directory.", { path: z.string() }, async () => ({ content: [] }));
  server.tool("list_schemes", "List available schemes for a project. Project is auto-detected if omitted.", { project: z.string().optional() }, async () => ({ content: [] }));

  // SimTools
  server.tool("list_sims", "List available iOS simulators with their state and UDID.", { filter: z.string().optional() }, async () => ({ content: [] }));
  server.tool("boot_sim", "Boot an iOS simulator by name or UDID.", { simulator: z.string() }, async () => ({ content: [] }));
  server.tool("shutdown_sim", "Shutdown a running simulator.", { simulator: z.string() }, async () => ({ content: [] }));
  server.tool("install_app", "Install an app bundle on a booted simulator. App path is auto-detected from last build if omitted.", { simulator: z.string().optional(), app_path: z.string().optional() }, async () => ({ content: [] }));
  server.tool("launch_app", "Launch an app on a booted simulator. Bundle ID is auto-detected from last build if omitted.", { simulator: z.string().optional(), bundle_id: z.string().optional() }, async () => ({ content: [] }));
  server.tool("terminate_app", "Terminate a running app on a simulator. Bundle ID is auto-detected from last build if omitted.", { simulator: z.string().optional(), bundle_id: z.string().optional() }, async () => ({ content: [] }));
  server.tool("clone_sim", "Clone a simulator to create a snapshot of its current state (apps, data, settings).", { simulator: z.string(), name: z.string() }, async () => ({ content: [] }));
  server.tool("erase_sim", "Erase a simulator — resets to factory state. Removes all apps, data, and settings. Simulator must be shut down first.", { simulator: z.string() }, async () => ({ content: [] }));
  server.tool("delete_sim", "Permanently delete a simulator. Use to clean up cloned snapshots that are no longer needed.", { simulator: z.string() }, async () => ({ content: [] }));
  server.tool("set_orientation", "Set device orientation (portrait/landscape) via WDA.", { orientation: z.enum(["PORTRAIT","LANDSCAPE","LANDSCAPE_LEFT","LANDSCAPE_RIGHT"]) }, async () => ({ content: [] }));
  server.tool("sim_status", "Quick-glance table of all simulators — like looking at phones on a desk. Shows state, short UDID, name, runtime, and cached info (running app, orientation) for booted sims. Fast: ~15ms.", { filter: z.string().optional(), active_only: z.boolean().optional() }, async () => ({ content: [] }));
  server.tool("sim_inspect", "Pick up one or more simulators for deep inspection. Returns cached state: running app, orientation, alert state, WDA status, console errors, screen info, uptime.", { udid: z.array(z.string()), refresh: z.boolean().optional() }, async () => ({ content: [] }));

  // ScreenshotTools
  server.tool("screenshot", "Take a screenshot of a booted simulator. Returns the image inline. Use quality: 'compact' for UI verification (75% smaller, saves context window).", { simulator: z.string().optional(), format: z.string().optional(), quality: z.string().optional() }, async () => ({ content: [] }));

  // UITools
  server.tool("wda_status", "Check if WebDriverAgent is running and reachable.", {}, async () => ({ content: [] }));
  server.tool("handle_alert", "Handle iOS system alerts AND in-app dialogs. Actions: accept, dismiss, get_text, accept_all, dismiss_all.", { action: z.string(), button_label: z.string().optional() }, async () => ({ content: [] }));
  server.tool("wda_create_session", "Create a new WDA session, optionally for a specific app.", { bundle_id: z.string().optional(), wda_url: z.string().optional() }, async () => ({ content: [] }));
  server.tool("find_element", "Find a UI element. With scroll: true, auto-scrolls the nearest ScrollView/List until the element appears.", { using: z.string(), value: z.string(), scroll: z.boolean().optional(), direction: z.string().optional(), max_swipes: z.number().optional() }, async () => ({ content: [] }));
  server.tool("find_elements", "Find multiple UI elements matching a query.", { using: z.string(), value: z.string() }, async () => ({ content: [] }));
  server.tool("click_element", "Click/tap a UI element by its ID. Set screenshot: true to get an inline screenshot after the tap.", { element_id: z.string(), screenshot: z.boolean().optional() }, async () => ({ content: [] }));
  server.tool("tap_coordinates", "Tap at specific x,y coordinates on screen. Set screenshot: true to get an inline screenshot after the tap.", { x: z.number(), y: z.number(), screenshot: z.boolean().optional() }, async () => ({ content: [] }));
  server.tool("type_text", "Type text into a specified element, or auto-find the first text input on screen.", { text: z.string(), element_id: z.string().optional(), clear_first: z.boolean().optional(), screenshot: z.boolean().optional() }, async () => ({ content: [] }));
  server.tool("get_text", "Get text content of a UI element.", { element_id: z.string() }, async () => ({ content: [] }));
  server.tool("get_source", "Get the view hierarchy of the current screen. Use format 'pruned' for a flat list of interactive elements (~80-90% smaller, ideal for LLM).", { format: z.string().optional() }, async () => ({ content: [] }));
  server.tool("navigate", "Navigate to a screen in one call: finds element by label, taps it, waits for animation, takes compact screenshot. Replaces 3 separate calls.", { target: z.string(), back: z.boolean().optional(), scroll: z.boolean().optional(), settle_ms: z.number().optional() }, async () => ({ content: [] }));

  // LogTools
  server.tool("start_log_capture", "Start capturing real-time logs from a simulator with smart filtering.", { simulator: z.string().optional(), mode: z.enum(["app","smart","verbose"]).optional(), process: z.string().optional(), subsystem: z.string().optional(), predicate: z.string().optional(), level: z.string().optional() }, async () => ({ content: [] }));
  server.tool("stop_log_capture", "Stop the running log capture.", {}, async () => ({ content: [] }));
  server.tool("read_logs", "Read captured log lines with topic-based filtering. Default shows only app logs + crashes.", { include: z.array(z.string()).optional(), last: z.number().optional(), clear: z.boolean().optional() }, async () => ({ content: [] }));
  server.tool("wait_for_log", "Wait for a specific log pattern to appear in the log stream. Eliminates the need for sleep() hacks when waiting for app state changes.", { pattern: z.string(), timeout: z.number().optional(), simulator: z.string().optional(), subsystem: z.string().optional() }, async () => ({ content: [] }));

  // GitTools
  server.tool("git_status", "Show git status (porcelain format) for a repository.", { path: z.string() }, async () => ({ content: [] }));
  server.tool("git_diff", "Show git diff for a repository. Optionally diff staged changes or specific files.", { path: z.string(), staged: z.boolean().optional(), file: z.string().optional() }, async () => ({ content: [] }));
  server.tool("git_log", "Show recent git log entries.", { path: z.string(), count: z.number().optional(), oneline: z.boolean().optional() }, async () => ({ content: [] }));
  server.tool("git_commit", "Create a git commit with staged changes.", { path: z.string(), message: z.string(), add_all: z.boolean().optional() }, async () => ({ content: [] }));
  server.tool("git_branch", "List, create, or switch git branches.", { path: z.string(), action: z.string().optional(), name: z.string().optional() }, async () => ({ content: [] }));

  // ConsoleTools
  server.tool("launch_app_console", "Launch an app with console output capture. Captures all print() and NSLog output.", { simulator: z.string().optional(), bundle_id: z.string().optional(), args: z.string().optional() }, async () => ({ content: [] }));
  server.tool("read_app_console", "Read captured console output (stdout + stderr) from a running app launched with launch_app_console.", { last: z.number().optional(), clear: z.boolean().optional(), stream: z.string().optional() }, async () => ({ content: [] }));
  server.tool("stop_app_console", "Stop the app console capture and terminate the app.", {}, async () => ({ content: [] }));

  // TestTools
  server.tool("test_sim", "Run xcodebuild test on simulator and return structured xcresult summary. Shows passed/failed/skipped counts and duration.", { project: z.string().optional(), scheme: z.string().optional(), simulator: z.string().optional(), configuration: z.string().optional(), testplan: z.string().optional(), filter: z.string().optional(), coverage: z.boolean().optional() }, async () => ({ content: [] }));

  // PlanExecutor
  server.tool("run_plan", "Execute a structured test plan deterministically. Runs find/click/verify/screenshot steps internally without LLM round-trips. 50x faster than individual tool calls for sequential UI interactions.", { steps: z.array(z.object({}).passthrough()), on_error: z.enum(["abort_with_screenshot","continue","abort"]).optional(), timeout_ms: z.number().optional(), operator: z.boolean().optional(), operator_budget: z.number().optional() }, async () => ({ content: [] }));
  server.tool("run_plan_decide", "Provide a decision for a paused plan. Called after run_plan returns status 'decision_needed'.", { session_id: z.string(), decision: z.enum(["accept","dismiss","skip","abort","continue"]), reasoning: z.string().optional() }, async () => ({ content: [] }));

  return server;
}

// Smithery commandFunction for local stdio launch
export default (config) => ({ command: 'SilbercueSwift', args: [], env: {} });

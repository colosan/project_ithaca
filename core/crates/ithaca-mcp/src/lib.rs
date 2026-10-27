//! `ithaca-mcp`: a Model Context Protocol server over stdio that lets the writer's own Claude read
//! the projects they chose in Settings → Claude (ADR-0001, ADR-0009, design/PRODUCT.md).
//!
//! - **Read-only.** Every request opens the library fresh with [`Store::open_read_only`]: no lock,
//!   nothing written, and the newest blocks the app has written are seen. There are no write tools
//!   yet; see [`tools::Access`] for how they will be added (recorded as `actor: claude`).
//! - **Only what the writer exposed.** `<library>/mcp.json` is read on every request; missing,
//!   unreadable or disabled → every tool returns an error telling the writer where to turn it on.
//! - **Protocol**: JSON-RPC 2.0, one message per line. Dual-era (MCP spec 2026-07-28 §Versioning):
//!   modern requests carry `_meta["io.modelcontextprotocol/protocolVersion"]` and are served
//!   statelessly (`server/discover` included); legacy clients open with `initialize` and get
//!   2025-11-25 (or the older version they ask for). Hand-written on serde_json; see ADR-0009.

pub mod tools;

use std::path::{Path, PathBuf};

use ithaca_store::Store;
use ithaca_store::mcp::McpSettings;
use serde_json::{Map, Value, json};

/// The current MCP revision (modern: per-request `_meta`, no handshake).
pub const MODERN_VERSION: &str = "2026-07-28";
/// Handshake (`initialize`) revisions this server also speaks, newest first.
pub const LEGACY_VERSIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

pub const SERVER_NAME: &str = "ithaca-mcp";
/// The app's version (changed: qa4): `ITHACA_APP_VERSION` at build time (tools/mac/build.sh passes
/// the repo's VERSION file), else the workspace version.
pub const SERVER_VERSION: &str = match option_env!("ITHACA_APP_VERSION") {
    Some(v) if !v.is_empty() => v,
    _ => env!("CARGO_PKG_VERSION"),
};

const META_VERSION: &str = "io.modelcontextprotocol/protocolVersion";
const META_CAPS: &str = "io.modelcontextprotocol/clientCapabilities";
const META_SERVER: &str = "io.modelcontextprotocol/serverInfo";

// JSON-RPC and MCP error codes.
pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const INTERNAL_ERROR: i64 = -32603;
pub const UNSUPPORTED_VERSION: i64 = -32022;

const INSTRUCTIONS: &str = "Ithaca is a writing app for serial fiction (mostly Korean web novels). \
These tools read the writer's manuscripts, read-only: only the projects the writer chose to share \
are visible. Start with list_projects; project, folder and sheet ids come from there and from \
get_outline (a project may also be named by its exact title). Setting notes, characters and \
world-building live in non-serial folders: get_lore returns them in one go. Episode numbers, \
statuses (draft/revising/scheduled/published) and stock (비축분) come from get_episode_stats. \
Characters, places, factions and terms the writer keeps as story-bible entries come from bible \
(one entry by name, with where it appears); mentions lists the entries a sheet names. \
You cannot change anything in Ithaca through these tools.";

/// Why a request opened no library: shown to the writer through Claude.
pub const DISABLED_MESSAGE: &str = "Claude access to Ithaca is turned off. In Ithaca, open \
Settings → Claude, turn it on and choose which works Claude may read.";

pub struct Server {
    library: PathBuf,
}

/// A tool failure: becomes a tool result with `isError: true` (the model can read and react).
#[derive(Debug, Clone, PartialEq)]
pub struct ToolError(pub String);

impl From<ithaca_store::StoreError> for ToolError {
    fn from(e: ithaca_store::StoreError) -> Self {
        use ithaca_store::StoreError as E;
        ToolError(match e {
            E::NotFound => "Not found.".into(),
            E::ReadOnly => "Ithaca is read-only for Claude.".into(),
            other => format!("Ithaca could not read the library: {other}"),
        })
    }
}

/// A JSON-RPC error.
struct RpcError {
    code: i64,
    message: String,
    data: Option<Value>,
}

impl RpcError {
    fn new(code: i64, message: impl Into<String>) -> RpcError {
        RpcError {
            code,
            message: message.into(),
            data: None,
        }
    }
}

/// What the tools see on one request: the settings and a fresh read-only snapshot.
pub struct Ctx {
    pub settings: McpSettings,
    pub store: Store,
}

impl Server {
    pub fn new(library: impl Into<PathBuf>) -> Server {
        Server {
            library: library.into(),
        }
    }

    pub fn library(&self) -> &Path {
        &self.library
    }

    /// The settings and a fresh snapshot of the library, or the message to show the writer.
    pub fn context(&self) -> Result<Ctx, ToolError> {
        let settings = match McpSettings::read(&self.library) {
            Ok(Some(s)) if s.enabled => s,
            Ok(_) => return Err(ToolError(DISABLED_MESSAGE.into())),
            Err(e) => {
                return Err(ToolError(format!(
                    "Ithaca's Claude settings could not be read ({e}). In Ithaca, open \
                     Settings → Claude and save them again."
                )));
            }
        };
        let store = Store::open_read_only(&self.library).map_err(|e| match e {
            ithaca_store::StoreError::NotFound => ToolError(format!(
                "No Ithaca library at {}. Open Ithaca once, or start ithaca-mcp with \
                 --library <folder>.",
                self.library.display()
            )),
            other => other.into(),
        })?;
        Ok(Ctx { settings, store })
    }

    /// One line of raw stdin bytes (without its `\n`) → the line to write back, if any. Bytes that
    /// are not UTF-8 get a parse error for that line only.
    pub fn handle_bytes(&self, line: &[u8]) -> Option<String> {
        match std::str::from_utf8(line) {
            Ok(s) => self.handle_line(s),
            Err(e) => Some(
                error_reply(
                    Value::Null,
                    RpcError::new(PARSE_ERROR, format!("message is not valid UTF-8: {e}")),
                )
                .to_string(),
            ),
        }
    }

    /// One line from stdin → the line to write back, if any.
    pub fn handle_line(&self, line: &str) -> Option<String> {
        let line = line.trim();
        if line.is_empty() {
            return None;
        }
        let out = match serde_json::from_str::<Value>(line) {
            Ok(Value::Array(batch)) if !batch.is_empty() => {
                let replies: Vec<Value> = batch
                    .into_iter()
                    .filter_map(|m| self.handle_message(m))
                    .collect();
                if replies.is_empty() {
                    return None;
                }
                Value::Array(replies)
            }
            Ok(Value::Array(_)) => {
                error_reply(Value::Null, RpcError::new(INVALID_REQUEST, "empty batch"))
            }
            Ok(msg) => self.handle_message(msg)?,
            Err(e) => error_reply(Value::Null, RpcError::new(PARSE_ERROR, e.to_string())),
        };
        Some(out.to_string())
    }

    /// One JSON-RPC message → its reply. Notifications and responses get none.
    pub fn handle_message(&self, msg: Value) -> Option<Value> {
        let Value::Object(msg) = msg else {
            return Some(error_reply(
                Value::Null,
                RpcError::new(INVALID_REQUEST, "not a JSON-RPC object"),
            ));
        };
        let Some(method) = msg.get("method").and_then(Value::as_str) else {
            // A response (we never send requests, so ignore it) or a request without a method.
            if msg.contains_key("result") || msg.contains_key("error") {
                return None;
            }
            let id = msg.get("id").cloned().unwrap_or(Value::Null);
            return Some(error_reply(id, RpcError::new(INVALID_REQUEST, "no method")));
        };
        // Notifications (`notifications/initialized`, `notifications/cancelled`, …): no reply.
        let id = msg.get("id")?.clone();
        if msg.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            let id = if id.is_string() || id.is_i64() || id.is_u64() {
                id
            } else {
                Value::Null
            };
            return Some(error_reply(
                id,
                RpcError::new(INVALID_REQUEST, "jsonrpc must be \"2.0\""),
            ));
        }
        if !(id.is_string() || id.is_i64() || id.is_u64()) {
            return Some(error_reply(
                Value::Null,
                RpcError::new(INVALID_REQUEST, "id must be a string or an integer"),
            ));
        }
        let empty = Map::new();
        let params = match msg.get("params") {
            None | Some(Value::Null) => &empty,
            Some(Value::Object(p)) => p,
            Some(_) => {
                return Some(error_reply(
                    id,
                    RpcError::new(INVALID_PARAMS, "params must be an object"),
                ));
            }
        };
        let modern = match check_meta(params) {
            Ok(m) => m,
            Err(e) => return Some(error_reply(id, e)),
        };
        Some(match self.dispatch(method, params) {
            Ok(mut result) => {
                if modern && let Value::Object(r) = &mut result {
                    r.entry("resultType").or_insert_with(|| json!("complete"));
                    let meta = r.entry("_meta").or_insert_with(|| json!({}));
                    if let Value::Object(m) = meta {
                        m.insert(META_SERVER.into(), server_info());
                    }
                }
                json!({ "jsonrpc": "2.0", "id": id, "result": result })
            }
            Err(e) => error_reply(id, e),
        })
    }

    fn dispatch(&self, method: &str, params: &Map<String, Value>) -> Result<Value, RpcError> {
        match method {
            "initialize" => Ok(initialize(params)),
            "ping" => Ok(json!({})),
            "server/discover" => Ok(json!({
                "supportedVersions": supported_versions(),
                "capabilities": capabilities(),
                "instructions": INSTRUCTIONS,
                "_meta": { META_SERVER: server_info() },
            })),
            "tools/list" => Ok(json!({ "tools": tools::list() })),
            "tools/call" => self.call_tool(params),
            "resources/list" => Ok(json!({ "resources": self.resources() })),
            "resources/templates/list" => Ok(json!({ "resourceTemplates": [] })),
            "resources/read" => self.read_resource(params),
            other => Err(RpcError::new(
                METHOD_NOT_FOUND,
                format!("Method not found: {other}"),
            )),
        }
    }

    fn call_tool(&self, params: &Map<String, Value>) -> Result<Value, RpcError> {
        let name = params
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::new(INVALID_PARAMS, "tools/call needs a tool name"))?;
        let tool = tools::find(name)
            .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("Unknown tool: {name}")))?;
        let empty = Map::new();
        let args = match params.get("arguments") {
            None | Some(Value::Null) => &empty,
            Some(Value::Object(a)) => a,
            Some(_) => return Err(RpcError::new(INVALID_PARAMS, "arguments must be an object")),
        };
        (tool.check)(args).map_err(|m| RpcError::new(INVALID_PARAMS, m))?;
        let out = self.context().and_then(|ctx| (tool.run)(&ctx, args));
        Ok(match out {
            Ok(out) => {
                let mut r = json!({
                    "content": [{ "type": "text", "text": out.text }],
                    "isError": false,
                });
                if let Some(s) = out.structured {
                    r["structuredContent"] = s;
                }
                r
            }
            Err(ToolError(msg)) => json!({
                "content": [{ "type": "text", "text": msg }],
                "isError": true,
            }),
        })
    }

    /// One outline and one lore resource per shared project; none when access is off.
    fn resources(&self) -> Vec<Value> {
        let Ok(ctx) = self.context() else {
            return vec![];
        };
        let mut out = Vec::new();
        for p in tools::shared_projects(&ctx) {
            out.push(json!({
                "uri": format!("ithaca://projects/{}/outline", p.id),
                "name": format!("{} — outline", p.title),
                "description": "Folders, sheets, counts and episode information (JSON).",
                "mimeType": "application/json",
            }));
            out.push(json!({
                "uri": format!("ithaca://projects/{}/lore", p.id),
                "name": format!("{} — setting notes", p.title),
                "description": "Every sheet of the project's non-serial folders.",
                "mimeType": "text/markdown",
            }));
        }
        out
    }

    fn read_resource(&self, params: &Map<String, Value>) -> Result<Value, RpcError> {
        let uri = params
            .get("uri")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::new(INVALID_PARAMS, "resources/read needs a uri"))?;
        let not_found = || RpcError {
            data: Some(json!({ "uri": uri })),
            ..RpcError::new(INVALID_PARAMS, "Resource not found")
        };
        let rest = uri
            .strip_prefix("ithaca://projects/")
            .ok_or_else(not_found)?;
        let (project, what) = rest.split_once('/').ok_or_else(not_found)?;
        let ctx = self
            .context()
            .map_err(|ToolError(m)| RpcError::new(INTERNAL_ERROR, m))?;
        let mut args = Map::new();
        args.insert("project".into(), json!(project));
        if what == "lore" {
            // A resource has no way to ask for the next page: allow the largest one.
            args.insert("limit".into(), json!(tools::MAX_LORE_CHARS));
        }
        let (out, mime) = match what {
            "outline" => (tools::get_outline(&ctx, &args), "application/json"),
            "lore" => (tools::get_lore(&ctx, &args), "text/markdown"),
            _ => return Err(not_found()),
        };
        let out = out.map_err(|_| not_found())?;
        Ok(json!({ "contents": [{ "uri": uri, "mimeType": mime, "text": out.text }] }))
    }
}

/// `Ok(true)` for a modern request, `Ok(false)` for a legacy one (no protocol version in `_meta`).
fn check_meta(params: &Map<String, Value>) -> Result<bool, RpcError> {
    let Some(meta) = params.get("_meta").and_then(Value::as_object) else {
        return Ok(false);
    };
    let Some(v) = meta.get(META_VERSION) else {
        return Ok(false);
    };
    let requested = v.as_str().unwrap_or_default();
    if requested == MODERN_VERSION {
        if !meta.contains_key(META_CAPS) {
            return Err(RpcError::new(
                INVALID_PARAMS,
                format!("_meta[\"{META_CAPS}\"] is required"),
            ));
        }
        return Ok(true);
    }
    // A legacy revision named per request: serve it like an initialized legacy session.
    if LEGACY_VERSIONS.contains(&requested) {
        return Ok(false);
    }
    Err(RpcError {
        data: Some(json!({ "supported": supported_versions(), "requested": v })),
        ..RpcError::new(UNSUPPORTED_VERSION, "Unsupported protocol version")
    })
}

fn supported_versions() -> Vec<&'static str> {
    std::iter::once(MODERN_VERSION)
        .chain(LEGACY_VERSIONS)
        .collect()
}

fn capabilities() -> Value {
    json!({ "tools": { "listChanged": false }, "resources": {} })
}

fn server_info() -> Value {
    json!({ "name": SERVER_NAME, "title": "Ithaca", "version": SERVER_VERSION })
}

/// Legacy handshake: the client's version if we speak it, else our newest legacy one.
fn initialize(params: &Map<String, Value>) -> Value {
    let asked = params
        .get("protocolVersion")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let version = LEGACY_VERSIONS
        .iter()
        .find(|v| **v == asked)
        .copied()
        .unwrap_or(LEGACY_VERSIONS[0]);
    json!({
        "protocolVersion": version,
        "capabilities": capabilities(),
        "serverInfo": server_info(),
        "instructions": INSTRUCTIONS,
    })
}

fn error_reply(id: Value, e: RpcError) -> Value {
    let mut err = json!({ "code": e.code, "message": e.message });
    if let Some(d) = e.data {
        err["data"] = d;
    }
    json!({ "jsonrpc": "2.0", "id": id, "error": err })
}

/// `$ITHACA_LIBRARY_PATH` when set (added: qa4), else
/// `~/Library/Application Support/Ithaca/Library` (ADR-0008 §4).
pub fn default_library() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("ITHACA_LIBRARY_PATH").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("Ithaca")
            .join("Library"),
    )
}

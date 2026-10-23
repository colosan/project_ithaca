//! Spawns the real `ithaca-mcp` binary and talks MCP to it over stdio while a writer (standing in
//! for the app) holds the library open.

use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use ithaca_model::{EpisodeInfo, EpisodeStatus, Language};
use ithaca_store::Store;
use serde_json::{Value, json};

struct Mcp {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next: i64,
}

impl Mcp {
    fn spawn(library: &Path) -> Mcp {
        let mut child = Command::new(env!("CARGO_BIN_EXE_ithaca-mcp"))
            .arg("--library")
            .arg(library)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Mcp {
            child,
            stdin,
            stdout,
            next: 1,
        }
    }

    fn send(&mut self, msg: &Value) {
        writeln!(self.stdin, "{msg}").unwrap();
        self.stdin.flush().unwrap();
    }

    fn recv(&mut self) -> Value {
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        assert!(line.ends_with('\n'), "one message per line: {line:?}");
        serde_json::from_str(&line).unwrap()
    }

    /// A request; returns the whole reply after checking its id.
    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.send(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        let r = self.recv();
        assert_eq!(r["jsonrpc"], "2.0");
        assert_eq!(r["id"], id, "{r}");
        r
    }

    fn call(&mut self, tool: &str, args: Value) -> Value {
        let r = self.request("tools/call", json!({ "name": tool, "arguments": args }));
        r["result"].clone()
    }
}

impl Drop for Mcp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn text(result: &Value) -> &str {
    result["content"][0]["text"].as_str().unwrap()
}

/// A library with a shared and a hidden project; returns (writer, shared id, hidden id).
fn library(dir: &Path) -> (Store, String, String) {
    let mut s = Store::open(dir, "mac-test").unwrap();
    let a = s
        .create_project(
            "등대지기의 딸",
            Language::Ko,
            &["연재".into(), "설정".into()],
        )
        .unwrap()
        .id;
    let o = s.outline(&a).unwrap();
    let (serial, notes) = (o.folders[0].id.clone(), o.folders[1].id.clone());
    let e1 = o.folders[0].sheets[0].id.clone();
    s.save_sheet(&a, &e1, "# 1화 안개\n\n등대 위로 안개가 올라왔다.")
        .unwrap();
    let e2 = s
        .create_sheet(&a, &serial, "# 2화 불빛\n\n불빛이 꺼졌다.")
        .unwrap()
        .id;
    s.create_sheet(
        &a,
        &notes,
        "# 인물\n\n해원: 등대지기의 딸. 안개를 싫어한다.",
    )
    .unwrap();
    s.renumber_episodes(&a, &serial).unwrap();
    s.set_status_through(&a, &serial, &e1, EpisodeStatus::Published)
        .unwrap();
    let mut info = s.sheet_summary_of(&a, &e2).unwrap().episode.unwrap();
    info.status = EpisodeStatus::Scheduled;
    info.publish_at = Some(4_102_444_800_000); // 2100-01-01
    s.set_episode(&a, &e2, Some(EpisodeInfo { ..info }))
        .unwrap();

    let b = s
        .create_project("비밀 원고", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let b1 = s.outline(&b).unwrap().folders[0].sheets[0].id.clone();
    s.save_sheet(&b, &b1, "# 숨김\n\n안개 속의 비밀.").unwrap();
    (s, a, b)
}

#[test]
fn without_mcp_json_every_tool_says_how_to_turn_it_on() {
    let dir = tempfile::tempdir().unwrap();
    let (_writer, a, _) = library(dir.path());
    let mut m = Mcp::spawn(dir.path());

    let init = m.request(
        "initialize",
        json!({ "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": { "name": "test", "version": "1" } }),
    );
    assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(init["result"]["serverInfo"]["name"], "ithaca-mcp");
    assert!(init["result"]["capabilities"]["tools"].is_object());
    m.send(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));

    let tools = m.request("tools/list", json!({}));
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "list_projects",
            "get_outline",
            "read_sheet",
            "search",
            "get_lore",
            "get_episode_stats"
        ]
    );
    for t in tools["result"]["tools"].as_array().unwrap() {
        assert_eq!(t["inputSchema"]["type"], "object");
        assert_eq!(t["annotations"]["readOnlyHint"], true);
    }

    let r = m.call("list_projects", json!({}));
    assert_eq!(r["isError"], true);
    assert!(text(&r).contains("Settings → Claude"), "{r}");
    let r = m.call("get_outline", json!({ "project": a }));
    assert_eq!(r["isError"], true);

    // Disabled is the same as missing; the server reads the file on every call.
    std::fs::write(
        dir.path().join("mcp.json"),
        json!({ "enabled": false, "projects": [a], "permission": "read" }).to_string(),
    )
    .unwrap();
    let r = m.call("list_projects", json!({}));
    assert_eq!(r["isError"], true);
    assert!(text(&r).contains("turned off"));
    assert_eq!(
        m.request("resources/list", json!({}))["result"]["resources"],
        json!([])
    );
}

#[test]
fn shared_project_is_readable_and_the_hidden_one_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let (mut writer, a, b) = library(dir.path());
    writer
        .set_mcp_settings(true, std::slice::from_ref(&a))
        .unwrap();
    let mut m = Mcp::spawn(dir.path());
    m.request(
        "initialize",
        json!({ "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": { "name": "test", "version": "1" } }),
    );

    let r = m.call("list_projects", json!({}));
    assert_eq!(r["isError"], false, "{r}");
    let ps = r["structuredContent"]["projects"].as_array().unwrap();
    assert_eq!(ps.len(), 1);
    assert_eq!(ps[0]["id"], a.as_str());
    assert_eq!(
        serde_json::from_str::<Value>(text(&r)).unwrap(),
        r["structuredContent"]
    );

    let hidden = m.call("get_outline", json!({ "project": b }));
    assert_eq!(hidden["isError"], true);

    // By title works too.
    let o = m.call("get_outline", json!({ "project": "등대지기의 딸" }));
    assert_eq!(o["isError"], false, "{o}");
    let folders = &o["structuredContent"]["folders"];
    assert_eq!(folders[0]["kind"], "serial");
    assert_eq!(folders[1]["kind"], "notes");
    assert_eq!(folders[0]["sheets"][0]["episode"]["status"], "published");
    let e1 = folders[0]["sheets"][0]["id"].as_str().unwrap().to_string();

    let s = m.call("read_sheet", json!({ "project": a, "sheet": e1 }));
    assert_eq!(s["isError"], false, "{s}");
    assert!(text(&s).contains("등대 위로 안개가 올라왔다."));
    assert!(text(&s).contains("Episode: published, number 1"));

    let hits = m.call("search", json!({ "query": "안개" }));
    let hits = hits["structuredContent"]["hits"]
        .as_array()
        .unwrap()
        .clone();
    assert!(hits.len() >= 2);
    assert!(hits.iter().all(|h| h["project"] == a.as_str()), "{hits:?}");

    let lore = m.call("get_lore", json!({ "project": a }));
    assert!(text(&lore).contains("## 설정 / 인물"));
    assert!(text(&lore).contains("안개를 싫어한다"));
    assert!(
        !text(&lore).contains("불빛이 꺼졌다"),
        "serial text is not lore"
    );

    let st = m.call("get_episode_stats", json!({ "project": a }));
    let f = &st["structuredContent"]["folders"][0];
    assert_eq!(
        (
            &f["episodes"],
            &f["published"],
            &f["scheduled"],
            &f["stock"]
        ),
        (&json!(2), &json!(1), &json!(1), &json!(1))
    );
    assert_eq!(f["nextRelease"]["ms"], 4_102_444_800_000_i64);

    // The writer keeps writing; the next call sees it without restarting the server.
    let o = writer.outline(&a).unwrap();
    let e2 = o.folders[0].sheets[1].id.clone();
    writer
        .save_sheet(&a, &e2, "# 2화 불빛\n\n불빛이 다시 켜졌다.")
        .unwrap();
    let s = m.call("read_sheet", json!({ "project": a, "sheet": e2 }));
    assert!(text(&s).contains("불빛이 다시 켜졌다."), "{s}");

    // Unknown tool: a protocol error. Bad arguments: a tool error.
    let r = m.request(
        "tools/call",
        json!({ "name": "save_sheet", "arguments": {} }),
    );
    assert_eq!(r["error"]["code"], -32602);
    let r = m.call("read_sheet", json!({ "project": a }));
    assert_eq!(r["isError"], true);

    // Resources mirror the outline and lore of shared projects only.
    let rs = m.request("resources/list", json!({}));
    assert_eq!(rs["result"]["resources"].as_array().unwrap().len(), 2);
    let uri = format!("ithaca://projects/{a}/lore");
    let rr = m.request("resources/read", json!({ "uri": uri }));
    assert!(
        rr["result"]["contents"][0]["text"]
            .as_str()
            .unwrap()
            .contains("해원")
    );
    let rr = m.request(
        "resources/read",
        json!({ "uri": format!("ithaca://projects/{b}/lore") }),
    );
    assert_eq!(rr["error"]["code"], -32602);
    assert!(!writer.read_only(), "the writer kept its lock throughout");
}

#[test]
fn modern_requests_are_stateless_and_versions_are_checked() {
    let dir = tempfile::tempdir().unwrap();
    let (mut writer, a, _) = library(dir.path());
    writer
        .set_mcp_settings(true, std::slice::from_ref(&a))
        .unwrap();
    let mut m = Mcp::spawn(dir.path());
    let meta = |v: &str| {
        json!({ "_meta": {
            "io.modelcontextprotocol/protocolVersion": v,
            "io.modelcontextprotocol/clientInfo": { "name": "test", "version": "1" },
            "io.modelcontextprotocol/clientCapabilities": {}
        } })
    };

    let d = m.request("server/discover", meta("2026-07-28"));
    assert_eq!(d["result"]["resultType"], "complete");
    assert_eq!(d["result"]["supportedVersions"][0], "2026-07-28");
    assert!(
        d["result"]["supportedVersions"]
            .as_array()
            .unwrap()
            .contains(&json!("2025-11-25"))
    );
    assert_eq!(
        d["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"],
        "ithaca-mcp"
    );

    // No initialize: a modern tools/call works on its own.
    let mut p = meta("2026-07-28");
    p["name"] = json!("list_projects");
    p["arguments"] = json!({});
    let r = m.request("tools/call", p);
    assert_eq!(r["result"]["resultType"], "complete");
    assert_eq!(r["result"]["isError"], false);

    let bad = m.request("tools/list", meta("1900-01-01"));
    assert_eq!(bad["error"]["code"], -32022);
    assert_eq!(bad["error"]["data"]["requested"], "1900-01-01");

    let mut no_caps = meta("2026-07-28");
    no_caps["_meta"]
        .as_object_mut()
        .unwrap()
        .remove("io.modelcontextprotocol/clientCapabilities");
    assert_eq!(m.request("ping", no_caps)["error"]["code"], -32602);

    assert_eq!(m.request("ping", json!({}))["result"], json!({}));
    assert_eq!(
        m.request("nope/nothing", json!({}))["error"]["code"],
        -32601
    );
    m.send(&json!("not json-rpc"));
    assert_eq!(m.recv()["error"]["code"], -32600);
    writeln!(m.stdin, "{{broken").unwrap();
    m.stdin.flush().unwrap();
    assert_eq!(m.recv()["error"]["code"], -32700);
}

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
    // (note) Only `원고` (episode metadata) are numbered: make every serial sheet one.
    for x in s.outline(&a).unwrap().folders[0]
        .sheets
        .iter()
        .map(|x| x.id.clone())
        .collect::<Vec<_>>()
    {
        s.set_episode(&a, &x, Some(ithaca_model::EpisodeInfo::default()))
            .unwrap();
    }
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
            "get_episode_stats",
            "bible",
            "mentions"
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

// ── qa4 ───────────────────────────────────────────────────────────────

/// The JSON of a tool result: `structuredContent` when small, else the text after the summary.
fn payload(result: &Value) -> Value {
    if !result["structuredContent"].is_null() {
        return result["structuredContent"].clone();
    }
    let (_summary, json) = text(result).split_once("\n\n").unwrap();
    serde_json::from_str(json).unwrap()
}

/// The `Page: {…}` line of read_sheet / get_lore.
fn page_of(result: &Value) -> Value {
    let line = text(result)
        .lines()
        .find_map(|l| l.strip_prefix("Page: "))
        .unwrap();
    serde_json::from_str(line).unwrap()
}

#[test]
fn bad_bytes_and_bad_envelopes_get_errors_and_the_server_goes_on() {
    let dir = tempfile::tempdir().unwrap();
    let (_writer, _, _) = library(dir.path());
    let mut m = Mcp::spawn(dir.path());
    // Not UTF-8: a parse error for that line only.
    m.stdin
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"x\":\"\xff\xfe\"}\n")
        .unwrap();
    m.stdin.flush().unwrap();
    let r = m.recv();
    assert_eq!(r["error"]["code"], -32700, "{r}");
    assert_eq!(r["id"], Value::Null);
    assert_eq!(m.request("ping", json!({}))["result"], json!({}));

    // `jsonrpc` must be "2.0".
    m.send(&json!({ "id": 7, "method": "ping" }));
    let r = m.recv();
    assert_eq!((&r["error"]["code"], &r["id"]), (&json!(-32600), &json!(7)));
    m.send(&json!({ "jsonrpc": "1.0", "id": 8, "method": "ping" }));
    assert_eq!(m.recv()["error"]["code"], -32600);
    assert_eq!(m.request("ping", json!({}))["result"], json!({}));

    // The app's version, not the core crate's old one.
    let init = m.request(
        "initialize",
        json!({ "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": { "name": "test", "version": "1" } }),
    );
    let v = init["result"]["serverInfo"]["version"].as_str().unwrap();
    assert_eq!(v, ithaca_mcp::SERVER_VERSION);
    assert_ne!(v, "0.1.0");
}

#[test]
fn library_path_comes_from_the_environment_without_the_flag() {
    let dir = tempfile::tempdir().unwrap();
    let (mut writer, a, _) = library(dir.path());
    writer
        .set_mcp_settings(true, std::slice::from_ref(&a))
        .unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_ithaca-mcp"))
        .env("ITHACA_LIBRARY_PATH", dir.path())
        .env("HOME", "/nonexistent")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut m = Mcp {
        stdin: child.stdin.take().unwrap(),
        stdout: BufReader::new(child.stdout.take().unwrap()),
        child,
        next: 1,
    };
    let r = m.call("list_projects", json!({}));
    assert_eq!(r["isError"], false, "{r}");
    assert_eq!(r["structuredContent"]["projects"][0]["id"], a.as_str());
}

#[test]
fn long_sheets_lore_and_outlines_come_in_pages() {
    let dir = tempfile::tempdir().unwrap();
    let (mut writer, a, _) = library(dir.path());
    let o = writer.outline(&a).unwrap();
    let (serial, notes) = (o.folders[0].id.clone(), o.folders[1].id.clone());
    // 50,000+ characters in lines of 100.
    let line = format!("{}\n", "가".repeat(99));
    let long = format!("# 긴 화\n{}", line.repeat(500));
    let total = long.chars().count();
    let sheet = writer.create_sheet(&a, &serial, &long).unwrap().id;
    // Three setting notes of 12,000 characters after the short one: a default lore page (30,000)
    // holds the short one and two of them.
    for i in 0..3 {
        writer
            .create_sheet(&a, &notes, &format!("# 설정 {i}\n{}", "나".repeat(12_000)))
            .unwrap();
    }
    // A project of 520 episodes and a note: more rows than one outline page.
    let src = dir.path().join("src");
    std::fs::create_dir_all(src.join("설정")).unwrap();
    for i in 1..=520 {
        std::fs::write(src.join(format!("{i}화.txt")), format!("{i}화")).unwrap();
    }
    std::fs::write(src.join("설정/인물.txt"), "인물").unwrap();
    writer
        .import_text_folder(&src, Some("긴 연재"), None)
        .unwrap();
    let big = writer.projects().last().unwrap().id.clone();
    writer
        .set_mcp_settings(true, &[a.clone(), big.clone()])
        .unwrap();
    let mut m = Mcp::spawn(dir.path());

    // read_sheet: pages of at most 20,000 characters, cut at a line end, that add up to the text.
    let mut got = String::new();
    let mut offset = 0;
    let mut pages = 0;
    loop {
        let r = m.call(
            "read_sheet",
            json!({ "project": a, "sheet": sheet, "offset": offset }),
        );
        assert_eq!(r["isError"], false, "{r}");
        let pg = page_of(&r);
        assert_eq!(pg["totalChars"], total);
        assert!(pg["returned"].as_u64().unwrap() <= 20_000);
        let (_, body) = text(&r).split_once("\n\n---\n\n").unwrap();
        got.push_str(body);
        pages += 1;
        if pg["truncated"] == false {
            assert!(pg["nextOffset"].is_null());
            break;
        }
        assert!(body.ends_with('\n'), "cut at a line end");
        offset = pg["nextOffset"].as_u64().unwrap();
        assert!(text(&r).contains(&format!("offset {offset}")));
    }
    assert_eq!(got, long);
    assert_eq!(pages, 3);
    let r = m.call(
        "read_sheet",
        json!({ "project": a, "sheet": sheet, "offset": total + 1 }),
    );
    assert_eq!(r["isError"], true);
    let r = m.call(
        "read_sheet",
        json!({ "project": a, "sheet": sheet, "limit": 10 }),
    );
    assert_eq!(
        page_of(&r)["returned"],
        6,
        "\"# 긴 화\\n\": the line end within the page"
    );

    // get_lore: whole sheets, about 30,000 characters per page.
    let l1 = m.call("get_lore", json!({ "project": a }));
    let pg = page_of(&l1);
    assert_eq!(
        (
            &pg["totalSheets"],
            &pg["returned"],
            &pg["truncated"],
            &pg["nextOffset"]
        ),
        (&json!(4), &json!(3), &json!(true), &json!(3))
    );
    assert!(text(&l1).contains("## 설정 / 인물"));
    assert!(text(&l1).contains("get_lore with offset 3"));
    assert!(!text(&l1).contains("## 설정 / 설정 2"));
    let l2 = m.call("get_lore", json!({ "project": a, "offset": 3 }));
    let pg = page_of(&l2);
    assert_eq!(
        (&pg["returned"], &pg["truncated"]),
        (&json!(1), &json!(false))
    );
    assert!(text(&l2).contains("## 설정 / 설정 2"));
    // A sheet longer than the page is cut, and says where to read on.
    let l3 = m.call(
        "get_lore",
        json!({ "project": a, "offset": 1, "limit": 100 }),
    );
    assert!(
        text(&l3).contains("read the rest with read_sheet"),
        "{}",
        text(&l3)
    );
    assert_eq!(page_of(&l3)["nextOffset"], 2);

    // get_outline: 500 rows per call; large output is sent once, as text after a summary.
    let o1 = m.call("get_outline", json!({ "project": big }));
    assert!(o1["structuredContent"].is_null(), "not sent twice");
    assert!(text(&o1).starts_with("Outline of"));
    let v = payload(&o1);
    let rows = 521;
    assert_eq!(
        v["page"],
        json!({ "offset": 0, "returned": 500, "total": rows, "truncated": true, "nextOffset": 500 })
    );
    assert_eq!(v["folders"][0]["sheets"].as_array().unwrap().len(), 500);
    assert_eq!(v["folders"][0]["sheetCount"], 520);
    assert_eq!(v["folders"][1]["sheets"], json!([]));
    assert!(v["note"].as_str().unwrap().contains("offset 500"));
    let v = payload(&m.call("get_outline", json!({ "project": big, "offset": 500 })));
    assert_eq!(v["page"]["returned"], rows - 500);
    assert_eq!(v["folders"][0]["sheets"].as_array().unwrap().len(), 20);
    assert_eq!(v["folders"][1]["sheets"].as_array().unwrap().len(), 1);

    let st = payload(&m.call("get_episode_stats", json!({ "project": big })));
    assert_eq!(st["page"]["total"], 520);
    assert_eq!(st["folders"][0]["rows"].as_array().unwrap().len(), 500);
    assert_eq!(st["folders"][0]["sheets"], 520, "totals cover every row");
    assert_eq!(st["folders"][0]["rows"][499]["number"], 500);
    // Small results still come as structuredContent with the same JSON in the text.
    let small = m.call("get_outline", json!({ "project": a }));
    assert_eq!(
        serde_json::from_str::<Value>(text(&small)).unwrap(),
        small["structuredContent"]
    );
}

#[test]
fn long_queries_are_not_echoed_and_huge_ones_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (mut writer, a, _) = library(dir.path());
    writer
        .set_mcp_settings(true, std::slice::from_ref(&a))
        .unwrap();
    let mut m = Mcp::spawn(dir.path());
    let r = m.call("search", json!({ "query": "안개" }));
    assert_eq!(r["structuredContent"]["query"], "안개");
    let q = "안".repeat(201);
    let r = m.call("search", json!({ "query": q }));
    assert_eq!(r["isError"], false);
    assert!(r["structuredContent"].get("query").is_none());
    assert_eq!(r["structuredContent"]["queryChars"], 201);
    assert!(!text(&r).contains(&q));
    let r = m.request(
        "tools/call",
        json!({ "name": "search", "arguments": { "query": "안".repeat(1001) } }),
    );
    assert_eq!(r["error"]["code"], -32602, "{r}");
    assert_eq!(m.request("ping", json!({}))["result"], json!({}));
}

// ── bible ─────────────────────────────────────────────────────────────

#[test]
fn bible_and_mentions_read_entries() {
    let dir = tempfile::tempdir().unwrap();
    let (mut writer, a, _) = library(dir.path());
    let o = writer.outline(&a).unwrap();
    let notes = o.folders[1].id.clone();
    let e1 = o.folders[0].sheets[0].id.clone();
    writer
        .save_sheet(
            &a,
            &e1,
            "# 1화 안개\n\n해원이가 등대에 올랐다.\n“윤이야, 해원아!”",
        )
        .unwrap();
    let haewon = writer
        .create_sheet(
            &a,
            &notes,
            "---\n종류: 인물\n별칭: 윤이\n나이: 17\n---\n# 해원\n\n## 한 줄 소개\n등대지기의 딸.\n\n## 말투\n짧게 끊어 말한다.\n",
        )
        .unwrap()
        .id;
    writer
        .create_sheet(&a, &notes, "---\n종류: 장소\n---\n# 벼리섬\n")
        .unwrap();
    writer
        .set_mcp_settings(true, std::slice::from_ref(&a))
        .unwrap();
    let mut m = Mcp::spawn(dir.path());
    m.request(
        "initialize",
        json!({ "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": { "name": "test", "version": "1" } }),
    );

    let all = m.call("bible", json!({ "project": a }));
    assert_eq!(all["isError"], false, "{all}");
    let v = payload(&all);
    let entries = v["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0]["name"], "해원");
    assert_eq!(entries[0]["kind"], "character");
    assert_eq!(
        entries[0]["fields"][0],
        json!({ "key": "나이", "value": "17" })
    );
    assert_eq!(entries[0]["sections"][1]["text"], "짧게 끊어 말한다.");
    // Last seen in reading order: the plain notes sheet of the second folder, after the episodes.
    assert!(entries[0]["lastSeen"]["episode"].is_null());
    assert_eq!(entries[0]["lastSeen"]["title"], "인물");
    assert_eq!(
        entries[0]["lastSeen"]["lines"],
        json!(["해원: 등대지기의 딸. 안개를 싫어한다."])
    );
    assert!(entries[1]["lastSeen"].is_null());

    // By alias: the entry and where it appears.
    let one = m.call("bible", json!({ "project": a, "name": "윤이" }));
    assert_eq!(one["isError"], false, "{one}");
    let v = payload(&one);
    assert_eq!(v["sheet"], haewon.as_str());
    assert_eq!(v["appearances"][0]["sheet"], e1.as_str());
    assert_eq!(v["appearances"][0]["episode"], 1);
    assert_eq!(v["appearances"][0]["mentions"], 3);
    assert_eq!(v["appearances"][0]["lines"], json!(["“윤이야, 해원아!”"]));
    assert_eq!(v["appearances"].as_array().unwrap().len(), 2);
    let none = m.call("bible", json!({ "project": a, "name": "아무개" }));
    assert_eq!(none["isError"], true);
    assert!(text(&none).contains("해원, 벼리섬"), "{none}");

    let ms = m.call("mentions", json!({ "project": a, "sheet": "1화 안개" }));
    assert_eq!(ms["isError"], false, "{ms}");
    let v = payload(&ms);
    assert_eq!(
        v["entries"],
        json!([{ "sheet": haewon, "kind": "character", "name": "해원", "mentions": 3, "byAlias": 1 }])
    );
    let bad = m.call("mentions", json!({ "project": a, "sheet": "없는 시트" }));
    assert_eq!(bad["isError"], true);
}

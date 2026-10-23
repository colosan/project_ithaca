//! `ithaca-mcp [--library <folder>]`: MCP over stdio. Messages are read from stdin and answered on
//! stdout, one JSON object per line; diagnostics go to stderr only.
//!
//! Claude Desktop config the app shows:
//! `{"mcpServers":{"ithaca":{"command":"/Applications/Ithaca.app/Contents/MacOS/ithaca-mcp"}}}`

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use ithaca_mcp::{SERVER_VERSION, Server, default_library};

const USAGE: &str = "usage: ithaca-mcp [--library <folder>]\n\
Read-only MCP server (stdio) for the Ithaca library. Default folder:\n\
~/Library/Application Support/Ithaca/Library";

fn main() -> ExitCode {
    let mut library: Option<PathBuf> = None;
    let mut args = std::env::args_os().skip(1);
    while let Some(a) = args.next() {
        match a.to_str() {
            Some("--library") => match args.next() {
                Some(p) => library = Some(PathBuf::from(p)),
                None => {
                    eprintln!("{USAGE}");
                    return ExitCode::from(2);
                }
            },
            Some("--version") => {
                println!("ithaca-mcp {SERVER_VERSION}");
                return ExitCode::SUCCESS;
            }
            Some("--help" | "-h") => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            _ => {
                eprintln!("ithaca-mcp: unknown argument {a:?}\n{USAGE}");
                return ExitCode::from(2);
            }
        }
    }
    let Some(library) = library.or_else(default_library) else {
        eprintln!("ithaca-mcp: HOME is not set; pass --library <folder>");
        return ExitCode::from(2);
    };
    let server = Server::new(library);
    eprintln!(
        "ithaca-mcp {SERVER_VERSION}: library {}",
        server.library().display()
    );

    let stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                eprintln!("ithaca-mcp: stdin: {e}");
                return ExitCode::FAILURE;
            }
        };
        if let Some(reply) = server.handle_line(&line)
            && writeln!(stdout, "{reply}")
                .and_then(|_| stdout.flush())
                .is_err()
        {
            // The client went away.
            return ExitCode::SUCCESS;
        }
    }
    ExitCode::SUCCESS
}

//! Word manuscript (.docx) export (added: docx). Korean contest and submission manuscripts are
//! HWP or DOCX (docs/research/2026-10-24-serial-writers-and-platforms.md §5).
//!
//! A minimal WordprocessingML package written by hand: no document library, only `zip` for the
//! container. The text follows the paste rules (export.rs) with Word structure instead of marks:
//! the title line → Heading 1, other headings → Heading 1–3, `**bold**` / `*italic*` / `~~strike~~`
//! → run formatting, list and quote marks dropped, every scene break → a centred `* * *`.
//! Emphasis is parsed recursively, so `**a *b* c**` keeps the inner italic (the paste text, which
//! strips one level only, would keep the inner marks).

use std::io::{Cursor, Write};

use zip::CompressionMethod;
use zip::write::{SimpleFileOptions, ZipWriter};

use crate::Language;
use crate::export::{SCENE_MARK, is_export_scene_break, strip_list_mark};
use crate::text::{is_heading, js_trim, js_trim_start, strip_heading_mark};

/// Layout of the Word file. A4 portrait always.
#[derive(Debug, Clone, PartialEq)]
pub struct DocxOptions {
    /// Font for Hangul / CJK and Latin text alike.
    pub font: String,
    /// Body size in points (rounded to half points, Word's unit).
    pub font_size: f32,
    /// Line spacing in percent of single spacing (160 = Hangul Office's default).
    pub line_spacing: u32,
    /// Indent each body paragraph's first line by one character.
    pub first_line_indent: bool,
    /// Start every sheet after the first on a new page.
    pub page_break: bool,
    /// Each sheet's first line as a Heading 1 (else it is left out).
    pub include_titles: bool,
    /// Page margins in millimetres.
    pub margin_top_mm: f32,
    pub margin_bottom_mm: f32,
    pub margin_left_mm: f32,
    pub margin_right_mm: f32,
}

impl Default for DocxOptions {
    fn default() -> Self {
        Self {
            font: "맑은 고딕".into(),
            font_size: 10.0,
            line_spacing: 160,
            first_line_indent: true,
            page_break: true,
            include_titles: true,
            margin_top_mm: 20.0,
            margin_bottom_mm: 15.0,
            margin_left_mm: 30.0,
            margin_right_mm: 30.0,
        }
    }
}

/// Paragraph kinds the document uses (style ids in styles.xml).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Para {
    Body,
    Heading(u8),
    SceneBreak,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct Fmt {
    bold: bool,
    italic: bool,
    strike: bool,
}

/// Same marks as text.rs `EMPHASIS`, longest first.
const MARKS: [&str; 6] = ["**", "__", "*", "_", "~~", "`"];

/// Emphasis → formatted runs. Matching is text.rs `strip_emphasis` (non-strict, lazy), applied
/// again inside each match.
fn runs(line: &str, fmt: Fmt, out: &mut Vec<(Fmt, String)>) {
    let mut plain = String::new();
    let mut i = 0;
    'outer: while i < line.len() {
        let rest = &line[i..];
        for m in MARKS {
            if !rest.starts_with(m) {
                continue;
            }
            let c0 = i + m.len();
            let Some(first) = line[c0..].chars().next() else {
                continue;
            };
            let mut j = c0 + first.len_utf8();
            while j < line.len() {
                if line[j..].starts_with(m) {
                    if !plain.is_empty() {
                        out.push((fmt, std::mem::take(&mut plain)));
                    }
                    let inner = match m {
                        "**" | "__" => Fmt { bold: true, ..fmt },
                        "*" | "_" => Fmt {
                            italic: true,
                            ..fmt
                        },
                        "~~" => Fmt {
                            strike: true,
                            ..fmt
                        },
                        _ => fmt,
                    };
                    runs(&line[c0..j], inner, out);
                    i = j + m.len();
                    continue 'outer;
                }
                j += line[j..].chars().next().map_or(1, char::len_utf8);
            }
        }
        let c = rest.chars().next().unwrap_or(' ');
        plain.push(c);
        i += c.len_utf8();
    }
    if !plain.is_empty() {
        out.push((fmt, plain));
    }
}

/// XML text: `& < > "` escaped, characters XML 1.0 forbids dropped.
fn esc(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\t' | '\n' | '\r' => out.push(c),
            c if (c as u32) < 0x20 || c == '\u{FFFE}' || c == '\u{FFFF}' => {}
            c => out.push(c),
        }
    }
}

fn run_xml(fmt: Fmt, text: &str, out: &mut String) {
    out.push_str("<w:r>");
    if fmt != Fmt::default() {
        out.push_str("<w:rPr>");
        if fmt.bold {
            out.push_str("<w:b/><w:bCs/>");
        }
        if fmt.italic {
            out.push_str("<w:i/><w:iCs/>");
        }
        if fmt.strike {
            out.push_str("<w:strike/>");
        }
        out.push_str("</w:rPr>");
    }
    // Tabs are their own element; everything else is literal text with spaces kept.
    for (k, part) in text.split('\t').enumerate() {
        if k > 0 {
            out.push_str("<w:tab/>");
        }
        if !part.is_empty() {
            out.push_str("<w:t xml:space=\"preserve\">");
            esc(part, out);
            out.push_str("</w:t>");
        }
    }
    out.push_str("</w:r>");
}

fn para_xml(kind: Para, page_break: bool, text: &str, out: &mut String) {
    out.push_str("<w:p>");
    let style = match kind {
        Para::Body => None,
        Para::Heading(n) => Some(format!("Heading{n}")),
        Para::SceneBreak => Some("SceneBreak".into()),
    };
    if style.is_some() || page_break {
        out.push_str("<w:pPr>");
        if let Some(s) = style {
            out.push_str(&format!("<w:pStyle w:val=\"{s}\"/>"));
        }
        // A paragraph property, not a `<w:br w:type="page"/>` run: Quick Look and TextEdit show
        // such a run as a box glyph.
        if page_break {
            out.push_str("<w:pageBreakBefore/>");
        }
        out.push_str("</w:pPr>");
    }
    let mut rs = Vec::new();
    if kind == Para::SceneBreak {
        // A mark, not emphasis: `* * *` would otherwise read as an italic space.
        rs.push((Fmt::default(), text.to_string()));
    } else {
        runs(text, Fmt::default(), &mut rs);
    }
    for (fmt, t) in rs {
        run_xml(fmt, &t, out);
    }
    out.push_str("</w:p>");
}

/// One sheet's paragraphs, in order.
fn sheet_paras<'a>(body: &'a str, o: &DocxOptions) -> Vec<(Para, std::borrow::Cow<'a, str>)> {
    let mut out = Vec::new();
    let mut first = true;
    for l in body.split('\n') {
        let l = l.trim_end_matches('\r');
        if js_trim(l).is_empty() {
            continue;
        }
        if std::mem::take(&mut first) {
            if o.include_titles {
                out.push((Para::Heading(1), js_trim(strip_heading_mark(l)).into()));
            }
            continue;
        }
        if is_export_scene_break(l) {
            out.push((Para::SceneBreak, SCENE_MARK.into()));
        } else if is_heading(l) {
            let level = (l.len() - l.trim_start_matches('#').len()).min(3) as u8;
            out.push((Para::Heading(level), js_trim(strip_heading_mark(l)).into()));
        } else {
            let s = strip_list_mark(l);
            // The style indents; a typed indent (spaces, U+3000) would double it.
            let s = if o.first_line_indent {
                js_trim_start(s)
            } else {
                s
            };
            out.push((Para::Body, s.trim_end().into()));
        }
    }
    out
}

fn twips_mm(mm: f32) -> u32 {
    (mm.max(0.0) * 1440.0 / 25.4).round() as u32
}

fn document_xml<'a>(bodies: impl IntoIterator<Item = &'a str>, o: &DocxOptions) -> String {
    let mut x = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
         <w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" \
         xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>",
    );
    let mut any = false;
    for (n, body) in bodies.into_iter().enumerate() {
        for (k, (kind, text)) in sheet_paras(body, o).into_iter().enumerate() {
            let brk = o.page_break && n > 0 && k == 0 && any;
            para_xml(kind, brk, &text, &mut x);
            any = true;
        }
    }
    if !any {
        x.push_str("<w:p/>");
    }
    x.push_str(&format!(
        "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>\
         <w:pgMar w:top=\"{}\" w:right=\"{}\" w:bottom=\"{}\" w:left=\"{}\" w:header=\"851\" w:footer=\"567\" w:gutter=\"0\"/>\
         <w:docGrid w:linePitch=\"360\"/></w:sectPr></w:body></w:document>",
        twips_mm(o.margin_top_mm),
        twips_mm(o.margin_right_mm),
        twips_mm(o.margin_bottom_mm),
        twips_mm(o.margin_left_mm),
    ));
    x
}

fn styles_xml(o: &DocxOptions, lang: Language) -> String {
    let mut font = String::new();
    esc(
        if o.font.trim().is_empty() {
            "맑은 고딕"
        } else {
            o.font.trim()
        },
        &mut font,
    );
    let half = ((o.font_size.clamp(4.0, 96.0)) * 2.0).round() as u32;
    let line = o.line_spacing.clamp(50, 500) * 240 / 100;
    let lang_val = match lang {
        Language::Ko => "ko-KR",
        Language::En => "en-US",
    };
    // One character of indent: `firstLineChars` (Word, in 1/100 char) with a twips fallback (Pages).
    let indent = if o.first_line_indent {
        format!(
            "<w:ind w:firstLineChars=\"100\" w:firstLine=\"{}\"/>",
            half * 10
        )
    } else {
        String::new()
    };
    let heading = |n: u8, scale: u32| {
        format!(
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading{n}\"><w:name w:val=\"heading {n}\"/>\
             <w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/>\
             <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"{}\" w:after=\"{}\"/><w:ind w:firstLine=\"0\" w:firstLineChars=\"0\"/>\
             <w:outlineLvl w:val=\"{}\"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val=\"{}\"/><w:szCs w:val=\"{}\"/></w:rPr></w:style>",
            half * 20 * scale / 100,
            half * 10 * scale / 100,
            n - 1,
            half * scale / 100,
            half * scale / 100,
        )
    };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
         <w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\
         <w:docDefaults><w:rPrDefault><w:rPr>\
         <w:rFonts w:ascii=\"{font}\" w:hAnsi=\"{font}\" w:eastAsia=\"{font}\" w:cs=\"{font}\"/>\
         <w:kern w:val=\"2\"/><w:sz w:val=\"{half}\"/><w:szCs w:val=\"{half}\"/>\
         <w:lang w:val=\"{lang_val}\" w:eastAsia=\"ko-KR\" w:bidi=\"ar-SA\"/></w:rPr></w:rPrDefault>\
         <w:pPrDefault><w:pPr><w:wordWrap w:val=\"0\"/><w:spacing w:after=\"0\" w:line=\"{line}\" w:lineRule=\"auto\"/>\
         <w:jc w:val=\"both\"/></w:pPr></w:pPrDefault></w:docDefaults>\
         <w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/>\
         <w:pPr>{indent}</w:pPr><w:rPr>\
         <w:rFonts w:ascii=\"{font}\" w:hAnsi=\"{font}\" w:eastAsia=\"{font}\" w:cs=\"{font}\"/>\
         <w:sz w:val=\"{half}\"/><w:szCs w:val=\"{half}\"/></w:rPr></w:style>\
         {}{}{}\
         <w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"SceneBreak\"><w:name w:val=\"Scene Break\"/>\
         <w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>\
         <w:pPr><w:spacing w:before=\"{}\" w:after=\"{}\"/><w:ind w:firstLine=\"0\" w:firstLineChars=\"0\"/><w:jc w:val=\"center\"/></w:pPr></w:style>\
         </w:styles>",
        heading(1, 160),
        heading(2, 130),
        heading(3, 115),
        half * 10,
        half * 10,
    )
}

const CONTENT_TYPES: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\
<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\
<Default Extension=\"xml\" ContentType=\"application/xml\"/>\
<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>\
<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>\
<Override PartName=\"/word/fontTable.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml\"/>\
<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>\
<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>\
</Types>";

const ROOT_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\
<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>\
<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>\
</Relationships>";

const DOC_RELS: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\
<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\
<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>\
<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable\" Target=\"fontTable.xml\"/>\
</Relationships>";

fn settings_xml(lang: Language) -> String {
    let v = match lang {
        Language::Ko => "ko-KR",
        Language::En => "en-US",
    };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
         <w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\
         <w:defaultTabStop w:val=\"800\"/><w:characterSpacingControl w:val=\"doNotCompress\"/>\
         <w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat>\
         <w:themeFontLang w:val=\"{v}\" w:eastAsia=\"ko-KR\"/></w:settings>"
    )
}

/// The font's Hangul charset and, for the Windows Korean fonts, their English names (Office for Mac lists them so).
fn font_table_xml(o: &DocxOptions) -> String {
    let name = font_name(o);
    let mut n = String::new();
    esc(name, &mut n);
    let alt = match name {
        "맑은 고딕" => "<w:altName w:val=\"Malgun Gothic\"/>",
        "바탕" => "<w:altName w:val=\"Batang\"/>",
        "굴림" => "<w:altName w:val=\"Gulim\"/>",
        "돋움" => "<w:altName w:val=\"Dotum\"/>",
        _ => "",
    };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
         <w:fonts xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\
         <w:font w:name=\"{n}\">{alt}<w:charset w:val=\"81\"/><w:pitch w:val=\"variable\"/></w:font></w:fonts>"
    )
}

fn font_name(o: &DocxOptions) -> &str {
    match o.font.trim() {
        "" => "맑은 고딕",
        f => f,
    }
}

fn core_xml(title: &str) -> String {
    let mut t = String::new();
    esc(title, &mut t);
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
         <cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" \
         xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>{t}</dc:title></cp:coreProperties>"
    )
}

/// The .docx package for these sheet bodies, in order. `title` goes into the document properties.
pub fn export_docx<'a>(
    bodies: impl IntoIterator<Item = &'a str>,
    title: &str,
    lang: Language,
    o: &DocxOptions,
) -> std::io::Result<Vec<u8>> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    let opts = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    let parts: [(&str, String); 7] = [
        ("[Content_Types].xml", CONTENT_TYPES.into()),
        ("_rels/.rels", ROOT_RELS.into()),
        ("word/document.xml", document_xml(bodies, o)),
        ("word/_rels/document.xml.rels", DOC_RELS.into()),
        ("word/styles.xml", styles_xml(o, lang)),
        ("word/settings.xml", settings_xml(lang)),
        ("word/fontTable.xml", font_table_xml(o)),
    ];
    for (name, xml) in parts
        .iter()
        .chain([&("docProps/core.xml", core_xml(title))])
    {
        zip.start_file(*name, opts).map_err(std::io::Error::other)?;
        zip.write_all(xml.as_bytes())?;
    }
    Ok(zip.finish().map_err(std::io::Error::other)?.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn unzip(bytes: &[u8]) -> std::collections::BTreeMap<String, String> {
        let mut z = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
        (0..z.len())
            .map(|i| {
                let mut f = z.by_index(i).unwrap();
                let mut s = String::new();
                f.read_to_string(&mut s).unwrap();
                (f.name().unwrap().to_string(), s)
            })
            .collect()
    }

    /// Tags balance, attributes are quoted, entities are known. Enough to catch an unescaped `<` or `&`.
    fn well_formed(xml: &str) {
        let body = xml
            .strip_prefix("<?xml")
            .and_then(|r| r.split_once("?>"))
            .map_or(xml, |(_, r)| r);
        let mut stack: Vec<&str> = Vec::new();
        let mut rest = body;
        while let Some(lt) = rest.find('<') {
            check_text(&rest[..lt]);
            let gt = rest[lt..].find('>').expect("unclosed tag") + lt;
            let tag = &rest[lt + 1..gt];
            assert!(!tag.contains('<'), "'<' inside a tag: {tag}");
            if let Some(name) = tag.strip_prefix('/') {
                assert_eq!(stack.pop(), Some(name), "mismatched </{name}>");
            } else {
                let name = tag.split([' ', '/']).next().unwrap();
                assert_eq!(tag.matches('"').count() % 2, 0, "unquoted attribute: {tag}");
                check_text(tag);
                if !tag.ends_with('/') {
                    stack.push(name);
                }
            }
            rest = &rest[gt + 1..];
        }
        check_text(rest);
        assert!(stack.is_empty(), "unclosed: {stack:?}");
    }

    fn check_text(t: &str) {
        assert!(!t.contains('>') || t.contains('='), "raw '>' in text: {t}");
        let mut s = t;
        while let Some(i) = s.find('&') {
            let e = &s[i..];
            assert!(
                ["&amp;", "&lt;", "&gt;", "&quot;", "&apos;"]
                    .iter()
                    .any(|k| e.starts_with(k)),
                "bad entity at {e}"
            );
            s = &s[i + 1..];
        }
    }

    /// Text of each paragraph, in order.
    fn paragraphs(doc: &str) -> Vec<String> {
        doc.split("<w:p>")
            .skip(1)
            .map(|p| {
                let p = p.split("</w:p>").next().unwrap();
                let mut out = String::new();
                for t in p.split("<w:t xml:space=\"preserve\">").skip(1) {
                    out.push_str(t.split("</w:t>").next().unwrap());
                }
                out.replace("&lt;", "<")
                    .replace("&gt;", ">")
                    .replace("&quot;", "\"")
                    .replace("&amp;", "&")
            })
            .collect()
    }

    const BODY: &str = "# 1화 · 시작\n\n그날 밤, **비가** 왔다.\n- 목록 같은 줄\n\n＊＊＊\n\n> 인용된 _말_\n## 소제목\n---\n\u{3000}끝 & <꼭> \"끝\".";

    #[test]
    fn package_structure_and_well_formed_xml() {
        let bytes = export_docx(
            [BODY, "# 2화\n둘째"],
            "작품 <1>",
            Language::Ko,
            &DocxOptions::default(),
        )
        .unwrap();
        let files = unzip(&bytes);
        for name in [
            "[Content_Types].xml",
            "_rels/.rels",
            "word/document.xml",
            "word/_rels/document.xml.rels",
            "word/styles.xml",
            "word/settings.xml",
            "word/fontTable.xml",
            "docProps/core.xml",
        ] {
            let xml = files.get(name).unwrap_or_else(|| panic!("missing {name}"));
            assert!(xml.starts_with("<?xml"));
            well_formed(xml);
        }
        assert!(files["docProps/core.xml"].contains("작품 &lt;1&gt;"));
        let styles = &files["word/styles.xml"];
        assert!(styles.contains("w:eastAsia=\"맑은 고딕\""));
        assert!(styles.contains("w:lang w:val=\"ko-KR\" w:eastAsia=\"ko-KR\""));
        assert!(styles.contains("<w:sz w:val=\"20\"/>"));
        assert!(styles.contains("w:line=\"384\""));
        assert!(styles.contains("w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/>"));
    }

    #[test]
    fn korean_text_round_trip_and_escaping() {
        let bytes = export_docx([BODY], "", Language::Ko, &DocxOptions::default()).unwrap();
        let doc = &unzip(&bytes)["word/document.xml"];
        assert_eq!(
            paragraphs(doc),
            [
                "1화 · 시작",
                "그날 밤, 비가 왔다.",
                "목록 같은 줄",
                "* * *",
                "인용된 말",
                "소제목",
                "* * *",
                "끝 & <꼭> \"끝\"."
            ]
        );
        assert!(doc.contains("끝 &amp; &lt;꼭&gt; &quot;끝&quot;."));
        assert!(doc.contains("<w:pStyle w:val=\"Heading1\"/>"));
        assert!(doc.contains("<w:pStyle w:val=\"Heading2\"/>"));
        assert!(doc.contains("<w:pStyle w:val=\"SceneBreak\"/>"));
        assert!(doc.contains("<w:b/><w:bCs/></w:rPr><w:t xml:space=\"preserve\">비가</w:t>"));
        assert!(doc.contains("<w:i/><w:iCs/></w:rPr><w:t xml:space=\"preserve\">말</w:t>"));
    }

    #[test]
    fn options_titles_page_breaks_indent_margins() {
        let o = DocxOptions {
            include_titles: false,
            page_break: false,
            first_line_indent: false,
            margin_left_mm: 25.4,
            ..Default::default()
        };
        let bytes = export_docx(["# A\n  하나", "# B\n둘"], "", Language::En, &o).unwrap();
        let files = unzip(&bytes);
        let doc = &files["word/document.xml"];
        assert_eq!(paragraphs(doc), ["  하나", "둘"]);
        assert!(!doc.contains("pageBreakBefore"));
        assert!(doc.contains("w:left=\"1440\""));
        assert!(!files["word/styles.xml"].contains("firstLineChars=\"100\""));
        assert!(files["word/styles.xml"].contains("w:lang w:val=\"en-US\" w:eastAsia=\"ko-KR\""));

        let bytes = export_docx(
            ["# A\n하나", "# B\n둘"],
            "",
            Language::Ko,
            &DocxOptions::default(),
        )
        .unwrap();
        let doc = &unzip(&bytes)["word/document.xml"];
        assert_eq!(doc.matches("<w:pageBreakBefore/>").count(), 1);
        assert!(doc.contains(
            "<w:pStyle w:val=\"Heading1\"/><w:pageBreakBefore/></w:pPr><w:r><w:t xml:space=\"preserve\">B<"
        ));
    }

    #[test]
    fn nested_emphasis_tabs_and_control_chars() {
        let mut rs = Vec::new();
        runs("**굵게 *기울* 끝**", Fmt::default(), &mut rs);
        let b = Fmt {
            bold: true,
            ..Fmt::default()
        };
        let bi = Fmt { italic: true, ..b };
        assert_eq!(
            rs,
            [(b, "굵게 ".into()), (bi, "기울".into()), (b, " 끝".into())]
        );
        let mut x = String::new();
        para_xml(Para::Body, false, "가\t나\u{1}다", &mut x);
        assert_eq!(
            x,
            "<w:p><w:r><w:t xml:space=\"preserve\">가</w:t><w:tab/><w:t xml:space=\"preserve\">나다</w:t></w:r></w:p>"
        );
    }

    #[test]
    fn empty_input_is_still_a_valid_document() {
        let bytes = export_docx([], "", Language::Ko, &DocxOptions::default()).unwrap();
        let doc = &unzip(&bytes)["word/document.xml"];
        well_formed(doc);
        assert!(doc.contains("<w:body><w:p/>"));
    }
}

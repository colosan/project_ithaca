//! Plain-text search with offsets in UTF-16 code units (what NSTextView and Android use).

use crate::types::SearchHit;

/// Stop after this many hits in one search.
pub const MAX_HITS: usize = 500;
/// Stop after this many hits in one project when searching several (added: qa1).
pub const MAX_PER_PROJECT: usize = 200;
const BEFORE: usize = 24;
const AFTER: usize = 48;

/// Case-insensitive where lowercasing keeps one character per character (so offsets stay exact).
fn fold(c: char) -> char {
    let mut l = c.to_lowercase();
    match (l.next(), l.next()) {
        (Some(x), None) => x,
        _ => c,
    }
}

/// Non-overlapping matches of `query` in `text`; `project`, `sheet` and `title` are left empty.
pub fn find(text: &str, query: &str, limit: usize) -> Vec<SearchHit> {
    let q: Vec<char> = query.chars().map(fold).collect();
    if q.is_empty() || q.iter().all(|c| c.is_whitespace()) || limit == 0 {
        return Vec::new();
    }
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let folded: Vec<char> = chars.iter().map(|(_, c)| fold(*c)).collect();
    let byte_at = |i: usize| chars.get(i).map_or(text.len(), |(b, _)| *b);
    let mut hits = Vec::new();
    let mut utf16 = 0usize; // UTF-16 offset of chars[scanned]
    let mut scanned = 0usize;
    let mut i = 0;
    while i + q.len() <= folded.len() {
        if folded[i..i + q.len()] != q[..] {
            i += 1;
            continue;
        }
        utf16 += chars[scanned..i]
            .iter()
            .map(|(_, c)| c.len_utf16())
            .sum::<usize>();
        scanned = i;
        let (start, end) = (byte_at(i), byte_at(i + q.len()));
        let matched = &text[start..end];
        let line_start = text[..start].rfind('\n').map_or(0, |n| n + 1);
        let line_end = text[end..].find('\n').map_or(text.len(), |n| end + n);
        let before: String = {
            let b: Vec<char> = text[line_start..start].chars().collect();
            b[b.len().saturating_sub(BEFORE)..].iter().collect()
        };
        let after: String = text[end..line_end].chars().take(AFTER).collect();
        hits.push(SearchHit {
            project: String::new(),
            sheet: String::new(),
            title: String::new(),
            offset: utf16 as u32,
            length: matched.encode_utf16().count() as u32,
            snippet_before: before,
            snippet_match: matched.to_string(),
            snippet_after: after,
        });
        if hits.len() >= limit {
            break;
        }
        i += q.len();
    }
    hits
}

#[cfg(test)]
mod tests {
    use super::find;

    #[test]
    fn utf16_offsets_and_snippets() {
        let text = "😀 첫 줄\n그는 Rain을 보았다. rain, RAIN.";
        let hits = find(text, "rain", 10);
        assert_eq!(hits.len(), 3);
        // "😀 첫 줄\n그는 " = 2 (surrogate pair) + 1 + 1 + 1 + 1 + 1 (newline) + 3 = 10 units.
        assert_eq!(hits[0].offset, 10);
        assert_eq!(hits[0].length, 4);
        assert_eq!(hits[0].snippet_before, "그는 ");
        assert_eq!(hits[0].snippet_match, "Rain");
        assert_eq!(hits[0].snippet_after, "을 보았다. rain, RAIN.");
        let utf16: Vec<u16> = text.encode_utf16().collect();
        for h in &hits {
            let s = String::from_utf16(&utf16[h.offset as usize..(h.offset + h.length) as usize])
                .unwrap();
            assert_eq!(s, h.snippet_match);
        }
        assert!(find(text, "  ", 10).is_empty());
        assert_eq!(find(text, "rain", 2).len(), 2);
    }
}

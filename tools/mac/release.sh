#!/usr/bin/env bash
# One-command Mac release (ADR-0008): bump VERSION → build → zip → EdDSA sign → appcast → commit/tag/push → GitHub release.
#   tools/mac/release.sh patch|minor|major|X.Y.Z [--dry-run]
# --dry-run does everything except commit / tag / push / gh release, and restores VERSION afterwards.
# Outputs: dist/release/<ver>/{Ithaca-<ver>.zip, appcast.xml, notes.md}. Source of truth for the feed: tools/mac/appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"

REPO="colosan/project_ithaca"
FEED_TITLE="Ithaca"
MIN_OS="14.0"
SPARKLE_BIN="$ROOT/swift/.build/artifacts/sparkle/Sparkle/bin"
RELEASE_HOME="$HOME/Library/Application Support/Ithaca-Release"
KEY_FILE="$RELEASE_HOME/sparkle_ed25519_private.key"   # exported copy of the keychain key (chmod 600)
KEY_ACCOUNT="ithaca"                                      # keychain account used by generate_keys
APPCAST="$ROOT/tools/mac/appcast.xml"

die() { echo "✗ $*" >&2; exit 1; }
BUMP=""; DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    patch|minor|major) BUMP="$a" ;;
    [0-9]*.[0-9]*.[0-9]*) BUMP="$a" ;;
    *) die "usage: tools/mac/release.sh <patch|minor|major|X.Y.Z> [--dry-run]" ;;
  esac
done
[ -n "$BUMP" ] || die "usage: tools/mac/release.sh <patch|minor|major|X.Y.Z> [--dry-run]"

# 1. Clean tree
if [ -n "$(git status --porcelain)" ]; then
  if [ "$DRY" = 1 ]; then echo "! working tree is not clean (ignored in --dry-run)"; else die "working tree is not clean — commit or stash first"; fi
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = main ] || echo "! releasing from '$BRANCH', not main"

# 2. Version
OLD="$(tr -d '[:space:]' < VERSION)"
IFS=. read -r MA MI PA <<< "$OLD"
case "$BUMP" in
  patch) NEW="$MA.$MI.$((PA + 1))" ;;
  minor) NEW="$MA.$((MI + 1)).0" ;;
  major) NEW="$((MA + 1)).0.0" ;;
  *) NEW="$BUMP" ;;
esac
TAG="v$NEW"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
# Build number = commit count of the release commit (made below), so it only ever grows. Sparkle compares it.
export BUILD="$(( $(git rev-list --count HEAD) + 1 ))"
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
echo "▸ release $OLD → $NEW (build $BUILD)$([ "$DRY" = 1 ] && echo ' [dry-run]')"

echo "$NEW" > VERSION
if [ "$DRY" = 1 ]; then trap 'echo "$OLD" > "$ROOT/VERSION"' EXIT; fi

# 3. Build
tools/mac/build.sh
APP="$ROOT/dist/Ithaca.app"
[ "$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)" = "$NEW" ] || die "built app has the wrong version"
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || die "Sparkle.framework is missing from the app"

# 4. Zip (ditto keeps the framework's symlinks and the signatures)
OUT="$ROOT/dist/release/$NEW"
rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="$OUT/Ithaca-$NEW.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 5. EdDSA signature (key file if exported, else the login keychain — the latter may show a keychain dialog)
[ -x "$SPARKLE_BIN/sign_update" ] || die "sign_update not found — run: (cd swift && swift package resolve --disable-keychain)"
if [ -f "$KEY_FILE" ]; then SIG_ATTRS="$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" "$ZIP")"
else SIG_ATTRS="$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$ZIP")"; fi
case "$SIG_ATTRS" in *edSignature=*length=*) ;; *) die "sign_update gave no signature" ;; esac
echo "  signed: $SIG_ATTRS"

# 6. Release notes (git log since the previous tag)
RANGE="${PREV_TAG:+$PREV_TAG..}HEAD"
git log --no-merges --pretty='- %s' "$RANGE" | grep -v '^- Release v' | head -50 > "$OUT/notes.md" || true
[ -s "$OUT/notes.md" ] || echo "- 작은 수정" > "$OUT/notes.md"
echo "  notes: $(wc -l < "$OUT/notes.md" | tr -d ' ') lines since ${PREV_TAG:-the beginning}"

# 7. Appcast: new item on top, previous items kept
cp "$APPCAST" "$OUT/appcast.prev.xml" 2>/dev/null || true
python3 - "$APPCAST" "$OUT/appcast.xml" "$NEW" "$BUILD" "$MIN_OS" "$SIG_ATTRS" "$OUT/notes.md" \
  "https://github.com/$REPO/releases/download/$TAG/Ithaca-$NEW.zip" "$FEED_TITLE" <<'PY'
import html, os, re, sys
from email.utils import formatdate
src, dst, ver, build, min_os, sig, notes_path, url, title = sys.argv[1:]
m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', sig)
if not m: sys.exit("could not parse sign_update output")
ed, length = m.groups()
notes = [l[2:].strip() for l in open(notes_path, encoding="utf-8") if l.startswith("- ")]
desc = "<ul>" + "".join(f"<li>{html.escape(n)}</li>" for n in notes) + "</ul>"
item = f"""    <item>
      <title>{html.escape(ver)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(ver)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <description><![CDATA[{desc}]]></description>
      <enclosure url="{html.escape(url)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{ed}"/>
    </item>
"""
if os.path.exists(src):
    feed = open(src, encoding="utf-8").read()
    if f"<sparkle:shortVersionString>{ver}</sparkle:shortVersionString>" in feed:
        # Re-running a dry-run for the same version: replace that item.
        feed = re.sub(r"    <item>\s*<title>" + re.escape(ver) + r"</title>.*?</item>\n", "", feed, flags=re.S)
    feed = re.sub(r"(<channel>.*?</language>\n)", lambda mm: mm.group(1) + item, feed, count=1, flags=re.S)
else:
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>{title}</title>
    <link>https://github.com/colosan/project_ithaca</link>
    <language>ko</language>
{item}  </channel>
</rss>
"""
open(dst, "w", encoding="utf-8").write(feed)
PY
xmllint --noout "$OUT/appcast.xml" 2>/dev/null || python3 -c "import sys,xml.dom.minidom as m; m.parse(sys.argv[1])" "$OUT/appcast.xml"

# 8. Self-check of what will be shipped
CHECK="$(mktemp -d)"; trap 'rm -rf "$CHECK"; [ "$DRY" = 1 ] && echo "$OLD" > "$ROOT/VERSION"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Ithaca.app" || die "codesign verify failed on the unzipped app"
[ -L "$CHECK/Ithaca.app/Contents/Frameworks/Sparkle.framework/Versions/Current" ] || die "framework symlinks lost in the zip"
if [ -f "$KEY_FILE" ]; then
  ED="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIG_ATTRS")"
  "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY_FILE" "$ZIP" "$ED" >/dev/null || die "EdDSA signature does not verify"
  echo "  signature verifies"
fi
echo "  zip: $ZIP ($(du -h "$ZIP" | cut -f1))"

if [ "$DRY" = 1 ]; then
  echo "✓ dry-run done — nothing committed, tagged, pushed or published. Outputs in $OUT"
  exit 0
fi

# 9. Commit, tag, push, publish
cp "$OUT/appcast.xml" "$APPCAST"
git add VERSION "$APPCAST"
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Ithaca $NEW"
git push origin "$BRANCH"
git push origin "$TAG"

if ! gh auth status >/dev/null 2>&1; then
  # Fall back to the token git already uses for github.com. Held only in this process's env; never printed.
  GH_TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
  [ -n "$GH_TOKEN" ] || die "no GitHub auth: run 'gh auth login' (tag $TAG is pushed; re-run the gh step by hand)"
  export GH_TOKEN
fi
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --title "Ithaca $NEW" --notes-file "$OUT/notes.md" \
  || die "gh release failed — tag $TAG is pushed; retry: gh release create $TAG '$ZIP' '$OUT/appcast.xml' --repo $REPO --notes-file '$OUT/notes.md'"
echo "✓ released $TAG — https://github.com/$REPO/releases/tag/$TAG"

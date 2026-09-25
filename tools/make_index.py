"""Build the ReaPack index.xml from the repo's v* tags.

Each tag becomes one package version. Version and changelog come from the
@version / @changelog header of "Spec Check.lua" at that tag; source URLs
point at the tag on the public GitHub mirror, with SHA-256 multihashes of
the exact blobs so ReaPack can verify downloads.

Release: bump @version (Spec Check.lua) and M.VERSION (speccheck_core.lua),
commit, tag vX.Y.Z, run this script, commit index.xml, push.
"""
import hashlib, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote
from xml.sax.saxutils import escape, quoteattr

REPO = Path(__file__).resolve().parent.parent
RAW = "https://raw.githubusercontent.com/tro2789/SpecCheck-REAPER"
WEBSITE = "https://github.com/tro2789/SpecCheck-REAPER"
MAIN = "Spec Check.lua"
FILES = [(MAIN, True), ("speccheck_core.lua", False)]  # (path, registers an action)


def git(*args, raw=False):
    out = subprocess.run(["git", *args], cwd=REPO, capture_output=True, check=True).stdout
    return out if raw else out.decode("utf-8").strip()


def header(text, tag):
    version = re.search(r"^-- @version\s+(\S+)", text, re.M)
    if not version:
        sys.exit(f"{tag}: no @version in {MAIN}")
    author = re.search(r"^-- @author\s+(.+)$", text, re.M)
    desc = re.search(r"^-- @description\s+(.+)$", text, re.M)
    log = re.search(r"^-- @changelog\n((?:--   .*\n)+)", text, re.M)
    changelog = "\n".join(l[5:] for l in log.group(1).splitlines()) if log else "Initial release"
    return (version.group(1), author.group(1).strip() if author else "",
            desc.group(1).strip() if desc else MAIN, changelog)


def main():
    tags = [t for t in git("tag", "-l", "v*", "--sort=v:refname").splitlines() if t]
    if not tags:
        sys.exit("no v* tags")
    versions, desc = [], MAIN
    for tag in tags:
        text = git("show", f"{tag}:{MAIN}")
        name, author, desc, changelog = header(text, tag)
        if f"v{name}" != tag:
            sys.exit(f"tag {tag} has @version {name}")
        when = datetime.fromisoformat(git("log", "-1", "--format=%cI", tag))
        when = when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        sources = []
        for path, is_main in FILES:
            blob = git("show", f"{tag}:{path}", raw=True)
            mh = "1220" + hashlib.sha256(blob).hexdigest()
            url = f"{RAW}/{tag}/{quote(path)}"
            main_attr = ' main="main"' if is_main else ""
            sources.append(f'        <source file={quoteattr(path)}{main_attr} hash="{mh}">{escape(url)}</source>')
        versions.append(
            f'      <version name="{name}" author={quoteattr(author)} time="{when}">\n'
            + "\n".join(sources)
            + f"\n        <changelog><![CDATA[{changelog}]]></changelog>\n      </version>")

    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<index version="1" name="Spec Check">
  <category name="Mixing">
    <reapack name={quoteattr(MAIN)} type="script" desc={quoteattr(desc)}>
{chr(10).join(versions)}
      <metadata>
        <link rel="website">{WEBSITE}</link>
      </metadata>
    </reapack>
  </category>
  <metadata>
    <link rel="website">{WEBSITE}</link>
  </metadata>
</index>
"""
    (REPO / "index.xml").write_text(xml, encoding="utf-8", newline="\n")
    print(f"index.xml: {len(versions)} version(s), latest {tags[-1]}")


if __name__ == "__main__":
    main()

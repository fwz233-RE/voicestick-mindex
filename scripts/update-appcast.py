#!/usr/bin/env python3
import argparse
import email.utils
import html
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def existing_item(path: Path, os_name: str) -> str:
    if not path.exists():
        return ""
    content = path.read_text(encoding="utf-8")
    match = re.search(
        rf"    <item>\s*.*?sparkle:os=\"{re.escape(os_name)}\".*?    </item>\r?\n?",
        content,
        flags=re.DOTALL,
    )
    return match.group(0) if match else ""


def main() -> None:
    parser = argparse.ArgumentParser(description="Write the Sparkle appcast for a VoiceStick release.")
    parser.add_argument("--version", required=True)
    parser.add_argument("--zip-url")
    parser.add_argument("--signature")
    parser.add_argument("--length", type=int)
    parser.add_argument("--windows-installer-url")
    parser.add_argument("--windows-installer-length", type=int)
    parser.add_argument("--output", default="website/public/appcast.xml")
    parser.add_argument("--release-notes", default="VoiceStick macOS release.")
    args = parser.parse_args()

    has_macos_update = bool(args.zip_url and args.signature and args.length)
    if has_macos_update and args.length <= 0:
        sys.exit("Error: --length must be greater than 0 for Sparkle updates.")
    if args.signature and "REPLACE_WITH" in args.signature:
        sys.exit("Error: --signature must be a real Sparkle EdDSA signature.")
    if args.windows_installer_url and (not args.windows_installer_length or args.windows_installer_length <= 0):
        sys.exit("Error: --windows-installer-length must be greater than 0 when --windows-installer-url is set.")

    notes = "".join(f"<li>{html.escape(line)}</li>" for line in args.release_notes.splitlines() if line.strip())
    if not notes:
        notes = "<li>VoiceStick macOS release.</li>"

    pub_date = email.utils.format_datetime(datetime.now(timezone.utc))
    output_path = Path(args.output)
    windows_item = ""
    if args.windows_installer_url and args.windows_installer_length:
        windows_item = f"""    <item>
      <title>Version {html.escape(args.version)}</title>
      <description><![CDATA[
        <ul>
          {notes}
        </ul>
      ]]></description>
      <pubDate>{pub_date}</pubDate>
      <enclosure
        url="{html.escape(args.windows_installer_url)}"
        sparkle:os="windows"
        sparkle:version="{html.escape(args.version)}"
        sparkle:shortVersionString="{html.escape(args.version)}"
        sparkle:installerArguments="/passive"
        length="{args.windows_installer_length}"
        type="application/octet-stream"
      />
    </item>
"""
    else:
        windows_item = existing_item(output_path, "windows")

    if has_macos_update:
        macos_item = f"""    <item>
      <title>Version {html.escape(args.version)}</title>
      <description><![CDATA[
        <ul>
          {notes}
        </ul>
      ]]></description>
      <pubDate>{pub_date}</pubDate>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure
        url="{html.escape(args.zip_url)}"
        sparkle:os="macos"
        sparkle:version="{html.escape(args.version)}"
        sparkle:shortVersionString="{html.escape(args.version)}"
        sparkle:edSignature="{html.escape(args.signature)}"
        length="{args.length}"
        type="application/octet-stream"
      />
    </item>
"""
    else:
        macos_item = existing_item(output_path, "macos")

    content = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>VoiceStick</title>
    <link>https://fwz233-re.github.io/voicestick-mindex/appcast.xml</link>
    <description>VoiceStick app updates</description>
    <language>zh-CN</language>
{windows_item}{macos_item}  </channel>
</rss>
"""
    output_path.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Update the release-download chart from GitHub's public Releases API.

Only the installable ``wordwise.koplugin.zip`` asset is counted. Checksum
assets are intentionally excluded so the chart represents actual plugin
install/download activity rather than auxiliary verification files.
"""

from __future__ import annotations

import html
import json
import math
import urllib.parse
import urllib.request
from pathlib import Path

OWNER = "trigon1998"
REPO = "wordwise.koplugin"
ASSET_NAME = "wordwise.koplugin.zip"
ROOT = Path(__file__).resolve().parents[1]
JSON_PATH = ROOT / "download-stats.json"
SVG_PATH = ROOT / "download-stats.svg"
API_URL = f"https://api.github.com/repos/{OWNER}/{REPO}/releases"


def fetch_releases() -> list[dict]:
    records: list[dict] = []
    page = 1
    while True:
        query = urllib.parse.urlencode({"per_page": 100, "page": page})
        request = urllib.request.Request(
            f"{API_URL}?{query}",
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": f"{REPO}-download-chart",
            },
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            releases = json.load(response)
        if not releases:
            break
        for release in releases:
            if release.get("draft") or release.get("prerelease"):
                continue
            asset = next(
                (item for item in release.get("assets", []) if item.get("name") == ASSET_NAME),
                None,
            )
            if asset is None:
                continue
            records.append(
                {
                    "release": release.get("tag_name") or release.get("name") or "unknown",
                    "published_at": release.get("published_at") or "",
                    "downloads": int(asset.get("download_count") or 0),
                }
            )
        if len(releases) < 100:
            break
        page += 1

    records.sort(key=lambda item: (item["published_at"], item["release"]))
    cumulative = 0
    for item in records:
        cumulative += item["downloads"]
        item["cumulative_downloads"] = cumulative
    return records


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def make_chart(records: list[dict]) -> str:
    width, height = 920, 500
    left, right, top, bottom = 72, 28, 74, 92
    chart_w = width - left - right
    chart_h = height - top - bottom
    max_value = max([item["downloads"] for item in records] + [1])
    max_value = max(4, int(math.ceil(max_value / 4) * 4))
    total = records[-1]["cumulative_downloads"] if records else 0
    count = max(1, len(records))
    slot = chart_w / count
    bar_w = min(72, slot * 0.58)
    colors = {"bar": "#2563eb", "line": "#dc2626", "grid": "#dbe3ef", "text": "#243447"}

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        '<title id="title">Word Wise download count by release</title>',
        f'<desc id="desc">Download count for {esc(ASSET_NAME)} by GitHub Release; current cumulative total {total}.</desc>',
        '<rect width="100%" height="100%" fill="#ffffff" rx="12"/>',
        f'<text x="{left}" y="32" font-family="Noto Sans, DejaVu Sans, Arial, sans-serif" font-size="22" font-weight="700" fill="{colors["text"]}">Word Wise download count by release</text>',
        f'<text x="{left}" y="56" font-family="Noto Sans, DejaVu Sans, Arial, sans-serif" font-size="14" fill="{colors["text"]}">Install asset: {esc(ASSET_NAME)} · Cumulative total: {total}</text>',
    ]

    for tick in range(5):
        value = max_value * tick / 4
        y = top + chart_h - chart_h * tick / 4
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}" stroke="{colors["grid"]}"/>')
        parts.append(f'<text x="{left-12}" y="{y+5:.1f}" text-anchor="end" font-family="Noto Sans, DejaVu Sans, Arial, sans-serif" font-size="12" fill="{colors["text"]}">{int(round(value))}</text>')

    parts.append(f'<line x1="{left}" y1="{top+chart_h}" x2="{width-right}" y2="{top+chart_h}" stroke="{colors["text"]}" stroke-width="1.2"/>')
    cumulative_max = max([item["cumulative_downloads"] for item in records] + [1])
    line_points: list[str] = []
    for index, item in enumerate(records):
        center = left + slot * (index + 0.5)
        bar_h = chart_h * item["downloads"] / max_value
        bar_x = center - bar_w / 2
        bar_y = top + chart_h - bar_h
        parts.append(f'<rect x="{bar_x:.1f}" y="{bar_y:.1f}" width="{bar_w:.1f}" height="{max(0, bar_h):.1f}" rx="4" fill="{colors["bar"]}"/>')
        parts.append(f'<text x="{center:.1f}" y="{bar_y-7:.1f}" text-anchor="middle" font-family="Noto Sans, DejaVu Sans, Arial, sans-serif" font-size="12" font-weight="700" fill="{colors["text"]}">{item["downloads"]}</text>')
        label = esc(item["release"])
        parts.append(f'<text x="{center:.1f}" y="{top+chart_h+25}" text-anchor="middle" font-family="Noto Sans, DejaVu Sans, Arial, sans-serif" font-size="13" fill="{colors["text"]}">{label}</text>')
        cumulative_y = top + chart_h - chart_h * item["cumulative_downloads"] / cumulative_max
        line_points.append(f"{center:.1f},{cumulative_y:.1f}")

    if line_points:
        parts.append(f'<polyline points="{" ".join(line_points)}" fill="none" stroke="{colors["line"]}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')
        for point in line_points:
            x, y = point.split(",")
            parts.append(f'<circle cx="{x}" cy="{y}" r="4" fill="#ffffff" stroke="{colors["line"]}" stroke-width="2"/>')

    legend_y = height - 28
    parts.extend(
        [
            f'<rect x="{left}" y="{legend_y-11}" width="14" height="14" rx="2" fill="{colors["bar"]}"/>',
            f'<text x="{left+22}" y="{legend_y}" font-family="Noto Sans, DejaVu Sans, Arial, sans-serif" font-size="12" fill="{colors["text"]}">Downloads per release</text>',
            f'<line x1="{left+236}" y1="{legend_y-4}" x2="{left+256}" y2="{legend_y-4}" stroke="{colors["line"]}" stroke-width="3"/>',
            f'<text x="{left+264}" y="{legend_y}" font-family="Noto Sans, DejaVu Sans, Arial, sans-serif" font-size="12" fill="{colors["text"]}">Cumulative total</text>',
            "</svg>",
        ]
    )
    return "\n".join(parts) + "\n"


def main() -> None:
    records = fetch_releases()
    JSON_PATH.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    SVG_PATH.write_text(make_chart(records), encoding="utf-8")
    print(f"updated {JSON_PATH} and {SVG_PATH} from {len(records)} releases")


if __name__ == "__main__":
    main()

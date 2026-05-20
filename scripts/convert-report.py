#!/usr/bin/env python3
"""Convert orphaned-roles JSON report to CSV and/or HTML."""

import argparse
import csv
import html
import json
import os
import sys
from datetime import datetime
from pathlib import Path


def load_report(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def short_id(full_id: str) -> str:
    """Extract the GUID at the end of a role-assignment resource ID."""
    return full_id.rsplit("/", 1)[-1] if "/" in full_id else full_id


def friendly_scope(scope: str) -> str:
    """Shorten a scope path to its most meaningful segment."""
    parts = scope.strip("/").split("/")
    # /subscriptions/<id>
    if len(parts) <= 2:
        return f"Subscription ({parts[-1][:8]}…)"
    # /subscriptions/<id>/resourceGroups/<rg>/...
    rg_idx = next((i for i, p in enumerate(parts) if p.lower() == "resourcegroups"), None)
    if rg_idx is not None and rg_idx + 1 < len(parts):
        rg_name = parts[rg_idx + 1]
        # If there are deeper resources, include the last one
        if len(parts) > rg_idx + 2:
            return f"{rg_name} / {parts[-1]}"
        return rg_name
    return parts[-1]


# ── CSV ──────────────────────────────────────────────────────────────────

CSV_COLUMNS = [
    "AssignmentId",
    "Role",
    "PrincipalId",
    "PrincipalType",
    "DisplayName",
    "Scope",
    "OrphanReason",
    "Status",
    "SafeToDelete",
    "Notes",
    "ScannedAt",
]


def assignment_to_row(a: dict) -> dict:
    return {
        "AssignmentId": short_id(a["RoleAssignmentId"]),
        "Role": a["RoleDefinitionName"],
        "PrincipalId": a["PrincipalId"],
        "PrincipalType": a["PrincipalType"],
        "DisplayName": a["DisplayName"] or "",
        "Scope": friendly_scope(a["Scope"]),
        "OrphanReason": a["OrphanReasons"].replace("Orphaned", ""),
        "Status": a["DetectionStatus"],
        "SafeToDelete": "Yes" if a["CanSafelyDelete"] else "No",
        "Notes": a["ValidationNotes"] or "",
        "ScannedAt": a["ScannedAt"][:10],
    }


def write_csv(report: dict, out_path: str):
    assignments = report.get("OrphanedAssignments", [])
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for a in assignments:
            writer.writerow(assignment_to_row(a))
    print(f"✅  CSV written → {out_path}  ({len(assignments)} rows)")


# ── HTML ─────────────────────────────────────────────────────────────────

def _esc(val) -> str:
    return html.escape(str(val)) if val else ""


def write_html(report: dict, out_path: str):
    meta = report.get("ReportMetadata", {})
    assignments = report.get("OrphanedAssignments", [])
    scan_scope = meta.get("ScanScope", "")
    generated = meta.get("GeneratedAt", "")[:19].replace("T", " ")
    dry_run = meta.get("DryRunMode", False)
    total = meta.get("TotalOrphaned", len(assignments))
    by_type = meta.get("OrphanedByType", {})
    by_status = meta.get("DetectionStatusBreakdown", {})

    rows_html = []
    for a in assignments:
        r = assignment_to_row(a)
        safe_class = "safe" if a["CanSafelyDelete"] else "review"
        status_class = "confirmed" if r["Status"] == "Confirmed" else "suspected"
        rows_html.append(f"""      <tr class="{safe_class}">
        <td class="mono">{_esc(r['AssignmentId'])}</td>
        <td>{_esc(r['Role'])}</td>
        <td class="mono">{_esc(r['PrincipalId'][:8])}…</td>
        <td>{_esc(r['PrincipalType'])}</td>
        <td>{_esc(r['DisplayName']) or '<span class="muted">—</span>'}</td>
        <td>{_esc(r['Scope'])}</td>
        <td>{_esc(r['OrphanReason'])}</td>
        <td><span class="badge {status_class}">{_esc(r['Status'])}</span></td>
        <td><span class="badge {safe_class}">{_esc(r['SafeToDelete'])}</span></td>
        <td class="notes">{_esc(r['Notes']) or '—'}</td>
      </tr>""")

    type_chips = " ".join(
        f'<span class="chip">{k.replace("Orphaned", "")} <strong>{v}</strong></span>'
        for k, v in by_type.items()
    )
    status_chips = " ".join(
        f'<span class="chip">{k} <strong>{v}</strong></span>'
        for k, v in by_status.items()
    )

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Orphaned Role Assignments Report</title>
<style>
  :root {{ --bg: #f8f9fa; --card: #fff; --border: #dee2e6; --accent: #0d6efd;
           --green: #198754; --yellow: #ffc107; --red: #dc3545; --muted: #6c757d; }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          background: var(--bg); color: #212529; padding: 2rem; }}
  h1 {{ font-size: 1.6rem; margin-bottom: .25rem; }}
  .subtitle {{ color: var(--muted); font-size: .85rem; margin-bottom: 1.5rem; }}
  .cards {{ display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1.5rem; }}
  .card {{ background: var(--card); border: 1px solid var(--border); border-radius: .5rem;
           padding: 1rem 1.25rem; min-width: 180px; flex: 1; }}
  .card .label {{ font-size: .75rem; text-transform: uppercase; color: var(--muted); letter-spacing: .05em; }}
  .card .value {{ font-size: 1.8rem; font-weight: 700; }}
  .chip {{ display: inline-block; background: #e9ecef; border-radius: .25rem;
           padding: .15rem .5rem; font-size: .8rem; margin-right: .25rem; }}
  .dry-run {{ background: var(--yellow); color: #000; padding: .15rem .5rem; border-radius: .25rem;
              font-size: .75rem; font-weight: 600; vertical-align: middle; }}
  table {{ width: 100%; border-collapse: collapse; background: var(--card);
           border: 1px solid var(--border); border-radius: .5rem; overflow: hidden;
           font-size: .85rem; }}
  th {{ background: #343a40; color: #fff; text-align: left; padding: .6rem .75rem;
        font-weight: 600; font-size: .75rem; text-transform: uppercase; letter-spacing: .04em; }}
  td {{ padding: .55rem .75rem; border-top: 1px solid var(--border); vertical-align: top; }}
  tr.safe {{ background: #d1e7dd33; }}
  tr.review {{ background: #fff3cd33; }}
  tr:hover {{ background: #e9ecef; }}
  .mono {{ font-family: "SFMono-Regular", Consolas, monospace; font-size: .8rem; }}
  .badge {{ display: inline-block; padding: .15rem .45rem; border-radius: .2rem;
            font-size: .75rem; font-weight: 600; }}
  .badge.confirmed {{ background: var(--green); color: #fff; }}
  .badge.suspected {{ background: var(--yellow); color: #000; }}
  .badge.safe {{ background: var(--green); color: #fff; }}
  .badge.review {{ background: var(--yellow); color: #000; }}
  .notes {{ max-width: 250px; font-size: .8rem; color: var(--muted); }}
  .muted {{ color: var(--muted); }}
  .legend {{ margin-top: 1rem; font-size: .8rem; color: var(--muted); }}
  .legend span {{ margin-right: 1rem; }}
  @media (max-width: 900px) {{ table {{ display: block; overflow-x: auto; }} }}
</style>
</head>
<body>
  <h1>Orphaned Role Assignments Report {'<span class="dry-run">DRY RUN</span>' if dry_run else ''}</h1>
  <p class="subtitle">Scope: <code>{_esc(scan_scope)}</code> &nbsp;|&nbsp; Generated: {_esc(generated)}</p>

  <div class="cards">
    <div class="card">
      <div class="label">Total orphaned</div>
      <div class="value">{total}</div>
    </div>
    <div class="card">
      <div class="label">By type</div>
      <div style="margin-top:.35rem">{type_chips}</div>
    </div>
    <div class="card">
      <div class="label">By status</div>
      <div style="margin-top:.35rem">{status_chips}</div>
    </div>
  </div>

  <table>
    <thead>
      <tr>
        <th>Assignment ID</th><th>Role</th><th>Principal</th><th>Type</th>
        <th>Display Name</th><th>Scope</th><th>Reason</th><th>Status</th>
        <th>Safe to Delete?</th><th>Notes</th>
      </tr>
    </thead>
    <tbody>
{"".join(rows_html)}
    </tbody>
  </table>

  <div class="legend">
    <span>🟢 <strong>Safe</strong> = confirmed orphan, can be removed</span>
    <span>🟡 <strong>Review</strong> = suspected orphan, verify before removing</span>
  </div>
</body>
</html>"""

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"✅  HTML written → {out_path}  ({len(assignments)} rows)")


# ── CLI ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Convert an orphaned-roles JSON report to CSV and/or HTML."
    )
    parser.add_argument("input", help="Path to the JSON report file")
    parser.add_argument("--csv", metavar="FILE", help="Output CSV path (default: <input>.csv)")
    parser.add_argument("--html", metavar="FILE", help="Output HTML path (default: <input>.html)")
    parser.add_argument("--no-csv", action="store_true", help="Skip CSV generation")
    parser.add_argument("--no-html", action="store_true", help="Skip HTML generation")
    args = parser.parse_args()

    report = load_report(args.input)
    base = os.path.splitext(args.input)[0]

    if not args.no_csv:
        write_csv(report, args.csv or f"{base}.csv")
    if not args.no_html:
        write_html(report, args.html or f"{base}.html")


if __name__ == "__main__":
    main()

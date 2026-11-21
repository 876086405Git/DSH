#!/usr/bin/env python3
"""Read aggregate v4 usage; never return installation IDs. Dates use UTC+8."""

import argparse
import json
import os
import re
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


COUNTS = (
    "observed", "in_positive", "in_zero", "in_partial", "in_missing", "in_invalid",
    "out_positive", "out_zero", "out_partial", "out_missing", "out_invalid", "paired", "clipped",
)
VALUES = ("tokens_in", "tokens_out", "paired_in", "paired_out", "uncached_in",
          "cache_read", "cache_write", "cache_known", "partial_in", "partial_out")
OPERATIONS = ("runtime_direct", "runtime_proot", "runtime_other",
              "ssh_initial", "ssh_reconnect", "relay_initial", "relay_reconnect",
              "chat_turn_local", "chat_turn_remote", "chat_first_text_local", "chat_first_text_remote", "phone_task", "update_download", "update_install", "call_connect", "call_session", "plugin_install",
              "plugin_execute", "onboarding_local", "onboarding_remote", "onboarding_tavern", "crash", "anr")
OP_COLS = ("episodes", "ready", "failed", "cancelled", "unknown",
           "le250ms", "le500ms", "le1s", "le2s", "le5s", "le10s", "le30s",
           "le60s", "le180s", "gt180s", "clipped")
READY = "has_base = 1 AND has_counts = 1 AND has_values = 1"


def daily_query(first, last, span, source="chat_log"):
    fields = [
        "max(if(blob3 = 'base', 1, 0)) AS has_base",
        f"max(if(blob3 = '{source}_counts', 1, 0)) AS has_counts",
        f"max(if(blob3 = '{source}_values', 1, 0)) AS has_values",
        "max(if(blob3 = 'base', double1, 0.0)) AS active",
        "max(if(blob3 = 'base', double3, 0.0)) AS mask",
        "max(if(blob3 = 'base' AND blob7 != '' AND blob7 != 'unknown', 1.0, 0.0)) AS model_known",
        "max(if(blob3 = 'base' AND blob8 != '' AND blob8 != 'unknown', 1.0, 0.0)) AS rom_known",
    ]
    for row_type, columns in ((f"{source}_counts", COUNTS), (f"{source}_values", VALUES)):
        fields.extend(f"max(if(blob3 = '{row_type}', double{i}, 0.0)) AS {name}"
                      for i, name in enumerate(columns, 1))
    joined_fields = ",\n    ".join(fields)
    totals = ",\n  ".join(f"sum(if({READY}, {name}, 0.0)) AS {name}_total"
                            for name in COUNTS + VALUES)
    return f"""SELECT day, count() AS install_days_seen, sum(active) AS dau,
  sum(if(mask = 1, 1, 0)) AS daily_only_install_days,
  sum(active * model_known) AS active_with_model, sum(active * rom_known) AS active_with_rom,
  sum(if({READY}, 1, 0)) AS complete_install_days,
  max(sample_step) AS max_sample_interval,
  {totals}
FROM (
  SELECT blob1 AS day, blob2 AS device, max(_sample_interval) AS sample_step,
    {joined_fields}
  FROM dshgo_usage_v4
  WHERE timestamp >= NOW() - INTERVAL '{span}' DAY AND blob1 >= '{first}' AND blob1 <= '{last}'
    AND blob3 IN ('base', '{source}_counts', '{source}_values')
  GROUP BY day, device
) GROUP BY day ORDER BY day FORMAT JSON"""


def operations_query(first, last, span):
    names = ", ".join(f"'{name}'" for name in OPERATIONS)
    maxima = ", ".join(f"max(double{i}) AS slot_{i}" for i in range(1, 17))
    totals = ", ".join(f"sum(slot_{i}) AS {key}" for i, key in enumerate(OP_COLS, 1))
    return f"""SELECT day, kind, max(sample_step) AS max_sample_interval, {totals}
FROM (
  SELECT blob1 AS day, blob2 AS device, blob3 AS kind, max(_sample_interval) AS sample_step, {maxima}
  FROM dshgo_usage_v4
  WHERE timestamp >= NOW() - INTERVAL '{span}' DAY AND blob1 >= '{first}' AND blob1 <= '{last}'
    AND blob3 IN ({names})
  GROUP BY day, device, kind
) GROUP BY day, kind ORDER BY day, kind FORMAT JSON"""


def retention_query(cohort, span):
    d1, d7 = (cohort + timedelta(days=n) for n in (1, 7))
    return f"""SELECT sum(first_day) AS cohort_size, sum(first_day * d1) AS returned_d1,
  sum(first_day * d7) AS returned_d7, sum(d1) AS active_d1, sum(d7) AS active_d7,
  max(sample_step) AS max_sample_interval
FROM (
  SELECT blob2 AS device, max(_sample_interval) AS sample_step,
    max(if(blob1 = '{cohort}' AND double2 = 1, 1, 0)) AS first_day,
    max(if(blob1 = '{d1}' AND double1 = 1, 1, 0)) AS d1,
    max(if(blob1 = '{d7}' AND double1 = 1, 1, 0)) AS d7
  FROM dshgo_usage_v4
  WHERE timestamp >= NOW() - INTERVAL '{span}' DAY AND blob3 = 'base'
    AND blob1 IN ('{cohort}', '{d1}', '{d7}')
  GROUP BY device
) FORMAT JSON"""


def ratio(n, d):
    return round(float(n) / float(d), 6) if float(d) else None


def summarize_daily(day, row, today):
    row = {k: int(v) for k, v in row.items() if k != "day"}
    active = row["dau"]
    observed = row["observed_total"]
    result = {
        "day": str(day), "mature": (today - day).days > 7, **row,
        "incomplete_install_days": (
            row["install_days_seen"] - row["complete_install_days"] - row["daily_only_install_days"]
        ),
        "model_coverage": ratio(row["active_with_model"], active),
        "rom_coverage": ratio(row["active_with_rom"], active),
        "input_coverage": ratio(row["in_positive_total"] + row["in_zero_total"], observed),
        "output_coverage": ratio(row["out_positive_total"] + row["out_zero_total"], observed),
        "paired_coverage": ratio(row["paired_total"], observed),
        "paired_input_per_output": ratio(row["paired_in_total"], row["paired_out_total"]),
    }
    if not row["complete_install_days"]:
        result.update((f"{name}_total", None) for name in COUNTS + VALUES)
    return result


def summarize_retention(cohort, row, today):
    row = {k: int(v or 0) for k, v in row.items()}
    size = row.get("cohort_size", 0)
    sample = row.get("max_sample_interval", 0)
    result = {"day": str(cohort), "cohort_size": size or None, "max_sample_interval": sample or None}
    for n in (1, 7):
        # Even a mature cohort can be incomplete when the query reports sampling.
        mature = (today - cohort).days > n + 7
        count = row.get(f"returned_d{n}", 0)
        result[f"d{n}_mature"] = mature
        available = mature and size and row.get(f"active_d{n}", 0)
        result[f"d{n}_visible_returns"] = count if available else None
        result[f"d{n}_rate"] = ratio(count, size) if available and sample == 1 else None
    return result


def main():
    opts = argparse.ArgumentParser(description=__doc__)
    opts.add_argument("--days", type=int, default=14)
    opts.add_argument("--dry-run", action="store_true")
    opts.add_argument("--cohort", type=date.fromisoformat, action="append", default=[])
    args = opts.parse_args()
    now = datetime.now(timezone(timedelta(hours=8)))
    today = now.date()
    if not 1 <= args.days <= 60 or any(not 1 <= (today - day).days <= 60 for day in args.cohort):
        opts.error("choose 1–60 ended days and cohorts within the last 60 days")
    first, last = today - timedelta(days=args.days), today - timedelta(days=1)
    sources = ("chat_log", "tavern", "companion", "engine")
    daily = {source: daily_query(first, last, args.days + 2, source) for source in sources}
    ops = operations_query(first, last, args.days + 2)
    cohorts = [(day, retention_query(day, (today - day).days + 2)) for day in sorted(set(args.cohort))]
    if args.dry_run:
        print(*daily.values(), ops, *(sql for _, sql in cohorts), sep=";\n\n")
        return 0
    account = os.environ.get("CF_ACCOUNT_ID", "")
    path = os.environ.get("CF_TOKEN_FILE")
    if not re.fullmatch(r"[0-9a-fA-F]{32}", account) or not path:
        opts.error("set CF_ACCOUNT_ID and CF_TOKEN_FILE (a token with Account Analytics Read)")

    try:
        token = Path(path).read_text(encoding="utf-8-sig").strip()
        if not token:
            opts.error("CF_TOKEN_FILE is empty")

        def query(sql):
            endpoint = f"https://api.cloudflare.com/client/v4/accounts/{account}/analytics_engine/sql"
            req = Request(endpoint, data=sql.encode(), headers={"Authorization": f"Bearer {token}"})
            with urlopen(req, timeout=30) as response:
                return json.load(response)["data"]

        result = {"as_of_utc8": now.isoformat(), "daily_by_source": {}, "operations": query(ops), "retention": []}
        for source, sql in daily.items():
            rows = {row["day"]: row for row in query(sql)}
            reports = result["daily_by_source"][source] = []
            for offset in range(args.days):
                day = first + timedelta(days=offset)
                row = rows.get(str(day))
                reports.append(summarize_daily(day, row, today) if row else {"day": str(day), "data": None})
        for day, sql in cohorts:
            data = query(sql)
            result["retention"].append(summarize_retention(day, data[0] if data else {}, today))
        print(json.dumps(result, indent=2))
        return 0
    except HTTPError as exc:
        print(f"usage-v4-report: Cloudflare HTTP {exc.code}", file=sys.stderr)
    except (OSError, URLError, ValueError, KeyError, TypeError):
        print("usage-v4-report: could not read the token file or complete the Analytics query", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

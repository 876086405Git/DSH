import importlib.util
import re
import sqlite3
import unittest
from datetime import date
from pathlib import Path


script = Path(__file__).resolve().parents[1] / "scripts" / "usage-v4-report.py"
spec = importlib.util.spec_from_file_location("usage_v4_report", script)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
D0 = date(2026, 11, 1)
TODAY = date(2026, 11, 21)


class ReportTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        self.db.row_factory = sqlite3.Row
        self.db.create_function("if", 3, lambda test, a, b: a if test else b)
        columns = [f"blob{i} TEXT" for i in range(1, 9)] + [f"double{i} REAL" for i in range(1, 17)]
        self.db.execute(f"CREATE TABLE dshgo_usage_v4 (_sample_interval INTEGER, {', '.join(columns)})")

    def point(self, day, device, name, values, *, model="test-model", sample=1):
        data = [sample, day, device, name, "1.0.21", "android", "test-maker", model, "android", *values]
        data += [0] * (25 - len(data))
        self.db.execute(f"INSERT INTO dshgo_usage_v4 VALUES ({','.join('?' for _ in data)})", data)

    def query(self, sql):
        # Strip the Analytics API's ingestion-time window and output directive;
        # use the same grouping, field filters and arithmetic on synthetic rows.
        sql = re.sub(r"timestamp >= NOW\(\) - INTERVAL '\d+' DAY AND ", "", sql).removesuffix(" FORMAT JSON")
        return dict(self.db.execute(sql).fetchone())

    def test_retry_is_counted_once_and_incomplete_rows_do_not_supply_tokens(self):
        day = str(D0)
        for _ in range(2):
            self.point(day, "a", "base", [1, 1, 3])
            self.point(day, "a", "chat_log_counts", [3, 2, 0, 0, 1, 0, 1, 1, 0, 1, 0, 2, 0])
            self.point(day, "a", "chat_log_values", [150, 9, 150, 9, 110, 40, 0, 1])
        self.point(day, "b", "base", [1, 1, 3], model="unknown")
        self.point(day, "b", "chat_log_values", [999, 999], sample=2)
        # Switched off: the base row alone still counts as a day in use, and
        # never supplies tokens or device coverage.
        self.point(day, "c", "base", [1, 1, 1], model="")
        row = report.summarize_daily(D0, self.query(report.daily_query(D0, D0, 30)), TODAY)
        self.assertEqual((row["dau"], row["daily_only_install_days"]), (3, 1))
        self.assertEqual((row["complete_install_days"], row["incomplete_install_days"]), (1, 1))
        self.assertEqual((row["output_coverage"], row["model_coverage"]), (0.666667, 0.333333))
        self.assertEqual((row["tokens_out_total"], row["max_sample_interval"]), (9, 2))

    def test_retention_uses_exact_return_day_and_requires_maturity_and_unobserved_sampling(self):
        for device in ("a", "b"):
            self.point("2026-11-01", device, "base", [1, 1, 3])
        self.point("2026-11-02", "a", "base", [1, 0, 3])
        self.point("2026-11-02", "a", "base", [1, 0, 3])
        self.point("2026-11-03", "b", "base", [1, 0, 3])
        sql = report.retention_query(D0, 30)
        row = self.query(sql)
        result = report.summarize_retention(D0, row, TODAY)
        self.assertEqual(result["d1_rate"], 0.5)
        self.assertIsNone(result["d7_rate"])
        self.assertIsNone(report.summarize_retention(D0, row, date(2026, 11, 9))["d1_rate"])
        self.point("2026-11-08", "b", "base", [1, 0, 3], sample=10)
        sampled = report.summarize_retention(D0, self.query(sql), TODAY)
        self.assertEqual(sampled["d7_visible_returns"], 1)
        self.assertIsNone(sampled["d7_rate"])


if __name__ == "__main__":
    unittest.main()

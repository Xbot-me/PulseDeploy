"""pulse-lt report: print the verdict of a finished run again.

    python3 report.py [RESULTS_DIR]     (default: the newest folder under loadtest/results)
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def newest(root):
    runs = sorted(p for p in root.glob("*") if (p / "summary.json").exists())
    return runs[-1] if runs else None


def main(argv):
    folder = Path(argv[0]) if argv else newest(HERE / "results")
    if folder is None or not (folder / "summary.json").exists():
        print("No finished run found. Run a test first: pulse-lt run SCENARIO --url ...", file=sys.stderr)
        return 1
    summary = json.loads((folder / "summary.json").read_text(encoding="utf-8"))
    print(summary.get("text") or json.dumps(summary, indent=2))
    print(f"\nFull report: {folder / 'report.html'}")
    return 1 if summary.get("problems") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

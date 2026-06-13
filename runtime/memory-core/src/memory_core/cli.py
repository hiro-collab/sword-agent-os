"""Small no-live CLI for Memory Core verification."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .store import MemoryStore


def main() -> int:
    parser = argparse.ArgumentParser(description="Memory Core no-live helper")
    parser.add_argument("--db", required=True, help="SQLite database path")
    parser.add_argument("--candidate-json", help="Candidate JSON to record")
    args = parser.parse_args()
    store = MemoryStore(Path(args.db))
    if args.candidate_json:
        candidate = json.loads(args.candidate_json)
        print(json.dumps(store.record_candidate(candidate), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

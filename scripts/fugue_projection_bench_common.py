"""Shared frozen selector map for Fugue projection benchmark tooling."""

SCENARIOS = (
    ("B1", "internal/branch", "branch_benchmark.mbt", "2", "branch - checkout (1000 ops)"),
    ("B2", "internal/branch", "branch_benchmark.mbt", "12", "branch - single advance (50 new ops)"),
    ("B3", "internal/branch", "branch_benchmark.mbt", "7", "branch - repeated advance steady-state (10 iterations)"),
    ("B4", "internal/branch", "branch_benchmark.mbt", "8", "branch - repeated advance with oplog mutations (10 iterations)"),
    ("B5", "internal/branch", "branch_merge_benchmark.mbt", "8", "merge - context apply operations (50 ops)"),
    ("D1", "internal/document", "document_benchmark.mbt", "11", "bench: observed Insert (1000-char warm index)"),
    ("D2", "internal/document", "document_benchmark.mbt", "12", "bench: observed Insert (10000-char warm index)"),
    ("D3", "internal/document", "document_benchmark.mbt", "13", "bench: observed Insert (100000-char warm index)"),
    ("D4", "internal/document", "document_benchmark.mbt", "14", "bench: observed Delete (1000-char warm index)"),
    ("D5", "internal/document", "document_benchmark.mbt", "15", "bench: observed Delete (10000-char warm index)"),
    ("D6", "internal/document", "document_benchmark.mbt", "16", "bench: observed Delete (100000-char warm index)"),
    ("D7", "internal/document", "document_benchmark.mbt", "17", "bench: observed Undelete (1000-char warm index)"),
    ("D8", "internal/document", "document_benchmark.mbt", "18", "bench: observed Undelete (10000-char warm index)"),
    ("D9", "internal/document", "document_benchmark.mbt", "19", "bench: observed Undelete (100000-char warm index)"),
    ("D10", "internal/document", "document_benchmark.mbt", "7", "bench: 10 remote inserts + queries (1000-char doc)"),
    ("D11", "internal/document", "document_benchmark.mbt", "8", "bench: 10 remote inserts + queries (5000-char doc)"),
    ("D12", "internal/document", "document_benchmark.mbt", "3", "bench: merge reverse dependency chain (10000 ops)"),
)

SCENARIO_BY_KEY = {row[0]: row for row in SCENARIOS}
TARGETS = ("js", "wasm-gc")

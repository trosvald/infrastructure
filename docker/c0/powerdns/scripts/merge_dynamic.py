#!/usr/bin/env python3
import argparse
import ipaddress
import pathlib
import re
import sqlite3

ZONE = "monosense.io"
OWNER = "external-dns-internal"
KEY_NAME = "external-dns-internal"
KEY_ALGORITHM = "hmac-sha256"
ALLOWED_TYPES = {"A", "AAAA", "CNAME", "TXT"}
OWNER_MARKER = f"external-dns/owner={OWNER}"
DNS_NAME = re.compile(r"^(?:[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?\.?$")


def fail(message: str) -> None:
    raise SystemExit(message)


def normalize_name(value: str) -> str:
    return value.rstrip(".").lower()


def write_policy(path: pathlib.Path, canonical_names: set[str]) -> None:
    entries = "\n".join(f'  ["{name}."] = true,' for name in sorted(canonical_names))
    path.write_text(
        "local canonical = {\n"
        f"{entries}\n"
        "}\n"
        "local allowed_types = { [1] = true, [5] = true, [16] = true, [28] = true, [255] = true }\n"
        "function updatepolicy(input)\n"
        "  local qname = string.lower(tostring(input:getQName()))\n"
        "  return tostring(input:getZoneName()) == \"monosense.io.\" and\n"
        "    tostring(input:getTsigName()) == \"external-dns-internal.\" and\n"
        "    allowed_types[input:getQType()] == true and canonical[qname] ~= true\n"
        "end\n",
        encoding="ascii",
    )


def validate_row(row: sqlite3.Row) -> None:
    record_type = row["type"]
    content = row["content"]
    if record_type == "A":
        if ipaddress.ip_address(content).version != 4:
            fail(f"invalid owned A record for {row['name']}")
    elif record_type == "AAAA":
        if ipaddress.ip_address(content).version != 6:
            fail(f"invalid owned AAAA record for {row['name']}")
    elif record_type == "CNAME":
        if not DNS_NAME.fullmatch(content):
            fail(f"invalid owned CNAME record for {row['name']}")
    elif record_type == "TXT":
        if OWNER_MARKER not in content or "heritage=external-dns" not in content:
            fail(f"unrecognized TXT record at owned name {row['name']}")
    if row["disabled"] not in (0, False) or not 1 <= row["ttl"] <= 86400:
        fail(f"invalid state or TTL at owned name {row['name']}")


def merge(
    source_path: pathlib.Path,
    candidate_path: pathlib.Path,
    key_path: pathlib.Path,
    policy_path: pathlib.Path,
) -> int:
    secret = key_path.read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[A-Za-z0-9+/]{43}=", secret):
        fail("PowerDNS TSIG secret must be a 32-byte base64 value")

    candidate = sqlite3.connect(candidate_path)
    candidate.row_factory = sqlite3.Row
    source = None
    try:
        candidate.execute("PRAGMA foreign_keys=ON")
        domain = candidate.execute("SELECT id FROM domains WHERE name=?", (ZONE,)).fetchone()
        if domain is None:
            fail(f"candidate is missing {ZONE}")
        candidate_domain_id = domain["id"]
        canonical_names = {
            normalize_name(row["name"])
            for row in candidate.execute("SELECT name FROM records WHERE domain_id=?", (candidate_domain_id,))
        }
        write_policy(policy_path, canonical_names)

        copied = 0
        if source_path.exists():
            source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
            source.row_factory = sqlite3.Row
            source.execute("BEGIN")
            source_domain = source.execute("SELECT id FROM domains WHERE name=?", (ZONE,)).fetchone()
            if source_domain is not None:
                rows = source.execute(
                    "SELECT name,type,content,ttl,prio,disabled,ordername,auth FROM records WHERE domain_id=? ORDER BY name,type,content",
                    (source_domain["id"],),
                ).fetchall()
                owned_names = {
                    normalize_name(row["name"])
                    for row in rows
                    if row["type"] == "TXT" and OWNER_MARKER in row["content"]
                }
                for name in sorted(owned_names):
                    if name == ZONE or not name.endswith(f".{ZONE}") or not DNS_NAME.fullmatch(name):
                        fail(f"owned dynamic name is outside the managed zone: {name}")
                    if name in canonical_names:
                        fail(f"dynamic RRset shadows canonical Git name: {name}")
                    owned_rows = [row for row in rows if normalize_name(row["name"]) == name]
                    if any(row["type"] not in ALLOWED_TYPES for row in owned_rows):
                        fail(f"unsupported record type at owned dynamic name: {name}")
                    ownership = [row for row in owned_rows if row["type"] == "TXT"]
                    targets = [row for row in owned_rows if row["type"] in {"A", "AAAA", "CNAME"}]
                    if len(ownership) != 1 or not targets:
                        fail(f"owned dynamic name must have one ownership TXT and at least one target: {name}")
                    for row in owned_rows:
                        validate_row(row)
                        candidate.execute(
                            "INSERT INTO records(domain_id,name,type,content,ttl,prio,disabled,ordername,auth) VALUES(?,?,?,?,?,?,?,?,?)",
                            (candidate_domain_id, name, row["type"], row["content"], row["ttl"], row["prio"], 0, row["ordername"], row["auth"]),
                        )
                        copied += 1

        candidate.execute("DELETE FROM tsigkeys")
        candidate.execute(
            "INSERT INTO tsigkeys(name,algorithm,secret) VALUES(?,?,?)",
            (KEY_NAME, KEY_ALGORITHM, secret),
        )
        candidate.commit()
        return copied
    finally:
        if source is not None:
            source.close()
        candidate.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    parser.add_argument("key", type=pathlib.Path)
    parser.add_argument("policy", type=pathlib.Path)
    args = parser.parse_args()
    copied = merge(args.source, args.candidate, args.key, args.policy)
    print(f"preserved {copied} validated {OWNER} records")


if __name__ == "__main__":
    main()

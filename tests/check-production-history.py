"""Guard the imported history against deleted, renamed or edited migrations.

New migrations may be added; historical versions must remain intact. This checks
the committed manifest, not the state of a remote database.
"""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'supabase/production-history.json').read_text())
historical = manifest['migrations']
assert len(historical) == 16
versions = [row['version'] for row in historical]
assert versions == sorted(set(versions))
directory = root / 'supabase/migrations'
files = list(directory.glob('*.sql'))
seen = set()
for file in files:
    match = re.fullmatch(r'(\d{14})_[a-z0-9_]+\.sql', file.name)
    assert match, f'Non-production migration filename: {file.name}'
    assert match[1] not in seen, f'Duplicate migration version: {match[1]}'
    seen.add(match[1])
for row in historical:
    path = directory / f"{row['version']}_{row['name']}.sql"
    assert path.exists(), f'Missing applied migration: {path.name}'
    assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'], f'Historical migration changed: {path.name}'
assert set(versions) <= seen
print(f'OK: {len(historical)} imported migrations intact; {len(seen) - len(versions)} new versions')

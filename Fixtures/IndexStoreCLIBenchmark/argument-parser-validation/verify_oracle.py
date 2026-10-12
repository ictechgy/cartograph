#!/usr/bin/env python3
"""Check frozen source evidence and manually authored graph, never tool results."""
import argparse
import collections
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('upstream_checkout', type=Path)
args = parser.parse_args()
root = args.upstream_checkout.resolve()
base = Path(__file__).resolve().parent
oracle = json.loads((base / 'oracle.json').read_text())
manifest = json.loads((base / 'source-manifest.json').read_text())
errors = []
contents = {}
for entry in manifest['files']:
    path = root / entry['path']
    try:
        data = path.read_bytes()
    except OSError as exc:
        errors.append(f"{entry['path']}: {exc}")
        continue
    if hashlib.sha256(data).hexdigest() != entry['sha256']:
        errors.append(f"{entry['path']}: source hash mismatch")
    contents[entry['path']] = data.decode().splitlines()

nodes = {n['id']: n for n in oracle['nodes']}
if len(nodes) != len(oracle['nodes']):
    errors.append('Duplicate node ID')
for node in nodes.values():
    lines = contents.get(node['path'], [])
    line_number = node['declaration_line']
    if not 1 <= line_number <= len(lines):
        errors.append(f"{node['id']}: missing declaration anchor")
        continue
    line = lines[line_number - 1]
    if line.strip() != node['declaration_text']:
        errors.append(f"{node['id']}: declaration text mismatch")
    column = node['declaration_name_column']
    if not line[column - 1:].startswith(node['name'] + '('):
        errors.append(f"{node['id']}: declaration-name column mismatch")
    if lines[node['definition_end_line'] - 1].strip() != '}':
        errors.append(f"{node['id']}: definition closing brace mismatch")

reverse = collections.defaultdict(set)
for edge in oracle['edges']:
    if edge['caller'] not in nodes or edge['callee'] not in nodes:
        errors.append(f"Unknown edge endpoint: {edge}")
        continue
    caller = nodes[edge['caller']]
    if caller['path'] != edge['path']:
        errors.append(f"{edge['caller']}: call site in wrong source file")
    for line, text in zip(edge['call_lines'], edge['call_text']):
        if not caller['declaration_line'] <= line <= caller['definition_end_line']:
            errors.append(f"{edge['caller']}: call site outside authored body range")
        actual = contents.get(edge['path'], [])
        if not 1 <= line <= len(actual) or actual[line - 1].strip() != text:
            errors.append(f"{edge['caller']}: call text mismatch at line {line}")
    reverse[edge['callee']].add(edge['caller'])

for query in oracle['queries']:
    distance = {query['seed']: 0}
    queue = collections.deque([query['seed']])
    while queue:
        callee = queue.popleft()
        if distance[callee] >= query['max_depth']:
            continue
        for caller in reverse[callee]:
            if caller not in distance:
                distance[caller] = distance[callee] + 1
                queue.append(caller)
    actual = {k: v for k, v in distance.items() if k != query['seed']}
    expected = {e['id']: e['minimum_depth'] for e in query['expected']}
    if actual != expected or len(actual) != query['expected_count']:
        errors.append(f"{query['id']}: authored BFS / expected result mismatch")
    for key, depth in actual.items():
        if nodes[key]['minimum_caller_depth'] != depth:
            errors.append(f"{query['id']}/{key}: minimum depth mismatch")

if errors:
    for error in errors:
        print('FAIL:', error)
    raise SystemExit(1)
print(json.dumps({
    'status': 'passed',
    'verified_source_files': len(manifest['files']),
    'source_nodes': len(nodes),
    'source_edges': len(oracle['edges']),
    'call_sites': sum(len(e['call_lines']) for e in oracle['edges']),
    'queries': {q['id']: q['expected_count'] for q in oracle['queries']},
    'comparison_tools_executed': False,
    'role': oracle['role'],
}, indent=2, sort_keys=True))

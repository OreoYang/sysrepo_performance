#!/usr/bin/env python3
"""Coverage matrix: which production rule shapes do the unit tests guard, for which edit action.

Inputs
  prod rules/struct CSV   from `inv` run on the production schemas
  test rules/struct CSV   from `inv` run on the schemas of the unit tests
  evidence files          output of the libyang test binary run with DL_COVER=1 (and, for the real-data sweep,
                          the same line format), one "[  COVER   ]" line per edit: the schema paths the edit
                          created/deleted/replaced, the nodes the validation dropped itself, and the error
                          full validation gave

An edit is evidence for a rule when full validation rejected it BECAUSE of that rule, so every credited edit is a
case where a wrong accept was possible. The action is read from what the edit touched:
  add_node   the edit created the node that carries the rule
  mod_node   the edit replaced the value of the node that carries the rule
  add_atom   the edit created a node the rule reads
  del_atom   the edit deleted a node the rule reads
  mod_atom   the edit replaced the value of a node the rule reads
  cascade    a `when` turned false and the validation dropped its node (the edit is accepted)

Usage: matrix.py --prod DIR --test DIR --evidence FILE [--evidence FILE ...] --out DIR
"""
import argparse
import collections
import csv
import json
import os
import re
import sys

ANTI_FUNCS = {"count", "last", "not", "position", "string-length", "sum", "bit-is-set", "ceiling", "concat",
              "contains", "enum-value", "floor", "lang", "local-name", "name", "namespace-uri", "normalize-space",
              "number", "re-match", "round", "starts-with", "string", "substring", "substring-after",
              "substring-before", "translate"}
ACTIONS = ["add_node", "mod_node", "add_atom", "del_atom", "mod_atom", "cascade"]


def strip_strings(e):
    return re.sub(r'"[^"]*"|\'[^\']*\'', 'S', e)


def pred_spans(e):
    """Text inside [...] at any depth, string literals already removed."""
    out, depth, start = [], 0, 0
    for i, c in enumerate(e):
        if c == '[':
            if depth == 0:
                start = i + 1
            depth += 1
        elif c == ']' and depth:
            depth -= 1
            if depth == 0:
                out.append(e[start:i])
    return out


def atom_module(path):
    mod = None
    for seg in path.split('/'):
        m = re.match(r'([\w\-.]+):', seg)
        if m:
            mod = m.group(1)
    return mod


def signature(r):
    """Features of a rule that decide which part of the incremental machinery protects it."""
    kind, e = r['kind'], strip_strings(r['expr'])
    f = collections.OrderedDict()
    f['kind'] = kind
    f['class'] = r['class']
    f['safe'] = int(r['creation_safe'])
    if kind in ('unique',):
        return f
    funcs = set(re.findall(r'([a-z][a-z0-9\-]*)\(', e))
    anti = bool(funcs & ANTI_FUNCS) or '!=' in e or bool(re.search(r'(?<![\w\-])[+*](?![\w\-])|\sdiv\s|\smod\s|\s-\s', e))
    f['anti'] = int(anti)
    pa = [p for p in r['atom_paths'].split('|') if p]
    f['abs'] = int(bool(re.search(r'(^|[\s(,=!<>|+])/', e)))
    ups = max([len(m) // 3 for m in re.findall(r'(?:\.\./)+', e)] + [0])
    f['ups'] = min(ups, 2) if not f['abs'] else 0
    own = atom_module(r['node']) or r['module']
    f['xmod'] = int(any((atom_module(p) or r['module']) != own for p in pa))
    f['deref'] = int('deref' in funcs)
    f['derived'] = int('derived-from' in funcs or 'derived-from-or-self' in funcs)
    f['axis'] = int(bool(re.search(r'[a-z\-]+::', e)))
    preds = pred_spans(e)
    f['pred'] = int(bool(preds))
    f['pred_cur'] = int(any('current()' in p for p in preds))
    f['implicit'] = int(r['implicit'])
    return f


def sigkey(f, drop=()):
    return tuple((k, v) for k, v in f.items() if k not in drop)


def load_rules(d):
    rows = list(csv.DictReader(open(os.path.join(d, 'rules.csv'))))
    for r in rows:
        r['sig'] = signature(r)
    return rows


def load_struct(d):
    return list(csv.DictReader(open(os.path.join(d, 'struct.csv'))))


def strip_pred(p):
    return re.sub(r"\[[^\]]*\]", '', p)


def is_under(p, anc):
    return p == anc or p.startswith(anc + '/')


def parse_evidence(files):
    ev, test, case = [], '?', '?'
    for fn in files:
        for line in open(fn, errors='replace'):
            m = re.match(r'\[ RUN      \] (\S+)', line)
            if m:
                test, case = m.group(1), '-'
                continue
            m = re.match(r'\[  CASE    \] (.*)', line)
            if m:
                case = m.group(1).strip()
                continue
            m = re.match(r'\[  COVER   \] rc=(\d+) ops=(.*?) (?:dropped=(.*?) )?\| (.*?) \| (.*)$', line)
            if not m:
                continue
            rc, ops, dropped, msg, dpath = int(m.group(1)), m.group(2), m.group(3) or '', m.group(4), m.group(5)
            ops = [tuple(o.split(':', 1)) for o in ops.split(';') if o]
            ev.append(dict(test=test, case=case, rc=rc, ops=ops, dropped=[d for d in dropped.split(';') if d],
                           msg=msg, dpath=dpath.strip()))
    return ev


def msg_rule(msg):
    """(kind, expression or None) of the rule named by a full-validation error."""
    m = re.match(r'Must condition "(.*)" not satisfied\.', msg)
    if m:
        return 'must', m.group(1)
    m = re.match(r'When condition "(.*)" not satisfied\.', msg)
    if m:
        return 'when', m.group(1)
    if msg.startswith('Invalid leafref value') or 'leafref' in msg.split(':')[0]:
        return 'leafref', None
    if msg.startswith('Invalid union value') and 'leafref' in msg:
        return 'leafref', None
    if msg.startswith('Unique data leaf'):
        return 'unique', None
    if msg.startswith('Too few'):
        return 'min-elements', None
    if msg.startswith('Too many'):
        return 'max-elements', None
    if msg.startswith('Mandatory node'):
        return 'mandatory', None
    if msg.startswith('Mandatory choice'):
        return 'mandatory-choice', None
    if msg.startswith('Invalid instance-identifier'):
        return 'instance-identifier', None
    return 'other', None


def norm_expr(e):
    return re.sub(r'\s+', ' ', e).strip()


def roles(rule, ops, dropped):
    """Actions an edit performs relative to a rule."""
    snode = rule['node']
    atoms = [p for p in rule['atom_paths'].split('|') if p]
    out = set()
    for op, p in ops:
        if rule['kind'] == 'unique':
            # the atoms of a unique are leaves of the list the rule sits on
            if is_under(p, snode) and p != snode and op == 'replace':
                out.add('mod_atom')
            if is_under(snode, p) and op == 'create':
                out.add('add_node')
            continue
        if is_under(snode, p):
            # the rule node lies in the touched subtree (or is the touched node)
            if op == 'create':
                out.add('add_node')
            elif op == 'replace' and p == snode:
                out.add('mod_node')
            continue
        for a in atoms:
            if is_under(a, p) or is_under(p, a):
                out.add({'create': 'add_atom', 'delete': 'del_atom', 'replace': 'mod_atom'}.get(op, 'mod_atom'))
    if rule['kind'] == 'when' and any(is_under(snode, d) for d in dropped):
        out.add('cascade')
    return out


def build_evidence(test_rules, ev):
    """Credit every rejecting edit to the rules it was rejected by. Returns {(sigkey, action): {case labels}}."""
    by_node = collections.defaultdict(list)
    for r in test_rules:
        by_node[(r['kind'], r['node'])].append(r)
    cover = collections.defaultdict(set)
    detail = []
    for e in ev:
        if e['rc'] == 0:
            # cascade evidence: accepted, but the validation dropped nodes
            for d in e['dropped']:
                for r in by_node.get(('when', d), []):
                    for a in roles(r, e['ops'], e['dropped']):
                        if a == 'cascade':
                            cover[(sigkey(r['sig']), 'cascade')].add((e['test'], e['case']))
                            detail.append((e, r, 'cascade'))
            continue
        kind, expr = msg_rule(e['msg'])
        node = strip_pred(e['dpath'])
        cands = by_node.get((kind, node), [])
        if kind in ('must', 'when') and expr is not None:
            exact = [r for r in cands if norm_expr(r['expr']) == norm_expr(expr)]
            cands = exact or cands
        for r in cands:
            for a in roles(r, e['ops'], e['dropped']):
                cover[(sigkey(r['sig']), a)].add((e['test'], e['case']))
                detail.append((e, r, a))
    return cover, detail


def applicable(r):
    """Actions that can make this production rule fire.

    A `when` that turns false on an existing node never rejects the edit: the validation drops the node, so the
    only rejecting action is adding a node whose `when` is false, and the other actions are the cascade.
    """
    f, kind = r['sig'], r['kind']
    if kind == 'unique':
        return ['add_node', 'mod_atom']
    acts = ['add_node']
    if kind == 'when':
        return acts + ['cascade']
    if kind == 'leafref' or re.search(r"(?<![\w.\-])\.(?![\w.\-/])|current\(\)", r['expr']):
        acts.append('mod_node')
    # nodes that appear can only break a rule that negates, counts or reads the first node of a set
    if f.get('anti') or f.get('deref'):
        acts.append('add_atom')
    if not upper_bound_count(r['expr']):
        acts.append('del_atom')
    if value_sensitive(r['expr']):
        acts.append('mod_atom')
    return acts


def upper_bound_count(expr):
    """A rule that is only `count(...) < N` (or <=): removing a counted node lowers the count, so no deletion fails it."""
    e = norm_expr(strip_strings(expr))
    m = re.fullmatch(r'count\((.*)\)\s*<=?\s*\d+', e)
    return bool(m) and not re.search(r'\b(count|not|or|and)\b', m.group(1))


def value_sensitive(expr):
    """Whether replacing the value of a node the rule reads can change its result.

    A rule that only tests nodes for existence (boolean(), a bare path, not()) is blind to values; predicates
    only select by key, which an edit cannot replace.
    """
    e = strip_strings(expr)
    for _ in range(4):
        e = re.sub(r'\[[^\[\]]*\]', '', e)
    return bool(re.search(r'[=<>]|derived-from|contains|starts-with|string-length|sum\(|number\(|count\(|deref', e)) \
        or bool(re.search(r'(?<![\w.\-])\.(?![\w.\-/])', e))


def struct_evidence(ev):
    cover = collections.defaultdict(set)
    for e in ev:
        if e['rc'] == 0:
            continue
        kind, _ = msg_rule(e['msg'])
        if kind in ('min-elements', 'max-elements', 'mandatory', 'mandatory-choice', 'unique'):
            for op, _p in e['ops']:
                cover[(kind, op)].add((e['test'], e['case']))
    return cover


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--prod', required=True)
    ap.add_argument('--test', required=True)
    ap.add_argument('--evidence', action='append', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--extra-evidence', action='append', default=[], help='real-data sweep evidence, counted apart')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    prod = load_rules(a.prod)
    test = load_rules(a.test)
    ev = parse_evidence(a.evidence)
    cover, detail = build_evidence(test, ev)
    ev2 = parse_evidence(a.extra_evidence) if a.extra_evidence else []
    sweep_cover, _ = build_evidence(prod, ev2) if ev2 else ({}, [])

    # exact: same signature; near: same kind, class, safe, anti, abs (ignores path depth, other module, predicate shape...)
    near_drop = ('ups', 'xmod', 'pred', 'pred_cur', 'implicit', 'axis', 'derived', 'deref')
    near = collections.defaultdict(set)
    for (sk, act), cases in cover.items():
        near[(tuple((k, v) for k, v in sk if k not in near_drop), act)] |= cases

    rows = []
    sigs = collections.OrderedDict()
    for r in prod:
        sk = sigkey(r['sig'])
        s = sigs.setdefault(sk, dict(rules=[], cells={}))
        s['rules'].append(r)
        for act in applicable(r):
            exact = cover.get((sk, act), set())
            nr = near.get((tuple((k, v) for k, v in sk if k not in near_drop), act), set())
            sw = sweep_cover.get((sk, act), set()) if sweep_cover else set()
            state = 'EXACT' if exact else ('NEAR' if nr else 'GAP')
            s['cells'][act] = (state, len(exact), len(nr), len(sw))
            rows.append(dict(module=r['module'], node=r['node'], kind=r['kind'], act=act, state=state,
                             exact=len(exact), near=len(nr), sweep=len(sw), sig=json.dumps(r['sig']),
                             expr=r['expr']))

    with open(os.path.join(a.out, 'matrix_rules.csv'), 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    # signature table
    with open(os.path.join(a.out, 'matrix_sigs.csv'), 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['prod_rules', 'signature'] + ACTIONS + ['example_node', 'example_expr'])
        for sk, s in sorted(sigs.items(), key=lambda kv: -len(kv[1]['rules'])):
            ex = s['rules'][0]
            w.writerow([len(s['rules']), ' '.join('%s=%s' % kv for kv in sk)] +
                       [('%s(%d/%d/%d)' % ((s['cells'][a_][0],) + s['cells'][a_][1:]) if a_ in s['cells'] else '-')
                        for a_ in ACTIONS] + [ex['node'], ex['expr'][:120]])

    # summary
    tot = collections.Counter(r['state'] for r in rows)
    print('production rules: %d, signatures: %d, cells: %d' % (len(prod), len(sigs), len(rows)))
    print('cell state (exact / near / gap): %d / %d / %d' % (tot['EXACT'], tot['NEAR'], tot['GAP']))
    per_act = collections.defaultdict(collections.Counter)
    for r in rows:
        per_act[r['act']][r['state']] += 1
    for act in ACTIONS:
        c = per_act[act]
        print('  %-9s exact %4d  near %4d  gap %4d' % (act, c['EXACT'], c['NEAR'], c['GAP']))

    # rules that read another module: sysrepo validates per module, so these need their own evidence
    xt = collections.defaultdict(lambda: collections.Counter())
    for r in prod:
        if r['sig'].get('xmod'):
            xt[r['kind']]['rules'] += 1
    for (sk, act), cases in cover.items():
        d = dict(sk)
        if d.get('xmod'):
            xt[d['kind']][act] += len(cases)
    print('cross-module rules and test cases that reject through one:')
    for k, c in sorted(xt.items()):
        print('  %-8s rules %3d  %s' % (k, c['rules'], {a_: c[a_] for a_ in ACTIONS if c[a_]}))
    json.dump({k: dict(v) for k, v in xt.items()}, open(os.path.join(a.out, 'xmod.json'), 'w'))

    # structural rules
    sev = struct_evidence(ev)
    st = load_struct(a.prod)
    cnt = collections.Counter(s['kind'] for s in st)
    print('structural: %s' % dict(cnt))
    with open(os.path.join(a.out, 'matrix_struct.csv'), 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['kind', 'prod_nodes', 'create_cases', 'delete_cases', 'replace_cases'])
        for k in ('mandatory', 'mandatory-choice', 'min-elements', 'max-elements', 'unique'):
            w.writerow([k, cnt[k], len(sev.get((k, 'create'), ())), len(sev.get((k, 'delete'), ())),
                        len(sev.get((k, 'replace'), ()))])
            print('  %-17s nodes %3d  create %3d delete %3d replace %3d' % (
                k, cnt[k], len(sev.get((k, 'create'), ())), len(sev.get((k, 'delete'), ())),
                len(sev.get((k, 'replace'), ()))))

    json.dump({'|'.join('%s=%s' % kv for kv in sk): {a_: [list(c) for c in sorted(v)[:5]] for (s2, a_), v in cover.items()
                                                     if s2 == sk} for sk in {k for k, _ in cover}},
              open(os.path.join(a.out, 'test_evidence.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()

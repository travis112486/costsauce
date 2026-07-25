#!/usr/bin/env python3
"""Push curated CostSauce repo to GitHub via Composio (GITHUB_COMMIT_MULTIPLE_FILES).
Text files as utf-8; binaries as base64. Batched ~750KB/commit."""
import base64, json, os, subprocess, sys
from pathlib import Path

HOME = Path('/opt/data')
ROOT = HOME / 'projects/company-builder-experiment/run-1'
COMPOSIO = HOME / '.composio/composio'
OWNER, REPO, BRANCH = 'travis112486', 'costsauce', 'main'

EXCLUDE_DIRS = {'videos/frames-launch', 'videos/frames-founder', 'videos/vo', 'videos/watch', 'node_modules', '__pycache__', '.git'}
EXCLUDE_FILES = {'product/costsauce.db', 'videos/music.wav', 'videos/music-loop.wav', 'videos/genframes.sh',
                 'brand/hero-owner.png', 'site/assets/img/hero-owner.png', 'deliverables/ad-feed-1x1.png',
                 'evidence/image-probe.png', 'videos/founder.mp4', 'videos/launch.mp4'}
TEXT_EXT = {'.py', '.js', '.css', '.html', '.md', '.json', '.svg', '.txt', '.gitignore', '.sh'}

def staged_files():
    out = []
    for p in sorted(ROOT.rglob('*')):
        if not p.is_file():
            continue
        rel = str(p.relative_to(ROOT))
        if rel in EXCLUDE_FILES or any(rel.startswith(d + '/') for d in EXCLUDE_DIRS):
            continue
        if any(part in {'.git', '__pycache__'} for part in p.parts):
            continue
        out.append((rel, p))
    return out

def run_composio(tool, payload):
    tmp = HOME / 'backups' / f'costsauce-push-{os.getpid()}.json'
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(payload))
    env = os.environ.copy()
    env['PATH'] = f"{HOME}/.composio:{env.get('PATH','')}"
    try:
        r = subprocess.run([str(COMPOSIO), 'execute', tool, '-d', f'@{tmp}'],
                           text=True, capture_output=True, timeout=300, env=env)
        out = r.stdout.strip()
        if r.returncode != 0:
            raise RuntimeError(f'composio rc={r.returncode}: {(r.stderr or out)[:400]}')
        return json.loads(out) if out else {}
    finally:
        tmp.unlink(missing_ok=True)

def main():
    files = staged_files()
    print(f'{len(files)} files staged, total {sum(p.stat().st_size for _, p in files)/1e6:.1f} MB')
    batches, cur, cur_size = [], [], 0
    LIMIT = 750_000
    for rel, p in files:
        raw = p.read_bytes()
        is_text = p.suffix.lower() in TEXT_EXT or p.name == '.gitignore'
        if is_text:
            try:
                entry = {'path': rel, 'content': raw.decode('utf-8'), 'encoding': 'utf-8'}
            except UnicodeDecodeError:
                entry = {'path': rel, 'content': base64.b64encode(raw).decode(), 'encoding': 'base64'}
        else:
            entry = {'path': rel, 'content': base64.b64encode(raw).decode(), 'encoding': 'base64'}
        size = len(entry['content'])
        if cur and cur_size + size > LIMIT:
            batches.append(cur); cur, cur_size = [], 0
        cur.append(entry); cur_size += size
    if cur:
        batches.append(cur)
    print(f'{len(batches)} batches')
    for i, b in enumerate(batches, 1):
        payload = {'owner': OWNER, 'repo': REPO, 'branch': BRANCH,
                   'message': f'CostSauce run-1 package (batch {i}/{len(batches)})', 'upserts': b}
        res = run_composio('GITHUB_COMMIT_MULTIPLE_FILES', payload)
        ok = res.get('successful', True)
        print(f'batch {i}/{len(batches)}: {len(b)} files, successful={ok}')
        if not ok:
            print(json.dumps(res)[:500]); sys.exit(1)
    print('PUSH COMPLETE')

if __name__ == '__main__':
    main()

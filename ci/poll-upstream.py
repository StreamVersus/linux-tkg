#!/usr/bin/env python3
"""Observe upstream master and enqueue one Woodpecker build per observed SHA."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
sys.path.insert(0, '/root/.local/libexec')
from linux_tkg_api import wp_request

ROOT = Path('/root/linux-tkg')
STATE = ROOT / 'state' / 'upstream.json'
REPO_ID = 1
UPSTREAM = 'https://github.com/Frogging-Family/linux-tkg.git'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--force', action='store_true', help='explicitly rebuild current upstream revision')
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--configure', action='store_true')
    args = parser.parse_args()
    Path('/run/linux-tkg-ci').mkdir(exist_ok=True)
    with open('/run/linux-tkg-ci/upstream.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        repo = wp_request(f'/repos/{REPO_ID}')
        if repo['full_name'] != 'StreamVersus/linux-tkg':
            raise RuntimeError('unexpected Woodpecker repository ID')
        if args.configure:
            wp_request(f'/repos/{REPO_ID}', 'PATCH', {'timeout':4320})
            print('Repository timeout set to 72 hours; trust privileges unchanged.')
            return
        if args.status:
            for build in wp_request(f'/repos/{REPO_ID}/pipelines?perPage=8'):
                print(build.get('number'), build.get('status'), build.get('message'))
            return
        output = subprocess.check_output(['git','ls-remote',UPSTREAM,'refs/heads/master'], text=True, timeout=25)
        sha = output.split()[0]
        if not re.fullmatch(r'[0-9a-f]{40}', sha):
            raise RuntimeError('invalid upstream SHA')
        state = json.loads(STATE.read_text()) if STATE.exists() else {}
        if state.get('last_dispatched_sha') == sha and not args.force:
            print('Unchanged upstream:', sha)
            return
        marker = 'upstream linux-tkg ' + sha
        builds = wp_request(f'/repos/{REPO_ID}/pipelines?perPage=100')
        existing = next((b for b in builds if marker in b.get('message','')), None)
        if existing and not args.force:
            number = existing['number']
            print('Already queued pipeline', number, 'for', sha)
        else:
            build = wp_request(f'/repos/{REPO_ID}/pipelines', 'POST', {
                'branch':'master', 'message':marker,
                'variables':{'TKG_UPSTREAM_COMMIT':sha}})
            if not build or not build.get('number'):
                raise RuntimeError('server did not create a pipeline; check workflow filters')
            number = build['number']
            print('Queued pipeline', number, 'for upstream', sha)
        STATE.parent.mkdir(exist_ok=True)
        temporary = STATE.with_suffix('.tmp')
        temporary.write_text(json.dumps({'last_dispatched_sha':sha,'pipeline':number},indent=2)+'\n')
        os.replace(temporary, STATE)

if __name__ == '__main__':
    try:
        main()
    except BlockingIOError:
        print('Another upstream check is active')
    except Exception as exc:
        print('Upstream poll failed:', str(exc), file=sys.stderr)
        raise SystemExit(1)

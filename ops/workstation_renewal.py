#!/usr/bin/env python3
"""Publish host-minted scoped identities using existing workstation OAuth.

No Cloudflare credential or private signing key crosses the SSH boundary.
All secret-bearing subprocess output is captured, never logged.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

SOURCE = Path('/Users/miakh/source/banksync')
HOST = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', 'deploy@2.31.8.159', 'sudo -n python3 -']
LOAD = """import importlib.util,json,fcntl,hashlib,time
s=importlib.util.spec_from_file_location('rotation','/opt/invoicesync/ops/rotate_credentials.py')
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
"""
PREPARE = LOAD + """
with (m.ROOT/'rotation.lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 state=m.protected_json(m.ROOT/'state.json')
 class PublicationPending(Exception):pass
 def stage(rows):
  print(json.dumps({'workloads':rows}))
  raise PublicationPending()
 try:
  result=m.rotate(state,publish=stage,persist=lambda value:m.save(m.ROOT/'state.json',value))
  m.save(m.ROOT/'health.json',{**result,'checked_at':int(time.time()),'publication':'workstation_oauth'})
  print(json.dumps(result))
 except PublicationPending:pass
"""


def remote(code):
    result = subprocess.run(HOST, input=code, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError('host_credential_check_failed')
    return json.loads(result.stdout)


def finalize_code(workloads):
    # Only the expected digest enters command source. The secret stays in host
    # state, and an intervening publication cannot finalize a different token.
    digest = hashlib.sha256(json.dumps(workloads, sort_keys=True).encode()).hexdigest()
    return LOAD + """
with (m.ROOT/'rotation.lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 state=m.protected_json(m.ROOT/'state.json')
 rows=[{**state['workloads'][0],'token':state['pending']['token']}]
 if hashlib.sha256(json.dumps(rows,sort_keys=True).encode()).hexdigest()!=EXPECTED:
  raise RuntimeError('publication_identity_changed')
 result=m.rotate(state,publish=lambda rows:None,persist=lambda value:m.save(m.ROOT/'state.json',value))
 m.save(m.ROOT/'health.json',{**result,'checked_at':int(time.time()),'publication':'workstation_oauth'})
 print(json.dumps(result))
""".replace('EXPECTED', repr(digest))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('credential_redirect_denied')


def publish(workloads):
    result = subprocess.run(['/opt/homebrew/bin/node', str(SOURCE / 'node_modules/wrangler/bin/wrangler.js'), 'auth', 'token', '--json'], cwd=SOURCE, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError('workstation_cloudflare_auth_unavailable')
    token = json.loads(result.stdout)['token']
    request = urllib.request.Request('https://api.cloudflare.com/client/v4/accounts/84b32318ac235bf6738bdf1c8caa0795/workers/scripts/invoicesync/secrets', method='PUT', data=json.dumps({'name': 'WORKLOADS_JSON', 'text': json.dumps(workloads), 'type': 'secret_text'}).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', 'User-Agent': 'InvoiceSync-Credential-Renewal/1'})
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=40) as response:
        data = json.load(response)
    if not data.get('success') or data.get('result', {}).get('name') != 'WORKLOADS_JSON':
        raise RuntimeError('credential_publication_failed')


def run(prepare=remote, publisher=publish, complete=remote):
    result = prepare(PREPARE)
    if 'workloads' in result:
        publisher(result['workloads'])
        result = complete(finalize_code(result['workloads']))
    if result.get('status') not in ('valid', 'renewed'):
        raise RuntimeError('credential_result_invalid')
    return {'worker': 'invoicesync', **result}


if __name__ == '__main__':
    try:
        print(json.dumps(run()))
    except Exception:
        raise SystemExit('InvoiceSync credential check failed; inspect host state and workstation SSH/Cloudflare login; pending identity retained') from None

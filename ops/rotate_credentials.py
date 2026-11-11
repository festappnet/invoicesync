#!/usr/bin/env python3
"""Host-only renewal of InvoiceSync's existing read/jobs/bank identity.

The private signer stays on the database host. State contains the complete
WORKLOADS_JSON binding, so publishing never drops unrelated configuration.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path('/opt/napojse/private/invoicesync-credential-rotation')
ACCOUNT = '84b32318ac235bf6738bdf1c8caa0795'
WORKER = 'invoicesync'


def decode(token):
    return json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '==='))


def renewal_sql(app, old, new, recover_expired=False):
    if app != 'catalogpilot':
        raise ValueError('credential_app_invalid')
    for claims in (old, new):
        if (claims.get('role'), claims.get('aud')) != ('invoicing_gateway', 'invoicing-rpc'):
            raise ValueError('credential_scope_invalid')
        if not re.fullmatch('[a-f0-9]{64}', claims.get('jti', '')) or type(claims.get('exp')) is not int:
            raise ValueError('credential_identity_invalid')
    previous = hashlib.sha256(old['jti'].encode()).hexdigest()
    following = hashlib.sha256(new['jti'].encode()).hexdigest()
    expiry = '' if recover_expired else ' AND expires_at>now()'
    return f"""INSERT INTO invoicing.credentials(jti_hash,app_id,audience,scopes,expires_at)
      SELECT '{following}',app_id,audience,scopes,to_timestamp({new['exp']})
      FROM invoicing.credentials WHERE jti_hash='{previous}' AND app_id='catalogpilot'
      AND audience='invoicing-rpc' AND scopes=ARRAY['read','jobs','bank']::text[]
      AND revoked_at IS NULL AND expires_at=to_timestamp({old['exp']}){expiry}
      ON CONFLICT(jti_hash) DO UPDATE SET jti_hash=excluded.jti_hash
      WHERE credentials.app_id=excluded.app_id AND credentials.audience=excluded.audience
      AND credentials.scopes=excluded.scopes AND credentials.expires_at=excluded.expires_at
      AND credentials.revoked_at IS NULL RETURNING jti_hash;"""


def save(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=path.name + '.')
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def protected_json(path):
    info = path.stat()
    if info.st_uid != 0 or info.st_mode & 0o077:
        raise RuntimeError('credential_file_permissions')
    return json.loads(path.read_text())


def sign(claims):
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    values = dict(line.split('=', 1) for line in Path('/opt/napojse/infra/supabase/.env').read_text().splitlines() if '=' in line and not line.startswith('#'))
    jwk = next(k for k in json.loads(values['JWT_KEYS'].strip().strip('\"\'')) if k.get('alg') == 'ES256' and 'd' in k)
    def b64(value):
        return base64.urlsafe_b64encode(value).decode().rstrip('=')
    header = b64(json.dumps({'alg': 'ES256', 'typ': 'JWT', 'kid': jwk['kid']}).encode())
    body = b64(json.dumps(claims).encode())
    key = ec.derive_private_key(int.from_bytes(base64.urlsafe_b64decode(jwk['d'] + '==='), 'big'), ec.SECP256R1())
    r, s = decode_dss_signature(key.sign((header + '.' + body).encode(), ec.ECDSA(hashes.SHA256())))
    return header + '.' + body + '.' + b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('credential_redirect_denied')


def http(url, headers, body=None, method=None):
    request = urllib.request.Request(url, headers={**headers, 'User-Agent': 'InvoiceSync-Credential-Rotation/1'}, data=None if body is None else json.dumps(body).encode(), method=method)
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
        return json.load(response)


def probe(token):
    result = http('https://catalogpilot-rpc.mendelio.net/rest/v1/rpc/dispatch', {
        'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
        'Content-Profile': 'invoicing_api', 'Accept-Profile': 'invoicing_api',
    }, {'p_op': 'lookup_permission', 'p_request': {}})
    if result != {'app_id': 'catalogpilot'}:
        raise RuntimeError('credential_probe_identity')


def register(app, old, new, recover_expired):
    result = subprocess.run(['docker', 'exec', '-i', 'napojse-db-1', 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-qAt'], input=renewal_sql(app, old, new, recover_expired), text=True, capture_output=True, timeout=20)
    if result.returncode or result.stdout.strip() != hashlib.sha256(new['jti'].encode()).hexdigest():
        raise RuntimeError('credential_registration_failed')


def rotate(state, *, now=None, recover_expired=False, signer=sign, registrar=register, verify=probe, publish=None, persist=None):
    now = int(time.time()) if now is None else now
    workloads = state['workloads']
    if len(workloads) != 1 or workloads[0]['app_id'] != 'catalogpilot' or workloads[0]['bank_account_id'] != 191:
        raise ValueError('workload_inventory_invalid')
    row = workloads[0]
    old = decode(row['token'])
    if not state.get('pending'):
        if old['exp'] - now > 7 * 86400:
            verify(row['token'])
            return {'status': 'valid', 'expires_at': old['exp']}
        if old['exp'] <= now and not recover_expired:
            raise RuntimeError('expired_credential_requires_recovery')
        new = {**old, 'jti': secrets.token_hex(32), 'iat': now, 'exp': now + 30 * 86400}
        state['pending'] = {'token': signer(new), 'registered': False}
        persist(state)
    pending = state['pending']
    new = decode(pending['token'])
    if new['exp'] <= now:
        raise RuntimeError('pending_credential_expired')
    if not pending['registered']:
        # Save before registration. On an uncertain result, verify the exact
        # pending identity before attempting an idempotent registration again.
        try:
            verify(pending['token'])
        except Exception:
            registrar(row['app_id'], old, new, recover_expired)
        pending['registered'] = True
        persist(state)
    verify(pending['token'])
    updated = [{**row, 'token': pending['token']}]
    publish(updated)
    # Publish retries use exactly the same credential after a lost CF response.
    row['token'] = pending['token']
    del state['pending']
    persist(state)
    return {'status': 'renewed', 'expires_at': new['exp']}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--recover-expired', action='store_true', help='Explicit one-time recovery of an unrevoked, exact registered predecessor')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    with (ROOT / 'rotation.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = protected_json(ROOT / 'state.json')
        if args.check:
            if state.get('pending'):
                raise RuntimeError('credential_publication_pending')
            for row in state['workloads']:
                probe(row['token'])
            print(json.dumps({'worker': WORKER, 'check': 'ok', 'expires_at': decode(state['workloads'][0]['token'])['exp']}))
            return
        credential = protected_json(ROOT / 'cloudflare-token.json')['token']
        def publish(workloads):
            result = http(f'https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/workers/scripts/{WORKER}/secrets', {'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'}, {'name': 'WORKLOADS_JSON', 'text': json.dumps(workloads), 'type': 'secret_text'}, 'PUT')
            if result.get('success') is not True or result.get('result', {}).get('name') != 'WORKLOADS_JSON':
                raise RuntimeError('credential_publish_failed')
        result = rotate(state, recover_expired=args.recover_expired, publish=publish, persist=lambda value: save(ROOT / 'state.json', value))
        save(ROOT / 'health.json', {**result, 'checked_at': int(time.time())})
        print(json.dumps({'worker': WORKER, **result}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('InvoiceSync credential renewal failed; protected state retained; inspect service and credential expiry') from None

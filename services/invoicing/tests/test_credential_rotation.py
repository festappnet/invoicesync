"""Real PostgreSQL scope/recovery fences and frozen publication failure replay."""
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import time
from unittest.mock import Mock
import psycopg
from postgres_case import PostgresCase

spec = importlib.util.spec_from_file_location('rotation', Path(__file__).resolve().parents[3] / 'ops/rotate_credentials.py')
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


def token(claims):
    return 'fixture.' + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=') + '.fixture'


def claims(exp):
    return {'role': 'invoicing_gateway', 'aud': 'invoicing-rpc', 'jti': 'a' * 64, 'exp': exp}


class CredentialRotationTests(PostgresCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        with psycopg.connect(cls.owner_dsn) as c:
            for path in sorted((Path(__file__).resolve().parents[1] / 'migrations').glob('*.sql')):
                c.execute(path.read_text())
            c.execute("INSERT INTO invoicing.applications(id,environment) VALUES('catalogpilot','simulation')")

    def test_registration_requires_exact_live_scope_and_explicit_expired_recovery(self):
        old = claims(int(time.time()) - 86400)
        new = {**old, 'jti': 'b' * 64, 'exp': int(time.time()) + 30 * 86400}
        previous = hashlib.sha256(old['jti'].encode()).hexdigest()
        following = hashlib.sha256(new['jti'].encode()).hexdigest()
        with psycopg.connect(self.owner_dsn) as c, c.transaction(force_rollback=True):
            c.execute("INSERT INTO invoicing.credentials(jti_hash,app_id,scopes,expires_at) VALUES(%s,'catalogpilot',ARRAY['read','jobs','bank'],to_timestamp(%s))", (previous, old['exp']))
            self.assertIsNone(c.execute(rotation.renewal_sql('catalogpilot', old, new)).fetchone())
            self.assertEqual(c.execute(rotation.renewal_sql('catalogpilot', old, new, True)).fetchone()[0], following)
            self.assertEqual(c.execute(rotation.renewal_sql('catalogpilot', old, new, True)).fetchone()[0], following)
            c.execute('SET LOCAL ROLE invoicing_gateway')
            c.execute("SELECT set_config('request.jwt.claims',%s,true)", (json.dumps(new),))
            self.assertEqual(c.execute("SELECT invoicing_api.dispatch('lookup_permission')").fetchone()[0], {'app_id': 'catalogpilot'})
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                c.execute("SELECT invoicing_api.dispatch('invoice_create')")
        for change in ("revoked_at=now()", "scopes=ARRAY['read','write','deliver']", "app_id='different'"):
            with psycopg.connect(self.owner_dsn) as c, c.transaction(force_rollback=True):
                c.execute("INSERT INTO invoicing.applications(id,environment) VALUES('different','simulation')")
                c.execute("INSERT INTO invoicing.credentials(jti_hash,app_id,scopes,expires_at) VALUES(%s,'catalogpilot',ARRAY['read','jobs','bank'],to_timestamp(%s))", (previous, old['exp']))
                c.execute('UPDATE invoicing.credentials SET ' + change)
                self.assertIsNone(c.execute(rotation.renewal_sql('catalogpilot', old, new, True)).fetchone())

    def test_expired_identity_requires_recovery_and_publication_retry_preserves_whole_binding(self):
        now = int(time.time())
        original = {'workloads': [{'app_id': 'catalogpilot', 'bank_account_id': 191, 'token': token(claims(now - 1)), 'bank_secrets': ['fixture'], 'webhook_keys': {'v1': 'fixture'}, 'email_from': 'fixture@example.invalid'}]}
        state = copy.deepcopy(original)
        with self.assertRaisesRegex(RuntimeError, 'requires_recovery'):
            rotation.rotate(state, now=now)
        register = Mock()
        verify = Mock(side_effect=[RuntimeError('not registered'), None])
        persist = Mock()
        with self.assertRaises(TimeoutError):
            rotation.rotate(state, now=now, recover_expired=True, signer=token, registrar=register, verify=verify, publish=Mock(side_effect=TimeoutError('lost publication response')), persist=persist)
        self.assertEqual(state['workloads'], original['workloads'])
        register.assert_called_once()
        pending = state['pending']['token']
        publish = Mock()
        result = rotation.rotate(state, now=now, signer=token, registrar=register, verify=Mock(), publish=publish, persist=persist)
        self.assertEqual(register.call_count, 1)
        self.assertEqual(result['status'], 'renewed')
        expected = [{**original['workloads'][0], 'token': pending}]
        publish.assert_called_once_with(expected)
        self.assertEqual(state, {'workloads': expected})

    def test_valid_credential_is_probed_without_rotation(self):
        now = int(time.time())
        state = {'workloads': [{'app_id': 'catalogpilot', 'bank_account_id': 191, 'token': token(claims(now + 30 * 86400))}]}
        verify, publish, register = Mock(), Mock(), Mock()
        self.assertEqual(rotation.rotate(state, now=now, verify=verify, publish=publish, registrar=register)['status'], 'valid')
        verify.assert_called_once_with(state['workloads'][0]['token'])
        publish.assert_not_called()
        register.assert_not_called()

"""Disposable PostgreSQL without any consumer application schema."""
import os,subprocess,tempfile,unittest
from pathlib import Path
class PostgresCase(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.tmp=tempfile.TemporaryDirectory(prefix='invoicesync-',dir='/tmp');folder=Path(cls.tmp.name)
  cls.pg=os.environ.get('TEST_PG_BIN','/opt/homebrew/opt/postgresql@17/bin').rstrip('/')+'/'
  cls.data=str(folder/'data');cls.addClassCleanup(cls.tearDownClass)
  cls.command([cls.pg+'initdb','-D',cls.data,'-A','trust','--no-locale','--encoding=UTF8','-U','test_owner'])
  cls.command([cls.pg+'pg_ctl','-D',cls.data,'-l',str(folder/'pg.log'),'-o',f"-k {folder} -c listen_addresses=''",'-w','start'])
  cls.owner_dsn=f'host={folder} user=test_owner dbname=postgres'
 @classmethod
 def command(cls,args):
  result=subprocess.run(args,capture_output=True,text=True)
  if result.returncode:raise RuntimeError(result.stderr[-1500:])
 @classmethod
 def tearDownClass(cls):
  if (Path(cls.data)/'postmaster.pid').exists():cls.command([cls.pg+'pg_ctl','-D',cls.data,'-m','fast','-w','stop'])
  cls.tmp.cleanup()

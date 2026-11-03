#!/usr/bin/env bash
# Exercise the shared queue's executable API with private paths and fake adb.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp=$(fm_test_tmproot fm-test-queues)
trap fm_test_cleanup EXIT
export QUEUE_TEST_ROOT="$tmp" QUEUE_CODE_ROOT="$ROOT"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$@" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

CODE = Path(os.environ['QUEUE_CODE_ROOT']) / 'bin'
CLI = CODE / 'fm-test-service.py'
sys.path.insert(0, str(CODE))
import fm_device_lease as leases
import fm_phone_queue as phones
import fm_queue_tickets as tickets
import fm_test_queues as queues

HOLD = '''import os,sys,time
from pathlib import Path
root, name, serial = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
(root / ('acquired-' + name)).write_text(serial + ':' + os.environ.get('FM_TEST_PHONE_QUEUE_HELD', 'suite'))
while not (root / ('release-' + name)).exists(): time.sleep(.01)
'''


class SharedQueues(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['QUEUE_TEST_ROOT'])
        self.root = Path(self.temp.name)
        self.children = {}
        self.logs = {}
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_TEST_', 'FROGPILE_'))}
        self.env.update(HOME=str(self.root / 'home'), FM_HOME=str(self.root / 'fm'),
                        FM_TEST_SERVICE_STATE=str(self.root / 'state'),
                        FM_TEST_SERVICE_CONFIG_ROOT=str(self.root / 'configs'),
                        FM_TEST_SUITE_CAPACITY='1')
        for d in ('home', 'configs', 'bin'):
            (self.root / d).mkdir()
        for project in ('one', 'two'):
            self.write_config(project)
        (self.root / 'home/online').write_text('a\nb\n')
        adb = self.root / 'bin/adb'
        adb.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
online = (Path(os.environ['HOME']) / 'online').read_text().splitlines()
if sys.argv[1] == 'devices':
    print('List of devices attached')
    for serial in online: print(serial + '\tdevice')
elif sys.argv[3] == 'get-state':
    print('device' if sys.argv[2] in online else 'offline')
elif sys.argv[3:] == ['shell', 'settings', 'get', 'global', 'stay_on_while_plugged_in']: print('2')
elif sys.argv[3:] == ['shell', 'dumpsys', 'window']: print('isKeyguardShowing=false')
''')
        adb.chmod(0o755)
        self.env['PATH'] = str(adb.parent) + ':' + self.env['PATH']

    def tearDown(self):
        for child in self.children.values():
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=10)
        for stream in self.logs.values():
            stream.close()
        self.temp.cleanup()

    def write_config(self, project, **extra):
        cfg = dict(suite=['suite.sh'], device=['device.sh', '{serial}'], phones=['a', 'b'],
                   any_phones=['a', 'b'], landing_branch='main', queue_mode='service')
        cfg.update(extra)
        (self.root / 'configs' / (project + '.json')).write_text(json.dumps(cfg))

    def start(self, name, argv, **kwargs):
        stream = (self.root / (name + '.log')).open('w')
        self.logs[name] = stream
        self.children[name] = subprocess.Popen(argv, env=self.env, stdout=stream,
                                               stderr=subprocess.STDOUT, start_new_session=True, **kwargs)
        return self.children[name]

    def logs_text(self):
        return '\n'.join(p.name + ': ' + p.read_text() for p in self.root.glob('*.log'))

    def until(self, condition, what, timeout=25):
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() > deadline:
                self.fail(f'timed out: {what}\n{self.logs_text()}')
            time.sleep(.02)

    def events(self, kind):
        path = self.root / 'state/queues' / ('phones' if kind == 'phone' else 'suite') / 'events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def request(self, name, kind='phone', serial='any', project='one', capacity=1, worktree=None):
        count = sum(r['event'] == 'request' for r in self.events(kind))
        args = [sys.executable, str(CLI), 'queue', kind]
        if kind == 'phone':
            args += ['--project', project, '--serial', serial]
        else:
            args += ['--capacity', str(capacity), '--worktree-lock', str(self.root / (worktree or name))]
        args += ['--', sys.executable, '-c', HOLD, str(self.root), name, '{serial}']
        child = self.start(name, args)
        self.until(lambda: sum(r['event'] == 'request' for r in self.events(kind)) > count,
                   name + ' ticket')
        return child

    def acquired(self, name):
        return (self.root / ('acquired-' + name)).exists()

    def wait_acquired(self, name):
        self.until(lambda: self.acquired(name), name + ' acquire')
        return (self.root / ('acquired-' + name)).read_text()

    def release(self, name):
        (self.root / ('release-' + name)).touch()
        self.assertEqual(self.children[name].wait(timeout=25), 0, self.logs_text())

    def cli(self, *args, **kwargs):
        return subprocess.run([sys.executable, str(CLI), *args], env=self.env,
                              capture_output=True, text=True, timeout=30, **kwargs)

    def descriptor_owner(self, name):
        queue = self.root / 'state/queues/suite'
        (queue / 'slots').mkdir(parents=True, exist_ok=True)
        (self.root / 'state/queues/legacy').mkdir(parents=True, exist_ok=True)
        script = '''set -eu
python=$1; cli=$2; root=$3; name=$4
queue=$root/state/queues/suite
exec 7> "$root/worktree-$name"
exec 8> "$queue/suite.lock"
exec 9> "$root/state/queues/legacy/frogpile-suite.lock"
exec 20> "$queue/slots/slot-0.lock"
"$python" "$cli" queue suite-acquire --queue "$queue" --owner-pid "$$" \\
  --holder "$queue/holders" --capacity 1 --selection-out "$root/selection-$name" \\
  --worktree-fd 7 --queue-fd 8 --legacy-fd 9 --slot-fd 20 &
helper=$!
printf '%s\\n' "$helper" > "$root/bridge-$name.pid"
wait "$helper"
printf suite > "$root/acquired-$name"
while [ ! -e "$root/release-$name" ]; do sleep .02; done
'''
        return self.start(name, ['bash', '-c', script, 'suite-owner', sys.executable,
                                 str(CLI), str(self.root), name])

    def wait_kernel_lock(self, pid):
        def blocked():
            pending = [pid]
            for current in pending:
                proc = Path('/proc') / str(current)
                try:
                    if 'lock' in (proc / 'wchan').read_text():
                        return True
                    pending.extend(int(p) for p in
                                   (proc / 'task' / str(current) / 'children').read_text().split())
                except FileNotFoundError:
                    continue
            return False
        self.until(blocked, f'process {pid} blocked in kernel lock admission')

    def legacy_suite_waiter(self, name):
        code = '''import fcntl,sys,time
from pathlib import Path
root, name = Path(sys.argv[1]), sys.argv[2]
with (root / 'state/queues/legacy/frogpile-suite.lock').open('a+') as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    (root / ('acquired-' + name)).touch()
    while not (root / ('release-' + name)).exists(): time.sleep(.02)
'''
        return self.start(name, [sys.executable, '-c', code, str(self.root), name])

    def test_vip_precedes_older_any_and_fifo_within_both_classes(self):
        self.write_config('one', phones=['a'], any_phones=['a'])
        self.request('holder', serial='a'); self.wait_acquired('holder')
        for name, serial in [('any1', 'any'), ('vip1', 'a'), ('any2', 'any'), ('vip2', 'a')]:
            self.request(name, serial=serial)
        # A stopped VIP still reserves its position against a polling any caller.
        self.children['vip1'].send_signal(signal.SIGSTOP)
        self.release('holder')
        time.sleep(.2)
        self.assertFalse(self.acquired('any1'))
        self.children['vip1'].send_signal(signal.SIGCONT)
        for name in ('vip1', 'vip2', 'any1', 'any2'):
            self.wait_acquired(name); self.release(name)
        acquired = [r['ticket'] for r in self.events('phone') if r['event'] == 'acquire']
        arrived = [r['ticket'] for r in self.events('phone') if r['event'] == 'request']
        self.assertEqual(acquired, [arrived[i] for i in (0, 2, 4, 1, 3)])

    def test_any_uses_project_preference_and_skips_vip_phone(self):
        self.write_config('two', any_phones=['b', 'a'])
        self.request('first', project='two'); self.assertEqual(self.wait_acquired('first'), 'b:b')
        self.request('second'); self.assertEqual(self.wait_acquired('second'), 'a:a')
        self.request('vip', serial='b')
        self.children['vip'].send_signal(signal.SIGSTOP)
        self.request('any')
        self.release('first'); time.sleep(.2)
        self.assertFalse(self.acquired('any'))
        self.release('second'); self.assertEqual(self.wait_acquired('any'), 'a:a')
        self.children['vip'].send_signal(signal.SIGCONT)
        self.assertEqual(self.wait_acquired('vip'), 'b:b')
        self.release('vip'); self.release('any')

    def test_two_projects_share_phone_and_suite_capacity_with_cli_callers(self):
        for kind in ('phone', 'suite'):
            self.request(kind + '1', kind, serial='a', project='one'); self.wait_acquired(kind + '1')
            self.request(kind + '2', kind, serial='a', project='two')
            time.sleep(.2); self.assertFalse(self.acquired(kind + '2'))
            self.release(kind + '1'); self.wait_acquired(kind + '2'); self.release(kind + '2')

    def test_suite_fifo_four_slots_and_killed_holder_release(self):
        for index in range(4):
            self.request(str(index), 'suite', capacity=4); self.wait_acquired(str(index))
        self.request('fifth', 'suite', capacity=4)
        self.request('sixth', 'suite', capacity=4)
        self.assertFalse(self.acquired('fifth'))
        os.killpg(self.children['0'].pid, signal.SIGKILL)
        self.children['0'].wait(timeout=10)
        self.wait_acquired('fifth')
        self.assertFalse(self.acquired('sixth'))
        self.release('fifth'); self.wait_acquired('sixth')
        for name in ('1', '2', '3', 'sixth'): self.release(name)
        arrived = [r['ticket'] for r in self.events('suite') if r['event'] == 'request']
        acquired = [r['ticket'] for r in self.events('suite') if r['event'] == 'acquire']
        self.assertEqual(acquired, arrived)

    def test_suite_same_worktree_stays_exclusive_with_multiple_slots(self):
        self.request('first', 'suite', capacity=2, worktree='shared'); self.wait_acquired('first')
        self.request('second', 'suite', capacity=2, worktree='shared')
        time.sleep(.2); self.assertFalse(self.acquired('second'))
        self.release('first'); self.wait_acquired('second'); self.release('second')

    def test_bad_capacity_and_mismatched_descriptor_count_are_rejected(self):
        result = self.cli('queue', 'suite', '--capacity', '0', '--', 'true')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.request('first', 'suite'); self.wait_acquired('first')
        result = self.cli('queue', 'suite', '--capacity', '2', '--', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('all callers must agree', result.stdout)
        result = self.cli('queue', 'suite-acquire', '--queue', str(self.root / 'bad'),
                          '--owner-pid', str(os.getpid()), '--holder', str(self.root),
                          '--capacity', '2', '--selection-out', str(self.root / 'selection'),
                          '--worktree-fd', '7', '--queue-fd', '8', '--legacy-fd', '9', '--slot-fd', '10')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('capacity and slot fd count differ', result.stderr)
        self.release('first')

    def test_dead_and_previous_boot_tickets_and_unique_leases_are_reaped(self):
        root = self.root / 'state/queues'
        pool = root / 'device-test-locks'
        for serial, boot in [('a', tickets.boot_id()), ('b', 'previous-boot')]:
            leases.acquire([serial], lock_dir=pool, device=serial, label='old-' + serial)
            directory = root / 'phones/tickets'; directory.mkdir(parents=True, exist_ok=True)
            record = dict(tickets.identity(), requested=serial, holding=serial, lease_label='old-' + serial)
            record.update(boot_id=boot)
            if serial == 'a': record['pid'] = 99999999
            (directory / ('00000000000' + ('1' if serial == 'a' else '2') + '-old.json')).write_text(json.dumps(record))
        self.request('new'); self.wait_acquired('new'); self.release('new')
        cleanup = [r for r in self.events('phone') if r['event'] == 'crash_cleanup']
        self.assertEqual(len(cleanup), 2)
        self.assertEqual(sorted(x for r in cleanup for x in r['released']), ['a', 'b'])
        self.assertFalse(any(pool.iterdir()))

    def test_lost_counter_keeps_legacy_waiter_ahead_of_new_ticket(self):
        root = self.root / 'state/queues/phones'
        (root / 'tickets').mkdir(parents=True)
        old = root / 'tickets/000000000099-legacy.json'
        old.write_text(json.dumps(dict(tickets.identity(), requested='a')))
        (root / 'sequence').write_text('corrupt')
        self.write_config('one', phones=['a'], any_phones=['a'])
        self.request('new', serial='a')
        time.sleep(.2); self.assertFalse(self.acquired('new'))
        requested = [r['ticket'] for r in self.events('phone') if r['event'] == 'request']
        self.assertTrue(requested[0].startswith('000000000100-'))
        old.unlink(); self.wait_acquired('new'); self.release('new')

    def test_recent_malformed_ticket_blocks_until_grace_expires(self):
        root = self.root / 'state/queues/phones/tickets'; root.mkdir(parents=True)
        bad = root / '000000000001-bad.json'; bad.write_text('[]')
        self.request('new')
        time.sleep(.2); self.assertFalse(self.acquired('new'))
        os.utime(bad, (time.time() - 31, time.time() - 31))
        self.wait_acquired('new'); self.release('new'); self.assertFalse(bad.exists())

    def test_legacy_phone_flock_and_device_lease_are_exclusive(self):
        legacy = self.root / 'state/queues/legacy'; legacy.mkdir(parents=True)
        with (legacy / 'frogpile-phone-a.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.request('waiting', serial='a'); time.sleep(.2)
            self.assertFalse(self.acquired('waiting'))
            fcntl.flock(lock, fcntl.LOCK_UN)
            self.wait_acquired('waiting')
            with self.assertRaises(BlockingIOError): fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.release('waiting')
        pool = self.root / 'state/queues/device-test-locks'
        leases.acquire(['a'], lock_dir=pool, device='a', label='old-device-test')
        self.request('leased', serial='a'); time.sleep(.2); self.assertFalse(self.acquired('leased'))
        self.assertFalse(leases.release('a', lock_dir=pool, label='someone-else'))
        self.assertTrue(leases.release('a', lock_dir=pool, label='old-device-test'))
        self.wait_acquired('leased'); self.release('leased')

    def test_legacy_suite_exclusive_lock_is_held_in_both_directions(self):
        legacy = self.root / 'state/queues/legacy'; legacy.mkdir(parents=True)
        with (legacy / 'frogpile-suite.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.request('new', 'suite'); time.sleep(.2); self.assertFalse(self.acquired('new'))
            fcntl.flock(lock, fcntl.LOCK_UN)
            self.wait_acquired('new')
            with self.assertRaises(BlockingIOError): fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.release('new')

    def test_suite_acquire_returns_locks_to_the_live_calling_shell(self):
        shell = self.descriptor_owner('shell')
        self.wait_acquired('shell')
        helper = int((self.root / 'bridge-shell.pid').read_text())
        self.assertIsNone(tickets.start_ticks(helper))
        self.assertIsNone(shell.poll())
        self.assertEqual((self.root / 'selection-shell').read_text().strip(), '0')
        for path in [self.root / 'worktree-shell', self.root / 'state/queues/suite/suite.lock',
                     self.root / 'state/queues/legacy/frogpile-suite.lock',
                     self.root / 'state/queues/suite/slots/slot-0.lock']:
            with path.open('a+') as stream:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.request('next', 'suite')
        self.assertFalse(self.acquired('next'))
        self.release('shell'); self.wait_acquired('next'); self.release('next')

    def test_suite_head_keeps_kernel_fifo_against_a_later_legacy_waiter(self):
        legacy = self.root / 'state/queues/legacy'; legacy.mkdir(parents=True)
        with (legacy / 'frogpile-suite.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            head = self.request('head', 'suite')
            self.wait_kernel_lock(head.pid)
            later = self.legacy_suite_waiter('later')
            self.wait_kernel_lock(later.pid)
            fcntl.flock(lock, fcntl.LOCK_UN)
            self.wait_acquired('head')
            self.assertFalse(self.acquired('later'))
            self.release('head'); self.wait_acquired('later'); self.release('later')

    def test_dead_shell_blocked_on_a_legacy_suite_lock_releases_its_slot(self):
        legacy = self.root / 'state/queues/legacy'; legacy.mkdir(parents=True)
        with (legacy / 'frogpile-suite.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            owner = self.descriptor_owner('dead')
            self.until((self.root / 'bridge-dead.pid').exists, 'descriptor helper pid')
            helper = int((self.root / 'bridge-dead.pid').read_text())
            self.wait_kernel_lock(helper)
            owner.kill(); owner.wait(timeout=10)
            self.until(lambda: any(r['event'] == 'abandon' for r in self.events('suite')),
                       'dead shell abandonment')
            self.until(lambda: tickets.start_ticks(helper) is None, 'descriptor helper exit')
            self.assertFalse((self.root / 'selection-dead').exists())
            self.request('next', 'suite')
            fcntl.flock(lock, fcntl.LOCK_UN)
            self.wait_acquired('next'); self.release('next')

    def test_cancellation_barrage_removes_waiting_tickets(self):
        for kind in ('phone', 'suite'):
            self.request(kind + '-hold', kind, serial='a'); self.wait_acquired(kind + '-hold')
            child = self.request(kind + '-wait', kind, serial='a')
            for _ in range(12):
                if child.poll() is None: child.send_signal(signal.SIGTERM)
                time.sleep(.01)
            self.assertNotEqual(child.wait(timeout=15), 0)
            remaining = list((self.root / 'state/queues' / ('phones' if kind == 'phone' else 'suite') / 'tickets').glob('*.json'))
            self.assertEqual(len(remaining), 1 if kind == 'phone' else 0)
            self.release(kind + '-hold')

    def test_held_client_cancels_child_before_releasing_phone(self):
        pidfile = self.root / 'child.pid'
        code = "import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(%r).write_text(str(os.getpid())); time.sleep(60)" % str(pidfile)
        child = self.start('hold', [sys.executable, str(CLI), 'queue', 'phone', '--project', 'one',
                                    '--serial', 'a', '--', sys.executable, '-c', code])
        self.until(pidfile.exists, 'child started')
        self.request('next', serial='a')
        for _ in range(10):
            if child.poll() is None: child.send_signal(signal.SIGTERM)
            time.sleep(.01)
        self.assertNotEqual(child.wait(timeout=15), 0)
        self.assertIsNone(tickets.start_ticks(int(pidfile.read_text())))
        self.wait_acquired('next'); self.release('next')

    def test_cancellation_reaps_a_resistant_descendant_after_its_parent_exits(self):
        pidfile = self.root / 'grandchild.pid'
        grandchild = '''import os,signal,sys,time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(60)
'''
        launcher = '''import subprocess,sys,time
subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]])
time.sleep(60)
'''
        child = self.start('tree', [sys.executable, str(CLI), 'queue', 'phone', '--project', 'one',
                                    '--serial', 'a', '--', sys.executable, '-c', launcher,
                                    grandchild, str(pidfile)])
        self.until(pidfile.exists, 'resistant grandchild started')
        grandchild_pid = int(pidfile.read_text())
        self.request('next', serial='a')
        child.terminate()
        self.assertNotEqual(child.wait(timeout=15), 0)
        self.until(lambda: tickets.start_ticks(grandchild_pid) is None, 'resistant grandchild exit')
        self.wait_acquired('next'); self.release('next')

    def test_nested_sentinel_is_refused_without_a_ticket(self):
        self.env['FM_TEST_PHONE_QUEUE_HELD'] = 'a'
        result = self.cli('queue', 'phone', '--project', 'one', '--', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nested phone reservation', result.stderr)
        self.assertFalse(self.events('phone'))

    def test_ancestor_phone_flock_is_refused_with_bounded_wait(self):
        legacy = self.root / 'legacy'; legacy.mkdir()
        lock = legacy / 'frogpile-phone-a.lock'
        code = '''import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import fm_phone_queue
root = Path(sys.argv[2])
with fm_phone_queue.reservation('a', root=root / 'queue', legacy_root=root / 'legacy',
        device_lock_dir=root / 'pool', connected=lambda: {'a'}, wait_seconds=.02, nested_timeout=.1): pass
'''
        result = subprocess.run(['flock', '-o', str(lock), sys.executable, '-c', code, str(CODE), str(self.root)],
                                env=self.env, text=True, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nested phone lock', result.stderr)

    def test_isolated_paths_ignore_ambient_legacy_paths_and_project_pool(self):
        self.env.update(FROGPILE_QUEUE_ROOT='/do-not-use', FROGPILE_SUITE_LOCK='/do-not-use-suite',
                        FROGPILE_SUITE_QUEUE='/do-not-use-queue')
        self.write_config('one', queue_lease_dir='/do-not-use-lease')
        result = self.cli('queue', 'paths', '--project', 'one')
        self.assertEqual(result.returncode, 0, result.stderr)
        locations = json.loads(result.stdout)
        self.assertTrue(all(str(self.root / 'state/queues') in path for path in locations.values()))
        self.env['FM_TEST_QUEUE_ROOT'] = str(self.root / 'explicit')
        self.env['FM_TEST_QUEUE_LEGACY_ROOT'] = str(self.root / 'old-locks')
        result = self.cli('queue', 'paths')
        self.assertEqual(json.loads(result.stdout)['legacy'], str(self.root / 'old-locks'))

    def test_any_clients_with_different_candidate_sets_use_free_phones(self):
        self.write_config('one', phones=['a'], any_phones=['a'])
        self.write_config('two', phones=['b'], any_phones=['b'])
        self.request('hold', serial='a'); self.wait_acquired('hold')
        self.request('older', project='one')
        self.request('younger', project='two')
        self.assertEqual(self.wait_acquired('younger'), 'b:b')
        self.assertFalse(self.acquired('older'))
        self.release('younger'); self.release('hold')
        self.wait_acquired('older'); self.release('older')

    def test_stopped_any_waiter_reserves_its_projects_preferred_phone(self):
        self.write_config('one', any_phones=['b', 'a'])
        for serial in ('a', 'b'):
            self.request('hold-' + serial, serial=serial); self.wait_acquired('hold-' + serial)
        older = self.request('older', project='one')
        older.send_signal(signal.SIGSTOP)
        self.request('younger', project='two')
        self.release('hold-a'); self.release('hold-b')
        self.assertEqual(self.wait_acquired('younger'), 'a:a')
        self.assertFalse(self.acquired('older'))
        older.send_signal(signal.SIGCONT)
        self.assertEqual(self.wait_acquired('older'), 'b:b')
        self.release('older'); self.release('younger')

    def test_installed_default_state_path_keeps_the_existing_host_queue(self):
        self.env['FM_TEST_SERVICE_STATE'] = str(self.root / 'home/.local/state/firstmate-test-service')
        result = self.cli('queue', 'paths')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['root'], str(self.root / 'home/.frogpile-queues'))

    def test_public_python_client_uses_configured_any_order(self):
        self.write_config('one', any_phones=['b', 'a'])
        code = "import sys; sys.path.insert(0,sys.argv[1]); import fm_test_queues;\nwith fm_test_queues.reservation(project='one') as serial: print(serial)"
        result = subprocess.run([sys.executable, '-c', code, str(CODE)], env=self.env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'b')
        self.assertFalse(list((self.root / 'state/queues/phones/tickets').glob('*.json')))

    def test_performance_entry_accepts_legacy_argv_and_uses_the_shared_client(self):
        self.env['FM_TEST_PROJECT'] = 'one'
        old_module = self.root / 'phone_queue.py'
        old_module.write_text('raise RuntimeError("project module must never load")\n')
        code = "import os,sys; print(sys.argv[1] + ':' + os.environ['FM_TEST_PHONE_QUEUE_HELD'])"
        result = subprocess.run([sys.executable, str(CODE / 'fm-perf-phone-queue.py'),
                                 str(old_module), '--serial', 'a', '--',
                                 sys.executable, '-c', code, '{serial}'], env=self.env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'a:a')
        self.assertEqual([r['event'] for r in self.events('phone')], ['request', 'acquire', 'release'])

    def test_unavailable_phone_and_unsafe_configuration_are_rejected(self):
        (self.root / 'home/online').write_text('')
        result = self.cli('queue', 'phone', '--project', 'one', '--', 'true')
        self.assertNotEqual(result.returncode, 0); self.assertIn('offline', result.stderr)
        self.assertFalse(self.events('phone'))
        self.write_config('one', phones=['../escape'])
        result = self.cli('queue', 'phone', '--project', 'one', '--', 'true')
        self.assertNotEqual(result.returncode, 0); self.assertIn('safe device serials', result.stderr)

    def test_permission_denied_at_listing_or_transport_never_enters_the_queue(self):
        adb = self.root / 'bin/adb'
        for listing in (True, False):
            adb.write_text('''#!/usr/bin/env python3
import sys
if sys.argv[1] == 'devices':
    print('List of devices attached')
    print('a\\t' + ('no permissions (missing uaccess)' if %r else 'device'))
else:
    print('error: no permissions', file=sys.stderr)
    sys.exit(1)
''' % listing)
            result = self.cli('queue', 'phone', '--project', 'one', '--serial', 'a', '--', 'true')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('permission-denied', result.stderr)
            self.assertFalse(self.events('phone'))

    def test_explicit_legacy_lease_pool_preserves_old_callers_and_crash_cleanup(self):
        self.env.pop('FM_TEST_SERVICE_STATE')
        self.env['FM_TEST_QUEUE_ROOT'] = str(self.root / 'state/queues')
        self.env['FM_TEST_QUEUE_LEGACY_ROOT'] = str(self.root / 'old-locks')
        pool = self.root / 'old-device-pool'
        self.write_config('one', queue_lease_dir=str(pool))
        leases.acquire(['a'], lock_dir=pool, device='a', label='old-caller')
        self.request('new', serial='a')
        self.assertFalse(self.acquired('new'))
        self.assertTrue(leases.release('a', lock_dir=pool, label='old-caller'))
        self.wait_acquired('new')
        self.assertTrue((pool / 'a/label').read_text().startswith('firstmate-test-'))
        os.killpg(self.children['new'].pid, signal.SIGKILL)
        self.children['new'].wait(timeout=10)
        self.request('recover', serial='a'); self.wait_acquired('recover'); self.release('recover')
        self.assertFalse((pool / 'a').exists())
        self.assertTrue(any(r['event'] == 'crash_cleanup' and r['released'] == ['a']
                            for r in self.events('phone')))

    def service(self, name):
        child = self.start(name, [sys.executable, str(CLI), 'serve'])
        self.until(lambda: (self.root / 'state/service.lock').exists(), 'service lock')
        self.until(lambda: (self.root / 'state/status.json').exists(), 'service status')
        return child

    def test_service_restart_preserves_direct_holders_and_waiters(self):
        self.write_config('one', phones=['a'], any_phones=['a'])
        server = self.service('server')
        self.request('phone-hold', serial='a'); self.wait_acquired('phone-hold')
        self.request('phone-wait')
        self.request('suite-hold', 'suite'); self.wait_acquired('suite-hold')
        self.request('suite-wait', 'suite')
        before = {kind: [r['ticket'] for r in self.events(kind) if r['event'] == 'request'] for kind in ('phone', 'suite')}
        server.terminate(); self.assertEqual(server.wait(timeout=20), 0)
        self.service('server2')
        self.assertFalse(self.acquired('phone-wait')); self.assertFalse(self.acquired('suite-wait'))
        for kind in ('phone', 'suite'):
            self.assertEqual([r['ticket'] for r in self.events(kind) if r['event'] == 'request'], before[kind])
            self.release(kind + '-hold'); self.wait_acquired(kind + '-wait'); self.release(kind + '-wait')

    def test_service_requests_and_direct_clients_share_one_line_across_projects(self):
        project = self.root / 'project'; project.mkdir()
        for script, text in [('suite.sh', 'echo suite'), ('device.sh', 'echo device:$1')]:
            path = project / script; path.write_text('#!/bin/sh\n' + text + '\n'); path.chmod(0o755)
        def git(*args):
            return subprocess.check_output(['git', '-C', str(project), *args], env=self.env, text=True).strip()
        git('init', '-q', '-b', 'main'); git('config', 'user.name', 'Test'); git('config', 'user.email', 'test@example.com')
        git('add', '.'); git('commit', '-qm', 'fixture'); sha = git('rev-parse', 'HEAD')
        self.request('direct-suite', 'suite'); self.wait_acquired('direct-suite')
        self.request('direct-phone', serial='a'); self.wait_acquired('direct-phone')
        for name in ('one', 'two'): self.write_config(name, phones=['a'], any_phones=['a'])
        self.service('server')
        ids = []
        for name in ('one', 'two'):
            result = self.cli('submit', name, str(project), sha, '--suite', '--device-gate', 'any')
            self.assertEqual(result.returncode, 0, result.stderr); ids.append(result.stdout.strip())
        for kind in ('phone', 'suite'):
            self.until(lambda: sum(r['event'] == 'request' for r in self.events(kind)) == 3, kind + ' service tickets')
            self.assertEqual(sum(r['event'] == 'acquire' for r in self.events(kind)), 1)
            self.release('direct-' + kind)
        for rid in ids:
            result = self.cli('wait', rid)
            self.assertEqual(result.returncode, 0, result.stderr + self.logs_text())
        for kind in ('phone', 'suite'):
            arrived = [r['ticket'] for r in self.events(kind) if r['event'] == 'request']
            acquired = [r['ticket'] for r in self.events(kind) if r['event'] == 'acquire']
            self.assertEqual(acquired, arrived)


if __name__ == '__main__':
    unittest.main(verbosity=2)
PY
pass 'shared phone and suite queues use one compatible restart-safe line'

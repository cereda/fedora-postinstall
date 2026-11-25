#!/usr/bin/env bats

# SPDX-License-Identifier: MIT

load "${BATS_TEST_DIRNAME}/../helpers/assertions"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_ROOT="${BATS_TEST_TMPDIR}/lock-holder"
    LOCK_HOLDER="${TEST_ROOT}/lock-holder.py"

    mkdir -p "${TEST_ROOT}"
    cp "${REPO_ROOT}/common/lock-holder.py" "${LOCK_HOLDER}"
}

@test "the removed hold-owner action is rejected" {
    run python3 "${LOCK_HOLDER}" hold-owner ignored 123
    assert_equal "${status}" 1
    assert_output_contains "usage:"
    refute_output_contains "lock-holder.py hold-owner "
}

@test "exact lock inode inspection remains unknown when descriptor access is denied" {
    local test_script="${TEST_ROOT}/unknown-lock-inode.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
module.read_process_group_members = lambda _group_id: ({42: identity}, False)
module.process_holds_lock_inode = lambda *_arguments: (False, True)
module.open_group_anchor_pidfd = lambda *_arguments: (_ for _ in ()).throw(
    AssertionError("an unknown lock-owner inspection opened an anchor")
)

try:
    module.find_lock_inode_group_anchor(42, 1, 2)
except module.MonitoringUnavailable:
    pass
else:
    raise SystemExit("unknown descriptor access was treated as no lock owner")
print("unknown lock inode inspection was retained")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "unknown lock inode inspection was retained"
}

@test "process stat parsing accepts non-ASCII comm bytes and isolates group scan failures" {
    local test_script="${TEST_ROOT}/process-stat-bytes.py"

    cat > "${test_script}" <<'PY'
import builtins
import importlib.util
import io
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

suffix = [b"S", b"10", b"20"] + [b"0"] * 16 + [b"12345"]
stat_bytes = b"999 (helper-\xff) " + b" ".join(suffix) + b"\n"
real_open = builtins.open


def fake_open(path, *arguments, **keywords):
    if path == "/proc/4242/stat":
        return io.BytesIO(stat_bytes)
    return real_open(path, *arguments, **keywords)


builtins.open = fake_open
try:
    details = module.read_process_details_checked(4242)
finally:
    builtins.open = real_open
if details != ("S", 10, 20, 12345):
    raise SystemExit(f"non-ASCII stat bytes were not parsed: {details!r}")

module.read_boot_id = lambda: "boot-id"
module.read_process_details_checked = lambda process_id: (
    (_ for _ in ()).throw(module.ProcessInspectionUnavailable("transient"))
    if process_id == 111
    else ("S", 1, 777, 222)
)
module.os.getpgid = lambda process_id: 888 if process_id == 111 else 777
module.os.listdir = lambda _path: ["111", "222"]
members, unknown = module.read_process_group_members(777)
if unknown or members != {222: module.ProcessIdentity(222, "boot-id")}:
    raise SystemExit(
        f"an unrelated inspection failure disabled the group scan: {unknown!r}"
    )

module.read_process_details_checked = lambda _process_id: (
    _ for _ in ()
).throw(module.ProcessInspectionUnavailable("transient"))
module.os.listdir = lambda _path: ["333"]
module.os.getpgid = lambda _process_id: 777
members, unknown = module.read_process_group_members(777)
if not unknown or members:
    raise SystemExit("an unidentified target-group member was not conservative")
print("process stat bytes and group scan isolation verified")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "process stat bytes and group scan isolation verified"
}

@test "status helper relationship and startup validation use one stat snapshot per process" {
    local test_script="${TEST_ROOT}/single-stat-snapshot.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identities = {
    10: module.ProcessIdentity(100, "boot-id"),
    11: module.ProcessIdentity(200, "boot-id"),
    12: module.ProcessIdentity(300, "boot-id"),
    13: module.ProcessIdentity(400, "boot-id"),
    14: module.ProcessIdentity(500, "boot-id"),
    os.getpid(): module.ProcessIdentity(600, "boot-id"),
}
parents = {
    10: 1,
    11: 10,
    12: 11,
    13: 12,
    14: 12,
    os.getpid(): 12,
}
reads = {}


def read_details(process_id):
    reads[process_id] = reads.get(process_id, 0) + 1
    identity = identities[process_id]
    return ("S", parents[process_id], process_id, identity.start_time)


module.read_process_details_checked = read_details
module.read_boot_id = lambda: "boot-id"
status = module.LockStatus(
    installer_process_id=10,
    installer_identity=identities[10],
    wrapper_process_id=11,
    wrapper_identity=identities[11],
    supervisor_process_id=12,
    supervisor_identity=identities[12],
    worker_process_id=13,
    worker_identity=identities[13],
    watchdog_process_id=14,
    watchdog_identity=identities[14],
)
module.read_lock_status = lambda _path: status

validated, definitive = module.inspect_lock_status(
    "unused",
    11,
    10,
    identities[10],
)
if validated is None or definitive:
    raise SystemExit("the single-snapshot status validation failed")
if any(reads.get(process_id) != 1 for process_id in identities if process_id != os.getpid()):
    raise SystemExit(f"status validation used multiple stat snapshots: {reads!r}")

reads.clear()
valid, definitive = module.validate_watchdog_startup(
    10,
    identities[10],
    11,
    identities[11],
    12,
    identities[12],
    13,
    identities[13],
)
if not valid or definitive:
    raise SystemExit("the single-snapshot startup validation failed")
if any(
    reads.get(process_id) != 1
    for process_id in (10, 11, 12, 13, os.getpid())
):
    raise SystemExit(f"startup validation used multiple stat snapshots: {reads!r}")

reads.clear()
if module.watchdog_helper_relationships_broken(
    10,
    11,
    identities[11],
    12,
    identities[12],
    13,
    identities[13],
):
    raise SystemExit("the single-snapshot helper relationship was broken")
if any(reads.get(process_id) != 1 for process_id in (11, 12, 13)):
    raise SystemExit(
        f"helper relationship validation used multiple stat snapshots: {reads!r}"
    )
print("single stat snapshots verified")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "single stat snapshots verified"
}

@test "lock status reads accumulate short file reads to EOF" {
    local test_script="${TEST_ROOT}/short-status-read.py"
    local status_file="${TEST_ROOT}/status"

    cat > "${status_file}" <<'EOF'
123
124
boot-id:101
boot-id:102
boot-id:103
125
boot-id:104
10
126
boot-id:105
schema=3
ready=1
EOF

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

real_read = os.read
calls = 0


def short_read(descriptor, size):
    global calls
    calls += 1
    return real_read(descriptor, min(size, 3))


os.read = short_read
status = module.read_lock_status(sys.argv[2])
if status is None:
    raise SystemExit("a short regular-file read was classified as malformed")
if calls < 2:
    raise SystemExit("the lock status was not accumulated across reads")
print("short lock status reads accumulated")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}" "${status_file}"
    assert_success
    assert_output_contains "short lock status reads accumulated"
}

@test "watchdog SIGUSR2 classifies committed cancelled and unknown decisions explicitly" {
    local test_script="${TEST_ROOT}/watchdog-decision-state.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import signal
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.DECISION_PATH = "unused"
module.watchdog_cancellation_observed = (
    lambda: module.WATCHDOG_CANCELLATION_REQUESTED
)


def reset_state():
    module.WATCHDOG_CANCELLATION_REQUESTED = False
    module.WATCHDOG_ABORT_REQUESTED = False
    module.WATCHDOG_DECISION_STATE = module.DECISION_UNKNOWN


reset_state()
module.resolve_cancellation_decision = lambda _path: module.DECISION_COMMITTED
module.request_watchdog_cancellation(signal.SIGUSR2, None)
if module.WATCHDOG_CANCELLATION_REQUESTED or module.WATCHDOG_ABORT_REQUESTED:
    raise SystemExit("a committed decision did not make SIGUSR2 harmless")

reset_state()
module.resolve_cancellation_decision = lambda _path: module.DECISION_CANCELLED
module.request_watchdog_cancellation(signal.SIGUSR2, None)
if not module.WATCHDOG_CANCELLATION_REQUESTED:
    raise SystemExit("a cancelled decision was not retained")
if module.WATCHDOG_ABORT_REQUESTED:
    raise SystemExit("a cancelled decision was classified as a generic abort")

reset_state()
module.resolve_cancellation_decision = lambda _path: module.DECISION_UNKNOWN
module.request_watchdog_cancellation(signal.SIGUSR2, None)
if module.WATCHDOG_CANCELLATION_REQUESTED:
    raise SystemExit("an unknown decision was classified as cancellation")
if not module.WATCHDOG_ABORT_REQUESTED:
    raise SystemExit("an unknown decision did not request a generic abort")
if not module.watchdog_shutdown_requested():
    raise SystemExit("the generic abort was not retained by the watchdog")
print("watchdog decision states classified")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "watchdog decision states classified"
}

@test "watchdog generic abort remains sticky after decision recovery" {
    local test_script="${TEST_ROOT}/watchdog-sticky-abort.py"
    local decision_file="${TEST_ROOT}/sticky.decision"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import signal
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.DECISION_PATH = sys.argv[2]
module.DECISION_RESOLUTION_ATTEMPTS = 2
module.DECISION_RESOLUTION_DELAY = 0
module.WATCHDOG_CANCELLATION_REQUESTED = False
module.WATCHDOG_ABORT_REQUESTED = False
module.WATCHDOG_DECISION_STATE = module.DECISION_UNKNOWN

with open(module.DECISION_PATH, "wb") as decision_file:
    decision_file.write(b"malformed")
module.request_watchdog_cancellation(signal.SIGUSR2, None)
if not module.WATCHDOG_ABORT_REQUESTED:
    raise SystemExit("the malformed decision did not request an abort")

os.unlink(module.DECISION_PATH)
with open(module.DECISION_PATH, "wb") as decision_file:
    decision_file.write(b"committed")
module.request_watchdog_cancellation(signal.SIGUSR2, None)
if not module.WATCHDOG_ABORT_REQUESTED:
    raise SystemExit("decision recovery cleared the sticky abort")
if module.WATCHDOG_CANCELLATION_REQUESTED:
    raise SystemExit("decision recovery turned the generic abort into cancellation")
if not module.watchdog_shutdown_requested():
    raise SystemExit("the sticky abort was not retained")
print("watchdog generic abort remained sticky")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}" "${decision_file}"
    assert_success
    assert_output_contains "watchdog generic abort remained sticky"
}

@test "watchdog generic abort notifies the installer and waits before removing the decision" {
    local test_script="${TEST_ROOT}/watchdog-generic-abort.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

events = []
identity = module.ProcessIdentity(123, "boot-id")
module.DECISION_PATH = "/authoritative/decision"
module.configure_watchdog_signal_handlers = lambda: None
module.watchdog_process_observation = (
    lambda _process_id, _identity: module.ProcessObservation.ALIVE
)
module.watchdog_shutdown_requested = lambda: True
module.close_watchdog_ready = lambda _descriptor: None


def notify_installer(monitor, process_id, installer_identity):
    events.append(("notify", monitor, process_id, installer_identity))
    return True


def wait_for_exit(process_id, installer_identity, monitor=None):
    events.append(("wait", process_id, installer_identity, monitor))
    events.append(("installer-exited", process_id))


module.notify_watchdog_installer = notify_installer
module.wait_for_watchdog_installer_exit = wait_for_exit
module.remove_decision = lambda path: events.append(("remove", path))

module.watchdog_fallback_loop(
    42,
    identity,
    43,
    identity,
    44,
    identity,
    45,
    identity,
    -1,
    False,
    True,
)

if events[0][0] != "notify" or events[1][0] != "wait":
    raise SystemExit(f"the watchdog did not use the notify-and-wait path: {events!r}")
if events[0][1] is not None or events[0][3] != identity:
    raise SystemExit("the watchdog did not use the identity-bound notification path")
if any(event[0] == "remove" for event in events):
    raise SystemExit("the watchdog removed the decision before installer exit")
print("watchdog generic abort retained the decision through installer exit")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "watchdog generic abort retained the decision through installer exit"
}

@test "an unknown watchdog decision remains a generic lock loss with status 141" {
    local decision_file="${TEST_ROOT}/malformed.decision"

    printf 'malformed' > "${decision_file}"

    run env \
        POSTINSTALL_LOG_FILE="${TEST_ROOT}/postinstall.log" \
        POSTINSTALL_LOG_STDOUT=1 \
        bash -c '
            source "$1/common/runtime.sh"
            RUNTIME_LOCK_ACQUIRED=1
            RUNTIME_LOCK_DECISION_FILE="$2"
            RUNTIME_LOCK_DECISION_STATE=unknown
            runtime_handle_lock_loss 141 lock-loss
        ' _ "${REPO_ROOT}" "${decision_file}"
    assert_equal "${status}" "141"
    assert_output_contains "installation lock was lost"
    refute_output_contains "installation lock acquisition was cancelled"
}

@test "generic decision observation is read-only and latches the first winner" {
    local test_script="${TEST_ROOT}/decision-observer.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.DECISION_RESOLUTION_ATTEMPTS = 3
module.DECISION_RESOLUTION_DELAY = 0
read_count = 0
claim_count = 0


def read_decision(_path):
    global read_count
    read_count += 1
    if read_count <= 2:
        return module.DECISION_COMMITTED
    return module.DECISION_UNKNOWN


def claim_decision(_path, _value):
    global claim_count
    claim_count += 1
    raise SystemExit("a generic observer attempted to claim a decision")


module.read_decision = read_decision
module.claim_decision = claim_decision

with tempfile.TemporaryDirectory(prefix="decision-observer-") as directory:
    requester_path = os.path.join(directory, "requester-decision")
    observer_path = os.path.join(directory, "observer-decision")
    resolved = module.resolve_cancellation_decision(requester_path)
    first = module.observe_decision(observer_path)
    second = module.observe_decision(observer_path)
    resolved_again = module.resolve_cancellation_decision(requester_path)
    if (
        first != module.DECISION_COMMITTED
        or second != module.DECISION_COMMITTED
        or resolved != module.DECISION_COMMITTED
        or resolved_again != module.DECISION_COMMITTED
    ):
        raise SystemExit(
            f"the authoritative decision was not latched: {first!r} {second!r} {resolved!r}"
        )
    if read_count != 2:
        raise SystemExit(f"the latched decision was read repeatedly: {read_count}")
    if claim_count != 0:
        raise SystemExit("the generic observer created or claimed a decision")

print("the generic decision observer remained read-only and latched its winner")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "the generic decision observer remained read-only and latched its winner"
}

@test "installer waits never resume while helper waits require a fresh alive observation" {
    local test_script="${TEST_ROOT}/split-process-waits.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
resume_count = 0
observations = iter(
    [
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.ALIVE,
    ]
)


def observe_process_identity(_process_id, _identity):
    try:
        return next(observations)
    except StopIteration:
        return module.ProcessObservation.ALIVE


def resume_process(_process_id, _identity):
    global resume_count
    resume_count += 1
    return True


module.observe_process_identity = observe_process_identity
module.resume_process = resume_process

if module.wait_for_live_process_identity(42, identity):
    raise SystemExit("the live installer wait accepted a stopped installer")
if resume_count != 0:
    raise SystemExit("the installer wait resumed a stopped process")

observations = iter(
    [
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.ALIVE,
    ]
)
if not module.wait_for_resumed_process_identity(42, identity):
    raise SystemExit("the helper wait did not reach a fresh alive observation")
if resume_count < 1:
    raise SystemExit(f"the helper resume count was wrong: {resume_count}")

print("installer and helper waits enforced separate resume semantics")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "installer and helper waits enforced separate resume semantics"
}

@test "a stopped identified child is resumed before graceful cancellation" {
    local test_script="${TEST_ROOT}/resume-before-cancel.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import signal
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
events = []
module.observe_process_identity = lambda *_arguments: module.ProcessObservation.STOPPED
module.resume_process = lambda *_arguments: events.append("resume") or True
module.signal_process_by_identity = (
    lambda _process_id, _identity, signal_number: events.append(("signal", signal_number)) or True
)
module.reap_child = lambda _process_id: events.append("reap") or True
module.terminate_child(42, identity)

if events[:2] != ["resume", ("signal", signal.SIGUSR2)]:
    raise SystemExit(f"the stopped child was not resumed before cancellation: {events!r}")
if ("signal", signal.SIGKILL) in events:
    raise SystemExit("the graceful cancellation path unexpectedly sent SIGKILL")
print("stopped child resumed before cancellation")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "stopped child resumed before cancellation"
}

@test "hold-owner-ready publishes strict status and validate-support verifies its bindings" {
    local test_script="${TEST_ROOT}/hold-owner-ready.py"

    cat > "${test_script}" <<'PY'
import fcntl
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
lock_holder = sys.argv[1]
spec = importlib.util.spec_from_file_location("lock_holder", lock_holder)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

installer_source = r"""
import signal
import sys
import time

signal_path = sys.argv[1]


def record_signal(signal_number, _frame):
    with open(signal_path, "a", encoding="utf-8") as signal_file:
        signal_file.write(signal.Signals(signal_number).name + "\n")
        signal_file.flush()
    if signal_number == signal.SIGTERM:
        raise SystemExit(0)


for signal_name in ("SIGHUP", "SIGINT", "SIGTERM", "SIGUSR1", "SIGUSR2"):
    signal.signal(getattr(signal, signal_name), record_signal)

while True:
    time.sleep(0.05)
"""


def wait_for_file(path, process=None, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        if process is not None and process.poll() is not None:
            stdout, stderr = process.communicate()
            raise SystemExit(
                f"the support process exited before publishing {path}: "
                f"{stdout!r} {stderr!r}"
            )
        time.sleep(0.01)
    raise SystemExit(f"timed out waiting for {path}")


with tempfile.TemporaryDirectory(prefix="hold-owner-ready-") as temporary_directory:
    status_path = os.path.join(temporary_directory, "owner.status")
    sentinel_status_path = os.path.join(temporary_directory, "sentinel.status")
    ack_path = os.path.join(temporary_directory, "sentinel.ack")
    marker_path = os.path.join(temporary_directory, "owner-retiring")
    signal_path = os.path.join(temporary_directory, "installer.signals")
    public_path = os.path.join(temporary_directory, "public.lock")
    scope_path = os.path.join(temporary_directory, "scope.lock")

    installer = subprocess.Popen(
        [sys.executable, "-c", installer_source, signal_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    owner = None
    sentinel = None
    public_descriptor = -1
    scope_descriptor = -1
    try:
        installer_identity = module.capture_process_identity(installer.pid)
        if installer_identity is None:
            raise SystemExit("unable to capture the installer identity")

        public_descriptor = os.open(public_path, os.O_RDWR | os.O_CREAT, 0o600)
        scope_descriptor = os.open(scope_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(public_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(scope_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        public_metadata = os.fstat(public_descriptor)
        scope_metadata = os.fstat(scope_descriptor)
        public_identity = module.DescriptorIdentity(
            public_metadata.st_dev,
            public_metadata.st_ino,
        )
        scope_identity = module.DescriptorIdentity(
            scope_metadata.st_dev,
            scope_metadata.st_ino,
        )

        owner = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "hold-owner-ready",
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                "run-owner",
                status_path,
                sentinel_status_path,
                marker_path,
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        owner_identity = module.capture_process_identity(owner.pid)
        if owner_identity is None:
            raise SystemExit("unable to capture the owner identity")
        time.sleep(0.1)
        if owner.poll() is not None:
            raise SystemExit("the owner exited before sentinel readiness")
        if os.path.exists(status_path):
            raise SystemExit("the owner published readiness before sentinel readiness")
        sentinel = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "lock-sentinel",
                "run-owner",
                sentinel_status_path,
                ack_path,
                marker_path,
                module.encode_process_identity(owner_identity),
                str(owner.pid),
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        os.close(public_descriptor)
        public_descriptor = -1
        os.close(scope_descriptor)
        scope_descriptor = -1

        wait_for_file(sentinel_status_path, sentinel)
        wait_for_file(status_path, owner)
        with open(status_path, "r", encoding="utf-8") as status_file:
            status_lines = status_file.read().splitlines()
        expected_keys = [
            "schema",
            "run_id",
            "state",
            "role",
            "installer_pid",
            "installer_identity",
            "process_pid",
            "process_identity",
            "owner_pid",
            "owner_identity",
            "peer_pid",
            "peer_identity",
            "file_fd",
            "scope_fd",
            "file_identity",
            "scope_identity",
        ]
        if [line.split("=", 1)[0] for line in status_lines] != expected_keys:
            raise SystemExit(f"the owner status schema was not strict: {status_lines!r}")
        status = dict(line.split("=", 1) for line in status_lines)
        if status["schema"] != "2" or status["state"] != "ready":
            raise SystemExit(f"the owner status was not ready: {status!r}")
        if status["role"] != "owner":
            raise SystemExit(f"the owner status had the wrong role: {status!r}")
        if status["run_id"] != "run-owner":
            raise SystemExit(f"the owner status had the wrong run id: {status!r}")
        if status["installer_pid"] != str(installer.pid):
            raise SystemExit(f"the owner status had the wrong installer: {status!r}")
        if status["process_pid"] != str(owner.pid):
            raise SystemExit(f"the owner status had the wrong process: {status!r}")
        if status["owner_pid"] != status["process_pid"]:
            raise SystemExit(f"the owner status did not identify its owner: {status!r}")
        if status["owner_identity"] != status["process_identity"]:
            raise SystemExit(f"the owner status identities did not match: {status!r}")
        if status["peer_pid"] != str(sentinel.pid):
            raise SystemExit(f"the owner status had the wrong peer: {status!r}")
        sentinel_identity = module.capture_process_identity(sentinel.pid)
        if sentinel_identity is None:
            raise SystemExit("unable to capture the sentinel identity")
        if status["peer_identity"] != module.encode_process_identity(sentinel_identity):
            raise SystemExit(f"the owner status had the wrong peer identity: {status!r}")

        owner_process_group = os.getpgid(owner.pid)
        if owner_process_group != owner.pid:
            raise SystemExit(
                f"the owner did not establish an independent process group: "
                f"{owner_process_group}"
            )
        if owner_process_group == os.getpgid(installer.pid):
            raise SystemExit("the owner shared the installer process group")
        if owner_process_group == os.getpgid(0):
            raise SystemExit("the owner shared the helper guardian process group")

        validation = subprocess.run(
            [
                sys.executable,
                lock_holder,
                "validate-support",
                status_path,
                "owner",
                "run-owner",
                status["process_pid"],
                status["process_identity"],
                status["owner_pid"],
                status["owner_identity"],
                status["peer_pid"],
                status["peer_identity"],
                status["installer_pid"],
                status["installer_identity"],
                status["file_fd"],
                status["scope_fd"],
                status["file_identity"],
                status["scope_identity"],
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if validation.returncode != 0 or validation.stdout or validation.stderr:
            raise SystemExit(
                f"the valid support status did not validate silently: {validation!r}"
            )

        with open(status_path, "w", encoding="utf-8") as status_file:
            status_file.write("\n".join(status_lines).replace(
                "run_id=run-owner",
                "run_id=wrong-run",
            ) + "\n")
        invalid_validation = subprocess.run(
            [
                sys.executable,
                lock_holder,
                "validate-support",
                status_path,
                "owner",
                "run-owner",
                status["process_pid"],
                status["process_identity"],
                status["owner_pid"],
                status["owner_identity"],
                status["peer_pid"],
                status["peer_identity"],
                status["installer_pid"],
                status["installer_identity"],
                status["file_fd"],
                status["scope_fd"],
                status["file_identity"],
                status["scope_identity"],
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if invalid_validation.returncode == 0:
            raise SystemExit("a mismatched support run id was accepted")

        if owner.poll() is not None:
            raise SystemExit("the ready owner exited before the installer")
        if os.path.exists(signal_path):
            with open(signal_path, "r", encoding="utf-8") as signal_file:
                early_signals = signal_file.read()
            if early_signals:
                raise SystemExit(f"the ready owner signaled the installer: {early_signals!r}")

        installer.send_signal(signal.SIGTERM)
        installer.wait(timeout=5.0)
        owner.wait(timeout=5.0)
        sentinel.wait(timeout=5.0)
        stdout, stderr = owner.communicate()
        if owner.returncode != 0 or stdout or stderr:
            raise SystemExit(
                f"the ready owner did not exit silently: {owner.returncode} "
                f"{stdout!r} {stderr!r}"
            )
        stdout, stderr = sentinel.communicate()
        if sentinel.returncode != 0 or stdout or stderr:
            raise SystemExit(
                f"the ready sentinel did not exit silently: {sentinel.returncode} "
                f"{stdout!r} {stderr!r}"
            )
        with open(signal_path, "r", encoding="utf-8") as signal_file:
            received_signals = signal_file.read().splitlines()
        if received_signals != ["SIGTERM"]:
            raise SystemExit(
                f"the ready owner sent an unexpected installer signal: {received_signals!r}"
            )
    finally:
        if sentinel is not None and sentinel.poll() is None:
            sentinel.kill()
            sentinel.wait()
        if owner is not None and owner.poll() is None:
            owner.kill()
            owner.wait()
        if installer.poll() is None:
            installer.kill()
            installer.wait()
        if public_descriptor >= 0:
            os.close(public_descriptor)
        if scope_descriptor >= 0:
            os.close(scope_descriptor)

print("hold-owner-ready status published and strictly validated")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "hold-owner-ready status published and strictly validated"
}

@test "sentinel readiness rejects every mismatched support binding" {
    local test_script="${TEST_ROOT}/support-binding-mismatch.py"

    cat > "${test_script}" <<'PY'
import dataclasses
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

installer_identity = module.ProcessIdentity(101, "boot-id")
sentinel_identity = module.ProcessIdentity(202, "boot-id")
owner_identity = module.ProcessIdentity(303, "boot-id")
file_identity = module.DescriptorIdentity(404, 505)
scope_identity = module.DescriptorIdentity(606, 707)
status = module.SupportStatus(
    run_id="run-binding",
    role=module.SUPPORT_ROLE_SENTINEL,
    installer_process_id=100,
    installer_identity=installer_identity,
    process_process_id=200,
    process_identity=sentinel_identity,
    owner_process_id=300,
    owner_identity=owner_identity,
    peer_process_id=300,
    peer_identity=owner_identity,
    file_descriptor=3,
    scope_descriptor=4,
    file_identity=file_identity,
    scope_identity=scope_identity,
)


def matches(candidate):
    return module.support_status_matches(
        candidate,
        module.SUPPORT_ROLE_SENTINEL,
        "run-binding",
        100,
        installer_identity,
        200,
        sentinel_identity,
        300,
        owner_identity,
        300,
        owner_identity,
        3,
        4,
        file_identity,
        scope_identity,
    )


if not matches(status):
    raise SystemExit("the exact sentinel binding was rejected")

encoded_status = module.encode_support_status(status)
if module.parse_support_status(encoded_status) is None:
    raise SystemExit("the exact sentinel status schema was rejected")
self_bound_status = dataclasses.replace(
    status,
    process_process_id=status.owner_process_id,
)
if module.parse_support_status(module.encode_support_status(self_bound_status)) is not None:
    raise SystemExit("a sentinel status bound to the owner process was accepted")
wrong_peer_status = dataclasses.replace(
    status,
    peer_identity=module.ProcessIdentity(305, "boot-id"),
)
if module.parse_support_status(module.encode_support_status(wrong_peer_status)) is not None:
    raise SystemExit("a sentinel status with the wrong peer identity was accepted")

mismatches = [
    dataclasses.replace(status, run_id="wrong-run"),
    dataclasses.replace(status, role=module.SUPPORT_ROLE_OWNER),
    dataclasses.replace(status, process_process_id=201),
    dataclasses.replace(
        status,
        process_identity=module.ProcessIdentity(203, "boot-id"),
    ),
    dataclasses.replace(
        status,
        installer_process_id=101,
    ),
    dataclasses.replace(
        status,
        installer_identity=module.ProcessIdentity(102, "boot-id"),
    ),
    dataclasses.replace(status, owner_process_id=301),
    dataclasses.replace(
        status,
        owner_identity=module.ProcessIdentity(304, "boot-id"),
    ),
    dataclasses.replace(status, peer_process_id=301),
    dataclasses.replace(
        status,
        peer_identity=module.ProcessIdentity(305, "boot-id"),
    ),
    dataclasses.replace(status, file_descriptor=5),
    dataclasses.replace(status, scope_descriptor=6),
    dataclasses.replace(
        status,
        file_identity=module.DescriptorIdentity(405, 505),
    ),
    dataclasses.replace(
        status,
        scope_identity=module.DescriptorIdentity(606, 708),
    ),
]
for candidate in mismatches:
    if matches(candidate):
        raise SystemExit(f"a mismatched sentinel binding was accepted: {candidate!r}")

module.read_support_status = lambda _path: status
module.observe_process_identity = lambda process_id, _identity: (
    module.ProcessObservation.REPLACED
    if process_id == status.process_process_id
    else module.ProcessObservation.ALIVE
)
if module.wait_for_sentinel_binding(
    "/unused/sentinel.status",
    "run-binding",
    300,
    owner_identity,
    100,
    installer_identity,
    3,
    4,
    file_identity,
    scope_identity,
) is not None:
    raise SystemExit("a replaced sentinel process identity was accepted")

print("all mismatched sentinel bindings were rejected")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "all mismatched sentinel bindings were rejected"
}

@test "hold-owner-ready reports sentinel death and retains the final lock descriptors" {
    local test_script="${TEST_ROOT}/hold-owner-sentinel-death.py"

    cat > "${test_script}" <<'PY'
import fcntl
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
lock_holder = sys.argv[1]
spec = importlib.util.spec_from_file_location("lock_holder", lock_holder)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

installer_source = r"""
import signal
import sys
import time

signal_path = sys.argv[1]
support_loss_signal = int(sys.argv[2])


def record_signal(signal_number, _frame):
    with open(signal_path, "a", encoding="utf-8") as signal_file:
        if signal_number == support_loss_signal:
            signal_file.write("SUPPORT_LOSS\n")
        elif signal_number == signal.SIGTERM:
            signal_file.write("TERM\n")
        else:
            signal_file.write(str(signal_number) + "\n")
        signal_file.flush()
    if signal_number == signal.SIGTERM:
        raise SystemExit(0)


signal.signal(support_loss_signal, record_signal)
signal.signal(signal.SIGTERM, record_signal)

while True:
    time.sleep(0.05)
"""


def wait_for_file(path, process=None, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        if process is not None and process.poll() is not None:
            stdout, stderr = process.communicate()
            raise SystemExit(
                f"the support process exited before publishing {path}: "
                f"{stdout!r} {stderr!r}"
            )
        time.sleep(0.01)
    raise SystemExit(f"timed out waiting for {path}")


def lock_is_held(path):
    descriptor = os.open(path, os.O_RDWR)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(descriptor)


with tempfile.TemporaryDirectory(prefix="hold-owner-sentinel-death-") as temporary_directory:
    owner_status_path = os.path.join(temporary_directory, "owner.status")
    sentinel_status_path = os.path.join(temporary_directory, "sentinel.status")
    ack_path = os.path.join(temporary_directory, "sentinel.ack")
    marker_path = os.path.join(temporary_directory, "owner-retiring")
    signal_path = os.path.join(temporary_directory, "installer.signals")
    public_path = os.path.join(temporary_directory, "public.lock")
    scope_path = os.path.join(temporary_directory, "scope.lock")

    installer = subprocess.Popen(
        [
            sys.executable,
            "-c",
            installer_source,
            signal_path,
            str(module.SIGSUPPORT_LOSS),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    owner = None
    sentinel = None
    public_descriptor = -1
    scope_descriptor = -1
    try:
        installer_identity = module.capture_process_identity(installer.pid)
        if installer_identity is None:
            raise SystemExit("unable to capture the installer identity")
        public_descriptor = os.open(public_path, os.O_RDWR | os.O_CREAT, 0o600)
        scope_descriptor = os.open(scope_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(public_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(scope_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        public_metadata = os.fstat(public_descriptor)
        scope_metadata = os.fstat(scope_descriptor)
        public_identity = module.DescriptorIdentity(
            public_metadata.st_dev,
            public_metadata.st_ino,
        )
        scope_identity = module.DescriptorIdentity(
            scope_metadata.st_dev,
            scope_metadata.st_ino,
        )

        owner = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "hold-owner-ready",
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                "run-owner-sentinel-death",
                owner_status_path,
                sentinel_status_path,
                marker_path,
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        owner_identity = module.capture_process_identity(owner.pid)
        if owner_identity is None:
            raise SystemExit("unable to capture the owner identity")
        sentinel = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "lock-sentinel",
                "run-owner-sentinel-death",
                sentinel_status_path,
                ack_path,
                marker_path,
                module.encode_process_identity(owner_identity),
                str(owner.pid),
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        os.close(public_descriptor)
        public_descriptor = -1
        os.close(scope_descriptor)
        scope_descriptor = -1

        wait_for_file(sentinel_status_path, sentinel)
        wait_for_file(owner_status_path, owner)
        sentinel.kill()
        sentinel.wait(timeout=5.0)
        wait_for_file(signal_path, owner)

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            with open(signal_path, "r", encoding="utf-8") as signal_file:
                received_signals = signal_file.read().splitlines()
            if received_signals:
                break
            time.sleep(0.01)
        if received_signals != ["SUPPORT_LOSS"]:
            raise SystemExit(
                f"the owner sent an unexpected installer signal: {received_signals!r}"
            )
        if owner.poll() is not None:
            raise SystemExit("the owner exited before the installer")
        if not lock_is_held(public_path) or not lock_is_held(scope_path):
            raise SystemExit("the owner did not retain the inherited locks")

        installer.send_signal(signal.SIGTERM)
        installer.wait(timeout=5.0)
        owner.wait(timeout=5.0)
        stdout, stderr = owner.communicate()
        if owner.returncode != 0 or stdout or stderr:
            raise SystemExit(
                f"the owner did not exit silently: {owner.returncode} "
                f"{stdout!r} {stderr!r}"
            )
        with open(signal_path, "r", encoding="utf-8") as signal_file:
            received_signals = signal_file.read().splitlines()
        if received_signals != ["SUPPORT_LOSS", "TERM"]:
            raise SystemExit(
                f"the owner sent an unexpected installer signal: {received_signals!r}"
            )
        if lock_is_held(public_path) or lock_is_held(scope_path):
            raise SystemExit("the inherited locks remained after installer exit")
    finally:
        if sentinel is not None and sentinel.poll() is None:
            sentinel.kill()
            sentinel.wait()
        if owner is not None and owner.poll() is None:
            owner.kill()
            owner.wait()
        if installer.poll() is None:
            installer.kill()
            installer.wait()
        if public_descriptor >= 0:
            os.close(public_descriptor)
        if scope_descriptor >= 0:
            os.close(scope_descriptor)

print("hold-owner-ready reported sentinel death and retained the locks")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "hold-owner-ready reported sentinel death and retained the locks"
}

@test "lock-sentinel notifies the installer of owner death and retains the locks" {
    local test_script="${TEST_ROOT}/lock-sentinel-owner-death.py"

    cat > "${test_script}" <<'PY'
import fcntl
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
lock_holder = sys.argv[1]
spec = importlib.util.spec_from_file_location("lock_holder", lock_holder)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

installer_source = r"""
import signal
import sys
import time

signal_path = sys.argv[1]
owner_loss_signal = int(sys.argv[2])


def record_signal(signal_number, _frame):
    with open(signal_path, "a", encoding="utf-8") as signal_file:
        if signal_number == owner_loss_signal:
            signal_file.write("OWNER_LOSS\n")
        elif signal_number == signal.SIGTERM:
            signal_file.write("TERM\n")
        else:
            signal_file.write(str(signal_number) + "\n")
        signal_file.flush()
    if signal_number == signal.SIGTERM:
        raise SystemExit(0)


signal.signal(owner_loss_signal, record_signal)
signal.signal(signal.SIGTERM, record_signal)

while True:
    time.sleep(0.05)
"""


def wait_for_file(path, process=None, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        if process is not None and process.poll() is not None:
            stdout, stderr = process.communicate()
            raise SystemExit(
                f"the support process exited before publishing {path}: "
                f"{stdout!r} {stderr!r}"
            )
        time.sleep(0.01)
    raise SystemExit(f"timed out waiting for {path}")


def lock_is_held(path):
    descriptor = os.open(path, os.O_RDWR)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(descriptor)


with tempfile.TemporaryDirectory(prefix="lock-sentinel-death-") as temporary_directory:
    owner_status_path = os.path.join(temporary_directory, "owner.status")
    sentinel_status_path = os.path.join(temporary_directory, "sentinel.status")
    ack_path = os.path.join(temporary_directory, "sentinel.ack")
    marker_path = os.path.join(temporary_directory, "owner-retiring")
    signal_path = os.path.join(temporary_directory, "installer.signals")
    public_path = os.path.join(temporary_directory, "public.lock")
    scope_path = os.path.join(temporary_directory, "scope.lock")

    installer = subprocess.Popen(
        [
            sys.executable,
            "-c",
            installer_source,
            signal_path,
            str(module.SIGUSR3),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    owner = None
    sentinel = None
    public_descriptor = -1
    scope_descriptor = -1
    try:
        installer_identity = module.capture_process_identity(installer.pid)
        if installer_identity is None:
            raise SystemExit("unable to capture the installer identity")
        public_descriptor = os.open(public_path, os.O_RDWR | os.O_CREAT, 0o600)
        scope_descriptor = os.open(scope_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(public_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(scope_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        public_metadata = os.fstat(public_descriptor)
        scope_metadata = os.fstat(scope_descriptor)
        public_identity = module.DescriptorIdentity(
            public_metadata.st_dev,
            public_metadata.st_ino,
        )
        scope_identity = module.DescriptorIdentity(
            scope_metadata.st_dev,
            scope_metadata.st_ino,
        )

        owner = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "hold-owner-ready",
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                "run-sentinel",
                owner_status_path,
                sentinel_status_path,
                marker_path,
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        owner_identity = module.capture_process_identity(owner.pid)
        if owner_identity is None:
            raise SystemExit("unable to capture the owner identity")

        sentinel = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "lock-sentinel",
                "run-sentinel",
                sentinel_status_path,
                ack_path,
                marker_path,
                module.encode_process_identity(owner_identity),
                str(owner.pid),
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        os.close(public_descriptor)
        public_descriptor = -1
        os.close(scope_descriptor)
        scope_descriptor = -1
        wait_for_file(sentinel_status_path, sentinel)
        wait_for_file(owner_status_path, owner)

        with open(sentinel_status_path, "r", encoding="utf-8") as status_file:
            sentinel_status = dict(
                line.split("=", 1) for line in status_file.read().splitlines()
            )
        if sentinel_status.get("role") != "sentinel":
            raise SystemExit(f"the sentinel status had the wrong role: {sentinel_status!r}")
        if sentinel_status.get("owner_pid") != str(owner.pid):
            raise SystemExit(f"the sentinel status had the wrong owner: {sentinel_status!r}")
        if sentinel_status.get("process_pid") != str(sentinel.pid):
            raise SystemExit(f"the sentinel status had the wrong process: {sentinel_status!r}")

        owner.kill()
        owner.wait(timeout=5.0)
        wait_for_file(signal_path, sentinel)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            with open(signal_path, "r", encoding="utf-8") as signal_file:
                received_signals = signal_file.read().splitlines()
            if received_signals:
                break
            time.sleep(0.01)
        if received_signals != ["OWNER_LOSS"]:
            raise SystemExit(
                f"the sentinel sent an unexpected installer signal: {received_signals!r}"
            )
        if os.path.exists(ack_path):
            raise SystemExit("the sentinel acknowledged an unexpected owner death")
        if sentinel.poll() is not None:
            raise SystemExit("the sentinel exited before the installer")
        if not lock_is_held(public_path) or not lock_is_held(scope_path):
            raise SystemExit("the sentinel did not retain the inherited locks")
        if not os.path.exists(owner_status_path) or not os.path.exists(sentinel_status_path):
            raise SystemExit("the sentinel removed a support status file")

        installer.send_signal(signal.SIGTERM)
        installer.wait(timeout=5.0)
        sentinel.wait(timeout=5.0)
        stdout, stderr = sentinel.communicate()
        if sentinel.returncode != 0 or stdout or stderr:
            raise SystemExit(
                f"the sentinel did not exit silently: {sentinel.returncode} "
                f"{stdout!r} {stderr!r}"
            )
        with open(signal_path, "r", encoding="utf-8") as signal_file:
            received_signals = signal_file.read().splitlines()
        if received_signals != ["OWNER_LOSS", "TERM"]:
            raise SystemExit(
                f"the sentinel sent an unexpected installer signal: {received_signals!r}"
            )
        if lock_is_held(public_path) or lock_is_held(scope_path):
            raise SystemExit("the inherited locks remained after installer exit")
    finally:
        if sentinel is not None and sentinel.poll() is None:
            sentinel.kill()
            sentinel.wait()
        if owner is not None and owner.poll() is None:
            owner.kill()
            owner.wait()
        if installer.poll() is None:
            installer.kill()
            installer.wait()
        if public_descriptor >= 0:
            os.close(public_descriptor)
        if scope_descriptor >= 0:
            os.close(scope_descriptor)

print("lock-sentinel notified owner death and retained the locks")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "lock-sentinel notified owner death and retained the locks"
}

@test "lock-sentinel retires an owner on request and publishes the teardown acknowledgement" {
    local test_script="${TEST_ROOT}/lock-sentinel-retirement.py"

    cat > "${test_script}" <<'PY'
import fcntl
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
lock_holder = sys.argv[1]
spec = importlib.util.spec_from_file_location("lock_holder", lock_holder)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

installer_source = r"""
import signal
import sys
import time

signal_path = sys.argv[1]
owner_loss_signal = int(sys.argv[2])


def record_signal(signal_number, _frame):
    with open(signal_path, "a", encoding="utf-8") as signal_file:
        if signal_number == owner_loss_signal:
            signal_file.write("OWNER_LOSS\n")
        elif signal_number == signal.SIGTERM:
            signal_file.write("TERM\n")
        else:
            signal_file.write(str(signal_number) + "\n")
        signal_file.flush()
    if signal_number == signal.SIGTERM:
        raise SystemExit(0)


signal.signal(owner_loss_signal, record_signal)
signal.signal(signal.SIGTERM, record_signal)

while True:
    time.sleep(0.05)
"""


def wait_for_file(path, process=None, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        if process is not None and process.poll() is not None:
            stdout, stderr = process.communicate()
            raise SystemExit(
                f"the support process exited before publishing {path}: "
                f"{stdout!r} {stderr!r}"
            )
        time.sleep(0.01)
    raise SystemExit(f"timed out waiting for {path}")


with tempfile.TemporaryDirectory(prefix="lock-sentinel-retire-") as temporary_directory:
    owner_status_path = os.path.join(temporary_directory, "owner.status")
    sentinel_status_path = os.path.join(temporary_directory, "sentinel.status")
    ack_path = os.path.join(temporary_directory, "sentinel.ack")
    marker_path = os.path.join(temporary_directory, "owner-retiring")
    signal_path = os.path.join(temporary_directory, "installer.signals")
    public_path = os.path.join(temporary_directory, "public.lock")
    scope_path = os.path.join(temporary_directory, "scope.lock")

    installer = subprocess.Popen(
        [
            sys.executable,
            "-c",
            installer_source,
            signal_path,
            str(module.SIGUSR3),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    owner = None
    sentinel = None
    public_descriptor = -1
    scope_descriptor = -1
    try:
        installer_identity = module.capture_process_identity(installer.pid)
        if installer_identity is None:
            raise SystemExit("unable to capture the installer identity")
        public_descriptor = os.open(public_path, os.O_RDWR | os.O_CREAT, 0o600)
        scope_descriptor = os.open(scope_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(public_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(scope_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        public_metadata = os.fstat(public_descriptor)
        scope_metadata = os.fstat(scope_descriptor)
        public_identity = module.DescriptorIdentity(
            public_metadata.st_dev,
            public_metadata.st_ino,
        )
        scope_identity = module.DescriptorIdentity(
            scope_metadata.st_dev,
            scope_metadata.st_ino,
        )

        owner = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "hold-owner-ready",
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                "run-retirement",
                owner_status_path,
                sentinel_status_path,
                marker_path,
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        owner_identity = module.capture_process_identity(owner.pid)
        if owner_identity is None:
            raise SystemExit("unable to capture the owner identity")

        sentinel = subprocess.Popen(
            [
                sys.executable,
                lock_holder,
                "lock-sentinel",
                "run-retirement",
                sentinel_status_path,
                ack_path,
                marker_path,
                module.encode_process_identity(owner_identity),
                str(owner.pid),
                module.encode_process_identity(installer_identity),
                str(installer.pid),
                str(public_descriptor),
                str(scope_descriptor),
                module.encode_descriptor_identity(public_identity),
                module.encode_descriptor_identity(scope_identity),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(public_descriptor, scope_descriptor),
        )
        os.close(public_descriptor)
        public_descriptor = -1
        os.close(scope_descriptor)
        scope_descriptor = -1
        wait_for_file(sentinel_status_path, sentinel)
        wait_for_file(owner_status_path, owner)

        sentinel.send_signal(signal.SIGTERM)
        time.sleep(0.1)
        if sentinel.poll() is not None:
            raise SystemExit("the sentinel did not ignore an ordinary shutdown signal")

        sentinel.send_signal(signal.SIGUSR2)
        wait_for_file(ack_path, sentinel)
        owner.wait(timeout=5.0)
        if owner.returncode != 0:
            raise SystemExit(f"the owner was not retired: {owner.returncode}")
        if sentinel.poll() is not None:
            raise SystemExit("the sentinel exited before the parent terminated it")
        if os.path.exists(signal_path):
            with open(signal_path, "r", encoding="utf-8") as signal_file:
                early_signals = signal_file.read()
            if early_signals:
                raise SystemExit(
                    f"the intentional retirement notified the installer: {early_signals!r}"
                )

        with open(ack_path, "r", encoding="utf-8") as ack_file:
            ack_lines = ack_file.read().splitlines()
        expected_keys = [
            "schema",
            "run_id",
            "state",
            "request_id",
            "owner_pid",
            "owner_identity",
            "sentinel_pid",
            "sentinel_identity",
            "installer_pid",
            "installer_identity",
        ]
        if [line.split("=", 1)[0] for line in ack_lines] != expected_keys:
            raise SystemExit(f"the teardown acknowledgement schema was not strict: {ack_lines!r}")
        acknowledgement = dict(line.split("=", 1) for line in ack_lines)
        if acknowledgement["schema"] != "1":
            raise SystemExit(f"the teardown acknowledgement schema was wrong: {ack_lines!r}")
        if acknowledgement["run_id"] != "run-retirement":
            raise SystemExit(f"the teardown acknowledgement run id was wrong: {ack_lines!r}")
        if acknowledgement["state"] != "owner-retired":
            raise SystemExit(f"the teardown acknowledgement state was wrong: {ack_lines!r}")
        if acknowledgement["owner_pid"] != str(owner.pid):
            raise SystemExit(f"the teardown acknowledgement owner was wrong: {ack_lines!r}")
        if acknowledgement["owner_identity"] != module.encode_process_identity(owner_identity):
            raise SystemExit(f"the teardown acknowledgement identity was wrong: {ack_lines!r}")
        if acknowledgement["sentinel_pid"] != str(sentinel.pid):
            raise SystemExit(f"the teardown acknowledgement sentinel was wrong: {ack_lines!r}")
        if acknowledgement["installer_pid"] != str(installer.pid):
            raise SystemExit(f"the teardown acknowledgement installer was wrong: {ack_lines!r}")
        if acknowledgement["installer_identity"] != module.encode_process_identity(installer_identity):
            raise SystemExit(f"the teardown acknowledgement installer identity was wrong: {ack_lines!r}")

        with open(marker_path, "r", encoding="utf-8") as marker_file:
            marker_lines = marker_file.read().splitlines()
        marker_keys = [
            "schema",
            "run_id",
            "state",
            "request_id",
            "owner_pid",
            "owner_identity",
            "sentinel_pid",
            "sentinel_identity",
            "installer_pid",
            "installer_identity",
        ]
        if [line.split("=", 1)[0] for line in marker_lines] != marker_keys:
            raise SystemExit(f"the owner retirement marker schema was not strict: {marker_lines!r}")
        retirement_marker = dict(line.split("=", 1) for line in marker_lines)
        if retirement_marker["schema"] != "1":
            raise SystemExit(f"the owner retirement marker schema was wrong: {retirement_marker!r}")
        if retirement_marker["run_id"] != "run-retirement":
            raise SystemExit(f"the owner retirement marker run id was wrong: {retirement_marker!r}")
        if retirement_marker["state"] != "owner-retiring":
            raise SystemExit(f"the owner retirement marker state was wrong: {retirement_marker!r}")
        if len(retirement_marker["request_id"]) != 64:
            raise SystemExit(f"the owner retirement marker request id was wrong: {retirement_marker!r}")
        if retirement_marker["owner_pid"] != str(owner.pid):
            raise SystemExit(f"the owner retirement marker owner was wrong: {retirement_marker!r}")
        if retirement_marker["owner_identity"] != module.encode_process_identity(owner_identity):
            raise SystemExit(f"the owner retirement marker identity was wrong: {retirement_marker!r}")
        if retirement_marker["sentinel_pid"] != str(sentinel.pid):
            raise SystemExit(f"the owner retirement marker sentinel was wrong: {retirement_marker!r}")
        sentinel_identity = module.capture_process_identity(sentinel.pid)
        if sentinel_identity is None:
            raise SystemExit("unable to capture the sentinel identity")
        if retirement_marker["sentinel_identity"] != module.encode_process_identity(
            sentinel_identity
        ):
            raise SystemExit(f"the owner retirement marker sentinel identity was wrong: {retirement_marker!r}")
        if retirement_marker["installer_pid"] != str(installer.pid):
            raise SystemExit(f"the owner retirement marker installer was wrong: {retirement_marker!r}")
        if retirement_marker["installer_identity"] != module.encode_process_identity(installer_identity):
            raise SystemExit(f"the owner retirement marker installer identity was wrong: {retirement_marker!r}")
        if retirement_marker["request_id"] != acknowledgement["request_id"]:
            raise SystemExit(f"the retirement transaction request ids differed: {retirement_marker!r}")

        sentinel.kill()
        sentinel.wait(timeout=5.0)
        installer.send_signal(signal.SIGTERM)
        installer.wait(timeout=5.0)
        with open(signal_path, "r", encoding="utf-8") as signal_file:
            received_signals = signal_file.read().splitlines()
        if received_signals != ["TERM"]:
            raise SystemExit(
                f"the intentional retirement sent an unexpected installer signal: {received_signals!r}"
            )
    finally:
        if sentinel is not None and sentinel.poll() is None:
            sentinel.kill()
            sentinel.wait()
        if owner is not None and owner.poll() is None:
            owner.kill()
            owner.wait()
        if installer.poll() is None:
            installer.kill()
            installer.wait()
        if public_descriptor >= 0:
            os.close(public_descriptor)
        if scope_descriptor >= 0:
            os.close(scope_descriptor)

print("lock-sentinel retired the owner and published the teardown acknowledgement")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "lock-sentinel retired the owner and published the teardown acknowledgement"
}

@test "owner retirement never acknowledges a pidfd signal delivered to an exited owner" {
    local test_script="${TEST_ROOT}/owner-retirement-false-ack.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

owner_identity = module.ProcessIdentity(101, "boot-id")
sentinel_identity = module.ProcessIdentity(202, "boot-id")
installer_identity = module.ProcessIdentity(505, "boot-id")
installer_process_id = 505
owner_target = module.MonitoredProcess(
    "owner",
    303,
    descriptor=42,
    identity=owner_identity,
)


class Monitor:
    def __init__(self):
        self.targets = [owner_target]

    def resume(self, _target):
        return True

    def mark_exited(self, _target):
        return None


observations = 0
signals = []


def observe_owner(process_id, _identity):
    global observations
    if process_id == installer_process_id:
        return module.ProcessObservation.ALIVE
    observations += 1
    if observations == 1:
        return module.ProcessObservation.ALIVE
    return module.ProcessObservation.EXITED


def signal_owner(_descriptor, signal_number):
    signals.append(signal_number)
    # A pidfd can report successful delivery even when the target has already
    # become an unreaped zombie. Only the owner's marker and confirmed exit
    # may authorize the acknowledgement.
    return True


module.observe_process_identity = observe_owner
module.signal_pidfd = signal_owner

with tempfile.TemporaryDirectory(prefix="owner-retirement-false-ack-") as directory:
    marker_path = os.path.join(directory, "owner-retiring")
    ack_path = os.path.join(directory, "sentinel.ack")
    retired = module.retire_sentinel_owner(
        Monitor(),
        owner_target.process_id,
        owner_identity,
        ack_path,
        marker_path,
        "run-false-ack",
        404,
        sentinel_identity,
        installer_process_id,
        installer_identity,
    )
    if retired != module.SentinelRetirementResult.OWNER_LOST:
        raise SystemExit("an exited owner was reported as intentionally retired")
    if signals != [module.signal.SIGUSR1]:
        raise SystemExit(f"the owner request used an unexpected signal: {signals!r}")
    if os.path.exists(ack_path):
        raise SystemExit("an exited owner received a false retirement acknowledgement")
    if os.path.exists(marker_path):
        raise SystemExit("the failed retirement request was left behind")

print("an exited owner did not receive a false retirement acknowledgement")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "an exited owner did not receive a false retirement acknowledgement"
}

@test "owner retirement rejects a zombie owner before publishing an acknowledgement" {
    local test_script="${TEST_ROOT}/owner-retirement-zombie.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

owner = subprocess.Popen([sys.executable, "-c", "pass"])
owner_identity = module.capture_process_identity(owner.pid)
if owner_identity is None:
    owner.kill()
    owner.wait()
    raise SystemExit("unable to capture the owner identity")
owner_descriptor = os.pidfd_open(owner.pid)

try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            with open(f"/proc/{owner.pid}/stat", "r", encoding="utf-8") as stat_file:
                state = stat_file.read().split(") ", 1)[1][0]
        except (FileNotFoundError, IndexError):
            state = ""
        if state == "Z":
            break
        time.sleep(0.01)
    else:
        raise SystemExit("the owner did not become a zombie")

    owner_target = module.MonitoredProcess(
        "owner",
        owner.pid,
        descriptor=owner_descriptor,
        identity=owner_identity,
    )

    class Monitor:
        def __init__(self):
            self.targets = [owner_target]

        def resume(self, _target):
            return True

        def mark_exited(self, _target):
            return None

    with tempfile.TemporaryDirectory(prefix="owner-retirement-zombie-") as directory:
        marker_path = os.path.join(directory, "owner-retiring")
        ack_path = os.path.join(directory, "sentinel.ack")
        result = module.retire_sentinel_owner(
            Monitor(),
            owner.pid,
            owner_identity,
            ack_path,
            marker_path,
            "run-zombie",
            404,
            module.ProcessIdentity(202, "boot-id"),
            os.getpid(),
            module.capture_process_identity(os.getpid()),
        )
        if result != module.SentinelRetirementResult.OWNER_LOST:
            raise SystemExit(f"a zombie owner was reported as retired: {result!r}")
        if os.path.exists(ack_path):
            raise SystemExit("a zombie owner received a retirement acknowledgement")
finally:
    os.close(owner_descriptor)
    owner.wait(timeout=5.0)

print("a zombie owner did not receive a retirement acknowledgement")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "a zombie owner did not receive a retirement acknowledgement"
}

@test "inherited lock validation rejects a separate descriptor for the same inode" {
    local test_script="${TEST_ROOT}/exact-inherited-descriptor.py"

    cat > "${test_script}" <<'PY'
import fcntl
import importlib.util
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="exact-inherited-descriptor-") as directory:
    lock_path = os.path.join(directory, "postinstall.lock")
    locked_descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    separate_descriptor = -1
    duplicate_descriptor = -1
    try:
        fcntl.flock(locked_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        metadata = os.fstat(locked_descriptor)
        identity = module.DescriptorIdentity(metadata.st_dev, metadata.st_ino)
        duplicate_descriptor = os.dup(locked_descriptor)
        separate_descriptor = os.open(lock_path, os.O_RDWR)
        if not module.validate_inherited_descriptor(duplicate_descriptor, identity):
            raise SystemExit("the inherited locked descriptor was rejected")
        if module.validate_inherited_descriptor(separate_descriptor, identity):
            raise SystemExit("a separate unlocked descriptor was accepted")
    finally:
        if separate_descriptor >= 0:
            os.close(separate_descriptor)
        if duplicate_descriptor >= 0:
            os.close(duplicate_descriptor)
        os.close(locked_descriptor)

print("exact inherited lock descriptors were distinguished from separate opens")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "exact inherited lock descriptors were distinguished from separate opens"
}

@test "sentinel notification retries transient pidfd signaling failures" {
    local test_script="${TEST_ROOT}/sentinel-notification-retry.py"

    cat > "${test_script}" <<'PY'
import errno
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.capture_process_identity(os.getpid())
if identity is None:
    raise SystemExit("unable to capture installer identity")
attempts = []


class Monitor:
    def __init__(self):
        self.targets = [
            module.MonitoredProcess(
                "installer",
                os.getpid(),
                descriptor=42,
                identity=identity,
            )
        ]

    def mark_exited(self, _target):
        raise AssertionError("a transient failure was treated as installer exit")


def flaky_pidfd_signal(_descriptor, signal_number):
    attempts.append(signal_number)
    if len(attempts) <= 25:
        raise OSError(errno.EAGAIN, "transient signal failure")
    return None


def forbidden_raw_kill(_process_id, _signal_number):
    raise AssertionError("raw PID signaling was used without a pidfd")


monitor = Monitor()
module.signal.pidfd_send_signal = flaky_pidfd_signal
module.os.kill = forbidden_raw_kill
if not module.notify_sentinel_installer(monitor):
    raise SystemExit("sentinel notification did not succeed")
if len(attempts) != 26:
    raise SystemExit("sentinel notification was not retried past the transient failures")
if attempts[0] != module.SIGUSR3:
    raise SystemExit(f"unexpected sentinel notification signal: {attempts[0]}")
print("sentinel notification retried")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "sentinel notification retried"
}

@test "support helpers accept setsid EPERM only for an existing singleton process group" {
    local test_script="${TEST_ROOT}/support-setsid.py"

    cat > "${test_script}" <<'PY'
import errno
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

real_setsid = module.os.setsid
real_getpgid = module.os.getpgid
current_process_id = module.os.getpid()
parent_process_id = module.os.getppid()


def denied_setsid():
    raise OSError(errno.EPERM, "setsid denied")


def singleton_getpgid(process_id):
    if process_id == 0:
        return current_process_id
    if process_id == parent_process_id:
        return current_process_id + 1000
    if process_id == 4242:
        return current_process_id + 2000
    return real_getpgid(process_id)


module.os.setsid = denied_setsid
module.os.getpgid = singleton_getpgid
try:
    group_id = module.establish_support_process_group((4242,))
finally:
    module.os.setsid = real_setsid
    module.os.getpgid = real_getpgid
if group_id != current_process_id:
    raise SystemExit(f"the singleton support group was not accepted: {group_id}")


def shared_getpgid(process_id):
    if process_id == 0:
        return current_process_id
    if process_id == parent_process_id:
        return current_process_id + 1000
    if process_id == 4242:
        return current_process_id
    return real_getpgid(process_id)


module.os.setsid = denied_setsid
module.os.getpgid = shared_getpgid
try:
    module.establish_support_process_group((4242,))
except module.MonitoringUnavailable:
    pass
else:
    raise SystemExit("a shared support process group was accepted")
finally:
    module.os.setsid = real_setsid
    module.os.getpgid = real_getpgid

print("setsid EPERM accepted only for an independent singleton group")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "setsid EPERM accepted only for an independent singleton group"
}

@test "wait_for classifies cancelled and unknown decisions without releasing the lock" {
    local test_script="${TEST_ROOT}/wait-for-decisions.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")


def unavailable_pidfd(_process_id):
    raise OSError("pidfd unavailable")


module.os.pidfd_open = unavailable_pidfd
module.observe_process_identity = lambda _process_id, _identity: (
    module.ProcessObservation.ALIVE
)

module.CANCELLATION_REQUESTED = False
module.CANCELLATION_ABORT_REQUESTED = True
monitor = module.ProcessMonitor([("installer", 42, identity)])
try:
    monitor.wait_for("installer")
except module.AcquisitionDecisionUnknown:
    pass
else:
    raise SystemExit("an unknown decision was ignored by wait_for")
finally:
    monitor.close()

module.CANCELLATION_REQUESTED = True
monitor = module.ProcessMonitor([("installer", 42, identity)])
try:
    monitor.wait_for("installer")
except module.AcquisitionCancelled:
    pass
else:
    raise SystemExit("a cancelled decision was ignored by wait_for")
finally:
    monitor.close()

module.CANCELLATION_REQUESTED = False
module.CANCELLATION_ABORT_REQUESTED = True
monitor = module.ProcessMonitor([("installer", 42, identity)])
try:
    target = monitor.wait_for(
        "installer",
        raise_on_cancellation=False,
        interruption_callback=lambda: True,
    )
    if target.exited:
        raise SystemExit("the notify-and-wait path released the locked installer")
finally:
    monitor.close()

print("wait_for classified cancellation and preserved the locked wait path")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "wait_for classified cancellation and preserved the locked wait path"
}

@test "ProcessMonitor never resumes a stopped installer" {
    local test_script="${TEST_ROOT}/process-monitor-stopped-installer.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

identity = module.ProcessIdentity(123, "boot-id")
resume_count = 0
sequences = {
    42: iter([]),
    43: iter([]),
}


def unavailable_pidfd(_process_id):
    raise OSError("pidfd unavailable")


def observe_process_identity(process_id, _identity):
    try:
        return next(sequences[process_id])
    except StopIteration:
        return module.ProcessObservation.EXITED


def resume_process(_process_id, _identity):
    global resume_count
    resume_count += 1
    return True


module.os.pidfd_open = unavailable_pidfd
module.observe_process_identity = observe_process_identity
module.resume_process = resume_process

sequences[42] = iter(
    [
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.EXITED,
    ]
)
monitor = module.ProcessMonitor([("installer", 42, identity)])
try:
    target = monitor.wait_for("installer")
    if not target.exited:
        raise SystemExit("the stopped installer wait did not observe its exit")
finally:
    monitor.close()
if resume_count != 0:
    raise SystemExit(f"a stopped installer was resumed {resume_count} times")

sequences[42] = iter(
    [
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.EXITED,
    ]
)
monitor = module.ProcessMonitor([("installer", 42, identity)])
try:
    target = monitor.wait()
    if target is None or not target.exited:
        raise SystemExit("the monitor did not observe the stopped installer's exit")
finally:
    monitor.close()
if resume_count != 0:
    raise SystemExit(f"the monitor resumed a stopped installer {resume_count} times")

sequences[43] = iter(
    [
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.ALIVE,
        module.ProcessObservation.EXITED,
    ]
)
monitor = module.ProcessMonitor([("helper", 43, identity)])
try:
    target = monitor.wait_for("helper")
    if not target.exited:
        raise SystemExit("the stopped helper wait did not observe its exit")
finally:
    monitor.close()
if resume_count != 1:
    raise SystemExit(f"the stopped helper resume count was wrong: {resume_count}")

print("ProcessMonitor resumed helpers but never resumed the installer")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "ProcessMonitor resumed helpers but never resumed the installer"
}

@test "failed owner retirement transactions remove their marker" {
    local test_script="${TEST_ROOT}/owner-retirement-cleanup.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

owner_identity = module.ProcessIdentity(101, "boot-id")
sentinel_identity = module.ProcessIdentity(202, "boot-id")
installer_identity = module.ProcessIdentity(505, "boot-id")
owner_target = module.MonitoredProcess(
    "owner",
    303,
    descriptor=42,
    identity=owner_identity,
)


class Monitor:
    def __init__(self):
        self.targets = [owner_target]

    def resume(self, _target):
        return True

    def mark_exited(self, _target):
        return None


def as_retiring_marker(marker):
    return module.OwnerRetirementMarker(
        state=module.OWNER_RETIREMENT_MARKER_STATE,
        run_id=marker.run_id,
        request_id=marker.request_id,
        owner_process_id=marker.owner_process_id,
        owner_identity=marker.owner_identity,
        sentinel_process_id=marker.sentinel_process_id,
        sentinel_identity=marker.sentinel_identity,
        installer_process_id=marker.installer_process_id,
        installer_identity=marker.installer_identity,
    )


real_read_marker = module.read_owner_retirement_marker
real_write_status = module.write_status
module.signal_pidfd = lambda _descriptor, _signal_number: True

with tempfile.TemporaryDirectory(prefix="owner-retirement-cleanup-") as directory:
    marker_path = os.path.join(directory, "owner-retiring")
    ack_path = os.path.join(directory, "sentinel.ack")
    owner_observations = 0

    def observe_process_identity(process_id, _identity):
        global owner_observations
        if process_id == 505:
            return module.ProcessObservation.ALIVE
        owner_observations += 1
        if owner_observations == 1:
            return module.ProcessObservation.ALIVE
        return module.ProcessObservation.EXITED

    module.observe_process_identity = observe_process_identity
    marker_reads = 0

    def mismatched_marker_read(path):
        global marker_reads
        marker = real_read_marker(path)
        if marker is None:
            return None
        marker_reads += 1
        matching = as_retiring_marker(marker)
        if marker_reads == 2:
            return module.OwnerRetirementMarker(
                state=matching.state,
                run_id=matching.run_id,
                request_id="f" * 64,
                owner_process_id=matching.owner_process_id,
                owner_identity=matching.owner_identity,
                sentinel_process_id=matching.sentinel_process_id,
                sentinel_identity=matching.sentinel_identity,
                installer_process_id=matching.installer_process_id,
                installer_identity=matching.installer_identity,
            )
        return matching

    module.read_owner_retirement_marker = mismatched_marker_read
    result = module.retire_sentinel_owner(
        Monitor(),
        owner_target.process_id,
        owner_identity,
        ack_path,
        marker_path,
        "run-cleanup",
        404,
        sentinel_identity,
        505,
        installer_identity,
    )
    if result != module.SentinelRetirementResult.OWNER_LOST:
        raise SystemExit(f"a mismatched marker was not rejected: {result!r}")
    if os.path.exists(marker_path):
        raise SystemExit("a mismatched retirement marker was left behind")
    if os.path.exists(ack_path):
        raise SystemExit("a mismatched retirement transaction was acknowledged")

    owner_observations = 0
    module.read_owner_retirement_marker = lambda path: (
        as_retiring_marker(real_read_marker(path))
        if real_read_marker(path) is not None
        else None
    )

    def failing_ack_write(path, content):
        if os.path.abspath(path) == os.path.abspath(ack_path):
            raise OSError("acknowledgement publication failed")
        real_write_status(path, content)

    module.write_status = failing_ack_write
    try:
        module.retire_sentinel_owner(
            Monitor(),
            owner_target.process_id,
            owner_identity,
            ack_path,
            marker_path,
            "run-cleanup",
            404,
            sentinel_identity,
            505,
            installer_identity,
        )
    except OSError:
        pass
    else:
        raise SystemExit("the acknowledgement publication failure was ignored")
    if os.path.exists(marker_path):
        raise SystemExit("a failed acknowledgement left its retirement marker")
    if os.path.exists(ack_path):
        raise SystemExit("a failed acknowledgement was published")

print("failed owner retirement transactions removed their markers")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "failed owner retirement transactions removed their markers"
}

@test "strict termination distinguishes an already-exited target" {
    local test_script="${TEST_ROOT}/strict-termination.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import subprocess
import sys
import time

sys.dont_write_bytecode = True
lock_holder = sys.argv[1]
spec = importlib.util.spec_from_file_location("lock_holder", lock_holder)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

real_observe = module.observe_process_identity
real_signal_pidfd = module.signal_pidfd
real_signal_process = module.signal_process_by_identity
identity = module.ProcessIdentity(123, "boot-id")
module.observe_process_identity = lambda _process_id, _identity: (
    module.ProcessObservation.EXITED
)
result = module.terminate_process_by_identity_result(
    42,
    identity,
    require_stopped=True,
)
if result != module.TerminationResult.ALREADY_EXITED:
    raise SystemExit(f"an exited target was not distinguished: {result!r}")

observations = iter(
    [
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.STOPPED,
        module.ProcessObservation.EXITED,
    ]
)
module.observe_process_identity = lambda _process_id, _identity: next(observations)
module.signal_process_by_identity = lambda _process_id, _identity, _signal: True
result = module.terminate_process_by_identity_result(
    42,
    identity,
    require_stopped=True,
)
if result != module.TerminationResult.TERMINATED:
    raise SystemExit(f"a delivered termination was not distinguished: {result!r}")

module.observe_process_identity = real_observe
module.signal_process_by_identity = real_signal_process
zombie_child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
try:
    zombie_identity = module.capture_process_identity(zombie_child.pid)
    if zombie_identity is None:
        raise SystemExit("unable to capture the zombie test child identity")

    def signal_after_zombie(descriptor, signal_number):
        if signal_number == module.signal.SIGSTOP:
            zombie_child.kill()
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                try:
                    with open(
                        f"/proc/{zombie_child.pid}/stat",
                        "r",
                        encoding="utf-8",
                    ) as stat_file:
                        state = stat_file.read().split(") ", 1)[1][0]
                except (FileNotFoundError, IndexError):
                    state = ""
                if state == "Z":
                    break
                time.sleep(0.01)
            else:
                raise SystemExit("the strict termination child did not become a zombie")
        return real_signal_pidfd(descriptor, signal_number)

    module.signal_pidfd = signal_after_zombie
    result = module.terminate_process_by_identity_result(
        zombie_child.pid,
        zombie_identity,
        require_stopped=True,
    )
    if result != module.TerminationResult.ALREADY_EXITED:
        raise SystemExit(f"a zombie target was classified as terminated: {result!r}")
finally:
    module.signal_pidfd = real_signal_pidfd
    if zombie_child.poll() is None:
        zombie_child.kill()
    zombie_child.wait(timeout=5.0)

live_child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
try:
    live_identity = module.capture_process_identity(live_child.pid)
    if live_identity is None:
        raise SystemExit("unable to capture the live test child identity")
    command = subprocess.run(
        [
            sys.executable,
            lock_holder,
            "terminate-process-required",
            str(live_child.pid),
            module.encode_process_identity(live_identity),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if command.returncode != 0 or command.stdout or command.stderr:
        raise SystemExit(f"the live strict termination failed: {command!r}")
finally:
    if live_child.poll() is None:
        live_child.kill()
    live_child.wait(timeout=5.0)

command = subprocess.run(
    [
        sys.executable,
        lock_holder,
        "terminate-process-required",
        "2147483647",
        module.encode_process_identity(identity),
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
if command.returncode != 75 or command.stdout or command.stderr:
    raise SystemExit(f"the strict termination status was wrong: {command!r}")

print("strict termination distinguished prior exit from signal delivery")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "strict termination distinguished prior exit from signal delivery"
}

@test "owner retirement markers are strictly bound for fallback classification" {
    local test_script="${TEST_ROOT}/owner-retirement-marker-validation.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import subprocess
import sys
import tempfile
from dataclasses import replace

sys.dont_write_bytecode = True
lock_holder = sys.argv[1]
spec = importlib.util.spec_from_file_location("lock_holder", lock_holder)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

owner_identity = module.ProcessIdentity(101, "boot-id")
sentinel_identity = module.ProcessIdentity(202, "boot-id")
installer_identity = module.ProcessIdentity(303, "boot-id")
marker = module.OwnerRetirementMarker(
    state=module.OWNER_RETIREMENT_MARKER_STATE,
    run_id="run-marker",
    request_id="a" * 64,
    owner_process_id=111,
    owner_identity=owner_identity,
    sentinel_process_id=222,
    sentinel_identity=sentinel_identity,
    installer_process_id=333,
    installer_identity=installer_identity,
)

with tempfile.TemporaryDirectory(prefix="owner-retirement-marker-") as directory:
    marker_path = os.path.join(directory, "owner-retiring")
    expected = (
        "run-marker",
        111,
        owner_identity,
        222,
        sentinel_identity,
        333,
        installer_identity,
    )

    def validation_command(expectation):
        (
            run_id,
            owner_process_id,
            expected_owner_identity,
            sentinel_process_id,
            expected_sentinel_identity,
            installer_process_id,
            expected_installer_identity,
        ) = expectation
        return [
            sys.executable,
            lock_holder,
            "validate-owner-retirement-marker",
            marker_path,
            run_id,
            str(owner_process_id),
            module.encode_process_identity(expected_owner_identity),
            str(sentinel_process_id),
            module.encode_process_identity(expected_sentinel_identity),
            str(installer_process_id),
            module.encode_process_identity(expected_installer_identity),
        ]

    module.write_status(marker_path, module.encode_owner_retirement_marker(marker))
    if not module.validate_owner_retirement_marker(marker_path, *expected):
        raise SystemExit("the bound owner retirement marker was rejected")

    command = subprocess.run(
        validation_command(expected),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if command.returncode != 0 or command.stdout or command.stderr:
        raise SystemExit(f"the marker validation command failed: {command!r}")

    rejections = [
        (
            "wrong run",
            marker,
            (
                "wrong-run",
                111,
                owner_identity,
                222,
                sentinel_identity,
                333,
                installer_identity,
            ),
        ),
        (
            "requested state",
            replace(marker, state=module.OWNER_RETIREMENT_REQUEST_STATE),
            expected,
        ),
        (
            "owner PID",
            replace(marker, owner_process_id=112),
            expected,
        ),
        (
            "owner identity",
            replace(marker, owner_identity=module.ProcessIdentity(112, "other-boot")),
            expected,
        ),
        (
            "sentinel PID",
            replace(marker, sentinel_process_id=223),
            expected,
        ),
        (
            "sentinel identity",
            replace(
                marker,
                sentinel_identity=module.ProcessIdentity(223, "other-boot"),
            ),
            expected,
        ),
        (
            "installer PID",
            replace(marker, installer_process_id=334),
            expected,
        ),
        (
            "installer identity",
            replace(
                marker,
                installer_identity=module.ProcessIdentity(334, "other-boot"),
            ),
            expected,
        ),
    ]
    for label, candidate, expectation in rejections:
        module.write_status(
            marker_path,
            module.encode_owner_retirement_marker(candidate),
        )
        if module.validate_owner_retirement_marker(marker_path, *expectation):
            raise SystemExit(f"an owner retirement marker accepted the wrong {label}")
        command = subprocess.run(
            validation_command(expectation),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if command.returncode != 1 or command.stdout or command.stderr:
            raise SystemExit(f"the wrong {label} marker was accepted: {command!r}")

print("owner retirement markers were strictly bound")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains "owner retirement markers were strictly bound"
}

@test "status publication keeps temporary names in the lock scope" {
    local test_script="${TEST_ROOT}/status-temporary-name.py"

    cat > "${test_script}" <<'PY'
import importlib.util
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("lock_holder", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

real_replace = module.os.replace
captured = []


def fail_replace(source, _destination, **_keywords):
    captured.append(source)
    raise OSError("publication failed")


module.os.replace = fail_replace
try:
    with tempfile.TemporaryDirectory(prefix="status-temporary-name-") as directory:
        status_path = os.path.join(
            directory,
            ".postinstall-lock-0123456789abcdef-run.owner",
        )
        try:
            module.write_status(status_path, "status\n")
        except OSError:
            pass
        else:
            raise SystemExit("the failed status publication was ignored")
finally:
    module.os.replace = real_replace

expected = f"{os.path.basename(status_path)}.{os.getpid()}.tmp"
if captured != [expected]:
    raise SystemExit(f"the status temporary name escaped its scope: {captured!r}")
if os.path.exists(status_path):
    raise SystemExit("the failed status publication left its final path")

print("status publication kept its temporary name in the lock scope")
PY

    run env PYTHONDONTWRITEBYTECODE=1 python3 \
        "${test_script}" "${LOCK_HOLDER}"
    assert_success
    assert_output_contains \
        "status publication kept its temporary name in the lock scope"
}

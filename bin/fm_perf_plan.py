"""Validated, project-neutral performance plans for fm-test-service.

The configured queue holds one phone lease while this module installs, drives,
captures, pulls, and uninstalls. Project commands write numeric JSON metrics to
the supplied {output} path. Optional Perfetto traces are indexed separately.
"""
import csv
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess


NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*\Z")
PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+\Z")


def _name(value, label):
    if not isinstance(value, str) or not NAME.fullmatch(value):
        raise ValueError(label + " must be a safe name")
    return value


def validate(plan, cfg):
    adapter = cfg.get("performance")
    if not isinstance(adapter, dict):
        raise ValueError("project has no performance adapter")
    for key in ("queue", "build", "install", "drive", "capture", "pull", "uninstall"):
        argv = adapter.get(key)
        if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
            raise ValueError("performance adapter needs " + key + " argv")
        service_tool = argv[0].startswith("@service/") and NAME.fullmatch(argv[0][9:])
        if not service_tool and (Path(argv[0]).is_absolute() or ".." in Path(argv[0]).parts):
            raise ValueError("performance " + key + " executable must be inside tested checkout")
    package = adapter.get("package")
    if not isinstance(package, str) or not PACKAGE.fullmatch(package):
        raise ValueError("performance adapter needs isolated package")
    prefixes = adapter.get("isolated_package_prefixes")
    if not isinstance(prefixes, list) or not prefixes or any(not isinstance(p, str) or not PACKAGE.fullmatch(p) for p in prefixes):
        raise ValueError("performance adapter needs isolated_package_prefixes")
    if not isinstance(plan, dict) or plan.get("schema") != "fm-performance-plan.v1":
        raise ValueError("performance plan needs schema=fm-performance-plan.v1")
    if set(plan) - {"schema", "device", "states", "compare_to"}:
        raise ValueError("unknown performance plan field")
    if plan.get("device") not in cfg["phones"]:
        raise ValueError("performance plan device is not configured")
    states = plan.get("states")
    if not isinstance(states, list) or not states:
        raise ValueError("performance plan needs ordered states")
    seen = set()
    for state in states:
        if not isinstance(state, dict) or set(state) != {"name", "target", "measurements", "repeats", "thresholds"}:
            raise ValueError("performance state needs name, target, measurements, repeats, thresholds")
        name = _name(state["name"], "state name")
        _name(state["target"], "state target")
        if name in seen:
            raise ValueError("duplicate performance state: " + name)
        seen.add(name)
        kinds = state["measurements"]
        if not isinstance(kinds, list) or not kinds or len(kinds) != len(set(map(str, kinds))):
            raise ValueError("measurements must be distinct names")
        for kind in kinds:
            _name(kind, "measurement")
        if isinstance(state["repeats"], bool) or not isinstance(state["repeats"], int) or not 1 <= state["repeats"] <= 20:
            raise ValueError("repeats must be 1..20")
        if not isinstance(state["thresholds"], dict):
            raise ValueError("thresholds must be a metric map")
        for metric, limits in state["thresholds"].items():
            _name(metric, "metric")
            if not isinstance(limits, dict) or not limits or set(limits) - {"min", "max"}:
                raise ValueError("threshold needs min or max")
            if any(isinstance(v, bool) or not isinstance(v, (int, float)) for v in limits.values()):
                raise ValueError("threshold limits must be numeric")
    if "compare_to" in plan:
        _name(plan["compare_to"], "compare_to")
    return plan


def load_committed_plan(source, sha, path, cfg):
    service_plan = path.startswith("@service/")
    if service_plan:
        source = Path(__file__).resolve().parent.parent
        path = path[9:]
        sha = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if Path(path).is_absolute() or ".." in Path(path).parts or not path.endswith(".json"):
        raise ValueError("performance plan must be a relative committed JSON file")
    result = subprocess.run(["git", "-C", str(source), "show", sha + ":" + path],
                            text=True, capture_output=True)
    if result.returncode:
        raise ValueError("performance plan is not committed in tested SHA: " + path)
    return validate(json.loads(result.stdout), cfg)


def command(argv, work, bundle, plan, serial, state, repeat, output, kind=""):
    values = {"worktree": str(work), "bundle": str(bundle), "device": serial,
              "state": state, "kind": kind, "repeat": str(repeat), "output": str(output)}
    rendered = [part.format_map(values) for part in argv]
    service_tool = rendered[0].startswith("@service/")
    executable = ((Path(__file__).resolve().parent / rendered[0][9:]) if service_tool
                  else (work / rendered[0])).resolve()
    allowed_root = Path(__file__).resolve().parent if service_tool else work
    if os.path.commonpath((str(allowed_root), str(executable))) != str(allowed_root) or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("performance command missing or not executable: " + rendered[0])
    rendered[0] = str(executable)
    return rendered


def _call(label, argv, work, log):
    result = subprocess.run(argv, cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(label + " failed (exit " + str(result.returncode) + "): " + result.stdout.strip().splitlines()[-1][:300] if result.stdout.strip() else label + " failed")


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _baseline(bundle, request):
    root = bundle.parents[2]
    prior = root / request
    candidates = sorted(prior.glob("*/performance/summary.json"))
    if len(candidates) != 1:
        raise ValueError("compare_to must name one completed performance bundle")
    return json.loads(candidates[0].read_text())


def validate_comparison(plan, result_root):
    request = plan.get("compare_to")
    if not request:
        return
    candidates = sorted((result_root / request).glob("*/performance/summary.json"))
    if len(candidates) != 1:
        raise ValueError("compare_to must name one completed performance bundle")
    old = json.loads(candidates[0].read_text())
    if old.get("device") != plan["device"]:
        raise ValueError("compare_to device differs from plan device")
    expected = {(state["name"], repeat) for state in plan["states"]
                for repeat in range(1, state["repeats"] + 1)}
    actual = {(row["state"], row["repeat"]) for row in old["rows"]}
    if expected != actual:
        raise ValueError("compare_to state/repeat set differs from plan")


def _foreground(serial):
    result = subprocess.run(["adb", "-s", serial, "shell", "dumpsys", "activity", "activities"],
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("cannot read foreground package")
    for line in result.stdout.splitlines():
        if "topResumedActivity" not in line and "mResumedActivity" not in line:
            continue
        match = re.search(r"\b([A-Za-z][A-Za-z0-9_.]+)/[A-Za-z0-9_.$]+", line)
        if match:
            return match.group(1)
    raise RuntimeError("foreground package is unknown")


def _force_stop(serial, package):
    result = subprocess.run(["adb", "-s", serial, "shell", "am", "force-stop", package],
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("could not force-stop isolated package " + package)


def run_plan(adapter, plan, work, bundle, serial, sha):
    # The queue process is the parent of this process; all commands below share its lease.
    records = []
    installed = False
    foreground = _foreground(serial)
    if any(foreground.startswith(prefix) for prefix in adapter["isolated_package_prefixes"]):
        _force_stop(serial, foreground)
    try:
        _call("install", command(adapter["install"], work, bundle, plan, serial, "", 0, ""), work, bundle / "install.log")
        installed = True
        for state in plan["states"]:
            for repeat in range(1, state["repeats"] + 1):
                tag = state["name"] + "-" + str(repeat)
                _call("drive " + tag, command(adapter["drive"], work, bundle, plan, serial,
                      state["target"], repeat, ""), work, bundle / (tag + "-drive.log"))
                if _foreground(serial) != adapter["package"]:
                    raise RuntimeError("profiling app did not hold focus before " + tag)
                metrics = {}
                for kind in state["measurements"]:
                    output = bundle / (tag + "-" + kind + ".json")
                    _call("capture " + tag + "/" + kind,
                          command(adapter["capture"], work, bundle, plan, serial, state["target"], repeat, output, kind),
                          work, bundle / (tag + "-" + kind + ".log"))
                    data = json.loads(output.read_text())
                    if not isinstance(data, dict) or any(not _number(v) for v in data.values()):
                        raise ValueError("capture output must be numeric metric JSON: " + str(output))
                    duplicate = sorted(set(metrics) & set(data))
                    if duplicate:
                        raise ValueError("capture " + kind + " repeats metric names: " + ", ".join(duplicate))
                    metrics.update(data)
                    _call("pull " + tag + "/" + kind,
                          command(adapter["pull"], work, bundle, plan, serial, state["target"], repeat, output, kind),
                          work, bundle / (tag + "-" + kind + "-pull.log"))
                verdict = all(("min" not in bounds or metrics.get(metric, float("-inf")) >= bounds["min"])
                              and ("max" not in bounds or metrics.get(metric, float("inf")) <= bounds["max"])
                              for metric, bounds in state["thresholds"].items())
                records.append({"state": state["name"], "repeat": repeat, "metrics": metrics, "pass": verdict})
    finally:
        if installed:
            try:
                _force_stop(serial, adapter["package"])
            finally:
                _call("uninstall", command(adapter["uninstall"], work, bundle, plan, serial, "", 0, ""),
                      work, bundle / "uninstall.log")
    index_traces(bundle, adapter.get("trace_processor", "trace_processor"))
    summary = {"schema": "fm-performance-bundle.v1", "sha": sha, "device": serial,
               "rows": records, "pass": all(row["pass"] for row in records)}
    if plan.get("compare_to"):
        old = _baseline(bundle, plan["compare_to"])
        old_rows = {(r["state"], r["repeat"]): r["metrics"] for r in old["rows"]}
        for row in records:
            if set(row["metrics"]) != set(old_rows[(row["state"], row["repeat"])]):
                raise ValueError("compare_to metric set differs for " + row["state"])
        summary["diff"] = [{"state": r["state"], "repeat": r["repeat"],
                            "delta": {k: v - old_rows[(r["state"], r["repeat"])][k]
                                      for k, v in r["metrics"].items()
                                      if (r["state"], r["repeat"]) in old_rows and k in old_rows[(r["state"], r["repeat"])]}}
                           for r in records]
    (bundle / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if not summary["pass"]:
        raise RuntimeError("performance thresholds failed; see " + str(bundle / "summary.json"))


def index_traces(bundle, processor):
    traces = sorted(bundle.rglob("*.pftrace"))
    db = sqlite3.connect(bundle / "traces.sqlite3")
    db.execute("CREATE TABLE IF NOT EXISTS slices (trace TEXT, id INTEGER, parent_id INTEGER, name TEXT, category TEXT, ts_ns INTEGER, dur_ns INTEGER, track_id INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS wallclock (trace TEXT, kind TEXT, name TEXT, calls INTEGER, total_ms REAL, mean_ms REAL, max_ms REAL)")
    sql = "SELECT id,parent_id,name,category,ts,dur,track_id FROM slice WHERE dur>=0 ORDER BY ts"
    for trace in traces:
        result = subprocess.run([processor, "query", str(trace), sql], text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError("Perfetto slice query failed for " + trace.name + ": " + result.stderr.strip()[-300:])
        rows = []
        for entry in csv.DictReader(result.stdout.splitlines()):
            rows.append((str(trace.relative_to(bundle)), int(entry["id"]),
                         None if entry["parent_id"] == "[NULL]" else int(entry["parent_id"]),
                         entry["name"], None if entry["category"] == "[NULL]" else entry["category"],
                         int(entry["ts"]), int(entry["dur"]), int(entry["track_id"])))
        db.executemany("INSERT INTO slices VALUES (?,?,?,?,?,?,?,?)", rows)
        groups = {}
        for entry in rows:
            name = entry[3]
            kind = "function" if "::" in name or name.startswith("GDScript") else "zone"
            key = (entry[0], kind, name)
            groups.setdefault(key, []).append(entry[6] / 1e6)
        db.executemany("INSERT INTO wallclock VALUES (?,?,?,?,?,?,?)",
                       [(trace_name, kind, name, len(values), sum(values),
                         sum(values) / len(values), max(values))
                        for (trace_name, kind, name), values in groups.items()])
    db.commit()
    db.close()


def query(bundle, sql):
    if not re.fullmatch(r"(?is)\s*select\s+[^;]+", sql):
        raise ValueError("perf-query accepts one SELECT only")
    db = sqlite3.connect(bundle / "traces.sqlite3")
    db.execute("PRAGMA query_only=ON")
    writer = csv.writer(os.sys.stdout)
    cursor = db.execute(sql)
    writer.writerow([field[0] for field in cursor.description])
    writer.writerows(cursor)

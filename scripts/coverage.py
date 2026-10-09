#!/usr/bin/env python3
"""Capture Foundry relay executable-line coverage with separate test/app images.

Requires an already prepared Linux/system-OpenSSL Titan SDK, GCC/matching gcov,
and gcovr8.4. Never installs a compiler, changes the SDK, or runs CI. Run A uses
the measured full runner and ordinary app; run B uses the ordinary process test
and measured app. Only the two compatible measured manifests are merged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

MODULES = ("main", "relay.api", "relay.config", "relay.hub", "relay.router",
           "relay.server", "relay.store", "relay.wire")
TEST_ROOTS = ("tests.router_test", "tests.store_test", "tests.api_test",
              "tests.protocol_test", "tests.integration_test", "tests.process_test")
PROCESS_FILTER = "^tests[.]process_test[.]"


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def resolve_tool(value):
    path = shutil.which(value) if not os.path.isabs(value) else value
    require(path and Path(path).is_file(), "Missing executable: " + value)
    return str(Path(path).resolve())


class Workflow:
    def __init__(self, args):
        self.args = args
        self.project = args.project.resolve(strict=True)
        self.sdk = args.sdk.resolve(strict=True)
        self.titan = args.titan_source.resolve(strict=True)
        self.output = args.output.resolve()
        for producer in (self.project, self.sdk, self.titan):
            require(not self.output.is_relative_to(producer), "Output must be outside producer trees")
        os.umask(0o077)
        self.output.mkdir(parents=True, mode=0o700, exist_ok=False)
        self.logs = self.output / "logs"
        self.logs.mkdir()
        self.cc, self.gcov, self.gcovr = map(resolve_tool, (args.cc, args.gcov, args.gcovr))
        self.titanc = self.sdk / "bin/titanc"
        self.coverage = self.sdk / "bin/titan-coverage"
        require(self.titanc.is_file() and self.coverage.is_file(), "SDK requires installed titanc and titan-coverage")
        require(self.coverage.read_bytes().startswith(b"#!/usr/bin/env python3"), "Installed coverage frontend is not the expected Python script")
        require(digest(self.coverage) == digest(self.titan / "titan-coverage"), "Installed coverage host differs from pinned source")
        self.host = [sys.executable, str(self.coverage)]
        self.modules = [name.replace(".", "/") + ".titan" for name in MODULES]
        production = {"main.titan", *(str(p.relative_to(self.project)) for p in (self.project / "relay").rglob("*.titan"))}
        require(production == set(self.modules), "Production inventory changed; explicitly revise all8 measured modules")
        self.test_files = [name.replace(".", "/") + ".titan" for name in TEST_ROOTS]
        test_owners = {str(p.relative_to(self.project)) for p in (self.project / "tests").rglob("*.titan")
                       if not p.is_relative_to(self.project / "tests/fixtures")}
        require(test_owners == set(self.test_files), "Test inventory changed; explicitly revise native test owners")
        self.relative_inputs = self.modules + self.test_files + ["Makefile", "TITAN_REVISION"]
        fixtures = self.project / "tests/fixtures"
        if fixtures.is_dir():
            self.relative_inputs += [str(p.relative_to(self.project)) for p in sorted(fixtures.rglob("*")) if p.is_file()]
        self.originals = {name: digest(self.project / name) for name in self.relative_inputs}
        self.expected_tests = set()
        for module, filename in zip(TEST_ROOTS, self.test_files):
            source = (self.project / filename).read_text(encoding="utf-8")
            names = re.findall(r"^function\s+(test_[A-Za-z0-9_]+)\s*\(", source, re.M)
            require(names, "Native test root has no public cases: " + module)
            self.expected_tests.update(module + "." + name for name in names)
        self.sdk_files = ["bin/titanc", "bin/titan-coverage", "lib/titan/0.6/titan.a",
                          "lib/titan/0.6/titan.so", "lib/titan/0.6/libtitan.a",
                          "share/titan/0.6/src/titan/test.titan", "etc/titan/build-profile"]
        payload = "lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc"
        if (self.sdk / payload).is_file():
            self.sdk_files.append(payload)
        self.sdk_hashes = {name: digest(self.sdk / name) for name in self.sdk_files}
        self.staged = []
        self.configuration = self.output / "configuration.json"
        self.environment = self.clean_environment()
        head = self.command("source-revision", ["/usr/bin/git", "-C", str(self.titan), "rev-parse", "HEAD"], self.output, self.environment).strip()
        source_status = self.command("source-status", ["/usr/bin/git", "-C", str(self.titan), "status", "--porcelain", "--untracked-files=no"], self.output, self.environment)
        require(not source_status.strip(), "--titan-source contains tracked changes")
        declared = (self.project / "TITAN_REVISION").read_text(encoding="utf-8").strip()
        require(re.fullmatch(r"[0-9a-f]{40}", declared) and head == declared, "TITAN_REVISION does not match --titan-source")
        save(self.configuration, {
            "project": str(self.project), "sdk": str(self.sdk), "declared_titan_revision": declared,
            "titan_source": str(self.titan), "source_head": head, "source_tracked_clean": True,
            "sdk_identity_note": "Actual file hashes, not authentication of the SDK as the declared source revision; retain its separate preparation provenance.",
            "original_inputs": self.originals, "sdk_inputs": self.sdk_hashes,
            "helper": {"path": str(Path(__file__).resolve()), "sha256": digest(__file__)},
            "modules": list(MODULES), "test_roots": list(TEST_ROOTS), "expected_public_tests": sorted(self.expected_tests),
            "cc": self.cc, "gcov": self.gcov, "gcovr": self.gcovr,
            "jobs": args.jobs, "timeout": args.timeout, "openssl_mode": "system",
            "removed_environment_names": self.removed_environment_names,
            "capture_a": "measured full runner -> ordinary app",
            "capture_b": "ordinary process-test runner -> measured app", "process_filter": PROCESS_FILTER,
        })

    def clean_environment(self):
        prefixes = ("TITAN_", "GCOV", "LLVM_PROFILE", "LUA_PATH", "LUA_CPATH", "LUA_INIT",
                    "RELAY_", "FOUNDRY_", "CCACHE_", "MISE_")
        names = {"CFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS", "CC", "CXX", "AR", "RANLIB", "ARFLAGS",
                 "MAKEFLAGS", "MFLAGS", "TEST_ARGS", "TEST_FILTER", "BUSTED_FILTER", "ROCKS_TREE", "PREFIX",
                 "LD_PRELOAD", "LD_LIBRARY_PATH", "GCOV_ERROR_FILE", "OS", "BASH_ENV", "ENV",
                 "GCC_EXEC_PREFIX", "COMPILER_PATH", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
                 "LIBRARY_PATH", "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_SYSROOT_DIR"}
        self.removed_environment_names = sorted(name for name in os.environ if name in names or name.startswith(prefixes))
        env = {name: value for name, value in os.environ.items() if name not in self.removed_environment_names}
        env.update(PATH=os.pathsep.join(dict.fromkeys((str(self.sdk / "bin"), str(Path(sys.executable).parent), "/usr/bin", "/bin"))),
                   CC=self.cc, AR="/usr/bin/ar", RANLIB="/usr/bin/ranlib", GCOV=self.gcov,
                   TITAN_BUILD_PROFILE="validation", TITAN_JOBS=str(self.args.jobs), TITAN_PROBE_CACHE_DISABLE="1",
                   TITAN_ROCKS_ROOT=str(self.sdk), TITAN_PATH_0_6=str(self.sdk / "lib/titan/0.6"),
                   LC_ALL="C", LANG="C")
        return env

    def image_environment(self, name):
        root = self.output / "resources" / name
        for child in ("tmp", "cache", "preparation-counters"):
            (root / child).mkdir(parents=True)
        env = dict(self.environment)
        env.update(TMPDIR=str(root / "tmp"), TMP=str(root / "tmp"), TEMP=str(root / "tmp"),
                   CCACHE_DIR=str(root / "cache"), XDG_CACHE_HOME=str(root / "cache"),
                   GCOV_PREFIX=str(root / "preparation-counters"), GCOV_PREFIX_STRIP="0")
        return env

    def command(self, label, argv, cwd, env):
        argv = [str(part) for part in argv]
        receipt = self.logs / (label + ".json")
        explicit = {name: env[name] for name in sorted(env) if name.startswith(("TITAN_", "GCOV", "RELAY_TEST_")) or name in ("CC", "AR", "RANLIB", "PATH", "TMPDIR", "TMP", "TEMP", "CCACHE_DIR", "XDG_CACHE_HOME")}
        record = {"argv": argv, "cwd": str(cwd), "environment": explicit}
        save(receipt, record)
        print("[coverage] " + label + ": " + shlex.join(argv), flush=True)
        result = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace", check=False)
        (self.logs / (label + ".log")).write_text(result.stdout, encoding="utf-8")
        record["exit_status"] = result.returncode
        save(receipt, record)
        require(result.returncode == 0, label + " failed; see " + str(self.logs / (label + ".log")))
        return result.stdout

    def stage(self, name):
        path = self.output / "sources" / name
        path.mkdir(parents=True)
        for relative in self.relative_inputs:
            destination = path / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.project / relative, destination)
            require(digest(destination) == self.originals[relative], "Source changed while staging: " + relative)
            self.staged.append(destination)
        return path

    def build_ordinary(self, name, target):
        stage, env = self.stage(name), self.image_environment(name)
        # Separate copies keep Make's own app-src/test-src and build/tmp private.
        self.command(name, ["/usr/bin/make", "-j1", target, "TITANC=" + str(self.titanc),
                           "TITAN_JOBS=" + str(self.args.jobs), "TITAN_STDLIB=" + str(self.sdk / "lib/titan/0.6"),
                           "OPENSSL_MODE=system", "PKG_CONFIG=/usr/bin/pkg-config"], stage, env)
        self.staged.extend(sorted(p for p in (stage / "build").rglob("*.titan") if p.is_file()))
        return stage / target

    def build_measured(self, name, test):
        stage, env = self.stage(name), self.image_environment(name)
        # Match compile-prefix/link settings across both manifests. Coverage owns
        # actual instrumentation; these are ordinary validation/SDK link inputs.
        cpp = self.command(name + "-openssl-cpp", ["/usr/bin/pkg-config", "--cflags", "openssl"], stage, env).strip()
        ld = self.command(name + "-openssl-ld", ["/usr/bin/pkg-config", "--libs", "openssl"], stage, env).strip()
        env.update(TITAN_EXTRA_CPPFLAGS=cpp, TITAN_EXTRA_CFLAGS="-O0 -fno-lto", TITAN_EXTRA_LDFLAGS=ld + " -O0 -fno-lto")
        build = self.output / "images" / name
        argv = [self.titanc, "--static", "-j", str(self.args.jobs), "--tree", stage,
                "--coverage", build, "--coverage-root", self.project,
                "--coverage-source-map", str(stage) + "=" + str(self.project), "--coverage-gcov", self.gcov]
        for module in MODULES:
            argv.extend(("--coverage-module", module))
        if test:
            argv.extend(("--test", *TEST_ROOTS))
        else:
            argv.append("main")
        self.command(name, argv, stage, env)
        manifest = build / "build.json"
        current = load(manifest)
        require({source["report_path"] for source in current["sources"]} == set(self.modules), "Measured inventory lost or gained sources")
        executable = build / "bin" / ("tests/router_test" if test else "main")
        require(executable.is_file(), "Expected coverage executable missing: " + str(executable))
        return manifest, executable

    def seal(self, name, manifest, ordinary_app, ordinary_runner):
        inputs = [self.configuration, Path(__file__).resolve(), ordinary_app, ordinary_runner]
        inputs += [self.project / name for name in self.relative_inputs] + self.staged
        argv = self.host + ["seal", "--manifest", str(manifest), "--cc", self.cc, "--gcov", self.gcov]
        for path in sorted(set(inputs)):
            argv.extend(("--unmeasured-input", str(path)))
        self.command(name, argv, self.output, self.image_environment(name))

    def audit_tests(self, name, text, expected):
        runs = re.findall(r"^\[ RUN      \] (.+)$", text, re.M)
        selected = re.findall(r"^\[==========\] ([0-9]+) tests? ran\.$", text, re.M)
        passed = re.findall(r"^\[  PASSED  \] ([0-9]+) tests?\.$", text, re.M)
        require(len(selected) == len(passed) == 1, name + " missing unique native test summary")
        count = int(selected[0])
        require(count > 0 and count == int(passed[0]) == len(runs) == len(set(runs)), name + " test selection/pass counts disagree")
        require(not re.search(r"^\[ (?: SKIPPED | FAILED  )\]", text, re.M), name + " contains skipped/failed tests")
        require(expected <= set(runs), name + " omitted public tests: " + repr(sorted(expected - set(runs))))
        if name == "capture-b":
            require(set(runs) == expected, "Process capture unexpectedly selected additional tests")
        evidence = {"selected": count, "passed": count, "skipped": 0, "expected_public_cases": sorted(expected), "observed_cases": runs}
        save(self.output / (name + "-selection.json"), evidence)
        return evidence

    def capture(self, name, manifest, runner, app, expected, filtered=False):
        run = self.output / "runs" / name
        env = self.image_environment(name)
        env.pop("GCOV_PREFIX")
        env.pop("GCOV_PREFIX_STRIP")
        env["RELAY_TEST_EXECUTABLE"] = str(app)
        argv = self.host + ["run", "--manifest", str(manifest), "--run", str(run), "--timeout", str(self.args.timeout), "--", str(runner)]
        if filtered:
            argv.append("--filter=" + PROCESS_FILTER)
        output = self.command(name, argv, self.output, env)
        receipt = load(run / "run.json")
        require(receipt.get("version") == 2 and receipt.get("state") == "complete" and receipt.get("exit_status") == 0,
                name + " incomplete or failed; refuse baseline")
        require(receipt.get("process_group_empty_confirmed") is True and receipt.get("group_retirement_requested") is False,
                name + " did not finish its owned process group normally")
        self.audit_tests(name, output, expected)
        return run

    def unchanged(self):
        require({name: digest(self.project / name) for name in self.relative_inputs} == self.originals, "Original application inputs changed during workflow")
        require({name: digest(self.sdk / name) for name in self.sdk_files} == self.sdk_hashes, "SDK inputs changed during workflow")

    def run(self):
        ordinary_app = self.build_ordinary("ordinary-app", "build/foundry-relay")
        ordinary_runner = self.build_ordinary("ordinary-tests", "build/relay-tests")
        test_manifest, measured_runner = self.build_measured("measured-tests", test=True)
        app_manifest, measured_app = self.build_measured("measured-app", test=False)
        self.unchanged()
        self.seal("seal-tests", test_manifest, ordinary_app, ordinary_runner)
        self.seal("seal-app", app_manifest, ordinary_app, ordinary_runner)
        run_a = self.capture("capture-a", test_manifest, measured_runner, ordinary_app, self.expected_tests)
        process_cases = {name for name in self.expected_tests if name.startswith("tests.process_test.")}
        run_b = self.capture("capture-b", app_manifest, ordinary_runner, measured_app, process_cases, filtered=True)
        self.unchanged()
        report = self.output / "report"
        self.command("report", self.host + ["report", "--manifest", str(test_manifest), "--manifest", str(app_manifest),
                     "--run", str(run_a), "--run", str(run_b), "--output", str(report), "--gcovr", self.gcovr],
                     self.output, self.image_environment("report"))
        summary = load(report / "summary.json")
        require(summary.get("complete") is True and summary.get("tests_passed") is True,
                "Report is incomplete or tests failed; refuse baseline")
        require(len(summary.get("manifest_ids", [])) == 2 and len(summary.get("runs", [])) == 2, "Report provenance omitted an image/run")
        paths = {str((self.project / item["file"]).resolve().relative_to(self.project))
                 for item in load(report / "lines.json")["files"]}
        require(paths == set(self.modules), "Final report omitted zero-hit production files or included tests/SDK")
        self.unchanged()
        save(self.output / "result.json", {"complete": True, "tests_passed": True, "configuration": str(self.configuration),
             "measured_modules": list(MODULES), "manifest_ids": summary["manifest_ids"], "runs": [str(run_a), str(run_b)],
             "report": str(report), "lines_covered": summary["lines_covered"], "lines_total": summary["lines_total"],
             "line_percent": summary["line_percent"], "original_inputs_unchanged": True, "sdk_inputs_unchanged": True})
        print(json.dumps(load(self.output / "result.json"), indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--titan-source", type=Path, required=True, help="Clean source checkout matching project's TITAN_REVISION")
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New private output directory outside source/SDK trees")
    parser.add_argument("--gcovr", required=True)
    parser.add_argument("--cc", default="/usr/bin/gcc")
    parser.add_argument("--gcov", default="/usr/bin/gcov")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    parser.error("jobs and timeout must be positive") if args.jobs < 1 or args.timeout < 1 else None
    Workflow(args).run()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("coverage workflow: " + str(error), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Exercise the production Gradle test listener using local, pinned fixture jars."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import textwrap
import time
import uuid
import xml.etree.ElementTree as ET

JARS = (
    ("junit", "junit", "4.13.2"),
    ("org.hamcrest", "hamcrest-core", "1.3"),
    ("org.junit.jupiter", "junit-jupiter-api", "5.11.4"),
    ("org.junit.jupiter", "junit-jupiter-engine", "5.11.4"),
    ("org.junit.jupiter", "junit-jupiter-params", "5.11.4"),
    ("org.junit.platform", "junit-platform-launcher", "1.11.4"),
    ("org.junit.platform", "junit-platform-engine", "1.11.4"),
    ("org.junit.platform", "junit-platform-commons", "1.11.4"),
    ("org.opentest4j", "opentest4j", "1.3.0"),
    ("org.apiguardian", "apiguardian-api", "1.1.2"),
)


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(data).lstrip(), encoding="utf-8")


class Fixture:
    def __init__(self, root, gradle, java_home, jar_cache):
        self.root = root.resolve()
        self.root.mkdir(parents=True)
        self.gradle = gradle.resolve()
        self.environment = dict(os.environ, JAVA_HOME=str(java_home.resolve()),
                                GRADLE_USER_HOME=str(self.root / "gradle-home"))
        self.lib = self.root / "lib"
        self.lib.mkdir()
        for group, name, version in JARS:
            source = next((jar_cache / group / name / version).glob(f"*/{name}-{version}.jar"))
            shutil.copy2(source, self.lib)
        source = (Path(__file__).resolve().parents[1] / "Sources/JavaIntelligence/Testing/GradleTestSidecar.swift").read_text()
        self.listener = self.root / "events.init.gradle"
        write(self.listener, source.split('#"""', 1)[1].split('"""#', 1)[0])
        self.materialize()

    def materialize(self):
        write(self.root / "settings.gradle", """
            rootProject.name = 'fixture'
            include 'alpha', 'beta', 'platform', 'workers', 'crash', 'delay'
            includeBuild('included')
        """)
        write(self.root / "gradle.properties", "org.gradle.workers.max=4\n")
        write(self.root / "included/settings.gradle", "rootProject.name = 'included'\n")
        for module in ("alpha", "beta", "included", "workers", "crash", "delay"):
            write(self.root / module / "build.gradle", """
                plugins { id 'java' }
                dependencies { testImplementation fileTree('../lib') }
                test { maxParallelForks = 2 }
            """)
        for module in ("alpha", "beta", "included"):
            failure = 'fail("unexpected")' if module != "included" else ""
            write(self.root / module / "src/test/java/fixture/SameTest.java", f"""
                package fixture;
                import org.junit.Test;
                import static org.junit.Assert.*;
                public class SameTest {{
                    @Test public void pass() {{ System.out.print("OUTPUT-{module}"); }}
                    @Test public void {module}Only() {{ {failure}; }}
                }}
            """)
        for worker in range(4):
            write(self.root / f"workers/src/test/java/fixture/Worker{worker}Test.java", f"""
                package fixture;
                import org.junit.Test;
                public class Worker{worker}Test {{
                    @Test public void run() {{ System.out.println("WORKER-{worker}"); }}
                }}
            """)
        write(self.root / "crash/src/test/java/fixture/CrashTest.java", """
            package fixture;
            import org.junit.Test;
            public class CrashTest {
                @Test public void exitsWorker() { Runtime.getRuntime().halt(23); }
            }
        """)
        write(self.root / "delay/src/test/java/fixture/LongTest.java", """
            package fixture;
            import org.junit.Test;
            public class LongTest {
                @Test public void stopsAfterCancellation() throws Exception { Thread.sleep(60000); }
            }
        """)
        write(self.root / "platform/build.gradle", """
            plugins { id 'java' }
            testing {
                suites {
                    integrationTest(JvmTestSuite) {
                        useJUnitJupiter('5.11.4')
                        dependencies { implementation fileTree('../lib') }
                    }
                }
            }
            configurations.configureEach {
                exclude group: 'org.junit.jupiter', module: 'junit-jupiter'
                exclude group: 'org.junit.platform', module: 'junit-platform-launcher'
            }
        """)
        write(self.root / "platform/src/integrationTest/java/fixture/PlatformTest.java", """
            package fixture;
            import org.junit.jupiter.api.*;
            import org.junit.jupiter.params.*;
            import org.junit.jupiter.params.provider.*;
            import java.util.List;
            class PlatformTest {
                @ParameterizedTest @ValueSource(ints = {1, 2}) void numbers(int value) {}
                @RepeatedTest(2) void repeated() {}
                @TestFactory List<DynamicTest> dynamic() {
                    return List.of(DynamicTest.dynamicTest("dynamic child", () -> {}));
                }
                @Nested class NestedCase { @Test void nested() {} }
            }
        """)

    def invocation(self, name, tasks, instrument=True, cache=False):
        output = self.root / name
        output.mkdir()
        identifier = str(uuid.uuid4())
        arguments = [str(self.gradle), "--offline", "--console=plain", "--parallel", "--continue",
                     "--configuration-cache" if cache else "--no-configuration-cache"]
        if instrument:
            arguments += ["--init-script", str(self.listener), f"-Dumbra.test.session={identifier}",
                          f"-Dumbra.test.directory={output}"]
        return output, identifier, arguments + tasks

    def invoke(self, name, tasks, status=0, instrument=True, cache=False, worker_crash=False):
        output, identifier, arguments = self.invocation(name, tasks, instrument=instrument, cache=cache)
        with (output / "gradle.log").open("w") as log:
            process = subprocess.run(arguments, cwd=self.root, env=self.environment, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=140, check=False)
        assert process.returncode == status, (name, process.returncode, (output / "gradle.log").read_text())
        print(f"{name}: exit {status}", flush=True)
        if not instrument:
            return []
        events = [json.loads(line) for line in (output / "events.jsonl").read_bytes().splitlines()]
        assert events and all(event["version"] == 1 and event["sessionID"] == identifier for event in events)
        sequences = [event["sequence"] for event in events]
        assert sequences == sorted(set(sequences))
        started = {event["nodeID"] for event in events if event["kind"] == "testStarted"}
        finished = [event for event in events if event["kind"] == "testFinished"]
        if not worker_crash:
            assert {event["nodeID"] for event in finished} == started
        for event in finished:
            assert event["parentID"] and event["durationMs"] >= 0
        return events

    def run(self):
        matrix = self.invoke("matrix", [":alpha:test", ":beta:test", ":workers:test", ":included:test"], status=1)
        tests = [item for item in matrix if item["kind"] == "testFinished"]
        assert len(tests) == 10
        assert {item["build"] for item in tests} == {str(self.root), str(self.root / "included")}
        failures = {(item["task"], item["name"]) for item in tests if item["outcome"] == "failed"}
        assert failures == {(":alpha:test", "alphaOnly"), (":beta:test", "betaOnly")}
        assert len({item["nodeID"] for item in tests}) == 10
        offsets = [item["output"] for item in matrix if item["kind"] == "output"]
        raw = (self.root / "matrix/test-output.raw").read_bytes()
        assert b"OUTPUT-alpha" in raw and b"OUTPUT-beta" in raw
        assert len(raw) == sum(item["length"] for item in offsets)
        assert len([item for item in matrix if item.get("name", "").startswith("Gradle Test Executor")
                    and item["kind"] == "suiteStarted" and item.get("task") == ":workers:test"]) >= 2

        for module in ("alpha", "beta"):
            events = self.invoke(f"retry-{module}", [f":{module}:test", "--rerun", "--tests", f"fixture.SameTest.{module}Only"], status=1)
            assert [(item["task"], item["name"]) for item in events if item["kind"] == "testFinished"] == [
                (f":{module}:test", f"{module}Only")
            ]
        events = self.invoke("complete-rerun", [":included:test", "--rerun", ":workers:test", "--rerun"])
        assert len([item for item in events if item["kind"] == "testFinished"]) == 6
        events = self.invoke("up-to-date", [":workers:test"])
        assert not any(item["kind"] == "testStarted" for item in events)
        self.invoke("cache-first", [":workers:test", "--rerun"], instrument=False, cache=True)
        self.invoke("cache-reused", [":workers:test", "--rerun"], instrument=False, cache=True)
        assert "Reusing configuration cache" in (self.root / "cache-reused/gradle.log").read_text()
        for file in (self.root / "workers/build/test-results/test").glob("TEST-*.xml"):
            assert ET.parse(file).find("testcase") is not None

        events = self.invoke("jupiter", [":platform:integrationTest"])
        results = [item for item in events if item["kind"] == "testFinished"]
        assert len(results) == 6 and all(item["outcome"] == "passed" for item in results)


    def edge_cases(self):
        events = self.invoke("worker-crash", [":crash:test"], status=1, worker_crash=True)
        failure = next(item["failure"] for item in events if item["kind"] == "taskFinished" and item["task"] == ":crash:test")
        assert "23" in failure["stackTrace"] and "Gradle Test Executor" in failure["stackTrace"]

        self.invoke("cache-populate", [":workers:test", "--rerun", "--build-cache"])
        self.invoke("cache-clean", [":workers:clean"])
        events = self.invoke("cache-restored", [":workers:test", "--build-cache"])
        assert not any(item["kind"] == "testStarted" for item in events)
        assert "Task :workers:test FROM-CACHE" in (self.root / "cache-restored/gradle.log").read_text()

        output, identifier, arguments = self.invocation("cancel", [":delay:test"])
        with (output / "gradle.log").open("w") as log:
            process = subprocess.Popen(arguments, cwd=self.root, env=self.environment, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    journal = output / "events.jsonl"
                    if journal.exists() and b'"kind":"testStarted"' in journal.read_bytes():
                        break
                    assert process.poll() is None, (output / "gradle.log").read_text()
                    time.sleep(0.05)
                else:
                    raise TimeoutError("Long-running test did not start")
                process.terminate()
                assert process.wait(timeout=15) != 0
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
        print(f"cancel: client drained ({identifier})", flush=True)
        recovery = self.invoke("after-cancel", [":workers:test", "--rerun"])
        assert len([item for item in recovery if item["kind"] == "testFinished"]) == 4


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gradle", required=True, type=Path)
    parser.add_argument("--java-home", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path, help="New scratch directory retained with all fixture output.")
    parser.add_argument("--jar-cache", type=Path, default=Path.home() / ".gradle/caches/modules-2/files-2.1")
    parser.add_argument("--edge-cases", action="store_true", help="Also exercise a worker exit, build-cache restoration and client cancellation.")
    args = parser.parse_args()
    fixture = Fixture(args.root, args.gradle, args.java_home, args.jar_cache)
    fixture.run()
    if args.edge_cases:
        fixture.edge_cases()


if __name__ == "__main__":
    main()

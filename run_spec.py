#!/usr/bin/env python3
import subprocess
import sys
import json
import os
import re
import tempfile

SHELL = os.environ.get("TEST_SHELL", "./zig-out/bin/zigsh")
TIMEOUT = 10

def parse_spec_file(path):
    with open(path) as f:
        lines = f.readlines()

    cases = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("#### "):
            name = line[5:].strip()
            code_lines = []
            i += 1
            while i < len(lines) and not lines[i].startswith("## "):
                if not lines[i].startswith("#"):
                    code_lines.append(lines[i])
                else:
                    code_lines.append(lines[i])
                i += 1

            code = ""
            expect_stdout = None
            expect_stdout_json = None
            expect_status = 0
            is_bash_only = False
            n_i_dash = False
            stdout_block = False

            real_code_lines = []
            j = 0
            while j < len(code_lines):
                ln = code_lines[j]
                if ln.startswith("## "):
                    break
                real_code_lines.append(ln)
                j += 1
            code = "".join(real_code_lines)

            while i < len(lines):
                ln = lines[i].rstrip("\n")
                if ln.startswith("#### "):
                    break
                if ln.startswith("## STDOUT:"):
                    stdout_lines = []
                    i += 1
                    while i < len(lines) and not lines[i].startswith("## END") and not re.match(r"^## (OK|BUG\S*|N-I) ", lines[i]):
                        stdout_lines.append(lines[i])
                        i += 1
                    expect_stdout = "".join(stdout_lines)
                    if i < len(lines) and lines[i].startswith("## END"):
                        i += 1
                    continue
                if re.match(r"^## (OK|BUG) dash(/\w+)* STDOUT:", ln):
                    stdout_lines = []
                    i += 1
                    while i < len(lines) and not lines[i].startswith("## END") and not re.match(r"^## (OK|BUG\S*|N-I) ", lines[i]):
                        stdout_lines.append(lines[i])
                        i += 1
                    expect_stdout = "".join(stdout_lines)
                    if i < len(lines) and lines[i].startswith("## END"):
                        i += 1
                    continue
                if re.match(r"^## N-I dash(/\w+)* STDOUT:", ln):
                    i += 1
                    while i < len(lines) and not lines[i].startswith("## END") and not re.match(r"^## (OK|BUG\S*|N-I) ", lines[i]):
                        i += 1
                    if i < len(lines) and lines[i].startswith("## END"):
                        i += 1
                    n_i_dash = True
                    continue
                if re.match(r"^## (OK|BUG\S*|N-I) \S+ STDOUT:", ln) and not re.match(r"^## (OK|BUG|N-I) dash(/\w+)* STDOUT:", ln):
                    i += 1
                    while i < len(lines) and not lines[i].startswith("## END") and not re.match(r"^## (OK|BUG\S*|N-I) ", lines[i]):
                        i += 1
                    if i < len(lines) and lines[i].startswith("## END"):
                        i += 1
                    continue
                if re.match(r"^## N-I dash(/\w+)*\b", ln):
                    n_i_dash = True
                m = re.match(r"^## code: (.*)$", ln)
                if m:
                    code = m.group(1) + "\n"
                m = re.match(r"^## stdout: (.*)$", ln)
                if m:
                    if expect_stdout is None:
                        expect_stdout = m.group(1) + "\n"
                m = re.match(r'^## stdout-json: "(.*)"$', ln)
                if m:
                    if expect_stdout is None:
                        try:
                            expect_stdout_json = json.loads('"' + m.group(1) + '"')
                        except:
                            pass
                m = re.match(r"^## status: (\d+)$", ln)
                if m:
                    expect_status = int(m.group(1))
                if re.match(r"^## BUG (bash|mksh|zsh|dash(/\w+)*)", ln):
                    m_bug_stdout = re.match(r'^## BUG dash(/\w+)* stdout: (.*)$', ln)
                    if m_bug_stdout:
                        expect_stdout = m_bug_stdout.group(2) + "\n"
                    m_bug_stdout_json = re.match(r'^## BUG dash(/\w+)* stdout-json: "(.*)"$', ln)
                    if m_bug_stdout_json:
                        try:
                            expect_stdout_json = json.loads('"' + m_bug_stdout_json.group(2) + '"')
                            expect_stdout = None
                        except:
                            pass
                    m_bug_status = re.match(r'^## BUG dash(/\w+)* status: (\d+)$', ln)
                    if m_bug_status:
                        expect_status = int(m_bug_status.group(2))
                if re.match(r"^## OK dash(/\w+)* stdout", ln):
                    m2 = re.match(r'^## OK dash(/\w+)* stdout: (.*)$', ln)
                    if m2:
                        expect_stdout = m2.group(2) + "\n"
                    m2 = re.match(r'^## OK dash(/\w+)* stdout-json: "(.*)"$', ln)
                    if m2:
                        try:
                            expect_stdout_json = json.loads('"' + m2.group(2) + '"')
                            expect_stdout = None
                        except:
                            pass
                m = re.match(r"^## OK dash(/\w+)* status: (\d+)$", ln)
                if m:
                    expect_status = int(m.group(2))
                m = re.match(r"^## N-I dash(/\w+)* status: (\d+)$", ln)
                if m:
                    n_i_dash = True
                i += 1

            if expect_stdout_json is not None and expect_stdout is None:
                expect_stdout = expect_stdout_json

            cases.append({
                "name": name,
                "code": code,
                "expect_stdout": expect_stdout,
                "expect_status": expect_status,
                "n_i_dash": n_i_dash,
            })
        else:
            i += 1

    return cases


def run_case(case):
    code = case["code"]
    with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
        f.write(code)
        f.flush()
        fname = f.name

    try:
        result = subprocess.run(
            [SHELL, fname],
            capture_output=True,
            timeout=TIMEOUT,
            env={
                **os.environ,
                "PATH": os.path.join(os.path.dirname(os.path.abspath(__file__)), "oil", "spec", "bin")
                    + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                "SH": os.path.abspath(SHELL),
                "TMP": tempfile.mkdtemp(),
                "REPO_ROOT": os.path.dirname(os.path.abspath(__file__)),
            },
        )
        stdout = result.stdout.decode("utf-8", errors="replace")
        status = result.returncode
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "timed out"
    except Exception as e:
        return "ERROR", str(e)
    finally:
        os.unlink(fname)

    if case["n_i_dash"]:
        return "N-I", "not implemented in dash"

    errors = []
    if case["expect_stdout"] is not None:
        if stdout != case["expect_stdout"]:
            errors.append(f"stdout: expected {case['expect_stdout']!r}, got {stdout!r}")
    if status != case["expect_status"]:
        errors.append(f"status: expected {case['expect_status']}, got {status}")

    if errors:
        return "FAIL", "; ".join(errors)
    return "PASS", ""


def main():
    if len(sys.argv) < 2:
        print("Usage: run_spec.py <spec-file> [--only-failures]")
        sys.exit(1)

    spec_file = sys.argv[1]
    only_failures = "--only-failures" in sys.argv
    cases = parse_spec_file(spec_file)

    passed = 0
    failed = 0
    ni = 0
    errors = 0
    timeouts = 0
    failures = []

    for case in cases:
        result, msg = run_case(case)
        if result == "PASS":
            passed += 1
        elif result == "N-I":
            ni += 1
        elif result == "TIMEOUT":
            timeouts += 1
            failures.append((case["name"], msg))
        elif result == "ERROR":
            errors += 1
            failures.append((case["name"], msg))
        else:
            failed += 1
            failures.append((case["name"], msg))

    total = passed + failed + ni + errors + timeouts
    print(f"{os.path.basename(spec_file)}: {passed}/{total} passed, {failed} failed, {ni} N-I, {errors} errors, {timeouts} timeouts")

    if failures and not only_failures:
        for name, msg in failures:
            print(f"  FAIL: {name}: {msg}")

    if only_failures:
        for name, msg in failures:
            print(f"  FAIL: {name}: {msg}")

    return 0 if failed == 0 and errors == 0 and timeouts == 0 else 1


if __name__ == "__main__":
    main()

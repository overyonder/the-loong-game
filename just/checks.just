# Apply Python syntax, lint and formatting checks to inline command bodies.
[group("Checks")]
check-recipes:
    #!/usr/bin/env -S {{quote(python)}}
    import json
    import subprocess

    dump = subprocess.check_output(["just", "--dump", "--dump-format", "json"], text=True)
    checked = 0
    for name, recipe in json.loads(dump)["recipes"].items():
        body = recipe["body"]
        if not body or not str(body[0][0]).startswith("#!"):
            continue
        if "python" not in json.dumps(body[0]):
            continue
        # Keep interpolation in the interpreter line, leaving Python as Python.
        if any(not isinstance(part, str) for line in body[1:] for part in line):
            raise ValueError(f"{name}: use arguments or environment, not interpolation")
        source = "\n".join("".join(line) for line in body[1:]) + "\n"
        filename = f"{name}.py"
        compile(source, filename, "exec")
        for operation in (["check"], ["format", "--check"]):
            result = subprocess.run(
                ["ruff", *operation, "--stdin-filename", filename, "-"],
                input=source,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode:
                raise SystemExit(
                    f"{name}: ruff {' '.join(operation)} failed\n"
                    f"{result.stdout}{result.stderr}"
                )
        checked += 1
    print(f"Checked {checked} inline Python recipes")

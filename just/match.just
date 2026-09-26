# One organiser process, its complete log, timeout and descendant cleanup.
[private]
_match log timeout +command:
    #!/usr/bin/env -S {{quote(python)}}
    import json
    import os
    import signal
    import subprocess
    import sys
    from pathlib import Path

    log_path = Path(sys.argv[1])
    timeout = float(sys.argv[2])
    with log_path.open("w") as output:
        process = subprocess.Popen(
            sys.argv[3:],
            stdout=output,
            stderr=subprocess.STDOUT,
            env={**os.environ, "NO_COLOR": "1"},
            start_new_session=True,
        )
        timed_out = False
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            code, timed_out = -1, True
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    print(json.dumps([code, timed_out]))


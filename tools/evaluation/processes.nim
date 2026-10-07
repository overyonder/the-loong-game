## Child processes the evaluation tools run, with Python's `subprocess`
## conventions for what the records keep: an exit code, or the negated signal
## that ended the process.

import std/[os, posix, times]

proc selfExecutable*(): string =
  ## The running tool's own binary, for starting copies of itself. A rebuild
  ## renames a new binary into place, after which the path `getAppFilename`
  ## reads from /proc/self/exe names the deleted file; /proc/self/exe itself,
  ## executed, still starts the binary this process runs.
  when defined(linux): "/proc/self/exe" else: getAppFilename()

proc runQuietly*(arguments: seq[string], cwd = "", timeout = 0.0,
                 output = "/dev/null"): tuple[code: int, timedOut: bool] =
  ## Run `arguments` with standard input from /dev/null and its output and
  ## errors to `output`, waiting at most `timeout` wall seconds (0 for no
  ## limit); a process past it is killed and reported as (-9, true).
  let pid = fork()
  if pid < 0: raiseOSError(osLastError())
  if pid == 0:
    if cwd.len > 0 and chdir(cwd.cstring) != 0: exitnow(127)
    let input = posix.open("/dev/null", O_RDONLY)
    let sink = posix.open(output.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
    if input < 0 or sink < 0: exitnow(127)
    discard dup2(input, 0)
    discard dup2(sink, 1)
    discard dup2(sink, 2)
    let argv = allocCStringArray(arguments)
    discard execvp(arguments[0].cstring, argv)
    exitnow(127)
  let deadline = if timeout > 0: epochTime() + timeout else: Inf
  var status: cint
  while true:
    let done = waitpid(pid, status, WNOHANG)
    if done == pid: break
    if done < 0 and errno != EINTR: raiseOSError(osLastError())
    if epochTime() >= deadline:
      discard kill(pid, SIGKILL)
      discard waitpid(pid, status, 0)
      return (-9, true)
    sleep(20)
  if WIFSIGNALED(status): (-int(WTERMSIG(status)), false) else: (int(WEXITSTATUS(status)), false)

type Child* = object
  ## A process started by `spawnChild`, its standard output on a pipe.
  pid*:    Pid
  output:  cint
  tag*:    int      ## the caller's name for it

proc spawnChild*(arguments: seq[string], tag: int, cwd = "", ownGroup = false): Child =
  ## Start `arguments` with standard input from /dev/null, standard errors
  ## inherited and standard output collected for `waitAnyChild`. With
  ## `ownGroup` it leads a process group of its own, so killing that group
  ## (`kill(-pid, ...)`) ends it and everything it started.
  var pipeEnds: array[2, cint]
  if pipe(pipeEnds) != 0: raiseOSError(osLastError())
  let pid = fork()
  if pid < 0: raiseOSError(osLastError())
  if pid == 0:
    if ownGroup: discard setpgid(0, 0)
    if cwd.len > 0 and chdir(cwd.cstring) != 0: exitnow(127)
    let input = posix.open("/dev/null", O_RDONLY)
    discard dup2(input, 0)
    discard dup2(pipeEnds[1], 1)
    discard close(pipeEnds[0])
    discard close(pipeEnds[1])
    let argv = allocCStringArray(arguments)
    discard execvp(arguments[0].cstring, argv)
    exitnow(127)
  discard close(pipeEnds[1])
  Child(pid: pid, output: pipeEnds[0], tag: tag)

proc readAllFrom(fd: cint): string =
  var buffer = newString(65536)
  while true:
    let count = read(fd, buffer[0].addr, buffer.len)
    if count < 0:
      if errno == EINTR: continue
      raiseOSError(osLastError())
    if count == 0: break
    result.add buffer[0 ..< count]
  discard close(fd)

proc finishChild*(child: Child): tuple[code: int, output: string] =
  ## Read everything `child` printed and wait for it to end.
  result.output = readAllFrom(child.output)
  var status: cint
  while waitpid(child.pid, status, 0) < 0:
    if errno != EINTR: raiseOSError(osLastError())
  result.code = if WIFSIGNALED(status): -int(WTERMSIG(status)) else: int(WEXITSTATUS(status))

proc waitAnyChild*(children: var seq[Child]): tuple[tag, code: int, output: string] =
  ## Wait for whichever of `children` ends first, remove it and return what
  ## it printed. Each child prints little, so its pipe never fills first.
  var status: cint
  while true:
    let pid = waitpid(-1, status, 0)
    if pid < 0:
      if errno == EINTR: continue
      raiseOSError(osLastError())
    for index, child in children:
      if child.pid == pid:
        let code = if WIFSIGNALED(status): -int(WTERMSIG(status)) else: int(WEXITSTATUS(status))
        result = (child.tag, code, readAllFrom(child.output))
        children.delete(index)
        return

type InterruptError* = object of CatchableError
  ## Ctrl-C, raised where a long loop next checks for it, so `finally`
  ## blocks run: a fleet run terminates its workers and records its cost.

var interrupted = false

proc installInterrupt*() =
  ## Turn SIGINT into an `InterruptError` at the next `checkInterrupt`.
  setControlCHook(proc () {.noconv.} = interrupted = true)

proc checkInterrupt*() =
  if interrupted: raise newException(InterruptError, "interrupted")

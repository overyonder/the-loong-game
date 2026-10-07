## Whole-file advisory locks (BSD `flock`), the kind every evaluation tool
## takes on registry entries, compile slots and the game cache, so separate
## processes serialise on them.

import std/[os, posix]

proc flock(fd: cint, operation: cint): cint {.importc, header: "<sys/file.h>".}
var
  LockExclusive {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
  LockNonBlocking {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint

proc lockExclusive*(file: File) =
  ## Wait for and take `file`'s exclusive lock; closing the file releases it.
  while flock(file.getFileHandle, LockExclusive) != 0:
    if errno != EINTR: raiseOSError(osLastError())

proc tryLockExclusive*(file: File): bool =
  ## Take `file`'s exclusive lock if no other holder has it.
  flock(file.getFileHandle, LockExclusive or LockNonBlocking) == 0

proc withLock*(path: string, body: proc ()) =
  ## Run `body` holding the exclusive lock on `path`, created if missing.
  let file = open(path, fmWrite)
  defer: file.close()
  lockExclusive(file)
  body()

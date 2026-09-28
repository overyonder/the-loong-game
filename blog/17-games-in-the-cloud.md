# Games in the cloud

> **Editor's note, 28 September 2026.** I've reworded the opening to say what the games are for: playing the bot against a pool of opponents to find what it gets wrong. The workers now play every game in our own Zig judge, which cut the cost of a run by more than half.

The [harness](03-the-evaluation-harness.md) plays games side by side on every core of one machine, and for a while that was enough. Then the work got bigger. Playing our bot against a pool of opponents across 120 maps, both sides and several seeds runs to thousands of games, and the games it loses are what tell us what to fix next. My desktop could grind through them overnight, but it's also the machine several of us work on, and every hour spent waiting for games is an hour before the next fault turns up.

So big batches now go to a fleet of cloud machines, and this post explains how it's built. The short version is that a handful of long-lived AWS resources are declared in OpenTofu, everything a run needs is created by the launcher when the run starts, and every run is built to end on its own, even if everything watching it dies.

![The fleet. Standing resources, declared in OpenTofu: the buckets, which hold run bundles and results, expire objects after 14 days and block public access; the fleet user, which launches, tags and terminates tagged Spot workers and runs queues; and the worker role, which reads the run's bundle, writes results and leases jobs from its queue. Made for each run by the launcher: the launcher packs workers into the vCPU allowance and checks the quota and the $50 ledger, creates one queue per run with a message per game, and starts Spot workers in Hyderabad and Mumbai, which pull games as cores free up, upload each result and shut down at the deadline. A reaper on a system timer, outside every agent, terminates any worker past its deadline.](images/fleet-run.svg)

## One run

A run starts on my machine. The launcher bundles the bots, maps and runner into one archive, uploads it to a bucket, and creates a queue with one message per game. Then it asks AWS for Spot instances, which are spare capacity sold cheaply on the understanding that it can be taken back, and packs them into the run's vCPU allowance, cheaper region first.

Each worker boots Amazon Linux, installs the official toolkit for its game engine, downloads the bundle and starts pulling games off the queue, one per free core, and plays each one in our own [Zig judge](16-the-machine-inside-the-judge.md). Every game has a wall-clock limit of 300 seconds, so a bot that hangs costs one game and five minutes of a core. A game's queue message is leased while it plays, and only acknowledged once its result is safely in the bucket, so a worker that disappears mid-game loses nothing but that game, which goes back on the queue for someone else. Back on my machine, the launcher collects results as they land, so a run that gets cut short still returns every game it finished.

The workers run in two AWS regions, Hyderabad and Mumbai, each allowed up to 320 vCPUs at once, capped by the live Spot quota. Mumbai's workers use Hyderabad's queue and bucket across the region boundary, which keeps a run in one place however its workers are spread.

## Standing resources in OpenTofu

Some things outlive any run: the buckets, the IAM user the launcher acts as, and the role the workers assume. I first made those by hand in the console and the CLI, copying JSON policy files around as the fleet grew. That works until you need to change something and can't remember what else depends on it. So they're now declared in [OpenTofu](https://opentofu.org), the open source fork of Terraform, in one file.

The permissions are the part worth reading. The fleet user can launch and tag instances only in the fleet's regions, and can only terminate instances that carry the fleet's project tag, so a bug in the launcher can't touch anything else in the account:

```hcl main.tf
{
  Effect   = "Allow"
  Action   = ["ec2:TerminateInstances"]
  Resource = "*"
  Condition = { StringEquals = {
    "aws:RequestedRegion"     = local.ec2_regions
    "ec2:ResourceTag/project" = local.fleet.project
  } }
},
```

Every name and region comes from one small JSON file that the launcher reads too, so a name is written down exactly once. The buckets expire everything after 14 days, because the launcher copies every result home as it lands, so anything still in a bucket after two weeks is no longer needed.

## Bringing hand-made resources under OpenTofu

The resources already existed, so the definition couldn't create them. OpenTofu's `import` blocks handle this: each one names an existing resource and the definition it should match.

```hcl main.tf
import {
  to = aws_iam_user.fleet
  id = local.fleet.user
}
```

The first plan shows whether the definition matches what exists, because any difference between what I'd written and what I'd clicked together earlier shows up as a change. It came back as "11 to import, 0 to add, 0 to change, 0 to destroy", so the definition matched reality exactly. After the import-only apply, the next plan said "No changes". The import blocks stay in the file, because they cost nothing once a resource is in state, and if the state file is ever lost, a plan and an apply rebuild it from AWS.

The first real change through it was adding Mumbai. The plan showed a single in-place update to the fleet user's policy: Mumbai added to the region conditions for launching, tagging, terminating and cancelling Spot requests, plus Mumbai's paths for the Amazon Linux image and the Spot quota. Nothing else moved, and the worker role needed nothing at all, because Mumbai's workers talk to Hyderabad's queue and bucket.

OpenTofu itself runs from nixpkgs through a small wrapper that decrypts an admin key for that one command, while the fleet keeps its own narrow key for day-to-day runs. The state file lives outside Git and holds no secrets, since the fleet user's access key is kept in our secrets store rather than managed by OpenTofu.

## Runs that end on their own

The fleet is the one place where a mistake costs money, and the agents that launch runs can crash, time out or be interrupted like any other program. So I wanted every run to end on its own, with no one needing to stay alive to stop it.

A run normally ends because it's finished: once every game is in, or once nothing has been committed for a while, the workers stop and shut down. Behind that, each run gets a hard deadline when it's launched, three hours out at most. The first thing a worker does when it boots is schedule its own shutdown for that moment, and an instance that shuts down is terminated. This is the line from the worker's startup script, with the deadline filled in by the launcher:

```bash
shutdown -h +$(( ({deadline} - $(date +%s) + 59) / 60 ))
```

The worker stops taking new games two minutes before the deadline and uploads what it finished. Behind that, a reaper runs every ten minutes on a system timer that belongs to no agent at all. It terminates any fleet instance past its deadline, removes orphaned queues, and records a cost for any run whose launcher died before it could.

Spending has its own guard. Every launch is written to a ledger at its worst-case cost, and the launcher refuses any launch that could take the total past $50. The ledger is our own estimate, covering compute, disks and addresses, and not an AWS billing limit, which is why it's deliberately pessimistic.

## What it costs

A two-region test with one small worker in each region, a c8i-flex.large in Hyderabad and another in Mumbai, played 8 games, four per worker, for an estimated $0.0008. Big batches scale that up, but by 26 September, eleven full runs had cost $17.51 between them, which is cheap for tens of thousands of games that would otherwise have tied up a desktop for days. Moving the games into our judge cut the compute again: 1,000 games of our main line against an older version now cost about $0.04, against $0.09 through the toolkit. At that price, downloading the replays the run keeps, about 2 GB compressed at roughly $0.11 a gigabyte, costs more than playing the games.

## Next up

[Game data in columns](18-game-data-in-columns.md): one binary format for all our game data, which a reader maps into memory and uses without parsing.

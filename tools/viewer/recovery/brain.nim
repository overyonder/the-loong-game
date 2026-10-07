## The records a bot on the k-line's design keeps in its memory, laid out as
## the contract's records (tools/viewer/diagnostics.md, "Brain from
## memory"): its Brain tree, its movement queries, its radio's rays and its
## turn's accounts. The bot shows its structure once and, at each turn's end,
## what it decided as numbers, with the trace of every calculation and check
## it made. The Brain hangs beneath the bot's own Brain root: the role and its
## alternatives, task selection with each behaviour's checks, score and
## targets, the state machine and the task's phases, the task claim and the
## orders. Every name, expression and rule text is the bot's: behaviour names,
## enum values, the source of each calculation and the rules it keeps. What
## this module adds is how the generic architectures read: how role slots
## fill, how the best pair wins, how movement ranks its options, and how a
## state machine's states came to act or not.

import std/[algorithm, intsets, json, math, strutils, tables, unicode]
import state

const
  MaxTargets = 24    ## Rows of a behaviour's targets table.
  MaxChecks = 8      ## Checks shown for a behaviour or state that found nothing.
  MaxWinners = 8     ## Members named as a role's holders.

type
  Site = object
    expression: string
    operands: seq[string]
    names: seq[seq[string]]
    condition: bool

  Trace = object
    site, first, inner: seq[int]
    result, values: seq[float]

  Turn = object
    ## One turn's records, decoded.
    sites: seq[Site]
    trace: Trace
    roles: seq[string]             ## The Role enum's values by ordinal.
    structure, roster, decided, decision, ledger, machine, phasing: JsonNode
    round: int
    nodes: seq[JsonNode]
    records: seq[JsonNode]

proc finite(x: float): bool = x.classify notin {fcNan, fcInf, fcNegInf}

proc shown(x: float): string =
  ## A number as a reason's text.
  if x == Inf: "∞"
  elif x == NegInf: "−∞"
  elif x.isNaN: "not reached"
  elif x == 0: "0"
  elif x == round(x) and abs(x) < 1e15: $int(x)
  else: formatFloat(x, ffDecimal, 3).strip(chars = {'0'}, leading = false).strip(chars = {'.'}, leading = false)

proc clip(text: string): string =
  ## A label or reason holds at most 512 characters (diagnostics.md).
  if text.runeLen <= 512: text else: text.runeSubStr(0, 510) & "…"

proc number(node: JsonNode): float =
  if node == nil: return NaN
  case node.kind
  of JInt: float(node.getBiggestInt)
  of JFloat: node.getFloat
  else: NaN

proc integer(node: JsonNode, otherwise = -1): int =
  if node != nil and node.kind == JInt: int(node.getBiggestInt) else: otherwise

proc decodeSites(node: JsonNode): seq[Site] =
  for entry in node.getElems:
    var site = Site(expression: entry{"expression"}.getStr, condition: entry{"condition"}.getBool)
    for operand in entry{"operands"}.getElems: site.operands.add operand.getStr
    for names in entry{"names"}.getElems:
      var values: seq[string]
      for name in names.getElems: values.add name.getStr
      site.names.add values
    result.add site

proc decodeTrace(node: JsonNode): Trace =
  if node == nil: return
  for working in node{"workings"}.getElems:
    result.site.add working{"site"}.integer
    result.result.add working{"result"}.number
    result.first.add working{"first"}.integer
  for value in node{"values"}.getElems: result.values.add value.number
  for inner in node{"inner"}.getElems: result.inner.add inner.integer

proc valid(turn: Turn, working: int): bool =
  working >= 0 and working < turn.trace.site.len and turn.trace.site[working] in 0 ..< turn.sites.len

proc expression(turn: Turn, working: int): string =
  if turn.valid(working): turn.sites[turn.trace.site[working]].expression else: ""

proc terms(turn: Turn, working: int, output: var seq[(string, float)],
    unreached, infinite: var seq[string], depth = 0) =
  ## A working's operands, each one whose evaluation showed a working followed
  ## by that working's own; one not reached or not finite goes to its list.
  if not turn.valid(working) or depth > 16: return
  let site = turn.sites[turn.trace.site[working]]
  for operand, name in site.operands:
    let at = turn.trace.first[working] + operand
    if at < 0 or at >= turn.trace.values.len: break
    let value = turn.trace.values[at]
    let inner = if at < turn.trace.inner.len: turn.trace.inner[at] else: -1
    var label = name
    if operand < site.names.len and site.names[operand].len > 0 and value.finite and
        int(value) in 0 ..< site.names[operand].len:
      label.add " (" & site.names[operand][int(value)] & ")"
    if value.isNaN:
      unreached.add name
      continue
    if not value.finite:
      infinite.add label & " = " & shown(value)
      continue
    if turn.valid(inner):
      output.add((label & " = " & turn.expression(inner), value))
      turn.terms(inner, output, unreached, infinite, depth + 1)
    else: output.add((label, value))

proc calculation(turn: var Turn, working: int, id, parent, label: string,
    leading: seq[(string, float)] = @[], wrap = "", result = NaN) =
  ## A working as a calculation record, its expression inside `wrap`'s `$1`
  ## and after `leading`'s operands; `result` in place of the working's own.
  if not turn.valid(working): return
  var operands = leading
  var unreached, infinite: seq[string]
  turn.terms(working, operands, unreached, infinite)
  var named = initCountTable[string]()
  var list = newJArray()
  var listed: seq[(string, float)]
  for (name, value) in operands:
    # An operand written twice is listed once.
    if (name, value) in listed: continue
    listed.add (name, value)
    named.inc name
    let unique = if named[name] > 1: name & " (" & $named[name] & ")" else: name
    list.add %*{"name": clip(unique), "value": value}
  let site = turn.sites[turn.trace.site[working]]
  let total = if result.isNaN: turn.trace.result[working] else: result
  var record = %*{"version": 1, "kind": "calculation", "id": id, "parent": parent,
    "label": clip(label & (if site.condition: (if total != 0: ": true" else: ": false") else: "")),
    "expression": clip(if wrap.len > 0: wrap % site.expression else: site.expression),
    "operands": list}
  var reasons: seq[string]
  if total.finite: record["result"] = %total
  else: reasons.add "The result is " & shown(total)
  if unreached.len > 0: reasons.add "Not reached: " & unreached.join(", ")
  if infinite.len > 0: reasons.add "Not finite: " & infinite.join(", ")
  if reasons.len > 0: record["reason"] = %clip(reasons.join(". "))
  turn.records.add record

proc outermost(turn: Turn, first, last: int): seq[int] =
  ## The workings in [first, last) that no other in the range encloses.
  if first < 0 or last <= first: return
  var enclosed: IntSet
  for working in first ..< min(last, turn.trace.site.len):
    if not turn.valid(working): continue
    let site = turn.sites[turn.trace.site[working]]
    for operand in 0 ..< site.operands.len:
      let at = turn.trace.first[working] + operand
      if at < turn.trace.inner.len and turn.trace.inner[at] >= 0: enclosed.incl turn.trace.inner[at]
  for working in first ..< min(last, turn.trace.site.len):
    if working notin enclosed: result.add working

proc checks(turn: var Turn, first, last: int, parent: string, excluded = initIntSet(),
    id = "check") =
  ## The outermost workings of a range, less `excluded`, as calculations under
  ## `parent`: what a gate or eligibility test computed, the last `MaxChecks`,
  ## since the one that decided comes last.
  var found: seq[int]
  for working in turn.outermost(first, last):
    if working notin excluded: found.add working
  for index, working in found:
    if index < found.len - MaxChecks: continue
    turn.calculation(working, parent & "-" & id & "-" & $index, parent,
      if turn.sites[turn.trace.site[working]].condition: "Check" else: "Value")

proc addNode(turn: var Turn, id, parent, label: string, active = false): JsonNode =
  result = %*{"id": id, "parent": parent, "label": clip(label), "active": active}
  turn.nodes.add result

# The role.

proc roleName(turn: Turn, ordinal: int): string =
  if ordinal in 0 ..< turn.roles.len: turn.roles[ordinal] else: "role " & $ordinal

proc roleOrdinal(turn: Turn, name: string): int = turn.roles.find(name)

proc renderRole(turn: var Turn) =
  let roster = turn.roster
  let decided = turn.decided
  let team = turn.structure{"team"}
  if roster == nil or decided == nil: return
  let members = roster{"members"}.getElems
  let own = roster{"own"}.integer
  let role = roster{"commitment"}{"role"}.getStr
  let held = roster{"previous"}.getStr
  let assigned = roster{"assigned"}.getElems
  let ownAssigned = if own in 0 ..< assigned.len: assigned[own].getStr else: ""
  let review = roster{"review"}.getStr
  let since = roster{"commitment"}{"since"}.integer
  let gates = decided{"gates"}.getElems
  let ownGates = if own in 0 ..< gates.len: gates[own].getElems else: @[]
  var detail = case review
    of "": ""
    else:
      if held != role: "It held " & held & "; it now holds " & role
      else: "It holds " & role & " since round " & $since & ", committed for " &
        $team{"commitment"}.integer & " rounds"
  if ownAssigned.len > 0 and ownAssigned != role:
    detail.add "; the assignment gives " & ownAssigned
  let heldOrdinal = turn.roleOrdinal(held)
  if review.startsWith("the role stopped being valid") and heldOrdinal in 0 ..< ownGates.len:
    let gate = ownGates[heldOrdinal].getStr
    detail.add ": " & (if gate != "open": gate
      elif roster{"held"}{"places"}.integer == 0: "the team needs none now"
      else: $roster{"held"}{"above"}.integer & " member(s) holding it outrank this dragon for " &
        $roster{"held"}{"places"}.integer & " place(s)")
  var order: seq[string]
  for slot in roster{"slots"}.getElems:
    order.add slot{"role"}.getStr & " " & $slot{"count"}.integer
  var node = turn.addNode("role", "decision", "Role: " & role, true)
  node["reason"] = %clip(capitalizeAscii(review) & ". " & detail & ". Slots fill in order, " &
    order.join(", ") & ", each place going to the unassigned member it suits best, " &
    "ties to the earlier member; the rest harvest")
  # One alternative per role a dragon can hold.
  let scores = roster{"scores"}.getElems
  let workings = decided{"workings"}.getElems
  let slotWorkings = decided{"slots"}.getElems
  for ordinal in 1 ..< turn.roles.len:
    let alternative = turn.roles[ordinal]
    var places = if alternative == "harvester": members.len else: 0
    var slotIndex = -1
    for index, slot in roster{"slots"}.getElems:
      if slot{"role"}.getStr == alternative: (places, slotIndex) = (slot{"count"}.integer, index)
    let value = if own in 0 ..< scores.len: scores[own][ordinal].number else: NaN
    let gate = if ordinal < ownGates.len: ownGates[ordinal].getStr else: "open"
    let id = "role-" & alternative
    var child = turn.addNode(id, "role", alternative, alternative == role)
    child["objective"] = %"suitability"
    child["eligible"] = %(places > 0 and value > NegInf)
    if value.finite and alternative != "harvester": child["score"] = %value
    # The members earlier slots left, best first as the assignment takes them.
    var earlier: seq[string]
    for index in 0 ..< max(slotIndex, 0): earlier.add roster{"slots"}[index]{"role"}.getStr
    var running: seq[int]
    for index in 0 ..< members.len:
      if index < assigned.len and assigned[index].getStr notin earlier and
          index < scores.len and scores[index][ordinal].number > NegInf:
        running.add index
    running.sort(proc(first, second: int): int =
      result = cmp(scores[second][ordinal].number, scores[first][ordinal].number)
      if result == 0: result = cmp(first, second))
    var reason: string
    if alternative == "harvester":
      var holding = 0
      for each in assigned:
        if each.getStr == "harvester": inc holding
      reason = "Everyone the slots leave: " & $holding & " of " & $members.len & " known dragons"
    elif places == 0:
      reason = "The team needs none now"
      if ordinal < slotWorkings.len:
        turn.calculation(slotWorkings[ordinal].integer, id & "-places", id, "Places")
    elif gate != "open": reason = capitalizeAscii(gate)
    elif ownAssigned in earlier: reason = "Taken first by " & ownAssigned & ", an earlier slot"
    else:
      var winners: seq[string]
      var count = 0
      for index in running:
        if assigned[index].getStr != alternative: continue
        inc count
        if count <= MaxWinners:
          winners.add "dragon " & $members[index]{"dragon"}.integer & " (" &
            shown(scores[index][ordinal].number) & ")"
      if count > MaxWinners: winners.add "and " & $(count - MaxWinners) & " more"
      reason = $places & " place(s), to " & (if winners.len > 0: winners.join(", ") else: "nobody") &
        ". This dragon ranks " & $(running.find(own) + 1) & " of " & $running.len & " at " & shown(value)
      if slotIndex >= 0 and ordinal < slotWorkings.len:
        turn.calculation(slotWorkings[ordinal].integer, id & "-places", id, "Places")
    child["reason"] = %clip(reason)
    if own in 0 ..< workings.len and ordinal < workings[own].len:
      let working = workings[own][ordinal].integer
      if turn.valid(working):
        turn.calculation(working, id & "-score", id,
          if gate != "open": "Gate" else: "Suitability")
  # Every known dragon's suitability per role and its assignment.
  var columns = @["dragon", "length", "head cell", "placed", "claimed role"]
  for ordinal in 1 ..< turn.roles.len:
    if turn.roles[ordinal] != "harvester": columns.add turn.roles[ordinal]
  columns.add "assigned"
  var rows, states: seq[JsonNode]
  for index, member in members:
    var row = @[$member{"dragon"}.integer, $member{"length"}.integer, $member{"head"}.integer,
      (if member{"seen"}.getBool: "in view"
       else: $int(member{"certainty"}.number * 100) & "% at its likeliest cell"),
      turn.roleName(member{"role"}.integer)]
    for ordinal in 1 ..< turn.roles.len:
      if turn.roles[ordinal] == "harvester": continue
      let score = if index < scores.len: scores[index][ordinal].number else: NaN
      row.add(if score.finite: shown(score) else: "-")
    row.add(if index < assigned.len: assigned[index].getStr else: "")
    rows.add %row
    states.add %(if index == own: "selected" else: "eligible")
  turn.records.add %*{"version": 1, "kind": "table", "id": "team-picture", "parent": "role",
    "label": "Team picture", "columns": columns, "rows": rows, "row_states": states}

# Task selection.

proc target(pair: JsonNode): string =
  let (cell, dragon) = (pair{"cell"}.integer, pair{"dragon"}.integer)
  if dragon >= 0: "enemy dragon " & $dragon
  elif cell >= 0: "cell " & $cell
  else: "no target"

proc behaviourName(turn: Turn, code: int): string =
  let names = turn.structure{"behaviours"}.getElems
  if code in 0 ..< names.len: names[code].getStr else: "code " & $code

proc describe(turn: Turn, pair: JsonNode): string =
  turn.behaviourName(pair{"behaviour"}.integer) & " at " & pair.target & " (" &
    shown(pair{"score"}.number) & ")"

proc renderSelection(turn: var Turn) =
  let decision = turn.decision
  if decision == nil: return
  let pairs = decision{"pairs"}.getElems
  let chosen = decision{"chosen"}.integer
  let best = decision{"best"}.integer
  var outcome = if chosen notin 0 ..< pairs.len: "No task"
    else: "Task: " & turn.describe(pairs[chosen])
  if chosen in 0 ..< pairs.len and best in 0 ..< pairs.len and
      pairs[chosen]{"score"}.number < pairs[best]{"score"}.number:
    outcome.add ", kept: it is within the margin of the best, " & turn.describe(pairs[best])
  var gave: seq[string]
  for pair in pairs:
    if pair{"idle"}.getBool: gave.add turn.describe(pair)
  if gave.len > 0:
    outcome.add ". Gave way, having no action: " & gave[0 ..< min(3, gave.len)].join(", ") &
      (if gave.len > 3: " and " & $(gave.len - 3) & " more" else: "")
  var node = turn.addNode("utility", "decision", "Task selection", chosen >= 0)
  node["reason"] = %clip("The highest duty weight × score wins; the current task stays " &
    "unless another beats it by more than " & shown(turn.structure{"margin"}.number) & ". " & outcome)
  for offered in decision{"offered"}.getElems:
    let code = offered{"behaviour"}.integer
    let name = turn.behaviourName(code)
    let weight = offered{"weight"}.number
    var mine: seq[int]
    for index, pair in pairs:
      if pair{"behaviour"}.integer == code: mine.add index
    let active = chosen in mine
    # The chosen pair when this is the task, else its best, which comes first.
    let shownPair = if active: chosen elif mine.len > 0: mine[0] else: -1
    var child = turn.addNode(name, "utility", name, active)
    child["objective"] = %"utility"
    child["eligible"] = %(mine.len > 0)
    # What it checked to offer its targets, apart from their scores.
    var scores: IntSet
    for index in mine: scores.incl pairs[index]{"working"}.integer
    turn.checks(offered{"first"}.integer, offered{"last"}.integer, name, scores)
    if shownPair < 0:
      child["reason"] = %"No eligible target"
      continue
    let pair = pairs[shownPair]
    let score = pair{"score"}.number
    if score.finite: child["score"] = %score
    child["reason"] = %clip("Duty weight " & shown(weight) & "; " & $mine.len & " target(s), shown at " &
      pair.target & (if pair{"idle"}.getBool: "; had no action this turn"
        elif not active: ""
        elif best in 0 ..< pairs.len and score < pairs[best]{"score"}.number: "; kept within the margin"
        else: "; highest score"))
    let working = pair{"working"}.integer
    let label = if pair.target == "no target": "Score" else: "Score at " & pair.target
    if turn.valid(working):
      turn.calculation(working, name & "-score", name, label, @[("duty weight", weight)],
        "duty weight × ($1)", score)
    elif weight != 0 and score.finite:
      turn.records.add %*{"version": 1, "kind": "calculation", "id": name & "-score", "parent": name,
        "label": label, "expression": "duty weight × score",
        "operands": [{"name": "duty weight", "value": weight}, {"name": "score", "value": score / weight}],
        "result": score}
    if mine.len < 2: continue
    # Every target it offered, best first, with its score's terms.
    var columns = @["target", "score"]
    var rows, states: seq[JsonNode]
    for place, index in mine:
      if place >= MaxTargets: break
      let each = pairs[index]
      var terms: seq[(string, float)]
      var unreached, infinite: seq[string]
      turn.terms(each{"working"}.integer, terms, unreached, infinite)
      var row = @[each.target, shown(each{"score"}.number)]
      for (term, value) in terms:
        if place == 0 and term notin columns: columns.add term
      for column in columns[2 .. ^1]:
        var text = ""
        for (term, value) in terms:
          if term == column:
            text = shown(value)
            break
        row.add text
      rows.add %row
      states.add %(if index == chosen: "selected" elif each{"idle"}.getBool: "ineligible" else: "eligible")
    turn.records.add %*{"version": 1, "kind": "table", "id": name & "-targets", "parent": name,
      "label": "Targets", "objective": clip("duty weight " & shown(weight) & " × (" &
        (if turn.valid(pair{"working"}.integer): turn.expression(pair{"working"}.integer) else: "score") &
        "), highest first"),
      "reason": $mine.len & " target(s)" & (if mine.len > MaxTargets: ", the best " & $MaxTargets & " shown" else: ""),
      "columns": columns, "rows": rows, "row_states": states}

# The state machines.

type States = object
  byAddress: Table[int, JsonNode]
  parentOf: Table[int, int]

proc collect(states: var States, state: JsonNode, parent: int) =
  if state == nil or state.kind != JObject or state{"name"} == nil: return
  let address = state{"@"}.integer
  states.byAddress[address] = state
  states.parentOf[address] = parent
  for child in state{"children"}.getElems: states.collect(child, address)

proc renderMachine(turn: var Turn, machine: JsonNode, parent, prefix: string, ticked: bool,
    asked: seq[(int, int)], label: proc(name: string): string): string =
  ## One node per state under `parent`, as the machine ran this turn, and
  ## each leaf's eligibility checks from `asked`, by leaf order. The acting
  ## leaf's node ID, "" for none.
  if machine == nil or machine{"root"} == nil: return
  var states: States
  states.collect(machine["root"], -1)
  let updates = machine{"updates"}.integer
  var path: IntSet
  if ticked and machine{"active"} != nil:
    var at = machine["active"]{"@"}.integer
    while at >= 0 and at in states.byAddress:
      path.incl at
      at = states.parentOf.getOrDefault(at, -1)
  var leaves = 0
  proc anyEligible(state: JsonNode): bool =
    if state{"kind"}.getStr == "compoundState":
      for child in state{"children"}.getElems:
        if anyEligible(child): return true
    elif state{"checked"}.integer == updates: return state{"eligibleNow"}.getBool
  var acting = ""
  proc walk(turn: var Turn, state: JsonNode, parent: string) =
    let name = state{"name"}.getStr
    let id = prefix & name
    let address = state{"@"}.integer
    var node = turn.addNode(id, parent, label(name), address in path)
    if address in path and state{"kind"}.getStr == "leafState": acting = id
    if state{"kind"}.getStr == "compoundState":
      if ticked: node["eligible"] = %anyEligible(state)
      node["reason"] = %(if state{"reactive"}.getBool: "The first eligible child acts, rechecked every turn"
        else: "Keeps its child until that child can't act")
      for child in state{"children"}.getElems: turn.walk(child, id)
    else:
      let place = leaves
      inc leaves
      let checked = ticked and state{"checked"}.integer == updates
      if checked:
        let eligible = state{"eligibleNow"}.getBool
        node["eligible"] = %eligible
        node["reason"] = %(if address in path: "Acts" elif not eligible: "Not eligible"
          elif state{"failed"}.integer == updates: "Eligible, but it had no action"
          else: "Eligible, but an earlier state acts")
        if place < asked.len: turn.checks(asked[place][0], asked[place][1], id)
      else:
        node["reason"] = %(if ticked: "Not evaluated: an earlier state acts" else: "Not run this turn")
  turn.walk(machine["root"], parent)
  acting

proc renderStates(turn: var Turn) =
  let decision = turn.decision
  if turn.machine == nil or decision == nil: return
  let pairs = decision{"pairs"}.getElems
  let chosen = decision{"chosen"}.integer
  var asked: seq[(int, int)]
  for range in decision{"interrupts"}.getElems:
    asked.add (range{"first"}.integer, range{"last"}.integer)
  # The task leaf comes after the interrupts.
  asked.add (-1, -1)
  let first = turn.nodes.len
  let task = if chosen in 0 ..< pairs.len:
      "task: " & turn.behaviourName(pairs[chosen]{"behaviour"}.integer) &
        (if pairs[chosen].target == "no target": "" else: " at " & pairs[chosen].target)
    else: "task"
  var acting = turn.renderMachine(turn.machine, "decision", "state-", true, asked,
    proc(name: string): string = (if name == "task": task else: name))
  # Every eligibility asked, so what the acting state checked is the rest.
  var eligibility: IntSet
  for (first, last) in asked:
    for working in turn.outermost(first, last): eligibility.incl working
  defer:
    if acting.len > 0:
      let range = decision{"acting"}
      turn.checks(range{"first"}.integer, range{"last"}.integer, acting, eligibility, "acting")
  if first < turn.nodes.len:
    let active = turn.machine{"active"}
    var at = if active != nil: active{"@"}.integer else: -1
    var name = "none"
    var states: States
    states.collect(turn.machine{"root"}, -1)
    if at in states.byAddress: name = states.byAddress[at]{"name"}.getStr
    turn.nodes[first]["label"] = %("State: " & name)
  # The chosen task's phases, under its leaf.
  if chosen notin 0 ..< pairs.len: return
  let behaviour = turn.behaviourName(pairs[chosen]{"behaviour"}.integer)
  for entry in turn.phasing.getElems:
    if entry{"behaviour"}{"name"}.getStr != behaviour: continue
    let phased = entry{"phased"}
    var ranges: seq[(int, int)]
    for range in phased{"asked"}.getElems:
      ranges.add (range{"first"}.integer, range{"last"}.integer)
    let ticked = phased{"round"}.integer == turn.round
    let phase = turn.renderMachine(phased{"machine"}, "state-task", "phase-", ticked, ranges,
      proc(name: string): string = name)
    if ticked:
      for (first, last) in ranges:
        for working in turn.outermost(first, last): eligibility.incl working
      if phase.len > 0: acting = phase
    break

# Claims and orders.

proc renderClaims(turn: var Turn, area: int) =
  let ledger = turn.ledger
  let decision = turn.decision
  if ledger == nil or decision == nil: return
  let code = ledger{"behaviour"}.integer
  let claim = ledger{"claim"}
  let own = if code >= 0 and claim{"expires"}.integer >= turn.round: claim{"task"}.integer else: -1
  let yielded = ledger{"yielded"}.integer
  var node = turn.addNode("claims", "decision", "Task claim", own >= 0)
  node["reason"] = %clip(if own >= 0: "Claims " & turn.behaviourName(code) & " at cell " & $own &
      " until round " & $claim{"expires"}.integer & (if ledger{"changed"}.getBool: "; changed this turn" else: "")
    elif yielded >= 0: "No claim: dragon " & $yielded & " holds this turn's target"
    else: "No claim: the task has no cell to claim")
  var rows, states: seq[JsonNode]
  if own >= 0:
    rows.add %[$claim{"owner"}.integer, turn.behaviourName(code), $own, $claim{"expires"}.integer, "ours"]
    states.add %"selected"
  for claimed in decision{"claims"}.getElems:
    let binding = claimed{"binding"}.getStr
    rows.add %[$claimed{"dragon"}.integer, turn.behaviourName(claimed{"behaviour"}.integer),
      $claimed{"cell"}.integer, $claimed{"expires"}.integer, binding]
    states.add %(if binding.startsWith("binds"): "eligible" else: "ineligible")
  turn.records.add %*{"version": 1, "kind": "table", "id": "task-claims", "parent": "claims",
    "label": "Task claims", "columns": ["dragon", "behaviour", "target cell", "expires", "status"],
    "rows": rows, "row_states": states}
  if own in 0 ..< area:
    turn.records.add %*{"version": 1, "kind": "target", "id": "claimed-target", "parent": "claims",
      "label": "Claimed: " & turn.behaviourName(code), "points": [own]}

proc renderOrders(turn: var Turn) =
  let decision = turn.decision
  if decision == nil: return
  var said: seq[string]
  for order in decision{"orders"}.getElems:
    said.add order{"command"}.getStr & " at cell " & $order{"cell"}.integer & " to dragon " &
      $order{"recipient"}.integer & " on ray " & $"NESW"[order{"ray"}.integer and 3]
  var rays: seq[string]
  for ray in decision{"paths"}.getElems: rays.add $"NESW"[ray.integer and 3]
  if rays.len > 0:
    said.add "right of way claimed on ray" & (if rays.len > 1: "s " else: " ") & rays.join(", ")
  var node = turn.addNode("orders", "decision", "Orders", said.len > 0)
  node["eligible"] = %(said.len > 0)
  node["reason"] = %clip(if said.len > 0: said.join("; ") else: "None sent this turn")

# The coil's lane.

proc renderCoil(turn: var Turn, start: var Image, task: JsonNode, area: int) =
  ## The cycle a coil task follows, in travel order from the head, on a turn
  ## the coil acted following or leaving it (`coil: task`, end).
  if task == nil or task.kind != JObject or turn.decision == nil or turn.machine == nil: return
  let pairs = turn.decision{"pairs"}.getElems
  let chosen = turn.decision{"chosen"}.integer
  if chosen notin 0 ..< pairs.len or turn.behaviourName(pairs[chosen]{"behaviour"}.integer) != "coil":
    return
  var states: States
  states.collect(turn.machine{"root"}, -1)
  let active = turn.machine{"active"}
  let leaf = if active != nil: states.byAddress.getOrDefault(active{"@"}.integer, nil) else: nil
  if leaf == nil or leaf{"name"}.getStr != "task": return
  if task{"round"}.integer != turn.round or task{"duty"}.getStr notin ["follow", "leave"]: return
  let coil = task{"coil"}
  let (order, place) = (coil{"order"}.getElems, coil{"place"}.getElems)
  let body = start.at("remembered", "memory", "body").getElems
  if order.len == 0 or body.len == 0: return
  let forward = task{"forward"}.getBool
  var (cell, points) = (body[0].integer, newJArray())
  for _ in 0 ..< order.len:
    if cell notin 0 ..< min(area, place.len): return
    let at = place[cell].integer
    if at notin 0 ..< order.len: return
    points.add %cell
    cell = order[if forward: (at + 1) mod order.len else: (at + order.len - 1) mod order.len].integer
  turn.records.add %*{"version": 1, "kind": "path", "id": "coil-lane", "label": "Coil", "points": points,
    "reason": $coil{"anchors"}.len & " blocks, " & $order.len & " cells, in travel order from the head"}

# Movement.

proc optionName(option: JsonNode): string =
  const names = ["North", "East", "South", "West"]
  let moves = option{"moves"}.getElems
  if moves.len == 0: "None"
  elif moves.len == 1: names[moves[0].integer and 3]
  else:
    var path = ""
    for move in moves: path.add "NESW"[move.integer and 3]
    "Sprint " & path

proc losesOn(option, chosen: JsonNode, classes: seq[string]): string =
  ## The first rank the chosen option wins on against `option`, as movement
  ## ranks them: its safety classes in order, then utility, the duel's value
  ## and the length kept.
  let (a, b) = (chosen{"key"}.getElems, option{"key"}.getElems)
  for index in 0 ..< min(a.len, b.len):
    if a[index].integer != b[index].integer:
      return if index < classes.len: classes[index] else: "class " & $index
  if chosen{"utility"}.number != option{"utility"}.number: "utility"
  elif chosen{"duelKnown"}.getBool and option{"duelKnown"}.getBool and
      chosen{"duel"}.number != option{"duel"}.number: "the duel's value"
  elif chosen{"length"}.integer != option{"length"}.integer: "length kept"
  else: "a tie, kept by the current heading"

proc renderMovement(turn: var Turn, queries: JsonNode, classes: seq[string], area: int) =
  ## Each movement query this turn as a table of its options, best first as
  ## movement ranked them, each assessed option's utility beneath its row.
  var count = 0
  for query in queries.getElems:
    if query{"round"}.integer != turn.round: continue
    inc count
    let id = "movement-" & $count
    let purpose = query{"purpose"}.getStr
    let options = query{"options"}.getElems
    let chosen = query{"chosen"}.integer
    var rows, states, ids: seq[JsonNode]
    var ranked = false
    for place, option in options:
      let name = option.optionName
      let row = id & "-" & $place
      let outcome = option{"outcome"}.getStr
      ids.add %row
      states.add %(if place == chosen: "selected"
        elif outcome.startsWith("illegal") or outcome.startsWith("no "): "ineligible"
        else: "eligible")
      if outcome != "assessed":
        rows.add %[name, outcome, "", "", "", "", "", "", "", ""]
        continue
      ranked = true
      let progress = option{"progress"}.integer
      rows.add %[name, (if place == chosen: "chosen" else: ""),
        (if chosen in 0 ..< options.len and place != chosen and
            options[chosen]{"outcome"}.getStr == "assessed":
          option.losesOn(options[chosen], classes) else: ""),
        $option{"exits"}.integer,
        $option{"survival"}.integer & "/" & $option{"horizon"}.integer,
        $option{"contested"}.integer & "/" & $option{"contestedHorizon"}.integer,
        $option{"threat"}.integer,
        (if option{"duelKnown"}.getBool: shown(option{"duel"}.number) else: ""),
        shown(option{"utility"}.number),
        (if progress >= high(int32): "" else: $progress)]
      turn.calculation(option{"utilityWorking"}.integer, row & "-utility", row, "Utility")
      turn.calculation(option{"objective"}.integer, row & "-objective", row, "Objective")
    let search = query{"search"}
    var reason = if not ranked: "No option to assess"
      elif not search{"ranked"}.getBool: "Single steps only"
      elif search{"affordable"}.getBool:
        "Sprints searched" & (if search{"stopped"}.getBool: ", cut short by the turn budget" else: "") &
          (if chosen in 0 ..< options.len and options[chosen]{"moves"}.len > 1:
            "; a sprint outranks every step" else: "; none outranks the best step")
      else: "Sprints not searched"
    let refused = search{"refused"}.integer(0)
    if refused > 0:
      reason.add "; " & $refused & " that outranked it would shed tail, which only an " &
        "emergency or the caller's payment allows"
    var record = %*{"version": 1, "kind": "table", "id": id, "label": clip("Movement: " & purpose),
      "reason": clip(reason),
      "columns": ["Option", "Outcome", "Loses on", "Exits", "Survival", "Contested", "Threat",
        "Duel", "Utility", "Route"],
      "rows": rows, "row_states": states, "row_ids": ids}
    if ranked:
      record["objective"] = %clip("Rank by the first of these that differs: " & classes.join("; ") &
        ". Then utility in pearls, the duel's value and the length kept")
    turn.records.add record
    turn.calculation(query{"searchWorking"}.integer, id & "-search", id, "Sprint search")
    var route: seq[int]
    for cell in query{"route"}.getElems: route.add cell.integer
    if chosen >= 0 and route.len > 1:
      var inside = true
      for cell in route: inside = inside and cell in 0 ..< area
      if inside:
        turn.records.add %*{"version": 1, "kind": "path", "label": clip("Route: " & purpose),
          "points": route}
    let target = query{"target"}.integer
    if target in 0 ..< area:
      turn.records.add %*{"version": 1, "kind": "target", "label": clip(purpose), "points": [target]}

# Radio.

proc recordText(record: JsonNode): string =
  ## A sonar record as its kind and fields.
  result = record{"kind"}.getStr
  for key, value in record.pairs:
    if key == "kind": continue
    result.add " " & key & "=" & (if value.kind == JString: value.getStr else: $value)

proc renderRadio(turn: var Turn, transmission: JsonNode, rule: string) =
  ## Each ray this turn: what it carried and why, or why it wasn't sent.
  var sent, unsent: seq[JsonNode]
  for ray in transmission{"rays"}.getElems:
    let chance = $int(ray{"chance"}.number * 100) & "%"
    let dragon = $ray{"dragon"}.integer
    let who = case ray{"recipient"}.getStr
      of "teammate": "teammate " & dragon & ", " & chance
      of "enemy": "enemy " & dragon & ", " & chance
      of "nobody": "nobody known: teammate " & $int(ray{"found"}{"teammate"}.number * 100) &
        "%, enemy " & $int(ray{"found"}{"enemy"}.number * 100) & "%"
      of "untraced": "not traced"
      else: "kelp or our body, " & chance
    let direction = $"NESW"[ray{"direction"}.integer and 3]
    let sending = ray{"sending"}.getStr
    if sending != "sent":
      unsent.add %[direction, who, sending, $ray{"dropped"}.integer]
      continue
    # The records in the order the fill added them: the action's, dragon
    # facts, then changed cells and the map walk.
    let (queued, told, changed) = (ray{"queued"}.integer, ray{"dragons"}.getElems,
      ray{"mapChanged"}.integer)
    let records = ray{"frame"}{"records"}.getElems
    var said: seq[string]
    for index, record in records:
      let (fromDragons, fromMap) = (index - queued, index - queued - told.len)
      let why = if index < queued: "action"
        elif fromDragons < told.len:
          (if told[fromDragons].integer < 0: "new or changed"
           else: "least recently told, r" & $told[fromDragons].integer)
        elif fromMap < changed: "changed cell"
        else: "map walk"
      said.add record.recordText & " [" & why & "]"
    let ambient = records.len - queued
    let value = ray{"value"}
    let number = if value.kind == JInt: $cast[uint64](value.getBiggestInt) else: value.getStr
    sent.add %[number, direction, who, clip(said.join("; ")),
      $queued & " from the action, " & $ambient & " ambient (" & $told.len & " dragon facts, " &
        $(ambient - told.len) & " map facts)" &
        (if ray{"braked"}.getBool: ", none past the turn's brake" else: "") & "; " &
        $ray{"frame"}{"used"}.integer & " bits"]
  turn.records.add %*{"version": 1, "kind": "table", "id": "radio", "label": "Radio",
    "objective": clip(rule),
    "reason": $transmission{"untold"}.integer & " changed cells untold, cursor at cell " &
      $transmission{"cursor"}.integer,
    "columns": ["value", "direction", "reaches", "records", "reason"], "rows": sent,
    "sonar": {"role": "sent", "value_column": 0, "meaning_column": 3}}
  if unsent.len > 0:
    turn.records.add %*{"version": 1, "kind": "table", "id": "radio-unsent", "parent": "radio",
      "label": "Rays not sent", "columns": ["direction", "reaches", "why", "action records dropped"],
      "rows": unsent}

proc renderInbox(turn: var Turn, heard: JsonNode) =
  ## This turn's sonar inbox: each value, its records and what the memory did
  ## with each.
  var rows: seq[JsonNode]
  for entry in heard.getElems:
    let value = entry{"value"}
    let number = if value.kind == JInt: $cast[uint64](value.getBiggestInt) else: value.getStr
    var meanings, outcomes, cells: seq[string]
    for record in entry{"records"}.getElems: meanings.add record.recordText
    for outcome in entry{"outcomes"}.getElems: outcomes.add outcome.getStr
    for cell in entry{"cells"}.getElems: cells.add $cell.integer
    rows.add %[number, clip(if meanings.len > 0: meanings.join("; ") else: "not ours"),
      clip(outcomes.join("; ")), cells.join(" ")]
  if rows.len == 0: return
  turn.records.add %*{"version": 1, "kind": "table", "id": "memory-inbox",
    "label": "Sonar received", "columns": ["value", "meaning", "outcome", "cells"], "rows": rows,
    "sonar": {"role": "received", "value_column": 0, "meaning_column": 1,
      "outcome_column": 2, "cells_column": 3}}

# The belief: where each dragon may be, and the kelp and pearls it believes
# out of sight, drawn for the viewer's Mental map.

proc float32At(bytes: seq[byte], at: int): float =
  if at < 0 or at + 4 > bytes.len: return 0.0
  var bits: uint32
  for index in countdown(3, 0): bits = (bits shl 8) or uint32(bytes[at + index])
  float(cast[float32](bits))

proc percent(chance: float): int = int(round(chance * 100))

proc renderBelief(turn: var Turn, start: var Image, area: int) =
  let (width, height) = (start.at("remembered", "memory", "width").integer,
    start.at("remembered", "memory", "height").integer)
  if width <= 0 or height <= 0 or width * height != area: return
  let self = start.at("remembered", "memory", "self").integer
  let length = start.at("remembered", "memory", "length").integer
  let body = start.at("remembered", "memory", "body").getElems
  let round = start.at("remembered", "belief", "round").integer
  # Where each dragon may be: ourselves, then every dragon with live belief.
  var positions = newJArray()
  if body.len > 0 and body[0].integer in 0 ..< area:
    positions.add %*{"cell": body[0].integer, "radius": 0, "age": 0, "source": "seen",
      "label": "us, dragon " & $self & ", length " & $length, "color": [96, 140, 200, 255],
      "dragon": self, "team": "ours", "length": length, "length_exact": true}
  let dragons = start.at("remembered", "belief", "dragons").getElems
  for dragon in dragons:
    var ranked: seq[(int, float)]
    for entry in dragon{"marginal"}.getElems: ranked.add (entry{"Field0"}.integer, entry{"Field1"}.number)
    if ranked.len == 0: continue
    ranked.sort(proc(first, second: (int, float)): int = cmp(second[1], first[1]))
    let alive = dragon{"alive"}.number
    var (cells, mass) = (newJArray(), 0.0)
    for (cell, chance) in ranked:
      if mass >= 0.9 * alive or cells.len >= 400: break
      cells.add %cell
      mass += chance
    let (fix, seenRound) = (dragon{"fixRound"}.integer, dragon{"seenRound"}.integer)
    let age = if fix >= 0: round - fix else: 4096
    let seen = seenRound == fix and fix >= 0
    let ours = dragon{"team"}.getStr == "ours"
    let (id, low) = (dragon{"id"}.integer, dragon{"lengthLow"}.integer)
    positions.add %*{"cell": ranked[0][0], "cells": cells, "age": min(age, 4096),
      "source": (if seen: "seen r" else: "reported r") & $fix,
      "label": clip((if ours: "teammate" else: "enemy") & " dragon " & $id & ", length " & $low &
        (if dragon{"lengthExact"}.getBool: "" else: "+") & ", alive " & $percent(alive) &
        "%; if alive, " & $percent(ranked[0][1] / max(alive, 1e-9)) & "% at best, " &
        $cells.len & " cells hold 90%" &
        (if dragon{"widened"}.getBool: ", widened: " & dragon{"widening"}.getStr else: "")),
      "color": (if ours: [96, 140, 200, int(40 + 215 * alive)] else: [251, 73, 52, int(40 + 215 * alive)]),
      "dragon": id, "team": (if ours: "ours" else: "enemy"), "length": min(low, 4096),
      "length_exact": dragon{"lengthExact"}.getBool}
  # Our own body, as far as it is located.
  var located = newJArray()
  for cell in body:
    if cell.integer in 0 ..< area: located.add cell
  if located.len > 0:
    turn.records.add %*{"version": 1, "kind": "path", "id": "memory-body", "parent": "memory",
      "label": "Own body", "points": located,
      "reason": (if start.at("remembered", "memory", "bodyComplete").getBool: "All " & $length & " segments"
        else: $body.len & " of " & $length & " segments located")}
  turn.records.add %*{"version": 1, "kind": "positions", "id": "belief-positions", "parent": "memory",
    "label": "Believed positions", "positions": positions}
  # Kelp on unknown sides whose chance moved from the prior, each at the
  # opacity of its chance; a cell whose strongest move changed by 5 points
  # sends all four sides again, so a side described since clears.
  let kinds = start.at("remembered", "belief", "kinds")
  var total = 0.0
  for count in kinds{"counts"}.getElems: total += count.number
  let strength = kinds{"strength"}.number
  let prior = (kinds{"counts"}[1].number + strength * kinds{"prior"}[1].number) / (total + strength)
  let (edges, edgeCount, edgeSize) = start.elements("remembered", "belief", "edges")
  let (described, describedCount, _) = start.elements("remembered", "belief", "described")
  var sides = newJArray()
  let shownKelp = addr start.shown.mgetOrPut("belief-kelp", initTable[int, string]())
  for cell in 0 ..< area:
    let (x, y) = (cell mod width, cell div width)
    var strongest = 0.0
    var drawn: seq[JsonNode]
    for side in 0 ..< 4:
      let edge = case side
        of 0: cell * 2
        of 2: ((y + 1) mod height * width + x) * 2
        of 3: cell * 2 + 1
        else: (y * width + (x + 1) mod width) * 2 + 1
      if edge >= edgeCount or edge >= describedCount: continue
      let known = described[edge] != 0
      let kelp = if known: 0.0 else: float32At(edges, edge * edgeSize + 4)
      let moved = not known and abs(kelp - prior) >= 0.05
      if not known: strongest = max(strongest, abs(kelp - prior))
      drawn.add %*{"cell": cell, "direction": side,
        "label": (if moved: "kelp " & $percent(kelp) & "%" else: ""),
        "color": [178, 226, 96, (if moved: int(255 * kelp) else: 0)]}
    let before = try: parseFloat(shownKelp[].getOrDefault(cell, "0")) except ValueError: 0.0
    if abs(strongest - before) < 0.05: continue
    shownKelp[][cell] = $strongest
    for side in drawn: sides.add side
  if sides.len > 0:
    turn.records.add %*{"version": 1, "kind": "map", "id": "belief-kelp", "parent": "memory",
      "label": "Believed kelp", "retain": true, "display_overlay": "mental",
      "reason": "Unknown sides whose kelp chance differs from the prior's " & $percent(prior) &
        "% by 5 points or more, as opacity", "edges": sides}
  # Pearls out of view by their chance; one coming into view clears, since
  # sight then says.
  var visible: IntSet
  for cell in start.at("remembered", "memory", "visible").getElems: visible.incl cell.integer
  let (pearls, pearlCount, pearlSize) = start.elements("remembered", "belief", "pearls")
  let shownPearl = addr start.shown.mgetOrPut("belief-pearls", initTable[int, string]())
  var pearlCells = newJArray()
  for cell in 0 ..< min(area, pearlCount):
    let chance = if cell in visible: 0.0 else: float32At(pearls, cell * pearlSize)
    let before = try: parseFloat(shownPearl[].getOrDefault(cell, "0")) except ValueError: 0.0
    if abs(chance - before) < 0.05 and not (chance == 0.0 and before > 0.0): continue
    shownPearl[][cell] = $chance
    pearlCells.add %*{"cell": cell, "value": percent(chance), "label": "pearl " & $percent(chance) & "%",
      "color": [232, 200, 114, int(255 * chance)]}
  if pearlCells.len > 0:
    turn.records.add %*{"version": 1, "kind": "map", "id": "belief-pearls", "parent": "memory",
      "label": "Believed pearls", "retain": true, "display_overlay": "mental",
      "reason": "Out of view: the chance a pearl lies there, as opacity", "cells": pearlCells}
  # Last turn's echoes, traced from our head, in the board's echo teal (palette.odin's
  # SONAR_ECHO) rather than the default gold of the view window.
  for echo in start.at("remembered", "belief", "echoes").getElems:
    var points = @[echo{"origin"}.integer]
    for cell in echo{"path"}.getElems: points.add cell.integer
    var inside = true
    for cell in points: inside = inside and cell in 0 ..< area
    if not inside: continue
    let direction = echo{"direction"}.integer and 3
    turn.records.add %*{"version": 1, "kind": "path", "id": "belief-echo-" & $direction,
      "label": "Echo " & $"NESW"[direction], "points": points, "color": [155, 189, 181, 150],
      "reason": "Traced to " & echo{"stop"}.getStr & ", " & $echo{"edges"}.len & " unknown edges; kelp " &
        $percent(echo{"kelp"}.number) & "%, miss " & $percent(echo{"miss"}.number) & "%, a dragon " &
        $percent(echo{"other"}.number) & "%"}

# The turn's accounts.

proc renderBudget(turn: var Turn, tally: JsonNode) =
  ## What each stage spent by the clock, and each kind of work's counted
  ## points, which set every cutoff (`just work-costs` reads the second).
  var rows: seq[JsonNode]
  for entry in tally{"stages"}.getElems:
    rows.add %[entry{"stage"}.getStr, $entry{"points"}.integer]
  rows.add %["turn so far", $tally{"total"}.integer]
  turn.records.add %*{"version": 1, "kind": "table", "label": "Turn points",
    "reason": "Limit " & $tally{"limit"}.integer, "columns": ["Stage", "Points"], "rows": rows}
  var units: seq[JsonNode]
  for entry in tally{"work"}.getElems:
    units.add %[entry{"kind"}.getStr, $entry{"units"}.integer, $entry{"points"}.integer]
  units.add %["counted", "", $tally{"estimate"}.integer]
  turn.records.add %*{"version": 1, "kind": "table", "label": "Turn work",
    "reason": (if tally{"braked"}.getBool: "The clock braked at " & $tally{"brake"}.integer &
      " points" else: "Counted work sets every cutoff"),
    "columns": ["Work", "Units", "Points"], "rows": units}

proc render*(start: var Image, ending: Image, round, area: int, primitives: seq[JsonNode]): seq[JsonNode] =
  ## The records built from what the bot kept this turn: beneath the Brain
  ## root it emitted, a `state` tree whose `decision` node they hang from and
  ## whose nodes grow in place, and a table per movement query.
  if not ending.ready or not start.ready: return
  var turn = Turn(round: round)
  turn.sites = decodeSites(start.at("explained sites"))
  turn.trace = decodeTrace(ending.at("explained trace"))
  let queries = ending.at("movement: queries")
  if queries != nil:
    var classes: seq[string]
    for name in start.at("movement: safety classes").getElems: classes.add name.getStr
    turn.renderMovement(queries, classes, area)
  let tally = ending.at("budget: turn")
  if tally != nil: turn.renderBudget(tally)
  turn.roles = start.enumNames("Role")
  turn.renderBelief(start, area)
  let heard = start.at("remembered", "memory", "heard")
  if heard != nil: turn.renderInbox(heard)
  let transmission = ending.at("radio: transmission")
  if transmission != nil: turn.renderRadio(transmission, start.at("radio: rule").getStr)
  var brain: JsonNode
  for primitive in primitives:
    if primitive{"slot"} == %"brain" and primitive{"kind"} == %"state": brain = primitive
  turn.decision = ending.at("utility: decision")
  turn.structure = start.at("utility: structure")
  if brain != nil and turn.decision != nil and turn.structure != nil:
    turn.roles = start.enumNames("Role")
    turn.roster = start.at("remembered", "roster")
    turn.decided = ending.at("roles: decided")
    turn.ledger = ending.at("utility: claims ledger")
    turn.machine = ending.at("utility: interrupts and task")
    turn.phasing = ending.at("task phases")
    turn.renderRole()
    turn.renderSelection()
    turn.renderStates()
    turn.renderClaims(area)
    turn.renderOrders()
    turn.renderCoil(start, ending.at("coil: task"), area)
    for node in turn.nodes: brain["nodes"].add node
  turn.records

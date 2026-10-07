@0xbee8ca02914a028c;
# Reconstructed from the unswbc replay viewer (capnp-ts classes).

struct Point { x @0 :Int32; y @1 :Int32; }

struct DebugDraw {
  shape @0 :UInt16; from @1 :Point; to @2 :Point;
  red @3 :UInt8; green @4 :UInt8; blue @5 :UInt8;
}

struct PlayerAction {
  union { move @0 :List(UInt16); split @1 :Int32; suicide @2 :Void; }
}

struct EventRoundStart { round @0 :Int32; }
struct EventTurnStart { id @0 :Int32; }
struct EventPearlCountdown { tile @0 :Point; countdown @1 :Int32; }
struct EventTileChange { tile @0 :Point; hasPearl @1 :Bool; }
struct EventDragonAction { id @0 :Int32; action @1 :PlayerAction; }
struct EventEngineLog { id @0 :Int32; text @1 :Text; }
struct EventDragonLog { id @0 :Int32; text @1 :Text; }
struct EventDragonIndicator { id @0 :Int32; text @1 :Text; }
struct EventDebugDraw { id @0 :Int32; draw @1 :DebugDraw; }
struct EventDragonUpdate { id @0 :Int32; facing @1 :UInt16; head @2 :Point; tail @3 :Point; }
struct EventDragonSplit {
  parentId @0 :Int32; childId @1 :Int32; team @2 :UInt16; childFacing @3 :UInt16;
  parentBody @4 :List(Point); childBody @5 :List(Point);
}
struct EventDragonDeath { id @0 :Int32; reason @1 :UInt16; }
struct EventSonarPing {
  senderId @0 :Int32; direction @1 :UInt16; value @2 :UInt32;
  origin @3 :Point; end @4 :Point;
  union { noHit @5 :Void; hitId @6 :Int32; }
  # Replay formatVersion >= 2 (PROTOCOL 3 engine): the full 64-bit payload
  # (`value` keeps only the low word) and what the ray struck.
  value64 @7 :UInt64;
  hitKind @8 :SonarHitKind;
}

enum SonarHitKind { unknown @0; empty @1; kelp @2; ally @3; allyHead @4; enemy @5; enemyHead @6; }

struct Event {
  union {
    roundStart @0 :EventRoundStart;
    turnStart @1 :EventTurnStart;
    pearlCountdown @2 :EventPearlCountdown;
    tileChange @3 :EventTileChange;
    dragonAction @4 :EventDragonAction;
    engineLog @5 :EventEngineLog;
    dragonLog @6 :EventDragonLog;
    dragonIndicator @7 :EventDragonIndicator;
    debugDraw @8 :EventDebugDraw;
    dragonUpdate @9 :EventDragonUpdate;
    dragonSplit @10 :EventDragonSplit;
    dragonDeath @11 :EventDragonDeath;
    sonarPing @12 :EventSonarPing;
  }
}

struct TeamStanding { dragonCount @0 :Int32; longestDragon @1 :Int32; totalLength @2 :Int32; }

struct GameResult {
  terminated @0 :Bool; endReason @1 :UInt16;
  union { noWinner @2 :Void; winner @3 :UInt16; }
  teamA @4 :TeamStanding; teamB @5 :TeamStanding;
}

struct Replay {
  map @0 :Text; botA @1 :Text; botB @2 :Text;
  events @3 :List(Event); result @4 :GameResult;
  formatVersion @5 :UInt32;   # 0/1: 32-bit sonar only; >= 2: value64 + hitKind
}

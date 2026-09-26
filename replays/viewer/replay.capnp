@0xbeefbeefdead1234;
# Field order reconstructed from the generated classes in unswbc 1.0.1's
# replay-viewer.vsix. Keep this schema tied to that artifact, not guessed offsets.
enum Team { a @0; b @1; }
enum Direction { north @0; east @1; south @2; west @3; }
struct Point { x @0 :Int32; y @1 :Int32; }
struct PlayerAction { union { move @0 :List(Direction); split @1 :Int32; suicide @2 :Void; } }
struct RoundStart { round @0 :Int32; }
struct TurnStart { id @0 :Int32; }
struct InstructionUsage { count @0 :UInt64; exceeded @1 :Bool; }
struct PearlCountdown { tile @0 :Point; countdown @1 :Int32; }
struct TileChange { tile @0 :Point; hasPearl @1 :Bool; }
struct DragonAction { id @0 :Int32; action @1 :PlayerAction; instructions @2 :InstructionUsage; tle @3 :Bool; }
struct TextEvent { id @0 :Int32; text @1 :Text; }
struct DebugDraw { shape @0 :UInt16; from @1 :Point; to @2 :Point; red @3 :UInt8; green @4 :UInt8; blue @5 :UInt8; }
struct DrawEvent { id @0 :Int32; draw @1 :DebugDraw; }
struct DragonUpdate { id @0 :Int32; facing @1 :Direction; head @2 :Point; tail @3 :Point; }
struct DragonSplit { parentId @0 :Int32; childId @1 :Int32; team @2 :Team; childFacing @3 :Direction; parentBody @4 :List(Point); childBody @5 :List(Point); }
struct DragonDeath { id @0 :Int32; reason @1 :UInt16; }
struct SonarPing {
  senderId @0 :Int32; direction @1 :Direction; value @2 :UInt32;
  origin @3 :Point; end @4 :Point;
  union { noHit @5 :Void; hitId @6 :Int32; }
  value64 @7 :UInt64; hitKind @8 :UInt16;
}
struct Event {
  union {
    roundStart @0 :RoundStart; turnStart @1 :TurnStart;
    pearlCountdown @2 :PearlCountdown; tileChange @3 :TileChange;
    dragonAction @4 :DragonAction; engineLog @5 :TextEvent;
    dragonLog @6 :TextEvent; dragonIndicator @7 :TextEvent;
    debugDraw @8 :DrawEvent; dragonUpdate @9 :DragonUpdate;
    dragonSplit @10 :DragonSplit; dragonDeath @11 :DragonDeath; sonarPing @12 :SonarPing;
  }
}
struct TeamStanding { dragonCount @0 :Int32; longestDragon @1 :Int32; totalLength @2 :Int32; }
struct GameResult {
  terminated @0 :Bool; endReason @1 :UInt16;
  union { noWinner @2 :Void; winner @3 :Team; }
  teamA @4 :TeamStanding; teamB @5 :TeamStanding;
}
struct Replay { map @0 :Text; botA @1 :Text; botB @2 :Text; events @3 :List(Event); result @4 :GameResult; formatVersion @5 :UInt32; }

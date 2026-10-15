# The final specification

<div class="oy-prose-wiki">

<svg class="oy-diagram oy-diagram-defs" width="0" height="0" aria-hidden="true"><defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z"/></marker></defs></svg>
<h2 id="reading">Reading this page</h2>
<p>This specification describes the expert bot and explains why we chose its methods. It's written for a reader who knows data structures, algorithms and the basics of neural networks, but hasn't seen how a game-playing system like this is put together.</p>
<p>Boxed asides explain a concept the first time it appears, and the <a href="#concepts">concept index</a> lists them all. Figures captioned "textbook" illustrate a general method, while implementation figures identify their source.</p>
<h2 id="objective">Objective</h2>
<p>The objective is first prize in the UNSW Battlecode Loong competition, whose rules are in <a href="https://game.battlecode.au/docs/">the competition documentation</a>. Under the Slay Queen rules from 1 October, a game is won by eliminating the other team. Otherwise, after round 500, the queens (dragons 0 and 1) are compared, then the longest living dragon, then total living length.</p>
<p>The expert line (<code>bots/expert</code>) is the only bot line in development, and its bot is judged by reviewing its decisions in replays in <code>just viewer</code>. Win rates, ratings and other aggregate statistics select games for review and tune parameters, but they don't establish that a decision was sound.</p>
<h2 id="game">The game in brief</h2>
<p>Two teams play on a rectangular grid, 10 to 64 cells a side, that wraps at both edges like a torus. Each team controls dragons: snakes whose head moves one cell north, east, south or west each turn while the body follows. Eating a pearl adds a segment. Crossing kelp, or running into your own body or another dragon's, kills the mover, and two heads meeting kill both. Portals join pairs of edges.</p>
<p>A dragon can also sprint several steps in one action, where the first ceil(L/4) steps are free for a dragon of length L and each later step costs a tail segment. It can split, handing its rear k segments to a new dragon, which starts as a fresh program with no memory. There's no way to stand still. A team may have up to 64 dragons alive, and they all act one after another in ID order every round.</p>
<p>Each dragon sees only the 7×7 square around its head and runs in a separate process with no shared memory, so anything beyond that square has to come from memory, inference or teammates. Teammates communicate only by sonar: up to four 64-bit values a turn, one in each direction, each travelling in a straight line until it hits kelp or the first dragon segment. The receiver doesn't learn who sent it, and the enemy can receive it too. On its next turn the sender gets <em>echoes</em>, counts of what its rays hit (kelp, allied body, allied head, enemy body, enemy head). When a dragon dies, alternate segments starting at its head become pearls, ceil(L/2) of them, so a death feeds whoever is nearby.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 300" role="img" aria-label="A dragon on a wrapping grid sees a 7 by 7 window around its head; its sonar rays travel in four directions and stop at the first dragon segment or kelp">
  <rect class="frame" x="20" y="20" width="400" height="260"/>
  <rect class="band" x="130" y="70" width="140" height="140"/>
  <rect class="box" x="190" y="130" width="20" height="20"/>
  <rect class="box" x="170" y="130" width="20" height="20"/>
  <rect class="box" x="150" y="130" width="20" height="20"/>
  <rect class="box" x="150" y="150" width="20" height="20"/>
  <circle class="dot" cx="200" cy="140" r="5"/>
  <circle class="dot" cx="240" cy="100" r="4"/>
  <circle class="dot" cx="90" cy="230" r="4"/>
  <path class="flow" d="M210,140 L370,140" marker-end="url(#arrow)"/>
  <rect class="bad" x="370" y="130" width="20" height="20"/>
  <path class="flow" d="M200,130 L200,30" marker-end="url(#arrow)"/>
  <path class="flow dash" d="M200,280 L200,236" marker-end="url(#arrow)"/>
  <path class="cut" d="M20,236 L60,236"/>
  <text class="small" x="216" y="124">ray east hits an enemy body</text>
  <text class="small" x="208" y="44">ray north wraps</text>
  <text class="small" x="208" y="268">and arrives from the south</text>
  <text class="small" x="28" y="252">kelp edge</text>
  <text class="small" x="134" y="64">7×7 view</text>
  <text class="head" x="450" y="60">One dragon's world</text>
  <text class="small" x="450" y="86">head (filled) and body segments</text>
  <text class="small" x="450" y="106">shaded square: everything it can see</text>
  <text class="small" x="450" y="126">dots: pearls, two of them out of sight</text>
  <text class="small" x="450" y="146">edges of the grid join up (a torus)</text>
  <text class="small" x="450" y="176">Each turn: one MOVE (or sprint) or SPLIT,</text>
  <text class="small" x="450" y="196">plus up to four 64-bit sonar values,</text>
  <text class="small" x="450" y="216">within 100M points, 48 MB, one thread.</text>
</svg>
<figcaption>The game's observation and communication rules</figcaption>
</figure>
<p>Every dragon's turn is metered. The judge, the organisers' program that runs matches, compiles each bot to WebAssembly and charges a fixed number of "points" for every instruction executed. Each dragon gets 100 million points a turn, 48 MB of memory and one thread, and a team's whole submission is at most 4 MB. A dragon that exceeds its points dies.</p>
<p>Teams upload bots to the <em>ladder</em>, the competition's online matchmaking, where ranked games move each team's Elo rating (Elo, 1978). The difference between two teams' ratings predicts how often one beats the other, so a 200-point gap means the stronger side wins about three games in four. The tournaments are played on unseen maps.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 165" role="img" aria-label="The competition: the ladder sets seeds for the Sprint, the Qualifiers and the Grand Final, each a single-elimination knockout on unseen maps">
  <rect class="neutral" x="10" y="40" width="160" height="60" rx="6"/>
  <text class="head" x="90" y="67" text-anchor="middle">Ladder</text>
  <text class="small" x="90" y="83" text-anchor="middle">rating sets the seeds</text>
  <path class="flow" d="M170,70 L208,70" marker-end="url(#arrow)"/>
  <rect class="neutral open" x="210" y="40" width="150" height="60" rx="6"/>
  <text class="head" x="285" y="67" text-anchor="middle">Sprint</text>
  <text class="small" x="285" y="83" text-anchor="middle">1 Oct, done</text>
  <path class="flow" d="M360,70 L398,70" marker-end="url(#arrow)"/>
  <rect class="mixed" x="400" y="40" width="150" height="60" rx="6"/>
  <text class="head" x="475" y="67" text-anchor="middle">Qualifiers</text>
  <text class="small" x="475" y="83" text-anchor="middle">10 Jan, best of 7</text>
  <path class="flow" d="M550,70 L588,70" marker-end="url(#arrow)"/>
  <rect class="good" x="590" y="40" width="120" height="60" rx="6"/>
  <text class="head" x="650" y="67" text-anchor="middle">Grand Final</text>
  <text class="small" x="650" y="83" text-anchor="middle">17 Jan, best of 5</text>
  <text class="small" x="475" y="120" text-anchor="middle">10 places go on</text>
  <text class="small" x="360" y="150" text-anchor="middle">every tournament is a seeded single-elimination knockout on unseen maps, the submission active at each cutoff plays</text>
</svg>
<figcaption>The competition's structure. The objective is first prize at the Grand Final.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-pomdp">
<h3>Partial observability and decentralisation</h3>
<p>A game where you can't see the whole state is a <em>partially observable</em> decision problem (a POMDP; Kaelbling, Littman and Cassandra, 1998). The right decision then depends on your <em>belief</em>, a probability distribution over the states consistent with all your observations and messages. That's why part 1 of the design is a belief, and why the network reads the belief instead of raw observations.</p>
<p>A team whose members decide separately, each with its own partial view, is a <em>decentralised</em> POMDP, and these are provably much harder. Bernstein and colleagues (2002) showed that solving one exactly is NEXP-complete, because a teammate's action depends on what it knows, and you can only guess that. The design's answer, below, is to learn the coordination offline where everything is visible, and execute it separately.</p>
</aside>
<h2 id="design">The design</h2>
<aside class="oy-card oy-alert" id="c-rl">
<h3>Reinforcement learning in one page</h3>
<p>Reinforcement learning (RL; Sutton and Barto, 2018) studies an <em>agent</em> that repeatedly observes a state, chooses an action and eventually receives a reward, here a win, draw or loss. A <em>policy</em> maps what the agent knows to a choice of action, often as probabilities over the legal actions, and a <em>value function</em> estimates the reward to expect from a position under that policy. A game's reward arrives only at the end, so most methods learn a value function to judge the positions in between. A learned value used to grade the policy's choices is called a <em>critic</em>, and that policy an <em>actor</em>.</p>
<p><em>Self-play</em> means the agent learns from games against copies of itself, so it always has an opponent at its own level. <em>Search</em> means looking ahead by simulating possible futures before choosing.</p>
</aside>
<p>The design is expert iteration (Anthony, Tian and Barber, 2017), the scheme behind AlphaGo Zero and AlphaZero (Silver et al., 2017 and 2018), applied to a decentralised team by centralised training with decentralised execution, CTDE (Lowe et al., 2017; Yu et al., 2022). Expensive, fully informed reasoning runs offline, where compute is cheap, to improve the training targets for a small network. During play, each dragon runs that network on its own observations and searches with the rest of its turn's budget.</p>
<aside class="oy-card oy-alert" id="c-exit">
<h3>Expert iteration</h3>
<p>Expert iteration pairs a fast <em>apprentice</em>, a neural network that picks a move in one pass, with a slow <em>expert</em>, a search that looks ahead using the apprentice's judgement as a guide. The search plays better than the network alone, because where the network only guesses at a move's consequences, the search checks them, so the expert's choices make better <em>training targets</em> for the network to reproduce. The apprentice improves by imitating the expert, a better apprentice guides the next search better, and the loop repeats.</p>
<p>Anthony and colleagues named it in 2017 ("thinking fast and slow"), and AlphaGo Zero and AlphaZero used the same loop to reach superhuman Go, chess and shogi from self-play alone.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 200" role="img" aria-label="Expert iteration: the apprentice network guides the expert search, the search's improved choices train the apprentice">
  <rect class="layer" x="40" y="60" width="200" height="80" rx="6"/>
  <text class="head" x="140" y="92" text-anchor="middle">Apprentice (fast)</text>
  <text class="small" x="140" y="114" text-anchor="middle">network: one pass per decision</text>
  <rect class="layer" x="480" y="60" width="200" height="80" rx="6"/>
  <text class="head" x="580" y="92" text-anchor="middle">Expert (slow)</text>
  <text class="small" x="580" y="114" text-anchor="middle">search guided by the network</text>
  <path class="flow" d="M240,80 L478,80" marker-end="url(#arrow)"/>
  <path class="flow" d="M480,120 L242,120" marker-end="url(#arrow)"/>
  <text class="small" x="360" y="70" text-anchor="middle">priors and leaf values guide the search</text>
  <text class="small" x="360" y="160" text-anchor="middle">improved move choices become training targets</text>
</svg>
<figcaption>Textbook: the expert-iteration loop. Each turn of the loop improves both.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-ctde">
<h3>Centralised training, decentralised execution (CTDE)</h3>
<p>During play, each dragon chooses its moves from its own information, but in training nothing stops us showing the learning system everything: every dragon's position, the hidden pearls, the enemy's plan. CTDE exploits that asymmetry. Components that exist only during training, such as a critic that judges positions or a teacher that chooses targets, see the whole board and the whole team, which makes training faster and better informed, while the deployed policy uses only what its dragon can know.</p>
<p>The standard examples are MADDPG (Lowe et al.), where each agent's critic sees all agents, and MAPPO (Yu et al.). Here the privileged parts are the teacher's search and its value network (part 5), and the deployed part is each dragon's network and search (parts 2 and 4).</p>
</aside>
<h3 id="lineage">Related systems</h3>
<p>AlphaGo combined imitation of human play, self-play and tree search. AlphaGo Zero and AlphaZero kept the search and dropped everything else, which is expert iteration in its purest form. AlphaStar and OpenAI Five learned by reinforcement learning in team and hidden-information games, without search at play. This design takes AlphaStar's start from imitation, AlphaZero's search-generated targets and OpenAI Five's one network shared by many units, then adds what Loong needs: a belief for the hidden board, a privileged teacher, and search within each dragon's own budget.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 230" role="img" aria-label="Comparison of AlphaGo, AlphaZero, AlphaStar, OpenAI Five and this design by starting data, source of training targets, search at play, hidden information and number of agents">
  <rect class="good open" x="562" y="8" width="112" height="198" rx="6"/>
  <text class="head" x="170" y="26" text-anchor="middle">AlphaGo</text>
  <text class="head" x="282" y="26" text-anchor="middle">AlphaZero</text>
  <text class="head" x="394" y="26" text-anchor="middle">AlphaStar</text>
  <text class="head" x="506" y="26" text-anchor="middle">OpenAI Five</text>
  <text class="head" x="618" y="26" text-anchor="middle">This design</text>
  <path class="rule" d="M8,36 L712,36"/>
  <text class="head" x="12" y="60" text-anchor="start">Starts from</text>
  <text class="small" x="170" y="60" text-anchor="middle">human games</text>
  <text class="small" x="282" y="60" text-anchor="middle">random</text>
  <text class="small" x="394" y="60" text-anchor="middle">human games</text>
  <text class="small" x="506" y="60" text-anchor="middle">random</text>
  <text class="small" x="618" y="60" text-anchor="middle">top teams' games</text>
  <path class="rule" d="M8,72 L712,72"/>
  <text class="head" x="12" y="92" text-anchor="start">Targets from</text>
  <text class="small" x="170" y="92" text-anchor="middle">policy gradient</text>
  <text class="small" x="282" y="92" text-anchor="middle">its own search</text>
  <text class="small" x="394" y="92" text-anchor="middle">gradient + league</text>
  <text class="small" x="506" y="92" text-anchor="middle">policy gradient</text>
  <text class="small" x="618" y="92" text-anchor="middle">privileged search</text>
  <path class="rule" d="M8,104 L712,104"/>
  <text class="head" x="12" y="124" text-anchor="start">Search at play</text>
  <text class="small" x="170" y="124" text-anchor="middle">MCTS + rollouts</text>
  <text class="small" x="282" y="124" text-anchor="middle">MCTS</text>
  <text class="small" x="394" y="124" text-anchor="middle">none</text>
  <text class="small" x="506" y="124" text-anchor="middle">none</text>
  <text class="small" x="618" y="124" text-anchor="middle">IS-MCTS</text>
  <path class="rule" d="M8,136 L712,136"/>
  <text class="head" x="12" y="156" text-anchor="start">Hidden info</text>
  <text class="small" x="170" y="156" text-anchor="middle">none</text>
  <text class="small" x="282" y="156" text-anchor="middle">none</text>
  <text class="small" x="394" y="156" text-anchor="middle">fog of war</text>
  <text class="small" x="506" y="156" text-anchor="middle">fog of war</text>
  <text class="small" x="618" y="156" text-anchor="middle">7×7 + sonar</text>
  <path class="rule" d="M8,168 L712,168"/>
  <text class="head" x="12" y="188" text-anchor="start">Agents</text>
  <text class="small" x="170" y="188" text-anchor="middle">one</text>
  <text class="small" x="282" y="188" text-anchor="middle">one</text>
  <text class="small" x="394" y="188" text-anchor="middle">one player</text>
  <text class="small" x="506" y="188" text-anchor="middle">5, shared weights</text>
  <text class="small" x="618" y="188" text-anchor="middle">≤64, one each</text>
  <path class="rule" d="M8,200 L712,200"/>
</svg>
<figcaption>Textbook comparison of the reference systems, with this design's choices for each.</figcaption>
</figure>
<p>Two measured limits shaped this. Simulating the whole team faithfully for every decision doesn't fit in a dragon's turn, so decision quality has to come from what the network learns offline. And hand-weighted scores, which don't check the consequences of a choice, plateau, so the learned value and the search together replace them.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 300" role="img" aria-label="Training loop: league games feed an offline teacher, whose improved targets train the network; the network is exported to the bot, which plays new league games">
  <rect class="layer" x="20" y="30" width="180" height="70" rx="6"/>
  <text class="head" x="110" y="58" text-anchor="middle">League games</text>
  <text class="small" x="110" y="80" text-anchor="middle">pool, mimics, self-play</text>
  <rect class="layer" x="270" y="30" width="180" height="70" rx="6"/>
  <text class="head" x="360" y="58" text-anchor="middle">Offline teacher</text>
  <text class="small" x="360" y="80" text-anchor="middle">full-board critic and search</text>
  <rect class="layer" x="520" y="30" width="180" height="70" rx="6"/>
  <text class="head" x="610" y="58" text-anchor="middle">Network training</text>
  <text class="small" x="610" y="80" text-anchor="middle">policy and value targets</text>
  <rect class="layer" x="520" y="190" width="180" height="70" rx="6"/>
  <text class="head" x="610" y="218" text-anchor="middle">Export</text>
  <text class="small" x="610" y="240" text-anchor="middle">quantised, metered in the judge</text>
  <rect class="layer" x="270" y="190" width="180" height="70" rx="6"/>
  <text class="head" x="360" y="218" text-anchor="middle">Expert bot</text>
  <text class="small" x="360" y="240" text-anchor="middle">registered judge build</text>
  <rect class="box" x="20" y="190" width="180" height="70" rx="6"/>
  <text class="head" x="110" y="218" text-anchor="middle">Replay review</text>
  <text class="small" x="110" y="240" text-anchor="middle">Review in the viewer</text>
  <path class="flow" d="M200,65 L268,65" marker-end="url(#arrow)"/>
  <path class="flow" d="M450,65 L518,65" marker-end="url(#arrow)"/>
  <path class="flow" d="M610,100 L610,188" marker-end="url(#arrow)"/>
  <path class="flow" d="M520,225 L452,225" marker-end="url(#arrow)"/>
  <path class="flow" d="M360,190 L200,100" marker-end="url(#arrow)"/>
  <path class="flow dash" d="M270,240 L202,240" marker-end="url(#arrow)"/>
  <text class="small" x="290" y="132" text-anchor="start">joins the pool</text>
</svg>
<figcaption>Intended design: the training loop.</figcaption>
</figure>
<p>Reading the loop clockwise, games are played against a <em>league</em> of opponents (part 6):</p>
<table>
<thead><tr><th>Opponent</th><th>Description</th></tr></thead>
<tbody>
<tr><td>Foil</td><td>Our earlier hand-written bot and our strongest, in its version foil-0039.</td></tr>
<tr><td>Pool</td><td>Frozen copies of earlier bots, compiled once and stored as registered builds so each plays identically every time.</td></tr>
<tr><td>Mimics</td><td>Networks trained to play like particular top ladder teams.</td></tr>
<tr><td>Current network</td><td>The network plays against itself.</td></tr>
</tbody>
</table>
<p>The <em>teacher</em> (part 5) replays positions from those games with a full view of the board and searches for better moves. The network is trained on them, <em>exported</em> as integer code for the judge (part 2), and built into the bot, which joins the league.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 230" role="img" aria-label="One dragon's turn: the belief feeds the options, the network scores them, search checks them, and the route controller emits the action and sonar">
  <rect class="box" x="10" y="80" width="110" height="64" rx="6"/>
  <text class="head" x="65" y="106" text-anchor="middle">Observation</text>
  <text class="small" x="65" y="126" text-anchor="middle">7×7 view, inbox</text>
  <rect class="layer" x="150" y="80" width="110" height="64" rx="6"/>
  <text class="head" x="205" y="106" text-anchor="middle">1 Belief</text>
  <text class="small" x="205" y="126" text-anchor="middle">input planes</text>
  <rect class="layer" x="290" y="80" width="110" height="64" rx="6"/>
  <text class="head" x="345" y="106" text-anchor="middle">3 Options</text>
  <text class="small" x="345" y="126" text-anchor="middle">candidates</text>
  <rect class="layer" x="430" y="20" width="120" height="64" rx="6"/>
  <text class="head" x="490" y="46" text-anchor="middle">2 Network</text>
  <text class="small" x="490" y="66" text-anchor="middle">priors and values</text>
  <rect class="layer" x="430" y="140" width="120" height="64" rx="6"/>
  <text class="head" x="490" y="166" text-anchor="middle">4 Search</text>
  <text class="small" x="490" y="186" text-anchor="middle">rest of the budget</text>
  <rect class="box" x="590" y="80" width="120" height="64" rx="6"/>
  <text class="head" x="650" y="106" text-anchor="middle">Route controller</text>
  <text class="small" x="650" y="126" text-anchor="middle">action and sonar</text>
  <path class="flow" d="M120,112 L148,112" marker-end="url(#arrow)"/>
  <path class="flow" d="M260,112 L288,112" marker-end="url(#arrow)"/>
  <path class="flow" d="M400,100 L428,60" marker-end="url(#arrow)"/>
  <path class="flow" d="M490,84 L490,138" marker-end="url(#arrow)"/>
  <path class="flow" d="M550,52 L588,100" marker-end="url(#arrow)"/>
  <path class="flow" d="M550,172 L588,128" marker-end="url(#arrow)"/>
</svg>
<figcaption>Intended design: one dragon's turn. Every dragon searches within its own budget.</figcaption>
</figure>
<p>Within one turn, the dragon updates what it believes from what it sees and hears (part 1). Its <em>options</em> (part 3) propose a short list of <em>candidates</em>, concrete actions for this turn such as "head for that pearl" or "escape east". The network (part 2) gives each candidate a <em>prior</em>, its estimated probability of being the best choice, and estimates the position's value. Search (part 4) checks the most promising candidates by simulating ahead, and a <em>route controller</em> turns the chosen candidate into this turn's move and sonar.</p>
<h3 id="principles">Principles for every component</h3>
<p>Every component is optimised towards its floor before the parts are balanced against each other, and its measured cost is reported against two lower bounds. Its <em>algorithm's floor</em> is its current algorithm's lowest possible cost in judge points, with each operation at its cheapest legal WebAssembly sequence. Its <em>operation's bound</em> is the lowest cost of any algorithm computing the same thing. For the network, the judge's prices allow at most about 3.2 multiply-adds a point (<a href="#budget">Budget</a>).</p>
<aside class="oy-card oy-alert" id="c-floors">
<h3>Floors and bounds</h3>
<p>Because the judge prices every instruction exactly, "how fast could this be?" has a precise answer in two layers. Take sorting. A particular merge sort, written as tightly as the instruction prices allow, costs at least its unavoidable loads, compares and stores, which is its floor. But no comparison sort beats roughly n log n comparisons, and if the keys are small integers a counting sort does even less work, so the cheapest possible method costs less still. A gap to the floor is closed by tightening the code, and a gap between the floor and the bound by a cheaper algorithm.</p>
</aside>
<p>Every constant in the bot, the teacher and the trainer (caps, radii, counts, exploration constants, expiries and reserves) is set by a derivation, a bound or a decision-theoretic criterion wherever theory gives one. It's measured only where theory gives none, or to confirm a rule: the bot's constants at equal cost in the judge, and the offline stages' by strength gained per GPU-second and per dollar. A constant set by neither is a placeholder.</p>
<p>Each part's method is a choice among known methods. Once the current design is implemented, optimised to its floors and playing on the ladder, so that its rating is the baseline, each of the seven parts gets a decision record covering:</p>
<table>
<thead><tr><th>Entry</th><th>Required content</th></tr></thead>
<tbody>
<tr><td>Known methods</td><td>The best known methods for the problem, including recent work and other teams' approaches.</td></tr>
<tr><td>Chosen method</td><td>The method and the theory or measurement behind it.</td></tr>
<tr><td>Credible contenders</td><td>An equal-cost test against the current method, or a stated reason for rejecting each contender.</td></tr>
</tbody>
</table>
<p>A contender that wins replaces the method, after a reviewed specification change. The records are revisited where the evidence points: information gaps in the value-lost report (part 5, which sorts every departure from the teacher's choice into one of three causes) point to the belief and sonar, ranking gaps to the network, candidate gaps to the options, and a search that loses to its own network to the search.</p>
<h2 id="parts">The seven parts</h2>
<h3 id="belief">1. Belief state per dragon</h3>
<p>Each dragon keeps a hand-built Bayes-filter world model (Thrun, Burgard and Fox, <em>Probabilistic Robotics</em>) of the map, pearl timers, enemy sightings and decoded sonar, and encodes it as a stack of input planes for the network. The filters do the inference explicitly, so the network has less to learn and can be smaller.</p>
<aside class="oy-card oy-alert" id="c-encoding">
<h3>Encoding, planes and channels</h3>
<p>The belief is <em>encoded</em> into fixed arrays. Spatial facts become <em>planes</em>, one number per map cell, such as "pearl chance here" or "kelp on this cell's left edge", stacked into height × width × <em>channels</em> like an image with 56 channels instead of 3. Facts that aren't spatial, such as the round or our length, become a vector of <em>scalars</em>, and each candidate move gets its own small record of bytes.</p>
<p>Two rules make encoding safe. Every value is an integer byte, so the bot and the GPU training engine produce identical inputs, bit for bit. And nothing privileged leaks in, because a network trained on information unavailable to the bot would learn to rely on it and fail in play.</p>
</aside>
<aside class="oy-card oy-alert" id="c-bayes">
<h3>Bayes filters</h3>
<p>A Bayes filter keeps a probability distribution over a hidden quantity, say where an unseen enemy's head is, and updates it in two alternating steps. <em>Predict</em> pushes the distribution forward one round with a model of how the quantity moves, spreading probability to every cell within the enemy's reach. <em>Correct</em> multiplies each possibility by how likely the latest observation would be if it were true and renormalises, and seeing an empty cell counts as an observation too. Confidence then behaves correctly by construction: an enemy last seen ten rounds ago could be anywhere within ten moves, and prediction spreads it exactly that far, with no hand-tuned "forget after N rounds" timer.</p>
</aside>
<h4 id="belief-filters">The remembered map and the filters</h4>
<aside class="oy-card oy-alert" id="c-filters">
<h3>Histogram, Bernoulli and renewal filters</h3>
<p>A <em>histogram filter</em> represents the distribution as discrete states with weights, here (cell, heading) pairs for an enemy's head. Prediction moves each state's weight to its legal successors and correction zeroes the states ruled out by an observation, so its cost grows with the number of states kept. A <em>Bernoulli filter</em> tracks whether the dragon is still alive, since a dragon can die out of sight, and unplaceable weight in the position filter is evidence it may be dead.</p>
<p>A <em>renewal process</em> models events that recur after random waiting times, such as a pearl tile's next spawn attempt, which comes a uniformly random number of rounds after the last, between a hidden minimum and maximum gap. A <em>hidden Markov model</em> is a chain of hidden states that switch with known probabilities and emit observations, such as a cell's pearl, switched on by spawns and off by being eaten, and seen only inside our window.</p>
</aside>
<p>The remembered map is the observation layer: every cell's latest sighting, by the dragon or a teammate, with its round. Over it, every other dragon has a Bernoulli filter for its chance of being alive and a histogram filter over its head's cell and heading (Ristic et al., 2013; Thrun, Burgard and Fox, section 4.1). Lengths are exact where a whole body or a status shows them, a status being a dragon's own report about itself over sonar. Each filter also keeps its dragon's body as last seen. The segment i places behind the head stays put for length − 1 − i of the dragon's moves, so a sampled state joins the drawn head to that body by a shortest way through free cells and keeps the seen segments in place, instead of laying the body straight. A queen's filter is never dropped, and not seeing her moves her without lowering her chance of being alive. Each spawning tile has a renewal process for its next attempt (Feller), and each cell's pearl a two-state hidden Markov model.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 330" role="img" aria-label="The belief's components: sight and sonar update the remembered map, and filters over it are encoded as planes">
  <rect class="box" x="8" y="10" width="150" height="46" rx="6"/>
  <text class="head" x="83" y="30" text-anchor="middle">Sight</text>
  <text class="small" x="83" y="47" text-anchor="middle">the 7×7 window</text>
  <rect class="box" x="8" y="70" width="150" height="46" rx="6"/>
  <text class="head" x="83" y="90" text-anchor="middle">Sonar</text>
  <text class="small" x="83" y="107" text-anchor="middle">records, echoes</text>
  <rect class="layer" x="200" y="30" width="180" height="66" rx="6"/>
  <text class="head" x="290" y="50" text-anchor="middle">Remembered map</text>
  <text class="small" x="290" y="67" text-anchor="middle">each cell's latest sighting</text>
  <text class="small" x="290" y="82" text-anchor="middle">with its round and source</text>
  <path class="flow" d="M158,33 L198,50" marker-end="url(#arrow)"/>
  <path class="flow" d="M158,93 L198,76" marker-end="url(#arrow)"/>
  <rect class="mixed" x="430" y="10" width="180" height="56" rx="6"/>
  <text class="head" x="520" y="30" text-anchor="middle">Each other dragon</text>
  <text class="small" x="520" y="47" text-anchor="middle">Bernoulli: alive?</text>
  <text class="small" x="520" y="62" text-anchor="middle">histogram: head cell, heading</text>
  <path class="flow" d="M380,63 L428,38" marker-end="url(#arrow)"/>
  <rect class="mixed" x="430" y="72" width="180" height="56" rx="6"/>
  <text class="head" x="520" y="92" text-anchor="middle">Each spawning tile</text>
  <text class="small" x="520" y="109" text-anchor="middle">renewal process:</text>
  <text class="small" x="520" y="124" text-anchor="middle">its next attempt</text>
  <path class="flow" d="M380,63 L428,100" marker-end="url(#arrow)"/>
  <rect class="mixed" x="430" y="134" width="180" height="56" rx="6"/>
  <text class="head" x="520" y="154" text-anchor="middle">Each cell's pearl</text>
  <text class="small" x="520" y="171" text-anchor="middle">two-state hidden</text>
  <text class="small" x="520" y="186" text-anchor="middle">Markov model</text>
  <path class="flow" d="M380,63 L428,162" marker-end="url(#arrow)"/>
  <rect class="mixed" x="430" y="196" width="180" height="56" rx="6"/>
  <text class="head" x="520" y="216" text-anchor="middle">The map</text>
  <text class="small" x="520" y="233" text-anchor="middle">which of 3 symmetries,</text>
  <text class="small" x="520" y="248" text-anchor="middle">fill where all agree</text>
  <path class="flow" d="M380,63 L428,224" marker-end="url(#arrow)"/>
  <rect class="mixed" x="430" y="258" width="180" height="56" rx="6"/>
  <text class="head" x="520" y="278" text-anchor="middle">Each teammate</text>
  <text class="small" x="520" y="295" text-anchor="middle">its latest intention</text>
  <text class="small" x="520" y="310" text-anchor="middle">and target</text>
  <path class="flow" d="M380,63 L428,286" marker-end="url(#arrow)"/>
  <rect class="good" x="640" y="130" width="72" height="60" rx="6"/>
  <text class="head" x="676" y="150" text-anchor="middle">Planes</text>
  <text class="small" x="676" y="167" text-anchor="middle">for the</text>
  <text class="small" x="676" y="182" text-anchor="middle">network</text>
  <path class="flow" d="M610,38 L638,160" marker-end="url(#arrow)"/>
  <path class="flow" d="M610,100 L638,160" marker-end="url(#arrow)"/>
  <path class="flow" d="M610,162 L638,160" marker-end="url(#arrow)"/>
  <path class="flow" d="M610,224 L638,160" marker-end="url(#arrow)"/>
  <path class="flow" d="M610,286 L638,160" marker-end="url(#arrow)"/>
</svg>
<figcaption>Part 1's belief: the observation layer and the filters built over it.</figcaption>
</figure>
<h4 id="belief-sonar">Sonar</h4>
<p>The teacher sees the whole board and needs no sonar, so sonar's content is chosen by how much of the teacher's advantage it recovers for the dragons in play (part 5). Other teams can decode our broadcasts as we decode theirs, so they're encrypted with a key for each team, derived from a secret kept out of source control. In self-play neither side reads the other's sonar either, and a message carries only what its sender knows while delivery uses the true state.</p>
<p>Each ray carries one frame of several variable-length records chosen for the ray's likely reader, with check bits that reject the other team's values and noise. The number of check bits minimises expected loss: the chance a forged frame is accepted times that forgery's cost, plus the bits times their value if they carried facts instead. A received fact enters the filters as an observation, so its confidence decays by prediction. Relays keep their facts' original rounds, newer facts replace older ones, sight beats report, and a dragon ignores its own reports when they come back. A teammate's intention record (its chosen option and where it's heading, part 3) becomes its latest plan in the belief, so the crop marks its target, a candidate aimed at the same target says so, and the search's samples move that teammate toward it.</p>
<aside class="oy-card oy-alert" id="c-checkbits">
<h3>Encryption and check bits</h3>
<p>The bot enciphers each 64-bit frame with SPECK (Beaulieu et al., 2013), a small block cipher designed for constrained hardware, under a key derived per team. The enemy, receiving our ray, sees noise, and so do we when we decipher the enemy's ray with our key. To tell our frames from noise, every frame ends with a required run of zero bits. Random noise passes k zero bits with probability 2<sup>−k</sup>, so each check bit halves the forgery rate but costs a bit that could carry a fact, and the expected-loss rule above sets the count.</p>
<p>Inside a frame, numbers such as dragon IDs, ages and lengths are written as exponential-Golomb codes (Golomb, 1966; Teuhola, 1978), in which small numbers take few bits and larger ones more. Most ages and IDs are small, so most records are short, and more fit in a ray.</p>
</aside>
<h4 id="belief-symmetry">Map symmetry</h4>
<p>Every map is a left–right mirror, a top–bottom mirror or a half turn, and bots aren't told which. The belief rules a symmetry out when partner edges differ, or when partner spawns can't share a countdown (one spawns and the other doesn't, or an attempt still to come differs at both sightings), using its own sight and teammates' relayed map facts. A forged value can occasionally pass the check bits, so a teammate's report needs confirmation before it rules a symmetry out. Until then a contradicting report only lowers that symmetry's weight, and the next report of the same fact replaces it. Once one symmetry is settled, a reported edge or spawn that differs from its settled partner is refused, because a forger doesn't know the map.</p>
<p>The map never changes, so a symmetry ruled out stays out, and each turn only that turn's new facts are checked. The belief fills each unseen edge, spawn and countdown wherever every remaining symmetry agrees, marked as inferred. The enemy queen starts at our queen's start mirrored by the true symmetry, so the belief marks one cell for each symmetry that still fits, at most three, for the network, the search's samples and the queen strike (an option that attacks the enemy queen, part 3). Current positions are never inferred by symmetry.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 200" role="img" aria-label="The three map symmetries: a seen cell's partner under a left-right mirror, a top-bottom mirror and a half turn">
  <rect class="frame" x="20" y="30" width="200" height="130"/>
  <path class="rule" d="M120,30 L120,160"/>
  <rect class="layer" x="40" y="50" width="16" height="16"/>
  <rect class="box" x="184" y="50" width="16" height="16"/>
  <text class="head" x="120" y="185" text-anchor="middle">Left–right mirror</text>
  <rect class="frame" x="260" y="30" width="200" height="130"/>
  <path class="rule" d="M260,95 L460,95"/>
  <rect class="layer" x="280" y="50" width="16" height="16"/>
  <rect class="box" x="280" y="124" width="16" height="16"/>
  <text class="head" x="360" y="185" text-anchor="middle">Top–bottom mirror</text>
  <rect class="frame" x="500" y="30" width="200" height="130"/>
  <circle class="dot" cx="600" cy="95" r="3"/>
  <rect class="layer" x="520" y="50" width="16" height="16"/>
  <rect class="box" x="664" y="124" width="16" height="16"/>
  <text class="head" x="600" y="185" text-anchor="middle">Half turn</text>
  <text class="small" x="360" y="20" text-anchor="middle">teal: a seen cell; gold: where its partner would be under each symmetry</text>
</svg>
<figcaption>Textbook: the three symmetries allowed by the rules. Each seen fact predicts a different partner cell under each, so a mismatch rules a symmetry out.</figcaption>
</figure>
<h4 id="belief-implementation">Implementation and filter size</h4>
<p>The belief is one integer implementation in the shared library, run identically by the bot and the <em>GPU engine</em>, our own CUDA simulator of the game, which plays thousands of games side by side for training, each in its own <em>lane</em> of the batch. Each filter's size is set adaptively within the turn's budget by a bound on its approximation error, the KL bound of KLD-sampling (Fox, 2003) or its effective sample size (its weights' worth in equally weighted states), instead of fixed caps on states, on the dragons tracked or on a drop threshold. Equal-cost comparisons set the bound.</p>
<aside class="oy-card oy-alert" id="c-kld">
<h3>KL divergence and KLD-sampling</h3>
<p>The Kullback–Leibler divergence (Kullback and Leibler, 1951) KL(p‖q) = Σ p(x) log(p(x)/q(x)) measures how much information is lost when a distribution q stands in for the true p. When a filter keeps only its heaviest states, holding total probability P, the loss is −log P, so keeping the fewest states whose total weight is at least e<sup>−ε</sup> bounds the error at ε exactly. Fox's KLD-sampling applied the same idea to particle filters, letting the number of samples grow when the distribution spreads out and shrink when it concentrates. A confined enemy needs a handful of states, and a long-unseen one many more.</p>
</aside>
<h4 id="belief-checks">Belief calibration and informativeness</h4>
<p>Identical bytes from the bot and the GPU engine only prove the two agree, so the belief is also checked against the true state of recorded and self-play games. Some checks hold whatever the opponents do and are settled once: no impossible state, certainty wherever the rules determine it, and coverage, meaning the truth stays inside the filter's support (the states with any probability), and a motion model that never gives a legal move zero probability guarantees it except where caps drop states. Calibration and informativeness depend on how the opponents move, so they're measured every training cycle and again whenever fresh ladder games arrive.</p>
<aside class="oy-card oy-alert" id="c-calibration">
<h3>Calibration and informativeness</h3>
<p>An event given 30% either happens or not, so a single probability can't be checked. <em>Calibration</em> can: across all the belief's 30% predictions, about 30% should come true, and the weighted average gap between stated and observed rates across bands is the <em>expected calibration error</em> (ECE; Guo et al., 2017). But a belief that says "uniformly anywhere" is perfectly calibrated and useless, so <em>informativeness</em> scores the belief's average log-probability for the truth, a proper scoring rule, so hedging can't game it (Gneiting and Raftery, 2007). Comparing it with the remembered map alone shows what the filters add.</p>
</aside>
<h3 id="network">2. The policy and value network</h3>
<p>The network reads the belief planes of part 1 and the candidates of part 3, and returns a score for each candidate and a value for the position. The judge prices every instruction at a fixed cost, so an evaluation's cost is an exact function of the network's shape, and the rest of the turn is sized from it (<a href="#budget">Budget</a>). It runs in exact integer arithmetic, int8 weights times 7-bit activations, sixteen multiply-adds an instruction, with its weights compiled into the code (<a href="#network-integer">below</a>), so the bot reproduces the trained network bit for bit.</p>
<aside class="oy-card oy-alert" id="c-policyvalue">
<h3>Policy and value heads</h3>
<p>The network answers two questions at once. Its <em>policy</em> output scores each candidate move by how likely the expert would be to choose it, and its <em>value</em> output estimates how the game will end from here. AlphaZero showed that one network with a shared body and two small "heads" learns both better than two separate networks, because what makes a position good and what makes a move good depend on the same features. The policy tells the search where to look, and the value tells it how good a position is without playing it out.</p>
</aside>
<aside class="oy-card oy-alert" id="c-conv">
<h3>Crops, stems and trunks</h3>
<p>The network reads a <em>crop</em>: a small window of cells around the dragon's head, turned so "ahead" is always up. Near the head is where precise detail matters, and a fixed-size, head-centred window lets the same weights work on every map size.</p>
<p>The first 3 × 3 convolution over the crop is the <em>stem</em>, and the stack of identical layers after it the <em>trunk</em>. Each of a kernel's 3 × 3 positions is a <em>tap</em>. Every layer grows each output's <em>receptive field</em>, the input area that determines it, by two cells, so after the stem and four trunk layers each output sees an 11 × 11 neighbourhood.</p>
</aside>
<p>The network is feed-forward, with memory in the belief instead of a recurrent layer. Its shape is chosen by playing candidates of equal measured cost against each other in the training loop, recurrent ones included. Until that comparison runs, the bot's network is a placeholder shape from the kickstart (part 5): about 0.42M weights in a 3 × 3 stem and four 3 × 3 trunk layers of 32 channels. An evaluation is most of a search simulation's cost, so the network's shape sets how many simulations a turn affords.</p>
<p>Beside the crop, the network reads a 15 × 15 overview of the whole map, a vector of scalars and a 48-byte record for each candidate. A candidate's record includes the room left after its action: the cells reachable from its end, at most 32, with the dragon's own segments admitted once they've left, and with cells where another dragon was seen this round, or a first step beside another dragon's head seen this round, shut.</p>
<p>The body summarises the trunk, the overview and the scalars into a global vector, which the value head turns into one number. The policy head runs once for each candidate on the trunk's features at the cell where that candidate ends, the candidate's own bytes and a context from the global vector, and a softmax over the candidates' scores gives the policy.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 560" role="img" aria-label="The network drawn as arrays: the crop passes through the stem and trunk, joins the overview and scalars in a global vector, and feeds a value head and a per-candidate policy head">
  <rect class="frame" x="8" y="8" width="704" height="318" rx="6"/>
  <text class="head" x="20" y="28">Body, shared by both heads</text>
  <rect class="box" x="44" y="56" width="64" height="64"/>
  <rect class="box" x="40" y="60" width="64" height="64"/>
  <rect class="box" x="36" y="64" width="64" height="64"/>
  <rect class="box" x="32" y="68" width="64" height="64"/>
  <rect class="box" x="28" y="72" width="64" height="64"/>
  <rect class="box" x="24" y="76" width="64" height="64"/>
  <text class="small" x="64" y="160" text-anchor="middle">crop window, 17×17</text>
  <text class="small" x="64" y="174" text-anchor="middle">× 56 channels</text>
  <path class="flow" d="M112,108 L136,108" marker-end="url(#arrow)"/>
  <text class="small" x="124" y="98" text-anchor="middle">stem</text>
  <rect class="layer" x="154" y="68" width="56" height="56"/>
  <rect class="layer" x="150" y="72" width="56" height="56"/>
  <rect class="layer" x="146" y="76" width="56" height="56"/>
  <rect class="layer" x="142" y="80" width="56" height="56"/>
  <text class="small" x="176" y="160" text-anchor="middle">15×15 × 32</text>
  <path class="flow" d="M216,108 L244,108" marker-end="url(#arrow)"/>
  <text class="small" x="230" y="98" text-anchor="middle">trunk</text>
  <rect class="layer" x="262" y="68" width="56" height="56"/>
  <rect class="layer" x="258" y="72" width="56" height="56"/>
  <rect class="layer" x="254" y="76" width="56" height="56"/>
  <rect class="layer" x="250" y="80" width="56" height="56"/>
  <rect class="dot" x="292" y="120" width="8" height="8"/>
  <text class="small" x="284" y="160" text-anchor="middle">15×15 × 32,</text>
  <text class="small" x="284" y="174" text-anchor="middle">4 layers of 3×3</text>
  <path class="flow" d="M324,108 L352,108" marker-end="url(#arrow)"/>
  <text class="small" x="338" y="98" text-anchor="middle">1×1</text>
  <rect class="layer" x="362" y="80" width="48" height="48"/>
  <rect class="layer" x="358" y="84" width="48" height="48"/>
  <text class="small" x="386" y="160" text-anchor="middle">15×15 × 16</text>
  <path class="flow" d="M414,108 L446,108" marker-end="url(#arrow)"/>
  <text class="small" x="430" y="98" text-anchor="middle">dense</text>
  <rect class="layer" x="452" y="76" width="14" height="64"/>
  <text class="small" x="459" y="160" text-anchor="middle">64</text>
  <rect class="box" x="32" y="192" width="48" height="48"/>
  <rect class="box" x="28" y="196" width="48" height="48"/>
  <rect class="box" x="24" y="200" width="48" height="48"/>
  <text class="small" x="56" y="268" text-anchor="middle">overview, 15×15 × 16</text>
  <path class="flow" d="M88,224 L136,224" marker-end="url(#arrow)"/>
  <text class="small" x="112" y="214" text-anchor="middle">3×3</text>
  <rect class="layer" x="150" y="192" width="48" height="48"/>
  <rect class="layer" x="146" y="196" width="48" height="48"/>
  <rect class="layer" x="142" y="200" width="48" height="48"/>
  <text class="small" x="174" y="268" text-anchor="middle">15×15 × 16</text>
  <path class="flow" d="M206,224 L248,224" marker-end="url(#arrow)"/>
  <text class="small" x="227" y="214" text-anchor="middle">dense</text>
  <rect class="layer" x="254" y="204" width="14" height="40"/>
  <text class="small" x="261" y="262" text-anchor="middle">32</text>
  <rect class="box" x="24" y="288" width="64" height="14"/>
  <text class="small" x="24" y="318">scalars, 48 bytes</text>
  <path class="flow" d="M88,295 L248,295" marker-end="url(#arrow)"/>
  <text class="small" x="168" y="288" text-anchor="middle">dense</text>
  <rect class="layer" x="254" y="282" width="14" height="28"/>
  <text class="small" x="274" y="318">32</text>
  <rect class="good" x="560" y="110" width="16" height="140"/>
  <path class="flow" d="M466,108 L556,150" marker-end="url(#arrow)"/>
  <path class="flow" d="M268,224 L556,190" marker-end="url(#arrow)"/>
  <path class="flow" d="M268,296 L556,232" marker-end="url(#arrow)"/>
  <text class="head" x="586" y="160">Global vector</text>
  <text class="small" x="586" y="178">64 + 32 + 32 joined,</text>
  <text class="small" x="586" y="192">then dense → 128</text>
  <rect class="frame" x="8" y="344" width="200" height="200" rx="6"/>
  <text class="head" x="20" y="364">Value head</text>
  <rect class="good" x="28" y="420" width="160" height="56" rx="6"/>
  <text class="head" x="108" y="444" text-anchor="middle">Value</text>
  <text class="small" x="108" y="462" text-anchor="middle">dense 128 → 1 number</text>
  <path class="flow" d="M564,250 L564,332 L108,332 L108,418" marker-end="url(#arrow)"/>
  <rect class="frame" x="224" y="344" width="488" height="200" rx="6"/>
  <text class="head" x="236" y="364">Policy head, once per candidate</text>
  <rect class="layer" x="244" y="400" width="110" height="44" rx="6"/>
  <text class="small" x="299" y="418" text-anchor="middle">trunk vector at</text>
  <text class="small" x="299" y="434" text-anchor="middle">its end cell, 32</text>
  <rect class="box" x="366" y="400" width="110" height="44" rx="6"/>
  <text class="small" x="421" y="418" text-anchor="middle">candidate's record,</text>
  <text class="small" x="421" y="434" text-anchor="middle">48 bytes</text>
  <rect class="layer" x="488" y="400" width="110" height="44" rx="6"/>
  <text class="small" x="543" y="418" text-anchor="middle">context,</text>
  <text class="small" x="543" y="434" text-anchor="middle">dense 128 → 32</text>
  <path class="flow dash" d="M300,124 L340,124 L340,340 L232,340 L232,422 L242,422" marker-end="url(#arrow)"/>
  <path class="flow" d="M572,250 L572,380 L543,380 L543,398" marker-end="url(#arrow)"/>
  <rect class="layer" x="300" y="476" width="190" height="48" rx="6"/>
  <text class="head" x="395" y="496" text-anchor="middle">dense → 32 → 1</text>
  <text class="small" x="395" y="514" text-anchor="middle">this candidate's score</text>
  <rect class="good" x="520" y="476" width="176" height="48" rx="6"/>
  <text class="head" x="608" y="496" text-anchor="middle">Policy</text>
  <text class="small" x="608" y="514" text-anchor="middle">softmax over candidates</text>
  <path class="flow" d="M299,444 L360,474" marker-end="url(#arrow)"/>
  <path class="flow" d="M421,444 L405,474" marker-end="url(#arrow)"/>
  <path class="flow" d="M543,444 L450,474" marker-end="url(#arrow)"/>
  <path class="flow" d="M490,500 L518,500" marker-end="url(#arrow)"/>
</svg>
<figcaption>The network as the trainer builds it (<code>tools/learning/trainer/network.cc</code>, <code>ExpertNetworkImpl::run</code>), each array drawn as a block whose depth is its channels. The filled cell on the trunk is one candidate's end cell, whose 32-number column feeds the policy head. The layers are a plain stack without skip connections, and every rectified layer (one that zeroes negative outputs, like a ReLU) clamps its outputs to 0–127. </figcaption>
</figure>
<p>Four additions to the inputs, all drawn from what the belief already holds, remain to be built:</p>
<ul>
<li>enemy tokens: one for each tracked enemy, summarising its filter (its likely positions and their spread, its length, the time since it was seen, and its reach to our head and to each candidate's route), read by a small set encoder or attention</li>
<li>route features for each candidate: the belief-weighted danger along its route, its arrival margin against the nearest enemy and the share of unknown cells on the way</li>
<li>spatial features for candidates far from the head, taken from the overview or a finer map</li>
<li>a finer whole-map layer than the overview</li>
</ul>
<p>The value head reads the enemy tokens' lengths among its inputs. Each addition stays only if it wins against the current inputs at equal measured cost.</p>
<aside class="oy-card oy-alert" id="c-tokens">
<h3>Set encoders and attention</h3>
<p>The number of tracked enemies varies, and their order means nothing, so they don't fit a fixed-size plane. A <em>set encoder</em> applies the same small network to each enemy's summary (its token) and then pools the results with a sum or maximum, which gives the same answer however the tokens are ordered (Deep Sets; Zaheer et al., 2017). <em>Attention</em> (Vaswani et al., 2017) goes further: each token's contribution is weighted by how relevant it is to a query, such as a particular candidate's route. AlphaStar and OpenAI Five (Berner et al., 2019) read units this way.</p>
</aside>
<h4 id="network-integer">Integer arithmetic in the judge</h4>
<aside class="oy-card oy-alert" id="c-quant">
<h3>Quantisation to int8</h3>
<p><em>Quantisation</em> stores each weight as an 8-bit integer, −128 to 127, times a per-layer scale, and each activation as an unsigned 7-bit integer, 0 to 127. A layer computes an exact integer sum of products, and an integer rescale, (sum × multiplier + offset) shifted right, brings the result back into 0–127 for the next layer, clamped at zero where the layer is rectified. Everything is integer, so the bot's answer is exactly reproducible, even across compilers that would round floats differently.</p>
<p>Rounding changes the network's answers, so <em>quantisation-aware training</em> (Jacob et al., 2018) simulates it during training. The forward pass rounds as the bot will, and the backward pass treats rounding as the identity, the <em>straight-through estimator</em> (Bengio, Léonard and Courville, 2013), since rounding's own gradient is zero almost everywhere. The network then learns weights that work after rounding, and the trainer's integer network computes exactly what the bot will.</p>
</aside>
<aside class="oy-card oy-alert" id="c-simd">
<h3>WebAssembly, SIMD and the relaxed dot</h3>
<p>The judge charges every <em>SIMD</em> instruction 2 points whatever its lanes, so one working on sixteen 8-bit values does up to sixteen times a scalar instruction's work for twice the price. WebAssembly's <em>locals</em> act like registers and cost a point to read, while a load from <em>linear memory</em> costs 2 points plus whatever address arithmetic the compiler adds, so a fast kernel keeps its inputs in locals.</p>
<p>The <em>relaxed dot</em>, <code>i32x4.relaxed_dot_i8x16_i7x16_add_s</code>, from WebAssembly's relaxed-SIMD extension, multiplies sixteen int8 weights by sixteen 7-bit activations, adds them in groups of four into four 32-bit sums, and adds those to an accumulator: sixteen multiply-adds in one instruction. Hardware may differ in edge cases, but with the second operand kept within 0–127 every implementation agrees and no intermediate sum can saturate, which is why activations are 7-bit.</p>
</aside>
<p>The weights are <em>immediates</em>, constants written into the instruction stream itself, so loading one costs no memory access or address arithmetic. That's why the network is compiled into the bot as code instead of loaded as data (<a href="#budget">Budget</a>).</p>
<h4 id="network-stem">The turn-stable crop and the incremental stem</h4>
<aside class="oy-card oy-alert" id="c-nnue">
<h3>Efficiently updatable networks (NNUE)</h3>
<p>Computer chess engines such as Stockfish evaluate millions of positions a second because their network updates its first layer after each move. Moving one piece changes only a few inputs, and a layer's output is a sum over inputs, so subtracting the old inputs' contributions and adding the new ones gives the same result for a fraction of the work. Nasu (2018) called this an efficiently updatable neural network, NNUE.</p>
</aside>
<p>The same idea works here if the inputs mostly don't change between evaluations, so the crop's 56 channels are arranged to keep the stem's work across the search's leaves and the dragon's turns. The crop is 17 × 17 real cells around the head in the dragon's frame, so the stem's 15 × 15 outputs see true neighbours instead of a zero border. Channels 0–47 (map memory, edges, dragons, marks, and inferred and told facts) depend only on the cell, the view and the facing. Times in them count from an epoch base 64 to 127 rounds back, so a remembered cell keeps its bytes. Channel 48 holds the round past that base, and the network derives each age from it. Channels 49–55 hold what moves every round, such as the filters' head chances and the steps from the head, so they're read at the stem's centre tap only.</p>
<p>The bot caches each stem output's int32 sum over channels 0–47 and reuses it until a byte in its window changes. Integer sums don't depend on their order, so the outputs equal the full stem's bit for bit. Evaluating several leaves together saves almost nothing, by contrast, because every relaxed dot already reads its weight from a local.</p>
<table>
<caption>Points an evaluation on help.map, seed 7</caption>
<thead><tr><th>Layer</th><th>Points</th></tr></thead>
<tbody>
<tr><td>Full stem</td><td>1.109M</td></tr>
<tr><td>Incremental stem</td><td>666K</td></tr>
<tr><td>One trunk layer</td><td>666K</td></tr>
</tbody>
</table>
<h3 id="options">3. Options as the action space</h3>
<p>Behaviour modules such as harvest, escape, door clearance and the queen strike generate candidate targets and joint plays, and the network scores those candidates instead of raw moves. In the options framework (Sutton, Precup and Singh, 1999), a chosen option is executed by a route controller and ends when its termination condition holds.</p>
<aside class="oy-card oy-alert" id="c-options">
<h3>The options framework</h3>
<p>A sprint already reaches many cells in one decision, so plans longer than one turn are the hard part. Reaching a distant spawning tile just as its next attempt is due takes a decision on each of several turns, any of which can go astray, and a search a few turns deep never sees the payoff. An <em>option</em> is a temporally extended action: a policy for getting something done ("go harvest the spawn at (31, 7)"), a rule for when it may start, and a termination condition. Sutton, Precup and Singh showed that a decision process over options is still a well-defined (semi-Markov) decision process, so the same learning and search methods apply over bigger steps.</p>
<p>Here, hand-written <em>generators</em> propose concrete options each turn, and the network learns which to pick. The generators supply reach, a plan many cells long, while the choice between them, and so the team's roles and timing, is learned. Raw primitive moves stay among the candidates, so an unanticipated behaviour can still emerge.</p>
</aside>
<p>Joint plays follow STP's plays (Browning et al., 2005): a few explicit cooperative tactics, such as guarding the queen or clearing its exit, coordinated over sonar. A dragon tells teammates its option in an intention record (option code, target and expiry), and a joint play is a one-record offer, and the recipient accepts it by acting on it, as its next status shows. There's no waiting action, so holding loops are candidates, and fatal actions stay candidates.</p>
<aside class="oy-card oy-alert" id="c-stp">
<h3>Skills, tactics and plays (STP)</h3>
<p>STP came from robot soccer, where several robots cooperate in real time with little communication. <em>Skills</em> are low-level abilities like driving to a point, <em>tactics</em> are one robot's role in a situation, like defending the goal, and <em>plays</em> are short team scripts assigning tactics, chosen only when their preconditions hold and ended when they fail. A joint play here is the same idea in miniature: one dragon offers a role, and the other accepts by acting.</p>
</aside>
<p>The five joint plays are short sequences between two dragons: guarded escape (the queen holds, a worker clears the threat, the queen sees a usable exit and leaves), door clearance (the blocker releases, the beneficiary sees the gap and passes), feed transfer (a donor deposits, the beneficiary collects), vanguard handover (a replacement arrives, then the incumbent leaves) and survey recruitment (a parent splits, the child takes a lane and surveys). An offer that isn't accepted leaves both dragons free to do something else.</p>
<p>Generators are drawn from the behaviour catalogue, and they're added in measured order, because each costs candidates and points. The first are harvest timed to spawns with holding loops, escape, the queen strike, feed and recombination (its timing learned), the rearguard, and the child map upload with the split that puts the child behind its parent. Which generator to use, and when, is the network's choice.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 380" role="img" aria-label="The agreed behaviour catalogue: 27 behaviours grouped as economy, growth and team, safety, attack and information, and five joint plays, with those that have generators marked">
  <rect class="frame" x="8" y="10" width="134" height="250" rx="6"/>
  <text class="head" x="75" y="30" text-anchor="middle">Economy</text>
  <rect class="good" x="14" y="42" width="122" height="24" rx="12"/><text class="small" x="75" y="58" text-anchor="middle">harvest</text>
  <rect class="neutral open" x="14" y="72" width="122" height="24" rx="12"/><text class="small" x="75" y="88" text-anchor="middle">scavenge</text>
  <rect class="neutral open" x="14" y="102" width="122" height="24" rx="12"/><text class="small" x="75" y="118" text-anchor="middle">farm</text>
  <rect class="neutral open" x="14" y="132" width="122" height="24" rx="12"/><text class="small" x="75" y="148" text-anchor="middle">coil</text>
  <rect class="neutral open" x="14" y="162" width="122" height="24" rx="12"/><text class="small" x="75" y="178" text-anchor="middle">relocate</text>
  <rect class="neutral open" x="14" y="192" width="122" height="24" rx="12"/><text class="small" x="75" y="208" text-anchor="middle">race</text>
  <rect class="neutral open" x="14" y="222" width="122" height="24" rx="12"/><text class="small" x="75" y="238" text-anchor="middle">contest</text>
  <rect class="frame" x="150" y="10" width="134" height="250" rx="6"/>
  <text class="head" x="217" y="30" text-anchor="middle">Growth and team</text>
  <rect class="neutral open" x="156" y="42" width="122" height="24" rx="12"/><text class="small" x="217" y="58" text-anchor="middle">expand</text>
  <rect class="neutral open" x="156" y="72" width="122" height="24" rx="12"/><text class="small" x="217" y="88" text-anchor="middle">recruit</text>
  <rect class="good" x="156" y="102" width="122" height="24" rx="12"/><text class="small" x="217" y="118" text-anchor="middle">feed</text>
  <rect class="neutral open" x="156" y="132" width="122" height="24" rx="12"/><text class="small" x="217" y="148" text-anchor="middle">relay</text>
  <rect class="frame" x="292" y="10" width="134" height="250" rx="6"/>
  <text class="head" x="359" y="30" text-anchor="middle">Safety</text>
  <rect class="good" x="298" y="42" width="122" height="24" rx="12"/><text class="small" x="359" y="58" text-anchor="middle">escape</text>
  <rect class="neutral open" x="298" y="72" width="122" height="24" rx="12"/><text class="small" x="359" y="88" text-anchor="middle">rescue</text>
  <rect class="neutral open" x="298" y="102" width="122" height="24" rx="12"/><text class="small" x="359" y="118" text-anchor="middle">vanguard</text>
  <rect class="good" x="298" y="132" width="122" height="24" rx="12"/><text class="small" x="359" y="148" text-anchor="middle">rearguard</text>
  <rect class="neutral open" x="298" y="162" width="122" height="24" rx="12"/><text class="small" x="359" y="178" text-anchor="middle">door</text>
  <rect class="neutral open" x="298" y="192" width="122" height="24" rx="12"/><text class="small" x="359" y="208" text-anchor="middle">intercept</text>
  <rect class="frame" x="434" y="10" width="134" height="250" rx="6"/>
  <text class="head" x="501" y="30" text-anchor="middle">Attack</text>
  <rect class="neutral open" x="440" y="42" width="122" height="24" rx="12"/><text class="small" x="501" y="58" text-anchor="middle">assassin</text>
  <rect class="good" x="440" y="72" width="122" height="24" rx="12"/><text class="small" x="501" y="88" text-anchor="middle">strike (queen strike)</text>
  <rect class="neutral open" x="440" y="102" width="122" height="24" rx="12"/><text class="small" x="501" y="118" text-anchor="middle">tail strike</text>
  <rect class="neutral open" x="440" y="132" width="122" height="24" rx="12"/><text class="small" x="501" y="148" text-anchor="middle">blocker</text>
  <rect class="neutral open" x="440" y="162" width="122" height="24" rx="12"/><text class="small" x="501" y="178" text-anchor="middle">portal block</text>
  <rect class="neutral open" x="440" y="192" width="122" height="24" rx="12"/><text class="small" x="501" y="208" text-anchor="middle">jam</text>
  <rect class="neutral open" x="440" y="222" width="122" height="24" rx="12"/><text class="small" x="501" y="238" text-anchor="middle">standoff</text>
  <rect class="frame" x="576" y="10" width="134" height="250" rx="6"/>
  <text class="head" x="643" y="30" text-anchor="middle">Information</text>
  <rect class="neutral open" x="582" y="42" width="122" height="24" rx="12"/><text class="small" x="643" y="58" text-anchor="middle">scout</text>
  <rect class="neutral open" x="582" y="72" width="122" height="24" rx="12"/><text class="small" x="643" y="88" text-anchor="middle">survey</text>
  <rect class="neutral open" x="582" y="102" width="122" height="24" rx="12"/><text class="small" x="643" y="118" text-anchor="middle">probe portal</text>
  <text class="head" x="8" y="290">Joint plays</text>
  <rect class="good" x="8" y="300" width="134" height="24" rx="12"/><text class="small" x="75" y="316" text-anchor="middle">guarded escape</text>
  <rect class="neutral open" x="150" y="300" width="134" height="24" rx="12"/><text class="small" x="217" y="316" text-anchor="middle">door clearance</text>
  <rect class="neutral open" x="292" y="300" width="134" height="24" rx="12"/><text class="small" x="359" y="316" text-anchor="middle">feed transfer</text>
  <rect class="neutral open" x="434" y="300" width="134" height="24" rx="12"/><text class="small" x="501" y="316" text-anchor="middle">vanguard handover</text>
  <rect class="neutral open" x="576" y="300" width="134" height="24" rx="12"/><text class="small" x="643" y="316" text-anchor="middle">survey recruitment</text>
  <rect class="good" x="8" y="344" width="170" height="24" rx="12"/><text class="small" x="93" y="360" text-anchor="middle">a generator exists</text>
  <rect class="neutral open" x="196" y="344" width="190" height="24" rx="12"/><text class="small" x="291" y="360" text-anchor="middle">in the pool, added if measured</text>
  <text class="small" x="404" y="360">also: holding loops, feeding deaths, accepting a joint play</text>
</svg>
<figcaption>The behaviour catalogue, grouped here for reading, against the generators in <code>candidates/0001.h</code>. The groups organise this explanation and impose no fixed roles.</figcaption>
</figure>
<p>Generators are added, rewritten and removed by measurement (part 5). One is added when candidate-gap losses cluster on a situation with no generator, rewritten when its candidates are chosen but the teacher keeps preferring another variant of the same behaviour (another target or route), and removed when it's rarely chosen or its ablation (the bot without it, measured against the bot with it) shows no gain at equal cost. When ranking gaps dominate, the network is trained and the generators are left alone.</p>
<h4 id="round5-options">Queen and champion options</h4>
<p>Four generators protect our queen or feed the team's longest dragon, offering their candidates to the same network and search:</p>
<div class="oy-table-properties"><table>
<caption>The queen and champion generators. Every route takes the remembered map's shortest-path first move.</caption>
<thead><tr><th>Option</th><th>Eligibility and target</th></tr></thead>
<tbody>
<tr><td>Champion walk</td><td>The champion is the longest other teammate in the dragon's filters that's alive with probability at least one half. The candidate heads for the reachable cell beside the champion's likeliest head with the shortest route.</td></tr>
<tr><td>Champion feed</td><td>Exactly as queen feed does for the queen: walk to the highest-weight reachable cell two steps ahead of the champion's expected head, where a later death leaves pearls in its path. Neither champion option may end on or target a possible champion head.</td></tr>
<tr><td>Queen retreat</td><td>Our queen gets up to two first moves toward cells with at least two free exits, beside ordinary escape, whether or not a threat is near. Targets maximise the distance from likely enemy heads, each weighted by its chance of being alive.</td></tr>
<tr><td>Queen escort</td><td>A non-queen within eight steps of our queen takes a reachable cell beside her on the side facing the nearest likely enemy head.</td></tr>
</tbody></table></div>
<p>Every move and sprint candidate also carries a survival depth: the longest certainly survivable continuation, up to eight further single steps. A bounded depth-first search finds it, respecting blocked edges and occupied cells, letting the tail move, and growing the body for remembered pearls. Each search examines at most 32 edges and all survival work in a turn shares a 4M-point cutoff, so when the budget runs out the depth is a lower bound. Fatal actions, splits and unknown endpoints have depth zero.</p>
<h3 id="search">4. Online search</h3>
<p>The search is determinised Monte Carlo tree search in the form of information-set MCTS (Cowling, Powley and Whitehouse, 2012). Hidden enemies are sampled from the belief, and the network supplies priors and leaf values (Silver et al., 2017).</p>
<aside class="oy-card oy-alert" id="c-mcts">
<h3>Monte Carlo tree search</h3>
<p>MCTS (Coulom, 2006; Kocsis and Szepesvári, 2006, whose UCT rule applies the UCB1 bandit formula of Auer, Cesa-Bianchi and Fischer, 2002) builds a game tree selectively, one simulation at a time. Each simulation has four steps:</p>
<table>
<thead><tr><th>Step</th><th>Operation</th></tr></thead>
<tbody>
<tr><td>Select</td><td>The search walks down from the root, choosing at each node the child that best balances a good average result so far against being little explored.</td></tr>
<tr><td>Expand</td><td>It adds a new child where the walk leaves the tree.</td></tr>
<tr><td>Evaluate</td><td>The network's value head estimates the new position's value instead of a random playout.</td></tr>
<tr><td>Back up</td><td>The search adds that value to the statistics of every node on the path.</td></tr>
</tbody>
</table>
<p>After many simulations, the most-visited root move is the choice. Promising lines get most of the effort, so the tree grows deep where it matters. AlphaZero's version selects by <em>PUCT</em> (after Rosin, 2011): a child's score is its average value, written <em>Q</em>, plus a bonus proportional to the network's prior for it and shrinking with its visit count, so the network tells the search where to look first.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 250" role="img" aria-label="PUCT: each child's score is its average value Q plus an exploration bonus proportional to its prior and shrinking with its visits; the search follows the child with the highest total">
  <text class="head" x="360" y="24" text-anchor="middle">score = Q + c · prior · √(N + 1) / (1 + n)</text>
  <text class="small" x="360" y="42" text-anchor="middle">N: the node's visits · n: this child's visits · c = 1.25 in tree/0002.h · an unvisited child's Q is the node's value</text>
  <path class="rule" d="M60,210 L660,210"/>
  <rect class="layer" x="110" y="130" width="70" height="80"/><rect class="box" x="110" y="110" width="70" height="20"/>
  <text class="small" x="145" y="228" text-anchor="middle">visited often,</text><text class="small" x="145" y="242" text-anchor="middle">good Q</text>
  <rect class="layer" x="320" y="160" width="70" height="50"/><rect class="box" x="320" y="80" width="70" height="80"/>
  <text class="small" x="355" y="228" text-anchor="middle">high prior,</text><text class="small" x="355" y="242" text-anchor="middle">rarely visited</text>
  <rect class="layer" x="530" y="170" width="70" height="40"/><rect class="box" x="530" y="150" width="70" height="20"/>
  <text class="small" x="565" y="228" text-anchor="middle">low prior,</text><text class="small" x="565" y="242" text-anchor="middle">weak Q</text>
  <text class="small" x="398" y="96">← chosen next</text>
  <rect class="layer" x="560" y="56" width="14" height="12"/><text class="small" x="580" y="66">Q (exploit)</text>
  <rect class="box" x="560" y="74" width="14" height="12"/><text class="small" x="580" y="84">bonus (explore)</text>
</svg>
<figcaption>Textbook PUCT, with the constants used by <code>tree/0002.h</code>'s <code>SelectEdge</code>: the bonus pulls the search toward highly rated, unchecked moves.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-ismcts">
<h3>Determinisation and information-set MCTS</h3>
<p>MCTS needs a concrete game to simulate, but a dragon doesn't know where the hidden enemies are. <em>Determinisation</em> samples a complete hidden state from the belief and simulates in that. Done naively, with a separate tree per sample, the search acts on hidden facts ("the enemy is behind that wall in this sample, so turn left"), a flaw called strategy fusion (Frank and Basin, 1998; Long and colleagues, 2010, studied when such sampling still works).</p>
<p><em>Information-set MCTS</em> fixes it by keying nodes by what the searching dragon has observed. Every simulation draws a fresh sample, but samples that look the same from the dragon's point of view share one node and get one decision, so the statistics average over the hidden possibilities in proportion to how likely the belief says they are.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 200" role="img" aria-label="Information-set MCTS: each simulation samples a hidden state from the belief, but nodes are keyed by the dragon's observations, so samples that look the same share a node">
  <rect class="layer" x="20" y="70" width="130" height="60" rx="6"/>
  <text class="head" x="85" y="96" text-anchor="middle">Belief</text>
  <text class="small" x="85" y="116" text-anchor="middle">over hidden state</text>
  <rect class="box" x="210" y="20" width="110" height="40" rx="6"/><text class="small" x="265" y="44" text-anchor="middle">sample 1</text>
  <rect class="box" x="210" y="80" width="110" height="40" rx="6"/><text class="small" x="265" y="104" text-anchor="middle">sample 2</text>
  <rect class="box" x="210" y="140" width="110" height="40" rx="6"/><text class="small" x="265" y="164" text-anchor="middle">sample 3</text>
  <path class="flow" d="M150,90 L208,42" marker-end="url(#arrow)"/>
  <path class="flow" d="M150,100 L208,100" marker-end="url(#arrow)"/>
  <path class="flow" d="M150,110 L208,158" marker-end="url(#arrow)"/>
  <circle class="layer" cx="480" cy="60" r="16"/>
  <text class="small" x="510" y="64">node: "what I've seen"</text>
  <circle class="layer" cx="480" cy="150" r="16"/>
  <text class="small" x="510" y="154">node: a different observation</text>
  <path class="flow" d="M320,40 L462,56" marker-end="url(#arrow)"/>
  <path class="flow" d="M320,100 L462,66" marker-end="url(#arrow)"/>
  <path class="flow" d="M320,160 L462,150" marker-end="url(#arrow)"/>
</svg>
<figcaption>Textbook: samples 1 and 2 differ only in hidden cells, so they share a node and a decision.</figcaption>
</figure>
<p>The leaf values come from the value head distilled in part 5, read only once it passes part 5's checks. The root simulates its likeliest candidates and narrows them by sequential halving, which improves the policy even at a few evaluations per turn (Danihelka et al., 2022). In play and in every evaluation of a bot, teacher or network, the Gumbel draws are zero, so sequential halving chooses deterministically by prior and value, as in Gumbel MuZero's evaluation. The teacher uses the draws to explore during self-play data collection (part 5).</p>
<aside class="oy-card oy-alert" id="c-gumbel">
<h3>Gumbel root search and sequential halving</h3>
<p>With hundreds of simulations, PUCT's most-visited move is reliably good, but with five or ten the search may never visit a strong move twice. Danihelka and colleagues' Gumbel search, used in Gumbel MuZero (MuZero being DeepMind's successor to AlphaZero; Schrittwieser et al., 2020), is designed for small budgets. At the root it takes the top few candidates by prior, then runs <em>sequential halving</em> (Karnin, Koren and Somekh, 2013): it splits the simulations across them, drops the worse half by prior plus estimated value, and repeats until one remains. Two constants, c_visit and c_scale, set how strongly the values outweigh the priors. Given accurate values, this provably improves on the network's own preference in expectation, while PUCT doesn't guarantee that at small counts.</p>
<p>For exploration, random <em>Gumbel noise</em> is added to the priors before choosing which candidates to consider, which is exactly sampling them without replacement (the Gumbel-top-k trick; Kool, van Hoof and Welling, 2019). Setting the noise to zero in play makes the bot choose its best estimate, which improved its rating by about 127 Elo against the same bot with noise.</p>
</aside>
<p>The number of simulations is set by what a node costs, so the encoding, the belief's prediction and the simulator are optimised to their floors before the state cap, the simulations, the depth and the network's size are balanced against each other:</p>
<table>
<caption>One search simulation on help.map, seed 7 (<a href="#budget">Budget</a>)</caption>
<thead><tr><th>Work</th><th>Points</th></tr></thead>
<tbody>
<tr><td>Leaf's network evaluation</td><td>4.24M</td></tr>
<tr><td>Leaf's encoding</td><td>1.15M to 1.26M</td></tr>
<tr><td>Complete simulation</td><td>5.4M to 5.9M</td></tr>
<tr><td>Simulations a turn</td><td>about 5.7</td></tr>
</tbody>
</table>
<p>Each dragon's 100M points are its own and lapse when its turn ends, so every dragon searches with its own budget, quiet workers included, and stops by the judge's virtual clock.</p>
<h4 id="search-others">Other dragons in the search</h4>
<p>Other dragons in a simulation are never frozen, and never act on the searcher's sampled hidden state or its knowledge:</p>
<table>
<thead><tr><th>Dragons</th><th>Model</th></tr></thead>
<tbody>
<tr><td>Nearby allies</td><td>The route controller follows their reported intentions.</td></tr>
<tr><td>Nearby enemies</td><td>Chance nodes over safe moves, with priors from one network evaluation each at the root, or from their team's mimic (part 6) once it passes a check of how faithfully it plays like that team.</td></tr>
<tr><td>Distant dragons</td><td>They keep their heading or intention.</td></tr>
<tr><td>Newborns</td><td>They follow a fixed rule.</td></tr>
</tbody>
</table>
<p>The distance that makes a dragon nearby, the fixed rules for distant dragons and newborns, and limiting enemies to safe moves are placeholders, each kept only if it beats a richer model at equal cost. Results are wins, draws and losses under the Objective's exact scoring order, without survival shaping (extra reward for staying alive, which would discourage useful sacrifices). A complete action is ready before the search starts, and search memory fits the 48 MB in dense arrays.</p>
<aside class="oy-card oy-alert" id="c-chance">
<h3>Chance nodes and expectimax</h3>
<p>Minimax assumes the opponent picks the reply worst for you, which is too pessimistic against many independent, partly unpredictable opponents. A <em>chance node</em> instead averages over an opponent's possible moves, weighted by how likely each is, and taking expectations at chance nodes and maxima at our own is called expectimax. The averages are only as useful as the weights, here from the network or a mimic of the enemy's team.</p>
</aside>
<p>Once the search reaches a useful depth, a transposition table will be tested. It hashes positions by Zobrist keys over the dragon's observation-relevant state (Zobrist, 1970), XORing a random 64-bit number for each feature present, so a move updates the key cheaply and move orders that reach the same position share their statistics. The table stays only if it saves points per useful node or wins at equal cost.</p>
<h4 id="search-alternatives">Alternatives for hidden information</h4>
<p>Information-set MCTS is one of several ways to search when a player can't see the whole state. They differ in what the tree's nodes stand for, and so in what they cost and what they can guarantee, and every one besides ours is a contender for part 4's decision record (<a href="#principles">Principles</a>). Playing the network's top candidate with no search is the baseline. Search has to beat it at equal cost, so the comparison is rerun whenever the network or the search changes, because a stronger network narrows the gap.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 360" role="img" aria-label="Comparison of search methods for hidden information, from no search through information-set MCTS to POMCP and public-belief-state search, with each one's status here">
  <text class="head" x="14" y="24">Method</text><text class="head" x="164" y="24">Nodes stand for</text><text class="head" x="334" y="24">Hidden information</text><text class="head" x="514" y="24">Status here</text>
  <path class="rule" d="M8,34 L712,34"/>
  <rect class="neutral" x="8" y="42" width="148" height="52" rx="6"/><text class="head" x="82" y="64" text-anchor="middle">Policy only</text><text class="small" x="82" y="82" text-anchor="middle">no search at play</text>
  <text class="small" x="164" y="64">no tree: one network</text><text class="small" x="164" y="80">evaluation decides</text>
  <text class="small" x="334" y="64">whatever the network</text><text class="small" x="334" y="80">learned to infer</text>
  <text class="small" x="514" y="64">baseline for search:</text><text class="small" x="514" y="80">it does, 27–13 (part 4)</text>
  <rect class="neutral" x="8" y="104" width="148" height="52" rx="6"/><text class="head" x="82" y="126" text-anchor="middle">Determinised MCTS</text><text class="small" x="82" y="144" text-anchor="middle">perfect-info sampling</text>
  <text class="small" x="164" y="126">full game states,</text><text class="small" x="164" y="142">one tree per sample</text>
  <text class="small" x="334" y="126">guessed per sample,</text><text class="small" x="334" y="142">suffers strategy fusion</text>
  <text class="small" x="514" y="126">superseded by information-set</text><text class="small" x="514" y="142">MCTS, which fixes the fusion</text>
  <rect class="good" x="8" y="166" width="148" height="52" rx="6"/><text class="head" x="82" y="188" text-anchor="middle">Information-set MCTS</text><text class="small" x="82" y="206" text-anchor="middle">ours (part 4)</text>
  <text class="small" x="164" y="188">what the dragon has</text><text class="small" x="164" y="204">observed, samples share nodes</text>
  <text class="small" x="334" y="188">fresh sample from the belief</text><text class="small" x="334" y="204">each simulation</text>
  <text class="small" x="514" y="188">used: ~6 simulations a turn,</text><text class="small" x="514" y="204">needs only a simulator + belief</text>
  <rect class="mixed" x="8" y="228" width="148" height="52" rx="6"/><text class="head" x="82" y="250" text-anchor="middle">POMCP</text><text class="small" x="82" y="268" text-anchor="middle">Silver and Veness</text>
  <text class="small" x="164" y="250">action–observation</text><text class="small" x="164" y="266">histories</text>
  <text class="small" x="334" y="250">particles kept at each node,</text><text class="small" x="334" y="266">built by the simulations</text>
  <text class="small" x="514" y="250">contender: close to ours, with</text><text class="small" x="514" y="266">particles for our Bayes filter</text>
  <rect class="mixed" x="8" y="290" width="148" height="60" rx="6"/><text class="head" x="82" y="312" text-anchor="middle">Public-belief search</text><text class="small" x="82" y="330" text-anchor="middle">ReBeL, Student of Games</text>
  <text class="small" x="164" y="312">public belief states: what</text><text class="small" x="164" y="328">everyone knows about all</text><text class="small" x="164" y="344">players' private information</text>
  <text class="small" x="334" y="312">solved for an equilibrium</text><text class="small" x="334" y="328">(CFR) with a value network</text><text class="small" x="334" y="344">over beliefs</text>
  <text class="small" x="514" y="312">contender: shown on two-player</text><text class="small" x="514" y="328">zero-sum games, scaling to</text><text class="small" x="514" y="344">many dragons is the open work</text>
</svg>
<figcaption>Textbook comparison, with each method's status in this design.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-pomcp">
<h3>POMCP</h3>
<p>Silver and Veness's partially observable Monte Carlo planning (2010) builds the tree over the searcher's own history of actions and observations, like information-set MCTS, and keeps sampled hidden states, <em>particles</em>, at each node, so it's a belief filter and a search in one, needing nothing but a simulator. This design samples from part 1's better-informed Bayes filters instead, and the open question is whether per-node particles help deeper in the tree.</p>
</aside>
<aside class="oy-card oy-alert" id="c-pbs">
<h3>Public belief states: ReBeL and Student of Games</h3>
<p>In poker each player's cards are private, but everyone can compute the same distribution over every player's possible cards from the public actions. Treating that <em>public belief state</em> as the state turns the game into a perfect-information game over beliefs. ReBeL (Brown et al., 2020) searches it with a value network over public belief states and counterfactual regret minimisation (CFR), solving each small subgame for a Nash equilibrium, and Student of Games (Schmid et al., 2023) generalises it to chess, Go, poker and Scotland Yard with one algorithm.</p>
<p>Both were shown on two-player zero-sum games with small private information. A public belief over every unseen dragon's position and the team's private sonar is vastly larger than a poker hand, and an equilibrium solve per decision costs far more than the six or so simulations per turn, so using them here would take a compact public belief and a solver that fits the judge.</p>
</aside>
<h4 id="search-reuse">Search across turns</h4>
<p>A dragon's process lives for its whole life, so its search tree persists between its turns, as AlphaZero reuses its tree. On the dragon's next turn the root moves to the node reached by its last action and the observation that followed, and every other branch is freed. If no grown node matches that observation, the search starts from a fresh root. The kept statistics were gathered under the earlier belief, so their visit counts are discounted by a factor derived from how far the belief moved, such as the KL divergence between the old and new root beliefs. Nothing is pruned for good: each turn the root regenerates its candidates from the new belief, and progressive widening admits more moves at a node as its visits grow, so a move left unexplored earlier is grown whenever the search comes to favour it.</p>
<aside class="oy-card oy-alert" id="c-widening">
<h3>Progressive widening</h3>
<p>When a node has many possible moves, splitting a handful of visits among all of them learns nothing about any. <em>Progressive widening</em> limits a node to its k best moves by prior and lets k grow as a power of its visit count n, k ≈ C·n<sup>α</sup>, so a node visited a lot considers more alternatives while a rarely visited one concentrates on its best few. The search admits 2 + √n moves, up to a node's limit of 16, with the base and exponent placeholders to be fitted.</p>
</aside>
<p>The Gumbel root's c_visit and c_scale (Danihelka et al.) and PUCT's constant (AlphaZero) are re-derived for our value scale and simulation count, progressive widening's exponent is fitted in Couëtoux et al.'s form, and the remaining constants are tuned jointly at equal cost by SPSA or CLOP. Nodes live in a fixed arena within the 48 MB, and when it's full the search recycles its least-visited leaves.</p>
<aside class="oy-card oy-alert" id="c-spsa">
<h3>Tuning constants: SPSA and CLOP</h3>
<p>Search has several interacting constants, and each match result is noisy, so tuning them one at a time by hand misses interactions and overreacts to noise. <em>SPSA</em> (simultaneous perturbation stochastic approximation; Spall, 1992) nudges all constants at once by random ± amounts, plays both versions, and moves every constant a little in the direction that won, which estimates a gradient from two noisy evaluations whatever the number of constants. <em>CLOP</em> (Coulom, 2011) instead fits a smooth model of win rate over the constants from all games played and moves towards its predicted optimum. Both are standard in chess-engine tuning.</p>
</aside>
<h4 id="search-budget">Spending the whole budget</h4>
<p>The judge's virtual clock advances 1 ns per point, so a dragon always knows its exact remaining budget, and every turn spends its full 100M points less a reserve for its reply. The network and the root come first, then growing the reused tree, then an all-pairs distance table over the dragon's known map, 16 MB on a 64 × 64 board, which answers in one lookup every distance needed by the generators, the route controller and the search. Measurement sets the split between search and table. The reply reserve is a high quantile of the measured reply cost, p99.99 plus a margin, with 6M points plus twice the costliest reply as a placeholder.</p>
<p>Recognising which top team's mimic this game's enemies resemble could give the enemy chance nodes better priors. The ladder's bots change, and unseen tournament maps may make matching harder, so it's tested late, against the final league, and kept only if it wins.</p>
<h3 id="teacher">5. The offline teacher</h3>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 224" role="img" aria-label="Part 5's training timeline: a kickstart by imitation, then repeated cycles of self-play with the teacher, targets, distillation and a check, with the privileged value supporting the teacher">
  <rect class="mixed" x="8" y="40" width="150" height="60" rx="6"/>
  <text class="head" x="83" y="58" text-anchor="middle">Kickstart</text>
  <text class="small" x="83" y="75" text-anchor="middle">imitate top teams'</text>
  <text class="small" x="83" y="90" text-anchor="middle">replayed games</text>
  <path class="flow" d="M158,70 L196,70" marker-end="url(#arrow)"/>
  <rect class="layer" x="200" y="40" width="118" height="60" rx="6"/>
  <text class="head" x="259" y="58" text-anchor="middle">Self-play</text>
  <text class="small" x="259" y="75" text-anchor="middle">teacher searches,</text>
  <text class="small" x="259" y="90" text-anchor="middle">Gumbel noise on</text>
  <path class="flow" d="M318,70 L326,70" marker-end="url(#arrow)"/>
  <rect class="layer" x="328" y="40" width="118" height="60" rx="6"/>
  <text class="head" x="387" y="58" text-anchor="middle">Targets</text>
  <text class="small" x="387" y="75" text-anchor="middle">improved policy</text>
  <text class="small" x="387" y="90" text-anchor="middle">and outcomes</text>
  <path class="flow" d="M446,70 L454,70" marker-end="url(#arrow)"/>
  <rect class="layer" x="456" y="40" width="118" height="60" rx="6"/>
  <text class="head" x="515" y="58" text-anchor="middle">Distil</text>
  <text class="small" x="515" y="75" text-anchor="middle">student learns</text>
  <text class="small" x="515" y="90" text-anchor="middle">the targets</text>
  <path class="flow" d="M574,70 L582,70" marker-end="url(#arrow)"/>
  <rect class="layer" x="584" y="40" width="118" height="60" rx="6"/>
  <text class="head" x="643" y="58" text-anchor="middle">Check</text>
  <text class="small" x="643" y="75" text-anchor="middle">beat the plain</text>
  <text class="small" x="643" y="90" text-anchor="middle">network to keep it</text>
  <path class="flow dash" d="M670,100 L670,130 L259,130 L259,102" marker-end="url(#arrow)"/>
  <text class="small" x="600" y="148" text-anchor="middle">next cycle starts from the stronger network</text>
  <rect class="good" x="200" y="170" width="340" height="44" rx="6"/>
  <text class="head" x="370" y="189" text-anchor="middle">Privileged value</text>
  <text class="small" x="370" y="205" text-anchor="middle">fitted on true states, values the teacher's leaves</text>
  <path class="flow" d="M370,170 L370,104" marker-end="url(#arrow)"/>
</svg>
<figcaption>Intended design: the kickstart, then expert-iteration cycles.</figcaption>
</figure>
<p>The first network is kickstarted by imitating the top ladder teams' decisions in public replays, which the organisers allow. Each game is replayed in the judge from its match seed, so every dragon's observation, pearl countdowns included, is what it saw. Expert iteration then takes over, as AlphaStar learned from human play before its league (Vinyals et al., 2019).</p>
<aside class="oy-card oy-alert" id="c-imitation">
<h3>Imitation learning and the kickstart</h3>
<p><em>Imitation learning</em>, or behaviour cloning, trains a network to predict what an expert did in recorded games. It can only reach the level of what it copies, but it gets there quickly, while expert iteration from a random network spends a long time rediscovering basics, because its first searches, guided by a network that knows nothing, find little.</p>
</aside>
<p>From then on, the same search, run with full information and generous budgets on GPUs, produces improved policy targets (Anthony et al., 2017), using Gumbel draws to explore during self-play data collection. Every match uses zero draws, including the teacher check, where it has to beat the network choosing without search before its targets are used. A faithful simulator serves as the oracle there, never inside the bot. The teacher's value network takes privileged whole-board inputs and learns from the outcomes of search-played games, as in AlphaZero, and its values reach search leaves only after they pass a calibration check on held-out games.</p>
<aside class="oy-card oy-alert" id="c-distil">
<h3>Distillation and cross-entropy</h3>
<p>The teacher's search ends with a distribution over the root's candidates, an improved policy. <em>Distillation</em> (Hinton, Vinyals and Dean, 2015) trains the student network to reproduce that distribution by minimising <em>cross-entropy</em>, −Σ target(a) · log student(a). It's smallest when the student puts its probability where the teacher did, and it rewards matching the whole distribution, so the student also learns which alternatives were nearly as good. The value head is trained alongside on the squared error between its estimate and its target. The trainer minimises both with AdamW (Loshchilov and Hutter, 2019), with gradients clipped to norm 1 (Pascanu, Mikolov and Bengio, 2013) so one bad batch can't throw the weights far.</p>
</aside>
<h4 id="teacher-value">The teacher's leaf value</h4>
<aside class="oy-card oy-alert" id="c-value">
<h3>Value functions, rollouts and privileged critics</h3>
<p>At its leaves a search needs an estimate of who will win. A <em>rollout</em> plays the game forward from the leaf with a fast policy and scores the result, which is slow and noisy but unbiased if the policy plays well, while a learned value network answers in one evaluation but only as well as it was trained. A value network given the whole board, a <em>privileged critic</em> as in asymmetric actor-critic (Pinto et al., 2018), judges positions far better than one that sees a 7×7 window. Only the teacher can use it, but the bot's own value head can then be trained to approximate it from what a dragon knows.</p>
</aside>
<p>The leaf value decides the teacher's strength. With the network's own value at its leaves, the teacher did no better than the plain network, and more simulations or depth didn't help. Its leaf log shows why: the network's value reads too optimistic at every depth, and its squared error against the outcome is worse than a constant's. Leaves played on for 20 rounds on the true state did far better:</p>
<div class="oy-table-properties"><table>
<caption>Teacher leaf values against the plain network, 32 small-map games with the same seeds for each and no root noise. Cost is a leaf's, relative to a privileged leaf on an RTX 5070 Ti.</caption>
<thead><tr><th>Leaf value</th><th>Teacher's wins</th><th>Cost</th></tr></thead>
<tbody>
<tr><td>Network's own value head (16 simulations and depth 2, with 256 simulations or depth 4 no better)</td><td>15 of 32</td><td></td></tr>
<tr><td>Fitted privileged value</td><td>25 of 32</td><td>1×</td></tr>
<tr><td>20-round rollout, valued by the team's standing</td><td>32 of 32</td><td>about 9×</td></tr>
<tr><td>20-round rollout, ending on the privileged value</td><td>29 of the 29 finished</td><td>about 9×</td></tr>
</tbody></table></div>
<p>The privileged value is fitted offline on recorded games so far, against the outcome, the n-step value 10 rounds on, and the team's shares of units, total length and longest dragon 10, 50 and 200 rounds on, and it passes the calibration check. Cycle 1's teacher values its leaves by 20-round rollouts ending on the privileged value, once a full-map check of hundreds of games confirms the small-map result. Their cost comes down by running a cheap rollout policy over every lane's dragons in one kernel, rolling out only from leaves whose value is uncertain, capturing the round loop as a CUDA graph and spreading games across GPUs. The teacher's simulations, depth and rollout length are set by strength gained per GPU-second and per dollar, while its root width is never cut.</p>
<h4 id="teacher-head">Distilling the bot's value head</h4>
<p>The bot's value head is distilled from the privileged value, as in asymmetric distillation (Warrington et al., 2021). At each of a dragon's decisions in training, on both teams' positions, it learns the fitted privileged value of the true state and the outcome. A training-only auxiliary head learns the team's shares 10, 50 and 200 rounds on, which shapes the shared body and is never exported. The value targets use TD(λ) instead of fixed horizons, with λ fitted on held-out calibration, and decisions that carry only value targets train no policy.</p>
<aside class="oy-card oy-alert" id="c-td">
<h3>TD(λ)</h3>
<p>The final outcome is a noisy target for an early position, because a blunder 300 rounds later can decide it. The network's own estimate one step later is less noisy but inherits the network's errors (<em>temporal-difference</em> learning; Sutton, 1988). The <em>n-step</em> target mixes them, real outcomes for n rounds and then the estimate, and TD(λ) averages all n-step targets with weights (1−λ)λ<sup>n−1</sup>, so λ near 0 trusts the estimate and λ near 1 the outcome.</p>
</aside>
<p>The privileged value's fit chooses its λ through a horizon. Samples are taken every K rounds, and a horizon of H rounds sets λ = 1 − K/H, so a target bootstraps H rounds ahead on average. Each horizon is one job, and the fit with the lowest calibration-set log loss among those that pass the calibration check is kept. Training stops when the held-out improvement over the best checkpoint so far, paired on the same decisions and with its standard error clustered by game, is no longer significant in a one-sided test at 95%.</p>
<p>The search reads the bot's value head only after it passes three checks: the held-out calibration check, a forked-continuation test, which copies recorded games at a random round and plays each copy to the end with the policy network so the head's values can be compared with the outcomes, and a match of the searching bot against the plain bot. The imitation-trained head fails the calibration check, because it learnt only from the top ten teams' sides, which won most of their games, so it reads too optimistic. The retrain on the new inputs replaces it.</p>
<h4 id="teacher-gap">Candidate, ranking and information gaps</h4>
<p>A dragon sees only its 7×7 window, so targets chosen with information unavailable to it may be hard to imitate (Warrington et al., 2021). A student distilled from this teacher is therefore compared with one distilled at equal compute from a teacher whose determinisations come from the acting dragon's belief, and the teacher whose student wins is kept. Where the student still departs from the teacher, the departure is measured in value lost, the teacher's value of its move less its value of the student's. A fact observed or decided by some teammate earns a place in sonar when adding it to the student's inputs recovers that value, and facts are ranked by value recovered per bit of a dragon's 256 bits a turn. Departures beyond any teammate's knowledge are left to belief and search.</p>
<aside class="oy-card oy-alert" id="c-gap">
<h3>The imitation gap</h3>
<p>A teacher that sees everything sometimes makes a move only because it knows something hidden, like turning away from an enemy just out of sight. A student that can't see the enemy can't learn when to make that move, and at best learns to make it on average, sometimes when it shouldn't. Warrington and colleagues call this the <em>imitation gap</em>. One remedy gives the teacher only what the student could know, at some cost in teacher strength, as tested by the comparison above. The other gives the student the missing information, which is how sonar's content is chosen.</p>
</aside>
<p>The teacher searches every legal primitive action as well as the generators' candidates, so each departure falls under exactly one of three causes. Without that, no departure can be called a candidate gap and no generator can be measured. A legal primitive action is a move, a legal split or a sprint, fatal ones included. A sprint is chosen first by its end cell and final heading, and its route is a second choice under that, admitted by progressive widening as the branch's visits grow, ordered by how different the resulting states are, with routes that leave the same state merged.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 220" role="img" aria-label="Value-lost attribution: each departure of the student from the teacher is a candidate gap, a ranking gap or an information gap, and each points to the part to change">
  <rect class="layer" x="230" y="16" width="260" height="56" rx="6"/>
  <text class="head" x="360" y="40" text-anchor="middle">Departure</text>
  <text class="small" x="360" y="60" text-anchor="middle">value lost = teacher's Q − student's Q</text>
  <rect class="bad" x="20" y="120" width="210" height="70" rx="6"/>
  <text class="head" x="125" y="144" text-anchor="middle">Candidate gap</text>
  <text class="small" x="125" y="164" text-anchor="middle">no candidate is the teacher's move</text>
  <text class="small" x="125" y="180" text-anchor="middle">→ options (part 3)</text>
  <rect class="mixed" x="255" y="120" width="210" height="70" rx="6"/>
  <text class="head" x="360" y="144" text-anchor="middle">Ranking gap</text>
  <text class="small" x="360" y="164" text-anchor="middle">a candidate is, but scored lower</text>
  <text class="small" x="360" y="180" text-anchor="middle">→ network and training (parts 2, 5)</text>
  <rect class="neutral" x="490" y="120" width="210" height="70" rx="6"/>
  <text class="head" x="595" y="144" text-anchor="middle">Information gap</text>
  <text class="small" x="595" y="164" text-anchor="middle">needs facts the dragon lacks</text>
  <text class="small" x="595" y="180" text-anchor="middle">→ belief and sonar (part 1)</text>
  <path class="flow" d="M300,72 L140,118" marker-end="url(#arrow)"/>
  <path class="flow" d="M360,72 L360,118" marker-end="url(#arrow)"/>
  <path class="flow" d="M420,72 L580,118" marker-end="url(#arrow)"/>
</svg>
<figcaption>Intended design: the value-lost report's three causes and where each points.</figcaption>
</figure>
<p>Each cycle reports value lost by cause, candidate gaps by situation and by generator, and for each generator how often its candidates are chosen, the value lost to other variants of its behaviour, its cost in bot points and self-play throughput, and its equal-cost ablation. A teacher is used only after it beats the plain network in a match whose size and pass bar are fixed before it runs.</p>
<h4 id="simulation">Parallel turns</h4>
<p>Most of the teacher's time goes to simulating the other dragons, whose moves come from the network. The rules play dragons one after another in ID order, each observing the effects of earlier moves, but dragon j's turn depends on an earlier mover i only when i's action changes one of j's inputs: a cell in j's view, j's inbox (i's rays, and later movers' rays now blocked or let through by i's segments), or a cell on j's own path. Each dragon casts at most four rays, and a ray stops at kelp or the first living segment, so a mover's messages reach at most four dragons.</p>
<aside class="oy-card oy-alert" id="c-pdes">
<h3>Parallel discrete-event simulation</h3>
<p>A simulation can run independent actors in parallel and still reproduce the results of their required order, because each actor only needs the earlier actors that could change what it reads. Conservative scheduling (Chandy and Misra, 1979) runs every actor whose possible influences have all finished. Optimistic scheduling, Time Warp (Jefferson, 1985), runs ahead regardless, records what each actor read, and reruns the few whose reads turned out to be changed by an earlier actor.</p>
</aside>
<p>Both schedules reproduce strict ID-order play exactly, provided each dragon has its own random stream. Every turn also reads its team's unit count, and any teammate's split or death changes it, so a purely conservative schedule waits on every earlier teammate. A hybrid that waits only on movers whose sprint or rays could reach a dragon does much better, but needs that reach computed for every pending mover:</p>
<table>
<caption>Turns played a wave over 1,500 rounds of eight queen-era games</caption>
<thead><tr><th>Schedule</th><th>Turns per wave</th></tr></thead>
<tbody>
<tr><td>Conservative</td><td>at most 1.70</td></tr>
<tr><td>Hybrid</td><td>6.28</td></tr>
<tr><td>True dependencies</td><td>7.93</td></tr>
</tbody>
</table>
<p>The implemented scheduler avoids computing reach. It chooses moves for the next eight dragons in a lane from the same starting state, then applies them in ID order, and a dragon whose turn block has changed by then ends the wave:</p>
<table>
<caption>The scheduler's trade-off by movers considered a wave (<code>loong-turn-dependencies</code>)</caption>
<thead><tr><th>Movers considered</th><th>Turns per wave</th><th>Discarded decisions per turn</th></tr></thead>
<tbody>
<tr><td>4</td><td>3.34</td><td>0.17</td></tr>
<tr><td>8</td><td>4.60</td><td>0.63</td></tr>
<tr><td>16</td><td>4.92</td><td>1.82</td></tr>
</tbody>
</table>
<p>It applies to every network-chosen turn, while the teacher still searches its own decisions in order. A persistent kernel for each block of games also plays step after step on the device without returning to the host. Both are checked by choice traces byte-identical to the ID-order teacher on recorded seeds.</p>
<aside class="oy-card oy-alert" id="c-launch">
<h3>Kernel launches, CUDA graphs and persistent kernels</h3>
<p>The CPU, called the <em>host</em>, queues GPU kernels on a stream, and each launch costs it a few microseconds. A small network's training step is hundreds of tiny kernels, so the GPU can finish each one before the host has queued the next, and sits idle between them. A <em>CUDA graph</em> records the step once and replays it from one launch, although it can't contain a point where the host reads a value back, and its shapes are fixed. A <em>persistent kernel</em> stays resident and loops over the steps itself, synchronising on the device, so the host only starts it and reads the result.</p>
</aside>
<p>Self-play also searches only a share of decisions in full and plays the rest by the network, which is playout cap randomization (Wu, 2019, for KataGo): more games for the same compute, while the searched decisions keep their full targets. Unlike the two methods above, it changes the training data, so its share is set by measured strength per GPU-hour, comparing networks distilled from equal compute at different shares.</p>
<h3 id="league">6. League training</h3>
<p>The network trains against the frozen pool, the foil and mimics of top ladder teams, in the style of AlphaStar's league (Vinyals et al., 2019), so the policy doesn't overfit to itself. The mimics come from the same imitation that kickstarts the first network, and no mimic is ever submitted as it stands. Games are played on generated maps matched to the official distribution, because tournament maps are unseen, and their network-chosen turns use part 5's <a href="#simulation">parallel simulation</a>. Registered builds such as the foil's run their WebAssembly on the CPU beside the CUDA engine, whose games match the official SDK byte for byte.</p>
<aside class="oy-card oy-alert" id="c-league">
<h3>League training</h3>
<p>Pure self-play has a known failure: the policy learns to beat its current self, forgets how to beat older strategies, and can cycle (rock beats scissors beats paper beats rock) without getting better overall. AlphaStar's <em>league</em> keeps a population of opponents: frozen past versions, agents trained to exploit the current policy's weaknesses, and, in our case, mimics of our competition opponents.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 200" role="img" aria-label="The league: the current network plays its own snapshots, the frozen pool and foil, and mimics of top ladder teams, on generated maps">
  <rect class="layer" x="270" y="70" width="180" height="60" rx="6"/>
  <text class="head" x="360" y="96" text-anchor="middle">Current network</text>
  <text class="small" x="360" y="116" text-anchor="middle">with its search</text>
  <rect class="box" x="20" y="20" width="180" height="50" rx="6"/>
  <text class="head" x="110" y="50" text-anchor="middle">Its own snapshots</text>
  <rect class="box" x="20" y="130" width="180" height="50" rx="6"/>
  <text class="head" x="110" y="160" text-anchor="middle">Frozen pool, the foil</text>
  <rect class="box" x="520" y="20" width="180" height="50" rx="6"/>
  <text class="head" x="610" y="50" text-anchor="middle">Top-team mimics</text>
  <rect class="neutral" x="520" y="130" width="180" height="50" rx="6"/>
  <text class="head" x="610" y="160" text-anchor="middle">Generated maps</text>
  <path class="flow" d="M200,45 L268,85" marker-end="url(#arrow)"/>
  <path class="flow" d="M200,155 L268,115" marker-end="url(#arrow)"/>
  <path class="flow" d="M520,45 L452,85" marker-end="url(#arrow)"/>
  <path class="flow" d="M520,155 L452,115" marker-end="url(#arrow)"/>
</svg>
<figcaption>Intended design: the league's opponents.</figcaption>
</figure>
<h3 id="review">7. Decision review</h3>
<p>The viewer shows for every decision the candidates, the network's values and the search's verdict, and the teacher review adds the played, network and teacher choices with each one's option, Q and value lost. Aggregate numbers say whether the bot wins, while individual decisions show why, which is how a wrong belief, a missing option or a misjudged value is found. The value-lost report points the review at the decisions that cost the most.</p>
<h4 id="checks">Checks</h4>
<p>Each stage passes a match or check whose size and pass bar are fixed before it runs, so a lucky run can't be chosen after the fact. The ladder stays empty until a bot implementing the full expert design is at least as good as foil-0039 in a local match.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 206" role="img" aria-label="The checks for a network, search or bot in training, for release and once a release is live">
  <text class="head" x="14" y="22" text-anchor="start">Training</text>
  <rect class="layer" x="8" y="32" width="160" height="60" rx="6"/>
  <text class="head" x="88" y="52" text-anchor="middle">Teacher check</text>
  <text class="small" x="88" y="69" text-anchor="middle">searched teacher beats</text>
  <text class="small" x="88" y="84" text-anchor="middle">the plain network</text>
  <path class="flow" d="M168,62 L196,62" marker-end="url(#arrow)"/>
  <rect class="layer" x="198" y="32" width="160" height="60" rx="6"/>
  <text class="head" x="278" y="52" text-anchor="middle">Value checks</text>
  <text class="small" x="278" y="69" text-anchor="middle">calibration, forked</text>
  <text class="small" x="278" y="84" text-anchor="middle">continuations, match</text>
  <path class="flow" d="M358,62 L386,62" marker-end="url(#arrow)"/>
  <rect class="layer" x="388" y="32" width="160" height="60" rx="6"/>
  <text class="head" x="468" y="52" text-anchor="middle">Search check</text>
  <text class="small" x="468" y="69" text-anchor="middle">searching bot beats</text>
  <text class="small" x="468" y="84" text-anchor="middle">the plain bot</text>
  <text class="head" x="14" y="124" text-anchor="start">Release</text>
  <rect class="mixed" x="8" y="134" width="200" height="60" rx="6"/>
  <text class="head" x="108" y="154" text-anchor="middle">Release check</text>
  <text class="small" x="108" y="171" text-anchor="middle">Wilson 95% lower bound</text>
  <text class="small" x="108" y="186" text-anchor="middle">above 50% vs foil-0039</text>
  <path class="flow" d="M208,164 L246,164" marker-end="url(#arrow)"/>
  <rect class="good" x="248" y="134" width="150" height="60" rx="6"/>
  <text class="head" x="323" y="154" text-anchor="middle">Upload</text>
  <text class="small" x="323" y="171" text-anchor="middle">the ladder, ladder</text>
  <text class="small" x="323" y="186" text-anchor="middle">games validate it</text>
  <rect class="neutral" x="430" y="134" width="282" height="60" rx="6"/>
  <text class="head" x="571" y="154" text-anchor="middle">Later, once a release is live</text>
  <text class="small" x="571" y="171" text-anchor="middle">a learned change: Wilson bound vs live,</text>
  <text class="small" x="571" y="186" text-anchor="middle">a logical fix: builds + smoke games</text>
  <path class="flow dash" d="M468,92 L108,132" marker-end="url(#arrow)"/>
  <text class="small" x="540" y="110" text-anchor="middle">size and pass bar fixed before each match</text>
</svg>
<figcaption>The checks before a network, search or bot is used or released</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-wilson">
<h3>Wilson bounds</h3>
<p>A match result is a sample: 27 wins in 40 games is 67.5%, but the true win rate could easily be lower. The Wilson score interval (Wilson, 1927) gives the range of win rates consistent with the result at a chosen confidence, and behaves well for small samples and rates near 0 or 1, where the simple ±2 standard errors doesn't. The check asks whether the interval's lower end, at 95%, is above 50%. The search bot's 27–13 against the plain bot gives 0.52 to 0.80, so it passes, while its 27–73 against foil-0039 gives 0.19 to 0.36, so it doesn't. A larger match narrows the interval, which is why gate sizes are chosen in advance.</p>
</aside>
<h2 id="strategic">Strategic improvement from review</h2>
<p>A learned bot can still make plainly wrong choices, such as not playing a move that kills the enemy queen. Each reviewed mistake is classified by where the right move was lost, because each place has a different fix. A move that was never offered is fixed in the hand-written generators, and such a <em>logical fix</em>, a change that stops the bot throwing a game in a specific situation, goes live once it builds and a few smoke games show no failed turns, without the statistical check for a learned change.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 330" role="img" aria-label="Where a reviewed mistake goes: a missing candidate to the generators, a low rating to training, a missed sure win to proven outcomes, and every position to a regression library">
  <rect class="layer" x="230" y="12" width="260" height="56" rx="6"/>
  <text class="head" x="360" y="36" text-anchor="middle">Reviewed mistake</text>
  <text class="small" x="360" y="56" text-anchor="middle">e.g. a missed queen kill</text>
  <rect class="bad" x="10" y="110" width="220" height="74" rx="6"/>
  <text class="head" x="120" y="132" text-anchor="middle">Not a candidate</text>
  <text class="small" x="120" y="152" text-anchor="middle">candidate gap: add or rewrite</text>
  <text class="small" x="120" y="168" text-anchor="middle">a generator (part 3), a logical fix</text>
  <rect class="mixed" x="250" y="110" width="220" height="74" rx="6"/>
  <text class="head" x="360" y="132" text-anchor="middle">Candidate, rated low</text>
  <text class="small" x="360" y="152" text-anchor="middle">ranking gap: network or value</text>
  <text class="small" x="360" y="168" text-anchor="middle">misjudged it, train on it (part 5)</text>
  <rect class="neutral" x="490" y="110" width="220" height="74" rx="6"/>
  <text class="head" x="600" y="132" text-anchor="middle">Searched, not chosen</text>
  <text class="small" x="600" y="152" text-anchor="middle">few simulations missed a sure win,</text>
  <text class="small" x="600" y="168" text-anchor="middle">prove the outcome (part 4)</text>
  <path class="flow" d="M290,68 L130,108" marker-end="url(#arrow)"/>
  <path class="flow" d="M360,68 L360,108" marker-end="url(#arrow)"/>
  <path class="flow" d="M430,68 L590,108" marker-end="url(#arrow)"/>
  <rect class="good" x="160" y="236" width="400" height="74" rx="6"/>
  <text class="head" x="360" y="260" text-anchor="middle">Reviewed-positions library</text>
  <text class="small" x="360" y="280" text-anchor="middle">position, correct move and reason, every new version is checked</text>
  <text class="small" x="360" y="296" text-anchor="middle">against it, and the positions train with extra weight</text>
  <path class="flow" d="M120,184 L250,234" marker-end="url(#arrow)"/>
  <path class="flow" d="M360,184 L360,234" marker-end="url(#arrow)"/>
  <path class="flow" d="M600,184 L470,234" marker-end="url(#arrow)"/>
</svg>
<figcaption>Intended design: where a reviewed mistake goes. The proven outcomes and the library are agreed and not yet built.</figcaption>
</figure>
<h4>Proven outcomes in search</h4>
<p>In the bot's search and the teacher's, a move proven by the rules to win or lose outright is marked proven instead of averaged, by MCTS-Solver (Winands, Björnsson and Saito, 2008). A proven win is always played and a proven loss never is, whatever the network says. The tree holds the searching dragon's own decisions, with other dragons' moves and the hidden state sampled between them, so a proof can't pass through a transition whose other outcomes were never seen. That leaves two sound kinds of proof: a root certainty, a move with an outcome fixed by the rules whatever is hidden, such as one that certainly kills the team's last dragon, and a proof over a fully determined segment, where nothing is hidden and no other dragon's move is sampled, such as an endgame with every relevant dragon in view. A queen kill doesn't end the game, but it decides the round-500 comparison while our queen lives, so it belongs to the value's targets and the reviewed positions instead of the solver.</p>
<aside class="oy-card oy-alert" id="c-solver">
<h3>MCTS-Solver</h3>
<p>Ordinary MCTS treats every result as a noisy estimate and averages it, so even a move that wins on the spot needs many visits before its average dominates, and with five or ten simulations it may never get them. MCTS-Solver adds proven values to the tree. A terminal position reached in a simulation is a known win or loss. At a node where we choose, one child proven to win makes the node a proven win, while at an opponent's node every child needs proving a win for us. Proofs propagate upward, and a proven move is played without further search.</p>
</aside>
<h4>Reviewed positions</h4>
<p>The review library keeps each flagged position with its correct move and explanation, and every new bot and network version is checked against it, as a regression suite does for code. The same positions enter training with extra weight, labelled by the teacher, because a network trained on millions of ordinary positions barely notices getting a rare decisive one wrong, which is the idea behind hard-example mining (Shrivastava, Gupta and Girshick, 2016).</p>
<h2 id="budget">Budget</h2>
<p>The judge's meter prices every instruction by its opcode, and every SIMD instruction costs 2 points whatever its lanes. Nothing else counts, not even a cache miss, so a branch-free kernel's cost is an exact function of its shape and a design's cost is known before it's trained. Optimising means using fewer, wider instructions. Measurements here were taken in the official SDK 1.2.7 compiler and sandbox, which build and run bots exactly as the online judge does, on help.map, the largest map at 64 × 64, with seed 7 fixing its pearls and the bots' random draws.</p>
<div class="oy-table-properties"><table>
<caption>Multiply-adds per point by kernel form, measured with the judge's clock</caption>
<thead><tr><th>Kernel form</th><th>Multiply-adds per point</th></tr></thead>
<tbody>
<tr><td>A 2.8M-weight network with int16 dots and weights parsed from a string</td><td>about 0.58</td></tr>
<tr><td>Packed int16 3×3 convolution</td><td>0.63</td></tr>
<tr><td>Relaxed int8 dot, C loop, weights through pointers</td><td>0.94–1.18</td></tr>
<tr><td>Relaxed int8 dot, inputs in locals, accumulation chained, weights through pointers</td><td>1.79–1.81</td></tr>
<tr><td>Relaxed int8 dot, weights embedded as immediates, dense layer</td><td>2.86–2.87</td></tr>
<tr><td>The same, 3×3 convolution on the 15×15 crop, 32 and 64 channels</td><td>2.80 and 2.99</td></tr>
</tbody></table></div>
<p>The compiler adds two points of address arithmetic to every load through a pointer. When the weights are a const array filled by C23's <code>#embed</code> and read at constant indices, it turns each load into a <code>v128.const</code> immediate, so a dot costs 5 points: the constant, the input from a local and the dot. That makes the ceiling 3.2 multiply-adds a point, before each output's reduction and store. The SDK's compiler and sandbox run the relaxed dot, but the online judge's acceptance of it is untested, because a test upload activates a submission.</p>
<table>
<thead><tr><th>Measurement</th><th>Value</th></tr></thead>
<tbody>
<tr><td>Probe network, 2.8M random int8 weights, about 9.7M multiply-adds</td><td>4.49M points an evaluation, 2.5–2.65 multiply-adds a point per layer including requantisation</td></tr>
<tr><td><code>expert-0001</code>'s turn with 128 states a filter, averaged over a whole game of 30,554 turns</td><td>17.4M points</td></tr>
<tr><td>4 MB submission, with trained int8 weights deflating to 67%</td><td>about 5.7M trained weights</td></tr>
</tbody>
</table>
<table>
<caption><code>expert-0001</code>'s average turn on help.map with 128 states a filter</caption>
<thead><tr><th>Component</th><th>Average points per turn</th></tr></thead>
<tbody>
<tr><td>Network</td><td>5.1M</td></tr>
<tr><td>Filters' prediction</td><td>3.2M</td></tr>
<tr><td>Reply's write</td><td>3.0M</td></tr>
<tr><td>Listing candidates</td><td>2.1M</td></tr>
<tr><td>Crop's encoding</td><td>1.0M</td></tr>
<tr><td>Overview, distances, pearl chances and the rest</td><td>2.9M</td></tr>
</tbody>
</table>
<p>That leaves the network and search about 88M points a turn before the reply reserve, enough for about 130 32-channel trunk layers. A search node costs only its encoding and one network evaluation, because its leaves start from the root's belief, predicted once a turn.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 170" role="img" aria-label="One 100M-point turn on help.map: about 17.4M for the turn's own work including one network evaluation, a reply reserve, and the rest for search">
  <rect class="layer" x="20" y="50" width="34.7" height="40"/>
  <rect class="box" x="54.7" y="50" width="21.8" height="40"/>
  <rect class="box" x="76.5" y="50" width="20.4" height="40"/>
  <rect class="box" x="96.9" y="50" width="14.3" height="40"/>
  <rect class="box" x="111.2" y="50" width="26.5" height="40"/>
  <rect class="neutral open" x="137.7" y="50" width="40.8" height="40"/>
  <rect class="good" x="178.5" y="50" width="521.5" height="40"/>
  <text class="small" x="20" y="40">network 5.1M</text>
  <text class="small" x="100" y="40">filters, reply, candidates, encoding, rest</text>
  <text class="small" x="140" y="110">reserve (placeholder 6M+)</text>
  <text class="small" x="438" y="75" text-anchor="middle">search: about 5.7 simulations of 5.4–5.9M each</text>
  <path class="rule" d="M20,130 L700,130"/>
  <text class="small" x="20" y="150">0</text>
  <text class="small" x="138" y="150" text-anchor="middle">17.4M</text>
  <text class="small" x="700" y="150" text-anchor="end">100M points</text>
</svg>
<figcaption>Where one turn's points go on help.map with 128 states a filter, drawn to scale from the figures in this section. The reserve's width is its placeholder's 6M before the reply term.</figcaption>
</figure>
<div class="oy-table-properties"><table>
<caption><code>expert-0001</code>, searching, against its floors and bounds on help.map seed 7 against foil-0039 (18,037 turns at 73.5M points a turn)</caption>
<thead><tr><th>Component</th><th>Points a turn</th><th>% of its floor</th><th>% of its bound</th><th>Not floored</th></tr></thead>
<tbody>
<tr><td>Network (0001 kernels)</td><td>34.79M</td><td>115%</td><td>121%</td><td>0</td></tr>
<tr><td>Network (0002 kernels, not yet in the bot)</td><td></td><td>103%</td><td>108%</td><td></td></tr>
<tr><td>Distances and step tables</td><td>7.37M</td><td>149%</td><td>~2,000%</td><td>0</td></tr>
<tr><td>Encoding</td><td>11.82M</td><td>177%</td><td>~1,300%</td><td>3.25M</td></tr>
<tr><td>Filters, with the pearl filter</td><td>8.42M</td><td>148%</td><td>~1,100%</td><td>0.05M</td></tr>
<tr><td>Search and tree</td><td>4.16M</td><td>134%</td><td>~3,500%</td><td>1.48M</td></tr>
<tr><td>Sonar</td><td>0.53M</td><td>≥138%</td><td>~1,800%</td><td>0.06M</td></tr>
</tbody></table></div>
<p>The network is close to both bounds. Everything else sits much further above its bound than its floor, so its remaining gaps need cheaper algorithms, such as incremental encodings and an overlay instead of a whole-game copy for each search sample.</p>
<h2 id="knowledge">Game knowledge</h2>
<p>Replay review and opponent study taught these lessons, and the options, rewards and review should account for them:</p>
<ul>
<li>Under the earlier rules, the foil started most of its head-on collisions, many by sprint, so a threat model has to include the sprint behind a head.</li>
<li>Under queen scoring, feeding consolidates into the queen, and recombination timing needs to be learned from its effect on queen survival and final length.</li>
<li>A child split directly behind its parent can receive a map upload over sonar.</li>
<li>Re-entering a farmed pocket that already holds teammates crowds them and can kill one, and two teammates can seal each other into a pocket two moves deep.</li>
<li>A 1×1 dead end is rarely productive.</li>
<li>Teammates' lengths can often be deduced exactly from observed splits and moves, and a dragon inside our own view can't be where we believe a teammate is.</li>
<li>Hard role holds should give way to a decaying persistence, so desperate need can still win.</li>
<li>Arrive at a spawning tile when its attempt is due, instead of chasing pearls already there.</li>
<li>An enemy that wants to live dodges a straight strike, so aim at the inner corner of its likely escape.</li>
<li>A route can collect pearls and reveal unseen ground at once, so collecting and exploring are values of one route.</li>
<li>Anaconda ring: a long dragon encloses a large space as a ring around a farming area, then turns inside itself. It stays one sprint from safety, and an enemy caught inside costs a cheap split, but it can't send sonar from inside.</li>
<li>Tail lurker: a small dragon waits at the enemy queen's tail to take the head of any dragon split off from it.</li>
<li>Rearguard: a length-2 dragon follows our queen and sends sonar of its rear, showing its escape route and where a rival's split could come from.</li>
</ul>
<h2 id="explored">Explored ideas</h2>
<p>These methods were studied, and several built, while the bot's training was designed, most in the reinforcement-learning (RL) line that preceded expert iteration. The RL line trained a policy by trial and error with PPO, and its larger, more elaborate networks didn't turn into strength, so the current network started small and plain to get the expert-iteration loop built and measured first. Each idea is a candidate for an equal-cost comparison in a part's decision record.</p>
<div class="oy-table-properties"><table>
<caption>Explored ideas and where each stands</caption>
<thead><tr><th>Idea</th><th>Where it stands</th></tr></thead>
<tbody>
<tr><td>Auxiliary prediction heads (UNREAL, multi-token prediction)</td><td>In the design as part 5's share head. The RL line's teacher also predicted unseen countdowns, enemy heads and its own future length.</td></tr>
<tr><td>Mixture of experts, where a router runs only a few expert sub-networks per input</td><td>The RL line's teacher and student both used it. An unchosen expert costs no points in the judge, so it suits the bot's budget.</td></tr>
<tr><td>FiLM, a per-channel scale and shift computed from global numbers</td><td>The RL line's teacher conditioned each residual block on the scalars, where the current network reads them once.</td></tr>
<tr><td>N-tuple tables, summed weights looked up by fixed groups of cells (Logistello, 2048)</td><td>The RL line's student carried 13. A lookup costs a few points, so tables distilled from the value head are the first contender for a cheap leaf evaluator (roadmap item 17).</td></tr>
<tr><td>Multi-teacher on-policy distillation</td><td>Planned with specialists by map type and opponent style, never run.</td></tr>
<tr><td>GRPO, critic-free advantages from a group of sampled actions</td><td>Planned for isolated decisions such as splits, never run.</td></tr>
<tr><td>FP8 and FP4 training</td><td>Planned, never run. Worth it only where arithmetic, not data movement or launches, limits a step.</td></tr>
<tr><td>Muon, an optimiser that orthogonalises each weight matrix's momentum</td><td>Not tried. The trainer uses AdamW.</td></tr>
<tr><td>PPO, GAE and reward shaping</td><td>The RL line's method. This design takes targets from search and values outcomes without shaping.</td></tr>
<tr><td>Kickstarting, DAPG, DAgger, DQfD, R2D2</td><td>The RL line used kickstarting and the foil's games as demonstrations. Expert iteration's later cycles are DAgger-like, because the teacher labels the student's own positions.</td></tr>
<tr><td>Level replay, PFSP, PBT, Procgen</td><td>The RL line used level replay and a PFSP league. Level replay could choose part 6's maps.</td></tr>
<tr><td>Residual blocks, normalisation, GRU memory, Neural Map, SimBa, BRO, Switch MoE</td><td>The RL line's teacher had eight residual blocks with LayerNorm and a 512-unit GRU. These are shapes to test at equal cost.</td></tr>
<tr><td>Option-Critic, FeUdal, local SGD, DiLoCo</td><td>The RL line used local SGD. A learned-option method is a contender for part 3 where candidate gaps persist.</td></tr>
</tbody></table></div>
<h2 id="concepts">Concept index</h2>
<p>Every concept explained on this page, in order of first appearance.</p>
<ul>
<li><a href="#c-pomdp">Partial observability and decentralisation</a> (the game)</li>
<li><a href="#c-rl">Reinforcement learning in one page</a>, <a href="#c-exit">expert iteration</a> and <a href="#c-ctde">CTDE</a> (the design)</li>
<li><a href="#c-floors">Floors and bounds</a> (principles)</li>
<li><a href="#c-encoding">Encoding, planes and channels</a>, <a href="#c-bayes">Bayes filters</a>, <a href="#c-filters">histogram, Bernoulli and renewal filters</a>, <a href="#c-checkbits">encryption and check bits</a>, <a href="#c-kld">KL divergence and KLD-sampling</a>, <a href="#c-calibration">calibration and informativeness</a> (part 1)</li>
<li><a href="#c-policyvalue">Policy and value heads</a>, <a href="#c-conv">crops, stems and trunks</a>, <a href="#c-tokens">set encoders and attention</a>, <a href="#c-quant">quantisation to int8</a>, <a href="#c-simd">WebAssembly, SIMD and the relaxed dot</a>, <a href="#c-nnue">efficiently updatable networks</a> (part 2)</li>
<li><a href="#c-options">The options framework</a>, <a href="#c-stp">skills, tactics and plays</a> (part 3)</li>
<li><a href="#c-mcts">Monte Carlo tree search and PUCT</a>, <a href="#c-ismcts">determinisation and information-set MCTS</a>, <a href="#c-gumbel">Gumbel root search and sequential halving</a>, <a href="#c-chance">chance nodes</a>, <a href="#c-pomcp">POMCP</a>, <a href="#c-pbs">public belief states: ReBeL and Student of Games</a>, <a href="#c-widening">progressive widening</a>, <a href="#c-spsa">SPSA and CLOP</a> (part 4)</li>
<li><a href="#c-imitation">Imitation learning</a>, <a href="#c-distil">distillation and cross-entropy</a>, <a href="#c-value">value functions, rollouts and privileged critics</a>, <a href="#c-td">TD(λ)</a>, <a href="#c-gap">the imitation gap</a>, <a href="#c-pdes">parallel discrete-event simulation</a>, <a href="#c-launch">kernel launches, CUDA graphs and persistent kernels</a> (part 5)</li>
<li><a href="#c-league">League training</a> (part 6)</li>
<li><a href="#c-wilson">Wilson bounds</a> (part 7)</li>
<li><a href="#c-solver">MCTS-Solver</a> (strategic improvement)</li>
</ul>
<h2 id="sources">Sources</h2>
<p>Every method on this page, grouped by where it sits.</p>
<h3 id="sources-method">The overall method</h3>
<ul>
<li>Anthony, Tian and Barber, <a href="https://arxiv.org/abs/1705.08439">Thinking Fast and Slow with Deep Learning and Tree Search</a> (2017): expert iteration.</li>
<li>Silver et al., Mastering the game of Go with deep neural networks and tree search (<em>Nature</em>, 2016): AlphaGo.</li>
<li>Silver et al., Mastering the game of Go without human knowledge (<em>Nature</em>, 2017), and A general reinforcement learning algorithm that masters chess, shogi and Go through self-play (<em>Science</em>, 2018): network-guided search and its policy and value targets.</li>
<li>Lowe et al., Multi-Agent Actor-Critic for Mixed Cooperative-Competitive Environments (2017), and Yu et al., The Surprising Effectiveness of PPO in Cooperative Multi-Agent Games (2022): centralised critics with decentralised actors.</li>
<li>Kaelbling, Littman and Cassandra, Planning and acting in partially observable stochastic domains (<em>Artificial Intelligence</em>, 1998): POMDPs and belief states.</li>
<li>Bernstein, Givan, Immerman and Zilberstein, The complexity of decentralized control of Markov decision processes (<em>Mathematics of Operations Research</em>, 2002): decentralised POMDPs and their hardness.</li>
<li>Sutton and Barto, <em>Reinforcement Learning: An Introduction</em>, 2nd edition (MIT Press, 2018): reinforcement learning, policies, values and critics.</li>
</ul>
<h3 id="sources-belief">Belief and sonar (part 1)</h3>
<ul>
<li>Thrun, Burgard and Fox, <em>Probabilistic Robotics</em> (2005): Bayes filters.</li>
<li>Ristic, Vo, Vo and Farina, A Tutorial on Bernoulli Filters (IEEE Transactions on Signal Processing, 2013): a target's chance of existing.</li>
<li>Feller, <em>An Introduction to Probability Theory and Its Applications</em>, volume 1, chapter 13: renewal processes.</li>
<li>Rabiner, A Tutorial on Hidden Markov Models (Proceedings of the IEEE, 1989): the pearl's two-state model.</li>
<li>Fox, <a href="https://doi.org/10.1177/0278364903022012001">Adapting the Sample Size in Particle Filters Through KLD-Sampling</a> (<em>IJRR</em>, 2003): sizing a filter by a bound on its approximation error.</li>
<li>Kullback and Leibler, On information and sufficiency (<em>Annals of Mathematical Statistics</em>, 1951): the divergence behind the filters' error bound.</li>
<li>Guo, Pleiss, Sun and Weinberger, On calibration of modern neural networks (ICML, 2017), and Gneiting and Raftery, Strictly proper scoring rules, prediction, and estimation (<em>JASA</em>, 2007): calibration, ECE and scoring the belief.</li>
<li>Beaulieu, Shors, Smith, Treatman-Clark, Weeks and Wingers, The SIMON and SPECK families of lightweight block ciphers (IACR ePrint 2013/404): sonar's cipher.</li>
<li>Golomb, Run-length encodings (<em>IEEE Transactions on Information Theory</em>, 1966), and Teuhola, A compression method for clustered bit-vectors (<em>Information Processing Letters</em>, 1978): the sonar records' exponential-Golomb fields.</li>
</ul>
<h3 id="sources-network">The network (part 2)</h3>
<ul>
<li>Jacob et al., <a href="https://arxiv.org/abs/1712.05877">Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference</a> (CVPR, 2018): quantisation-aware training.</li>
<li>Nasu, Efficiently Updatable Neural-Network-based Evaluation Functions for Computer Shogi (2018): NNUE, the incrementally updated first layer.</li>
<li>Bengio, Léonard and Courville, Estimating or propagating gradients through stochastic neurons for conditional computation (2013): the straight-through estimator.</li>
<li>Zaheer et al., Deep Sets (NeurIPS, 2017), and Vaswani et al., Attention is all you need (NeurIPS, 2017): reading the planned enemy tokens.</li>
</ul>
<h3 id="sources-options">Options (part 3)</h3>
<ul>
<li>Sutton, Precup and Singh, Between MDPs and semi-MDPs: A framework for temporal abstraction in reinforcement learning (<em>Artificial Intelligence</em>, 1999): options.</li>
<li>Browning et al., STP: Skills, tactics and plays for multi-robot control in adversarial environments (2005): cooperative plays.</li>
</ul>
<h3 id="sources-search">Search (part 4)</h3>
<ul>
<li>Coulom, Efficient selectivity and backup operators in Monte-Carlo tree search (Computers and Games, 2006), and Kocsis and Szepesvári, Bandit based Monte-Carlo planning (ECML, 2006): Monte Carlo tree search and UCT.</li>
<li>Auer, Cesa-Bianchi and Fischer, Finite-time analysis of the multiarmed bandit problem (<em>Machine Learning</em>, 2002): UCB1.</li>
<li>Rosin, Multi-armed bandits with episode context (<em>Annals of Mathematics and Artificial Intelligence</em>, 2011): the predictor-weighted bound behind PUCT.</li>
<li>Cowling, Powley and Whitehouse, Information Set Monte Carlo Tree Search (<em>IEEE TCIAIG</em>, 2012): search under hidden information.</li>
<li>Frank and Basin, Search in games with incomplete information: a case study using Bridge card play (<em>Artificial Intelligence</em>, 1998): strategy fusion.</li>
<li>Long, Sturtevant, Buro and Furtak, Understanding the success of perfect information Monte Carlo sampling in game tree search (AAAI, 2010): determinisation.</li>
<li>Danihelka, Guez, Schrittwieser and Silver, Policy improvement by planning with Gumbel (ICLR, 2022): policy improvement from few simulations.</li>
<li>Karnin, Koren and Somekh, Almost optimal exploration in multi-armed bandits (ICML, 2013): sequential halving.</li>
<li>Kool, van Hoof and Welling, Stochastic beams and where to find them: the Gumbel-top-k trick (ICML, 2019): sampling without replacement by Gumbel noise.</li>
<li>Couëtoux et al., Continuous Upper Confidence Trees (LION, 2011): progressive widening's exponent form.</li>
<li>Spall, Multivariate Stochastic Approximation Using a Simultaneous Perturbation Gradient Approximation (<em>IEEE TAC</em>, 1992), and Coulom, CLOP: Confident Local Optimization for Noisy Black-Box Parameter Tuning (2011): tuning constants jointly from noisy matches.</li>
<li>Winands, Björnsson and Saito, Monte-Carlo tree search solver (Computers and Games, 2008): proven outcomes in search.</li>
<li>Silver and Veness, Monte-Carlo Planning in Large POMDPs (NeurIPS, 2010): POMCP, a contender to information-set MCTS.</li>
<li>Brown, Bakhtin, Lerer and Gong, Combining deep reinforcement learning and search for imperfect-information games (NeurIPS, 2020): ReBeL, search over public belief states, a contender.</li>
<li>Schmid et al., Student of Games: a unified learning algorithm for both perfect and imperfect information games (<em>Science Advances</em>, 2023): growing-tree CFR, a contender.</li>
</ul>
<h3 id="sources-teacher">Teacher and training (part 5)</h3>
<ul>
<li>Schrittwieser et al., Mastering Atari, Go, chess and shogi by planning with a learned model (<em>Nature</em>, 2020): MuZero, the setting of Gumbel MuZero.</li>
<li>Warrington et al., <a href="https://arxiv.org/abs/2012.15566">Robust Asymmetric Learning in POMDPs</a> (ICML, 2021): the imitation gap of privileged teachers.</li>
<li>Pinto, Andrychowicz, Welinder, Zaremba and Abbeel, Asymmetric actor critic for image-based robot learning (RSS, 2018): a critic with privileged state for an actor without it.</li>
<li>Wilson, Probable inference, the law of succession, and statistical inference (<em>JASA</em>, 1927): the Wilson score interval.</li>
<li>Sutton, Learning to predict by the methods of temporal differences (<em>Machine Learning</em>, 1988): TD(λ).</li>
<li>Hinton, Vinyals and Dean, Distilling the knowledge in a neural network (2015): distillation.</li>
<li>Kingma and Ba, Adam: a method for stochastic optimization (ICLR, 2015): Adam.</li>
<li>Loshchilov and Hutter, <a href="https://arxiv.org/abs/1711.05101">Decoupled Weight Decay Regularization</a> (ICLR, 2019): AdamW.</li>
<li>Pascanu, Mikolov and Bengio, On the difficulty of training recurrent neural networks (ICML, 2013): clipping gradients by norm.</li>
<li>Shrivastava, Gupta and Girshick, Training region-based object detectors with online hard example mining (CVPR, 2016): weighting the examples a model gets wrong.</li>
<li>Chandy and Misra, Distributed simulation: a case study in design and verification of distributed programs (<em>IEEE Transactions on Software Engineering</em>, 1979): conservative parallel discrete-event simulation.</li>
<li>Jefferson, Virtual time (<em>ACM Transactions on Programming Languages and Systems</em>, 1985): Time Warp, optimistic parallel discrete-event simulation.</li>
<li>Wu, <a href="https://arxiv.org/abs/1902.10565">Accelerating Self-Play Learning in Go</a> (2019): KataGo's playout cap randomization.</li>
</ul>
<h3 id="sources-league">League and ratings (part 6)</h3>
<ul>
<li>Vinyals et al., Grandmaster level in StarCraft II using multi-agent reinforcement learning (<em>Nature</em>, 2019): league training.</li>
<li>Berner et al., Dota 2 with large scale deep reinforcement learning (2019): OpenAI Five.</li>
<li>Schulman, Wolski, Dhariwal, Radford and Klimov, Proximal policy optimization algorithms (2017): PPO, a policy-gradient reinforcement-learning method.</li>
<li>Elo, <em>The Rating of Chessplayers, Past and Present</em> (Arco, 1978): Elo ratings.</li>
</ul>
<h3 id="sources-precedents">Precedents in similar games</h3>
<ul>
<li>Lux AI Season 1 (Kaggle, 2021), won by Toad Brigade with deep reinforcement learning, per <a href="https://arxiv.org/pdf/2301.01609">arXiv 2301.01609</a>: a reference result for learned agents in multi-unit grid games.</li>
<li>Kaggle Hungry Geese (2021), a four-player snake game on a wrapped board, won by DeNA's HandyRL team (<a href="https://dena.ai/news/kaggle-hungry-geese/">DeNA</a>; <a href="https://github.com/DeNA/HandyRL">HandyRL</a>), and the closest published precedent to Loong. The team trained a CNN, designed so convolutions respect the wrapped board, by distributed off-policy deep reinforcement learning in self-play (<a href="https://zenn.dev/ktechb/articles/e2394bc27358c4">a participant's review</a>), and at play time ran MCTS with a linear evaluation function, ensembled with a large network (<a href="https://speakerdeck.com/nagiss/kagglesimiyuresiyonkonpenodong-xiang">a competitor's survey of Kaggle simulation competitions</a>).</li>
</ul>
<h3 id="sources-explored">Explored ideas</h3>
<ul>
<li>Jaderberg et al., Reinforcement learning with unsupervised auxiliary tasks (ICLR, 2017): UNREAL.</li>
<li>Gloeckle et al., Better and faster large language models via multi-token prediction (ICML, 2024): multi-token prediction.</li>
<li>DeepSeek-AI, DeepSeek-V3 technical report (2024): FP8 training, multi-token prediction and DeepSeekMoE.</li>
<li>DeepSeek-AI, <a href="https://arxiv.org/abs/2606.19348">DeepSeek-V4: Towards Highly Efficient Million-Token Context Intelligence</a> (2026): Muon, FP4 quantisation-aware training of expert weights, and specialists distilled on-policy into one model.</li>
<li>DeepSeek-AI, DeepSeek-R1: Incentivizing reasoning capability in LLMs via reinforcement learning (2025), and Shao et al., DeepSeekMath (2024): GRPO.</li>
<li>Shazeer et al., Outrageously large neural networks: the sparsely-gated mixture-of-experts layer (ICLR, 2017); Puigcerver et al., From sparse to soft mixtures of experts (ICLR, 2024); Obando-Ceron et al., Mixtures of experts unlock parameter scaling for deep RL (ICML, 2024).</li>
<li>Perez, Strub, de Vries, Dumoulin and Courville, FiLM: visual reasoning with a general conditioning layer (AAAI, 2018).</li>
<li>Buro, From simple features to sophisticated evaluation functions (Computers and Games, 1999): Logistello's patterns; Szubert and Jaśkowski, Temporal difference learning of n-tuple networks for the game 2048 (IEEE CIG, 2014).</li>
<li>Rusu et al., Policy distillation (ICLR, 2016); Teh et al., Distral: robust multitask reinforcement learning (NeurIPS, 2017); Agarwal et al., On-policy distillation of language models (ICLR, 2024).</li>
<li>Micikevicius et al., FP8 formats for deep learning (2022).</li>
<li>Zobrist, A new hashing method with application for game playing (1970): transposition keys.</li>
<li>Schulman et al., High-dimensional continuous control using generalized advantage estimation (ICLR, 2016); Huang et al., The 37 implementation details of proximal policy optimization (2022); Ng, Harada and Russell, Policy invariance under reward transformations (ICML, 1999).</li>
<li>Ross, Gordon and Bagnell, A reduction of imitation learning and structured prediction to no-regret online learning (AISTATS, 2011): DAgger; Rajeswaran et al., Learning complex dexterous manipulation with deep reinforcement learning and demonstrations (RSS, 2018): DAPG; Hester et al., Deep Q-learning from demonstrations (AAAI, 2018); Schmitt et al., Kickstarting deep reinforcement learning (2018); Kapturowski et al., Recurrent experience replay in distributed reinforcement learning (ICLR, 2019): R2D2.</li>
<li>Jiang, Grefenstette and Rocktäschel, Prioritized level replay (ICML, 2021); Cobbe et al., Leveraging procedural generation to benchmark reinforcement learning (ICML, 2020); Jaderberg et al., Population based training of neural networks (2017), and Human-level performance in 3D multiplayer games with population-based reinforcement learning (<em>Science</em>, 2019).</li>
<li>He, Zhang, Ren and Sun, Deep residual learning for image recognition (CVPR, 2016); Ba, Kiros and Hinton, Layer normalization (2016); Wu and He, Group normalization (ECCV, 2018); Cho et al., Learning phrase representations using RNN encoder-decoder for statistical machine translation (EMNLP, 2014): the GRU; Parisotto and Salakhutdinov, Neural Map (ICLR, 2018); Lee et al., SimBa (ICLR, 2025); Nauman et al., Bigger, regularized, optimistic (NeurIPS, 2024): BRO; Fedus, Zoph and Shazeer, Switch Transformers (<em>JMLR</em>, 2022).</li>
<li>Bacon, Harb and Precup, The option-critic architecture (AAAI, 2017); Vezhnevets et al., FeUdal networks for hierarchical reinforcement learning (ICML, 2017); Lin et al., Don't use large mini-batches, use local SGD (ICLR, 2020); Douillard et al., DiLoCo: distributed low-communication training of language models (2023).</li>
<li>Jordan et al., Muon: an optimizer for hidden layers in neural networks (2024), and Liu et al., Muon is scalable for LLM training (2025).</li>
</ul>
  
</div>

# The final specification

<div class="oy-prose-wiki">

<svg class="oy-diagram oy-diagram-defs" width="0" height="0" aria-hidden="true"><defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z"/></marker></defs></svg>
<h2 id="reading">Reading this page</h2>
<p>This page is both the design's specification and a guided tour of the ideas behind it. It is written for a reader who knows data structures, algorithms and the basics of neural networks, but hasn't seen how a game-playing system like this is put together, or why its pieces were chosen.</p>
<p>The page runs in the order the ideas build on each other. It starts with the game and its limits, then explains the overall method, expert iteration with centralised training, and then takes the seven parts in turn: what a dragon believes, the network that scores its choices, the choices themselves, the search that checks them, the teacher that improves the network, the opponents it trains against, and how decisions are reviewed. The Budget section then gives the measurements everything is sized from.</p>
<p>The specification's own statements are in the main text. Boxed asides explain a concept the first time it appears: what it is, why it works and why it was chosen here. The <a href="#concepts">concept index</a> lists them all. Figures captioned "textbook" illustrate a general method. Figures that describe the implementation identify their source.</p>
<h2 id="objective">Objective</h2>
<p>The objective is first prize in the UNSW Battlecode Loong competition. The rules are in <a href="https://game.battlecode.au/docs/">the competition documentation</a>. Under the Slay Queen rules from 1 October, a game is won by eliminating the other team. Otherwise, after round 500, the queens (dragons 0 and 1) are compared, then the longest living dragon, then total living length.</p>
<p>The expert line (<code>bots/expert</code>) is the only bot line in development. Its bot is judged by reviewing its decisions in replays in <code>just viewer</code>. Win rates, ratings and other aggregate statistics select games for review and tune parameters. They don't establish that a decision was sound.</p>
<h2 id="game">The game in brief</h2>
<p>The design only makes sense against the game's shape, so here is the part of <code>planning/rules.md</code> that drives it. Two teams play on a rectangular grid, 10 to 64 cells a side, that wraps at both edges like a torus. Each team controls dragons: snakes whose head moves one cell north, east, south or west each turn while the body follows. Eating a pearl adds a segment. Crossing kelp, running into your own body or into another dragon's body kills the mover, and two heads meeting kill both. Portals join pairs of edges.</p>
<p>A dragon can also sprint, several steps in one action, where the first ceil(L/4) steps are free for a dragon of length L and each later step costs a tail segment. It can split, handing its rear k segments to a new dragon, which starts as a fresh program with no memory. There is no way to stand still. Up to 64 dragons a team may live, and all of them act one after another in ID order every round.</p>
<p>Two facts shape everything below. First, each dragon sees only the 7×7 square around its head. Everything beyond it must be remembered, inferred or told. Second, each dragon runs as its own process with no shared memory. Teammates communicate only by sonar: up to four 64-bit values a turn, one in each direction, each travelling in a straight line until it hits kelp or the first dragon segment. The receiver doesn't learn who sent it, and the enemy can receive it too. On its next turn the sender gets <em>echoes</em>: counts of what its rays hit (kelp, allied body, allied head, enemy body, enemy head), which is a little sensing beyond the window. When a dragon dies, alternate segments starting at its head become pearls, ceil(L/2) of them, so a death feeds whoever is nearby.</p>
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
<figcaption>Illustration of the game's observation and communication rules, from <code>planning/rules.md</code>.</figcaption>
</figure>
<p>Every dragon's turn is metered. The judge, the organisers' program that runs matches, compiles each bot to WebAssembly, a compact portable instruction set that runs in a sandbox, and charges a fixed number of "points" for every instruction executed. Each dragon gets 100 million points a turn, 48 MB of memory and one thread, and the whole team's submission is at most 4 MB. A dragon that exceeds its points dies.</p>
<p>Teams upload bots to the <em>ladder</em>, the competition's online matchmaking, where ranked games move each team's Elo rating (Elo, 1978): a number whose difference between two teams predicts how often one beats the other (a 200-point gap means the stronger side wins about three games in four). The tournaments are played on maps nobody has seen.</p>
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
  <text class="small" x="360" y="150" text-anchor="middle">every tournament is a seeded single-elimination knockout on maps nobody has seen; the submission active at each cutoff plays</text>
</svg>
<figcaption>The competition's structure, from <code>planning/rules.md</code>. The objective is first prize at the Grand Final.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-pomdp">
<h3>Partial observability and decentralisation</h3>
<p>A game where you can't see the whole state is a <em>partially observable</em> decision problem (a POMDP; Kaelbling, Littman and Cassandra, 1998). The right decision then depends not on the true state, which you don't know, but on your <em>belief</em>: a probability distribution over the states consistent with everything you've seen and been told. That is why part 1 of the design is a belief, and why the network reads the belief rather than raw observations.</p>
<p>A team whose members decide separately, each with its own partial view, is a <em>decentralised</em> POMDP. These are much harder, provably so: Bernstein and colleagues (2002) showed that solving one exactly is NEXP-complete, far beyond an ordinary POMDP: a teammate's action depends on what it knows, which you can only guess. The design's answer, below, is to learn the coordination offline where everything is visible, and execute it separately.</p>
</aside>
<h2 id="design">The design</h2>
<aside class="oy-card oy-alert" id="c-rl">
<h3>Reinforcement learning in one page</h3>
<p>Reinforcement learning (RL; Sutton and Barto, 2018) studies an <em>agent</em> that repeatedly observes a state, chooses an action and eventually receives a reward, here a win, draw or loss. A <em>policy</em> maps what the agent knows to a choice of action, often as probabilities over the legal actions. A <em>value function</em> estimates the reward to expect from a position under that policy. Learning a policy from trial and error alone is slow because a game's reward arrives only at the end, so most methods also learn a value function to judge positions in between. A learned value used to grade the policy's choices is called a <em>critic</em>, and the policy it grades an <em>actor</em>.</p>
<p><em>Self-play</em> means the agent learns from games against copies of itself, so it always has an opponent at its own level. <em>Search</em> means looking ahead by simulating possible futures before choosing. The methods below combine all of these.</p>
</aside>
<p>The design is expert iteration (Anthony, Tian and Barber, 2017), the scheme behind AlphaGo Zero and AlphaZero (Silver et al., 2017 and 2018), applied to a decentralised team. In multi-agent reinforcement learning the standard pattern for this is centralised training with decentralised execution, CTDE (Lowe et al., 2017; Yu et al., 2022). Expensive, fully informed reasoning runs offline, where compute is cheap. It improves the targets a small network learns. During play, each dragon runs that network on its own observations, and searches with the rest of its own turn's budget.</p>
<aside class="oy-card oy-alert" id="c-exit">
<h3>Expert iteration</h3>
<p>Expert iteration pairs a fast <em>apprentice</em>, a neural network that picks a move in one pass, with a slow <em>expert</em>, a search that looks ahead using the apprentice's judgement as a guide. The search plays better than the network on its own, because it checks the consequences of moves the network merely guesses at. So the expert's choices make better training targets than anything the apprentice could produce. Train the apprentice to imitate the expert, and it improves. A better apprentice guides the next search better, so the expert improves too, and the loop repeats.</p>
<p>The <em>training target</em> for a decision is the answer the network is trained to reproduce, here the expert's choice. Anthony and colleagues named it in 2017 ("thinking fast and slow"), and AlphaGo Zero and AlphaZero used the same loop to reach superhuman Go, chess and shogi from self-play alone. If you know genetic programming, the closest analogy is a population improved by selection, except that here the improvement step is a search that proposes better moves directly, and gradient descent copies them into one network.</p>
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
<p>In play, each dragon must decide from its own view. In training nothing stops us from showing the learning system everything: every dragon's position, the hidden pearls, the enemy's plan. CTDE exploits that asymmetry. Components that exist only during training, such as a critic that judges positions or a teacher that chooses targets, see the whole board and the whole team. The policy that is actually deployed sees only what one dragon would see. The privileged components make learning faster and better informed, and the deployed policy stays honest about what it can know.</p>
<p>The standard examples are MADDPG (Lowe et al.), where each agent's critic sees all agents, and MAPPO (Yu et al.). Here the privileged parts are the teacher's search and its value network (part 5), and the deployed part is each dragon's network and search (parts 2 and 4).</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 210" role="img" aria-label="CTDE: in training, a privileged teacher sees the whole board and produces targets; in play, each dragon's network sees only its own belief">
  <rect class="frame" x="10" y="10" width="340" height="190" rx="6"/>
  <text class="head" x="180" y="34" text-anchor="middle">Training (offline, GPU)</text>
  <rect class="box" x="30" y="50" width="140" height="56" rx="6"/>
  <text class="head" x="100" y="74" text-anchor="middle">True state</text>
  <text class="small" x="100" y="94" text-anchor="middle">whole board, all dragons</text>
  <rect class="layer" x="190" y="50" width="140" height="56" rx="6"/>
  <text class="head" x="260" y="74" text-anchor="middle">Teacher</text>
  <text class="small" x="260" y="94" text-anchor="middle">search + privileged value</text>
  <rect class="layer" x="90" y="130" width="180" height="56" rx="6"/>
  <text class="head" x="180" y="154" text-anchor="middle">Student network</text>
  <text class="small" x="180" y="174" text-anchor="middle">learns from one dragon's view</text>
  <path class="flow" d="M170,78 L188,78" marker-end="url(#arrow)"/>
  <path class="flow" d="M260,106 L215,128" marker-end="url(#arrow)"/>
  <text class="small" x="262" y="124">targets</text>
  <rect class="frame" x="370" y="10" width="340" height="190" rx="6"/>
  <text class="head" x="540" y="34" text-anchor="middle">Play (each dragon, in the judge)</text>
  <rect class="box" x="390" y="60" width="90" height="50" rx="6"/>
  <text class="head" x="435" y="90" text-anchor="middle">Dragon A</text>
  <rect class="box" x="495" y="60" width="90" height="50" rx="6"/>
  <text class="head" x="540" y="90" text-anchor="middle">Dragon B</text>
  <rect class="box" x="600" y="60" width="90" height="50" rx="6"/>
  <text class="head" x="645" y="90" text-anchor="middle">Dragon C</text>
  <text class="small" x="540" y="140" text-anchor="middle">each: own belief → network → search</text>
  <text class="small" x="540" y="160" text-anchor="middle">no shared memory; sonar only</text>
  <path class="flow dash" d="M270,158 L388,90" marker-end="url(#arrow)"/>
  <text class="small" x="290" y="170">exported copy</text>
</svg>
<figcaption>Textbook: the CTDE split as this design uses it.</figcaption>
</figure>
<h3 id="lineage">The systems this design builds on</h3>
<p>Four published systems shaped this design. AlphaGo combined imitation of human play, self-play and tree search. AlphaGo Zero and AlphaZero kept the search and dropped everything else, which is expert iteration in its purest form. AlphaStar, whose league is described in part 6, and OpenAI Five learned by reinforcement learning in team and hidden-information games, without search at play. This design takes AlphaStar's start from imitation, AlphaZero's search-generated targets, and OpenAI Five's one network shared by many units, then adds what Loong needs: a belief for the hidden board, a privileged teacher, and search within each dragon's own budget.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 190" role="img" aria-label="AlphaGo: human games train a supervised policy, self-play improves it into an RL policy, whose games train a value network; at play, MCTS takes priors from the supervised policy and values leaves by mixing the value network with fast rollouts">
  <rect class="box" x="8" y="10" width="150" height="56" rx="6"/>
  <text class="head" x="83" y="30" text-anchor="middle">Human games</text>
  <text class="small" x="83" y="47" text-anchor="middle">expert positions</text>
  <path class="flow" d="M158,38 L196,38" marker-end="url(#arrow)"/>
  <rect class="layer" x="198" y="10" width="150" height="56" rx="6"/>
  <text class="head" x="273" y="30" text-anchor="middle">SL policy</text>
  <text class="small" x="273" y="47" text-anchor="middle">imitates the experts</text>
  <path class="flow" d="M348,38 L386,38" marker-end="url(#arrow)"/>
  <rect class="layer" x="388" y="10" width="150" height="56" rx="6"/>
  <text class="head" x="463" y="30" text-anchor="middle">RL policy</text>
  <text class="small" x="463" y="47" text-anchor="middle">improved by self-play</text>
  <path class="flow" d="M538,38 L576,38" marker-end="url(#arrow)"/>
  <rect class="layer" x="578" y="10" width="134" height="56" rx="6"/>
  <text class="head" x="645" y="30" text-anchor="middle">Value network</text>
  <text class="small" x="645" y="47" text-anchor="middle">trained on RL games</text>
  <rect class="neutral" x="8" y="110" width="150" height="56" rx="6"/>
  <text class="head" x="83" y="130" text-anchor="middle">Fast rollout policy</text>
  <text class="small" x="83" y="147" text-anchor="middle">small, linear</text>
  <rect class="good" x="250" y="110" width="300" height="70" rx="6"/>
  <text class="head" x="400" y="130" text-anchor="middle">MCTS at play</text>
  <text class="small" x="400" y="147" text-anchor="middle">priors from the SL policy; leaf =</text>
  <text class="small" x="400" y="162" text-anchor="middle">½ value network + ½ rollout result</text>
  <path class="flow" d="M273,66 L330,108" marker-end="url(#arrow)"/>
  <path class="flow" d="M645,66 L520,108" marker-end="url(#arrow)"/>
  <path class="flow" d="M158,138 L248,142" marker-end="url(#arrow)"/>
</svg>
<figcaption>Textbook: AlphaGo (Silver et al., 2016).</figcaption>
</figure>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 182" role="img" aria-label="AlphaGo Zero and AlphaZero: one network with policy and value heads plays itself with MCTS; the search visit counts and the game result become its targets, and the loop repeats">
  <rect class="layer" x="8" y="50" width="170" height="64" rx="6"/>
  <text class="head" x="93" y="70" text-anchor="middle">One network</text>
  <text class="small" x="93" y="87" text-anchor="middle">policy head + value head</text>
  <text class="small" x="93" y="102" text-anchor="middle">residual body</text>
  <path class="flow" d="M178,82 L236,82" marker-end="url(#arrow)"/>
  <rect class="layer" x="238" y="50" width="180" height="64" rx="6"/>
  <text class="head" x="328" y="70" text-anchor="middle">Self-play with MCTS</text>
  <text class="small" x="328" y="87" text-anchor="middle">about 800–1,600</text>
  <text class="small" x="328" y="102" text-anchor="middle">simulations a move</text>
  <path class="flow" d="M418,82 L476,82" marker-end="url(#arrow)"/>
  <rect class="good" x="478" y="50" width="234" height="64" rx="6"/>
  <text class="head" x="595" y="70" text-anchor="middle">Targets</text>
  <text class="small" x="595" y="87" text-anchor="middle">policy: MCTS visit counts</text>
  <text class="small" x="595" y="102" text-anchor="middle">value: the game's result</text>
  <path class="flow" d="M595,114 L595,150 L93,150 L93,116" marker-end="url(#arrow)"/>
  <text class="small" x="344" y="168" text-anchor="middle">train, then play again with the new network: no human data, no rollouts</text>
  <text class="small" x="344" y="30" text-anchor="middle">AlphaGo Zero kept a new network only if it won 55% against the best so far; AlphaZero dropped the gate</text>
</svg>
<figcaption>Textbook: AlphaGo Zero and AlphaZero (Silver et al., 2017 and 2018), expert iteration in its best-known form.</figcaption>
</figure>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 218" role="img" aria-label="OpenAI Five: five heroes each run a copy of one LSTM network reading the game as a list of units; rollout workers play self-play games against current and past versions; a PPO optimiser updates the shared weights">
  <rect class="frame" x="8" y="10" width="300" height="170" rx="6"/>
  <text class="head" x="158" y="30" text-anchor="middle">Five heroes, five copies</text>
  <rect class="layer" x="18" y="42" width="52" height="44" rx="6"/>
  <text class="head" x="44" y="62" text-anchor="middle">H1</text>
  <text class="small" x="44" y="79" text-anchor="middle">LSTM</text>
  <rect class="layer" x="76" y="42" width="52" height="44" rx="6"/>
  <text class="head" x="102" y="62" text-anchor="middle">H2</text>
  <text class="small" x="102" y="79" text-anchor="middle">LSTM</text>
  <rect class="layer" x="134" y="42" width="52" height="44" rx="6"/>
  <text class="head" x="160" y="62" text-anchor="middle">H3</text>
  <text class="small" x="160" y="79" text-anchor="middle">LSTM</text>
  <rect class="layer" x="192" y="42" width="52" height="44" rx="6"/>
  <text class="head" x="218" y="62" text-anchor="middle">H4</text>
  <text class="small" x="218" y="79" text-anchor="middle">LSTM</text>
  <rect class="layer" x="250" y="42" width="52" height="44" rx="6"/>
  <text class="head" x="276" y="62" text-anchor="middle">H5</text>
  <text class="small" x="276" y="79" text-anchor="middle">LSTM</text>
  <text class="small" x="158" y="108" text-anchor="middle">one set of weights; each copy reads</text>
  <text class="small" x="158" y="124" text-anchor="middle">the game as a list of units</text>
  <text class="small" x="158" y="148" text-anchor="middle">reward blends own and team ("team spirit")</text>
  <path class="flow" d="M308,95 L346,95" marker-end="url(#arrow)"/>
  <rect class="box" x="348" y="60" width="170" height="70" rx="6"/>
  <text class="head" x="433" y="80" text-anchor="middle">Rollout workers</text>
  <text class="small" x="433" y="97" text-anchor="middle">self-play games:</text>
  <text class="small" x="433" y="112" text-anchor="middle">80% current, 20% past</text>
  <path class="flow" d="M518,95 L556,95" marker-end="url(#arrow)"/>
  <rect class="good" x="558" y="60" width="154" height="70" rx="6"/>
  <text class="head" x="635" y="80" text-anchor="middle">PPO optimiser</text>
  <text class="small" x="635" y="97" text-anchor="middle">GAE advantages,</text>
  <text class="small" x="635" y="112" text-anchor="middle">huge batches</text>
  <path class="flow dash" d="M635,130 L635,194 L158,194 L158,182" marker-end="url(#arrow)"/>
  <text class="small" x="470" y="210" text-anchor="middle">new weights to every worker; "surgery" carried training through changes to the network</text>
</svg>
<figcaption>Textbook: OpenAI Five (Berner et al., 2019), reinforcement learning without search.</figcaption>
</figure>
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
<p>The design follows from two measured limits. Each dragon has 100M points a turn, 48 MB and one thread. Simulating the whole team faithfully for every decision doesn't fit in that budget. Decision quality therefore has to come from what the network learns offline. Hand-weighted scores don't check the consequences of a choice, and they plateau. The learned value and the search together replace them.</p>
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
<p>Reading the loop clockwise: games are played against a <em>league</em> of opponents (part 6). Those are the <em>foil</em>, our earlier hand-written bot and the strongest one we had (bot versions are named line, kind and number, so foil-0039 is the foil line's 39th main version, frozen once a later one exists); the <em>pool</em>, frozen copies of earlier bots kept as registered builds (compiled once and stored, so each plays identically every time); <em>mimics</em>, networks trained to play like particular top ladder teams; and the network itself. The <em>teacher</em> (part 5) replays positions from those games with a full view of the board and searches for better moves. The network is trained on them, <em>exported</em> as integer code the judge can run (part 2), and built into the bot, which joins the league.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 230" role="img" aria-label="One dragon's turn: observation and sonar update the belief planes, options propose candidates, the network scores them, search spends the rest of the dragon's budget, and the route controller emits the action and sonar">
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
<p>Within one turn, the dragon updates what it believes from what it sees and hears (part 1). Its <em>options</em> (part 3) propose a short list of <em>candidates</em>, concrete things it could do this turn such as "head for that pearl" or "escape east". The network (part 2) gives each candidate a <em>prior</em>, its estimated probability of being the best choice, and estimates the position's value. Search (part 4) checks the most promising candidates by simulating ahead, and a <em>route controller</em> turns the chosen candidate into this turn's move and sonar.</p>
<h3 id="principles">Principles for every component</h3>
<p>Every component is optimised towards its floor before the parts are balanced against each other. Each component has two lower bounds. Its algorithm's floor is the fewest judge points its current algorithm can cost, with each operation at its cheapest legal WebAssembly sequence under the judge's prices. Its operation's bound is the fewest points any algorithm needs for what the component has to compute: for the network, the judge's prices allow at most about 3.2 multiply-adds a point (<a href="#budget">Budget</a>). Each component's measured cost is reported against both. A gap to the algorithm's floor is closed by tightening the code, and a gap between the floor and the operation's bound by a cheaper algorithm.</p>
<aside class="oy-card oy-alert" id="c-floors">
<h3>Floors and bounds</h3>
<p>Because the judge prices every instruction exactly, "how fast could this be?" has a precise answer, in two layers. Take sorting as an example. A particular merge sort, written as tightly as the instruction prices allow, has a floor: the cost of its unavoidable loads, compares and stores. That is the <em>algorithm's floor</em>. But no comparison sort can beat roughly n log n comparisons, and if the keys are small integers a counting sort does even less work. The least any method could spend is the <em>operation's bound</em>. Measuring against both tells you whether to polish the code (you're far from the floor) or change the algorithm (the floor itself is far from the bound).</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 120" role="img" aria-label="A component's measured cost sits above its algorithm's floor, which sits above the operation's bound; tightening code closes the first gap, a cheaper algorithm the second">
  <path class="rule" d="M40,60 L680,60"/>
  <circle class="dot" cx="120" cy="60" r="6"/>
  <circle class="dot" cx="360" cy="60" r="6"/>
  <circle class="dot" cx="620" cy="60" r="6"/>
  <text class="head" x="120" y="40" text-anchor="middle">Operation's bound</text>
  <text class="head" x="360" y="40" text-anchor="middle">Algorithm's floor</text>
  <text class="head" x="620" y="40" text-anchor="middle">Measured cost</text>
  <text class="small" x="240" y="90" text-anchor="middle">closed by a cheaper algorithm</text>
  <text class="small" x="490" y="90" text-anchor="middle">closed by tighter code</text>
  <text class="small" x="40" y="110">fewer points</text>
  <text class="small" x="680" y="110" text-anchor="end">more points</text>
</svg>
<figcaption>Textbook: the two lower bounds every component is reported against.</figcaption>
</figure>
<p>Every constant in the bot, the teacher and the trainer (caps, radii, counts, exploration constants, expiries and reserves) is set by a principled rule wherever theory gives one: a derivation, a bound or a decision-theoretic criterion. It is measured only where theory gives none, or to confirm a rule: the bot's constants at equal cost in the judge, the offline stages' by strength gained per GPU-second and per dollar. The method is named beside each constant, and a constant set by neither is a placeholder.</p>
<p>Each part's method is a choice among known methods, not a given. Once the current design is implemented, optimised to its floors and playing on the ladder, so that its rating is the baseline, each of the seven parts gets a decision record: the best known methods for its problem, recent work and other teams' approaches included; the method chosen and the theory or measurement behind it; and each credible contender, either tested against the current method at equal cost or argued out with a stated reason. A contender that wins replaces the method, after a reviewed specification change. The records are revisited where the evidence points: information gaps in the value-lost report (part 5, which sorts every departure from the teacher's choice into one of three causes) point to the belief and sonar, ranking gaps to the network, candidate gaps to the options, and a search that loses to its own network to the search.</p>
<h2 id="parts">The seven parts</h2>
<p>Each part names its textbook method. A change to any part requires a reviewed specification revision. The parts follow the order of a dragon's turn and then the order of training: what the dragon believes (1), how it scores options (2), what its options are (3), how it checks them (4), how the scorer is improved offline (5), who it trains against (6), and how its decisions are judged (7).</p>
<h3 id="belief">1. Belief state per dragon</h3>
<p>Keep a hand-built Bayes-filter world model (Thrun, Burgard and Fox, <em>Probabilistic Robotics</em>): the map, pearl timers, enemy sightings and decoded sonar. It becomes a stack of input planes for the network. Inference we do ourselves is inference the network doesn't have to learn, so the network can be smaller. Sonar carries the facts the planes need from teammates.</p>
<aside class="oy-card oy-alert" id="c-encoding">
<h3>Encoding, planes and channels</h3>
<p>A neural network reads numbers, not game objects, so the belief is <em>encoded</em> into fixed arrays. Spatial facts become <em>planes</em>: a grid of numbers aligned with the map, one number per cell, such as "pearl chance here" or "kelp on this cell's left edge". Stacking many planes gives a three-dimensional array, height × width × <em>channels</em>, the same layout as an image's red, green and blue channels, only with 56 channels instead of 3. Facts that aren't spatial, such as the round or our length, become a vector of <em>scalars</em>. Each candidate move gets its own small record of bytes.</p>
<p>Two rules make encoding safe here. Every value is an integer byte, so the bot and the GPU training engine produce identical inputs, bit for bit. And nothing privileged leaks in: if training inputs ever contained something the bot can't know, the network would learn to rely on it and fail in play.</p>
</aside>
<aside class="oy-card oy-alert" id="c-bayes">
<h3>Bayes filters</h3>
<p>A Bayes filter keeps a probability distribution over a hidden quantity, say where an unseen enemy's head is, and updates it in two alternating steps. <em>Predict</em>: push the distribution forward one round using a model of how the quantity moves, so the probability spreads to every cell the enemy could have reached. <em>Correct</em>: when an observation arrives, multiply each possibility by how likely that observation would be if it were true, and renormalise. Seeing an empty cell is an observation too: it sets the probability there to zero and raises it elsewhere.</p>
<p>The appeal is that confidence behaves correctly by construction. An enemy last seen ten rounds ago really could be anywhere within ten moves, and the prediction step spreads it exactly that far. Nothing needs a hand-tuned "forget after N rounds" timer.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 190" role="img" aria-label="Bayes filter cycle: the belief is predicted forward by the motion model, then corrected by the observation's likelihood, giving the new belief">
  <rect class="layer" x="20" y="60" width="160" height="70" rx="6"/>
  <text class="head" x="100" y="90" text-anchor="middle">Belief at t</text>
  <text class="small" x="100" y="110" text-anchor="middle">probability per state</text>
  <rect class="box" x="280" y="60" width="160" height="70" rx="6"/>
  <text class="head" x="360" y="90" text-anchor="middle">Predict</text>
  <text class="small" x="360" y="110" text-anchor="middle">apply the motion model</text>
  <rect class="box" x="540" y="60" width="160" height="70" rx="6"/>
  <text class="head" x="620" y="90" text-anchor="middle">Correct</text>
  <text class="small" x="620" y="110" text-anchor="middle">× observation likelihood</text>
  <path class="flow" d="M180,95 L278,95" marker-end="url(#arrow)"/>
  <path class="flow" d="M440,95 L538,95" marker-end="url(#arrow)"/>
  <path class="flow dash" d="M620,130 L620,170 L100,170 L100,132" marker-end="url(#arrow)"/>
  <text class="small" x="360" y="164" text-anchor="middle">normalised: belief at t + 1</text>
  <text class="small" x="490" y="40" text-anchor="middle">sight, absence, sonar reports</text>
  <path class="flow" d="M560,46 L600,58" marker-end="url(#arrow)"/>
</svg>
<figcaption>Textbook: the recursive Bayes filter's predict–correct cycle.</figcaption>
</figure>
<h4 id="belief-filters">The remembered map and the filters</h4>
<aside class="oy-card oy-alert" id="c-filters">
<h3>Histogram, Bernoulli and renewal filters</h3>
<p>A <em>histogram filter</em> represents the distribution as a list of discrete states with weights, here (cell, heading) pairs for an enemy's head. It's the natural form on a grid: the prediction step moves each state's weight to its legal successors, and the correction step zeroes the states an observation rules out. The cost grows with the number of states kept, which is why the filter's size is a budget question (below).</p>
<p>A <em>Bernoulli filter</em> tracks a single yes/no quantity, here "is this dragon still alive?", alongside the position filter. A dragon can die out of sight, so its existence is uncertain, and weight that the position filter can't place (an observation shows none of its states) is evidence it may be dead.</p>
<p>A <em>renewal process</em> models events that recur after random waiting times. A pearl tile's next spawn attempt comes a uniformly random number of rounds, between a hidden minimum and maximum gap, after the last one. A <em>hidden Markov model</em> is a chain of hidden states that switch with known probabilities and emit observations. A cell's pearl is present or absent, switched by spawns and by being eaten, and we only see it inside our window.</p>
</aside>
<p>Each hidden quantity is predicted forward by a model of how it changes and corrected by each observation's likelihood, observed absence included, so confidence in anything that moves falls because prediction spreads it, never by a timer. The remembered map is the observation layer: every cell's latest sighting, by the dragon or a teammate, with its round. Over it, every dragon but the dragon itself has a Bernoulli filter for its chance of being alive and a histogram filter over its head's cell and heading (Ristic et al., 2013; Thrun, Burgard and Fox, section 4.1), with lengths exact where a whole body or a status shows them (a status is the report a dragon broadcasts about itself over sonar, below). Each filter also keeps its dragon's body as last seen, head first: the segment i places behind the head stays where it was for length - 1 - i of the dragon's moves, so a sampled state joins the drawn head to that body by a shortest way through free cells and keeps the seen segments still in place, rather than laying the body straight. Dragons 0 and 1 are the queens: a queen's filter is never dropped, and not seeing her moves her without lowering her chance of being alive. Each spawning tile has a renewal process for its next attempt (Feller), and each cell's pearl a two-state hidden Markov model.</p>
<h4 id="belief-sonar">Sonar</h4>
<p>The teacher sees the whole board and needs no sonar, so sonar's content is chosen by how much of the teacher's advantage it recovers for the dragons in play (part 5). Our broadcasts can be decoded by other teams, as we decode theirs, so they are encrypted (the callout below explains how), with a key for each team derived from a secret kept out of source control, so that in self-play neither side reads the other's sonar, as against real opponents. A message carries only what its sender knows, in self-play as in the bot; only its delivery uses the true state. Each ray carries one frame of several variable-length records chosen for the reader it will reach, with check bits that reject the other team's values and noise. A received fact enters the filters as an observation, so its confidence decays by prediction, never by a record's timer. The number of check bits minimises expected loss: the chance a forged frame is accepted times that forgery's cost, plus the bits times the value per bit they would otherwise carry. Relays keep their facts' original rounds, newer facts replace older ones for the same dragon or cell, sight beats report, and a dragon ignores its own reports when they come back. Teammates' intention records (which option a teammate has chosen and where it is heading, part 3) go into the belief as each teammate's latest plan, its confidence decaying by prediction: the crop marks their targets, an option whose target a teammate already intends says so in its candidate bytes, and the search's samples move those teammates toward their targets.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 256" role="img" aria-label="How a received sonar frame is accepted: deciphered and checked, each record checked, map facts that contradict needing confirmation, and accepted facts entering the filters as observations">
  <rect class="box" x="10" y="10" width="150" height="46" rx="6"/>
  <text class="head" x="85" y="30" text-anchor="middle">Frame arrives</text>
  <text class="small" x="85" y="46" text-anchor="middle">64 bits on a ray</text>
  <path class="flow" d="M160,33 L198,33" marker-end="url(#arrow)"/>
  <rect class="layer" x="200" y="10" width="170" height="46" rx="6"/>
  <text class="head" x="285" y="30" text-anchor="middle">Decipher, check bits</text>
  <text class="small" x="285" y="46" text-anchor="middle">with our team key</text>
  <path class="flow" d="M370,33 L408,33" marker-end="url(#arrow)"/>
  <rect class="bad" x="410" y="10" width="140" height="46" rx="6"/>
  <text class="head" x="480" y="30" text-anchor="middle">Fails: discard</text>
  <text class="small" x="480" y="46" text-anchor="middle">enemy value or noise</text>
  <text class="small" x="390" y="26" text-anchor="middle">no</text>
  <path class="flow" d="M285,56 L285,88" marker-end="url(#arrow)"/>
  <text class="small" x="300" y="76" text-anchor="start">passes</text>
  <rect class="layer" x="200" y="90" width="170" height="46" rx="6"/>
  <text class="head" x="285" y="110" text-anchor="middle">Each record</text>
  <text class="small" x="285" y="126" text-anchor="middle">checked against what</text>
  <text class="small" x="285" y="148" text-anchor="middle">the receiver knows (planned)</text>
  <path class="flow" d="M370,113 L408,113" marker-end="url(#arrow)"/>
  <rect class="mixed" x="410" y="90" width="300" height="56" rx="6"/>
  <text class="head" x="560" y="108" text-anchor="middle">Map fact contradicting a partner?</text>
  <text class="small" x="560" y="125" text-anchor="middle">second report needed to rule out a symmetry;</text>
  <text class="small" x="560" y="140" text-anchor="middle">a settled symmetry refuses it</text>
  <path class="flow" d="M285,152 L285,186" marker-end="url(#arrow)"/>
  <rect class="good" x="120" y="188" width="330" height="56" rx="6"/>
  <text class="head" x="285" y="206" text-anchor="middle">Enters the filters as an observation</text>
  <text class="small" x="285" y="223" text-anchor="middle">sight beats report; newer replaces older;</text>
  <text class="small" x="285" y="238" text-anchor="middle">own reports ignored; confidence decays by prediction</text>
  <path class="flow" d="M560,146 L450,200" marker-end="url(#arrow)"/>
</svg>
<figcaption>How part 1 accepts a received frame. The checks against the receiver's own knowledge are designed and not yet built.</figcaption>
</figure>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 150" role="img" aria-label="One 64-bit sonar frame: a two-bit send round, several variable-length records each followed by a continue bit, then zero check bits, all encrypted under the team key">
  <rect class="layer" x="20" y="40" width="50" height="44"/>
  <text class="small" x="45" y="66" text-anchor="middle">round</text>
  <rect class="box" x="70" y="40" width="160" height="44"/>
  <text class="small" x="150" y="66" text-anchor="middle">record (e.g. sighting)</text>
  <rect class="box" x="230" y="40" width="130" height="44"/>
  <text class="small" x="295" y="66" text-anchor="middle">record (e.g. status)</text>
  <rect class="box" x="360" y="40" width="130" height="44"/>
  <text class="small" x="425" y="66" text-anchor="middle">record …</text>
  <rect class="neutral open" x="490" y="40" width="210" height="44"/>
  <text class="small" x="595" y="66" text-anchor="middle">zero check bits (and spare)</text>
  <text class="small" x="360" y="28" text-anchor="middle">64 bits</text>
  <path class="rule" d="M20,110 L700,110"/>
  <text class="small" x="360" y="130" text-anchor="middle">the whole 64 bits are enciphered with the team's key; a value from anyone else deciphers to noise and fails the zero check</text>
</svg>
<figcaption>One sonar frame's layout, as part 1 specifies it and <code>sonar/0001.h</code> packs it. Field widths are illustrative.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-checkbits">
<h3>Encryption and check bits</h3>
<p>The bot enciphers each 64-bit frame with SPECK (Beaulieu et al., 2013), a small block cipher designed for constrained hardware, under a key derived per team. Two things follow. The enemy, receiving our ray, sees noise. And when we receive the enemy's ray and decipher it with our key, we also get noise. To tell our frames from noise, every frame ends in a run of bits that must be zero. Random noise passes k zero bits with probability 2<sup>−k</sup>, so each check bit halves the forgery rate but costs a bit that could carry a fact. That's a decision-theory trade-off, which is why the bit count is set by expected loss rather than by taste.</p>
<p>Inside a frame, numbers such as dragon IDs, ages and lengths are written as exponential-Golomb codes (Golomb, 1966; Teuhola, 1978): a variable-length code in which small numbers take few bits and larger ones more (<code>sonar/0001.h</code>). Most ages and IDs are small, so most records are short, and more fit in a ray.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 330" role="img" aria-label="The belief's components: sight and sonar update the remembered map; over it, filters for each other dragon, each spawning tile, each pearl, the map's symmetry and teammates' intentions; all are encoded as planes">
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
  <text class="small" x="520" y="233" text-anchor="middle">which of 3 symmetries;</text>
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
<h4 id="belief-symmetry">Map symmetry</h4>
<p>Every map is a left–right mirror, a top–bottom mirror or a half turn, and bots aren't told which (<code>planning/rules.md</code>). The belief rules symmetries out by partner edges that differ and partner spawns that can't share a countdown (one spawns and the other doesn't, or an attempt still to come at both sightings differs), from its own sight and teammates' relayed map facts. A teammate's fact rules a symmetry out only once a second report confirms it, because a forged value occasionally passes the check bits; a lone report contradicting a partner only lowers that symmetry's weight, and the next report of the same fact replaces it. Once one symmetry is settled, a told edge or spawn that differs from its settled partner is refused, because a forger doesn't know the map. The design also checks reports against what the receiver already knows: an ID that exists or could, a sighting that agrees with the receiver's own sight that round, and an intention whose target lies on a path from its sender. These checks aren't built yet. The map never changes, so a symmetry ruled out stays out, and each turn only the facts written that turn are checked. It fills each unseen edge, spawn and countdown wherever every symmetry that still fits agrees, marked as inferred. The enemy queen starts at our queen's start mirrored by the true symmetry, so the belief marks those cells for the network, the search's samples and the queen strike (an option that attacks the enemy queen, part 3): one for each symmetry that still fits, at most three because the rules allow three symmetries (<code>planning/rules.md</code>). Current positions are never inferred by symmetry.</p>
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
<figcaption>Textbook: the three symmetries the rules allow. Each seen fact predicts a different partner cell under each, so a mismatch rules a symmetry out.</figcaption>
</figure>
<h4 id="belief-implementation">One implementation, sized by an error bound</h4>
<p>The belief is one integer implementation in the shared library, run identically by the bot and the GPU engine. The <em>GPU engine</em> is our own simulator of the game in CUDA (NVIDIA's language for programming GPUs), which plays thousands of games side by side for training, each game in its own <em>lane</em> of the batch. Each filter's size is set adaptively within the turn's budget by a bound on its approximation error, the KL bound of KLD-sampling (Fox, 2003) or its effective sample size (how many equally weighted states its weights are worth), rather than by fixed caps on states, on the dragons tracked or on a drop threshold; equal-cost comparison confirms the bound's setting, not whether the belief exists.</p>
<aside class="oy-card oy-alert" id="c-kld">
<h3>KL divergence and KLD-sampling</h3>
<p>The Kullback–Leibler divergence (Kullback and Leibler, 1951) KL(p‖q) = Σ p(x) log(p(x)/q(x)) measures how much information is lost when a distribution q stands in for the true p. When a filter keeps only its heaviest states and drops the rest, the divergence between the full and the trimmed distribution has a simple form: if the kept states hold total probability P, the loss is −log P. So "keep the fewest states whose total weight is at least e<sup>−ε</sup>" bounds the error at ε exactly. Fox's KLD-sampling applied the same idea to particle filters: let the number of samples grow when the distribution is spread out and shrink when it is concentrated, instead of fixing a count. A confined enemy needs a handful of states, a long-unseen one many more.</p>
</aside>
<h4 id="belief-checks">How the belief is checked</h4>
<p>The belief is checked against the true state of recorded and self-play games, because parity between implementations (the bot and the GPU engine producing identical bytes) proves agreement, not correctness. Some checks hold whatever the opponents do and are settled once: no impossible state, certainty wherever the rules determine it, and coverage, since a motion model that never gives a legal move zero probability keeps the truth inside the filter's support (the states it gives any probability at all) except where its caps drop it. Others depend on how the opponents move: calibration, so that a stated 30% happens about 30% of the time, and informativeness, the log-probability the belief gives the truth against the remembered map alone. These are measured every training cycle against the current opponents, and again whenever fresh ladder games arrive.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 200" role="img" aria-label="The belief's checks against the true state: three settled once, two measured every training cycle">
  <rect class="layer" x="10" y="10" width="340" height="46" rx="6"/>
  <text class="head" x="180" y="30" text-anchor="middle">Settled once</text>
  <text class="small" x="180" y="46" text-anchor="middle">hold whatever the opponents do</text>
  <rect class="mixed" x="370" y="10" width="340" height="46" rx="6"/>
  <text class="head" x="540" y="30" text-anchor="middle">Every training cycle</text>
  <text class="small" x="540" y="46" text-anchor="middle">and whenever new ladder games arrive</text>
  <rect class="good" x="30" y="70" width="300" height="32" rx="6"/>
  <text class="head" x="180" y="91" text-anchor="middle">no impossible state</text>
  <rect class="good" x="30" y="110" width="300" height="32" rx="6"/>
  <text class="head" x="180" y="131" text-anchor="middle">certainty where the rules determine it</text>
  <rect class="good" x="30" y="150" width="300" height="32" rx="6"/>
  <text class="head" x="180" y="171" text-anchor="middle">coverage: the truth stays in the filter's support</text>
  <rect class="mixed" x="390" y="70" width="300" height="32" rx="6"/>
  <text class="head" x="540" y="91" text-anchor="middle">calibration: stated 30% happens about 30%</text>
  <rect class="mixed" x="390" y="110" width="300" height="32" rx="6"/>
  <text class="head" x="540" y="131" text-anchor="middle">informativeness: log-probability of the truth</text>
  <text class="small" x="540" y="168" text-anchor="middle">both depend on how the opponents move</text>
</svg>
<figcaption>Part 1's checks of the belief against recorded and self-play games.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-calibration">
<h3>Calibration and informativeness</h3>
<p>A probability can't be "right" on a single occasion: an event given 30% either happens or not. What can be checked is <em>calibration</em>: across everything the belief called 30%, about 30% should come true. Grouping predictions into bands and comparing each band's stated and observed rates gives a reliability curve, and the weighted average gap is the <em>expected calibration error</em> (ECE; Guo et al., 2017).</p>
<p>Calibration alone isn't enough, since a belief that says "uniformly anywhere" is perfectly calibrated and useless. <em>Informativeness</em> scores how much probability the belief puts on what actually happened, as the average log-probability of the truth (a proper scoring rule, so it can't be gamed by hedging; Gneiting and Raftery, 2007). Comparing it with the remembered map alone shows what the filters add.</p>
</aside>
<h4 id="belief-planes">The planes the network reads</h4>
<p>The planes and scalars are integers computed by one implementation, shared by the bot and the training engine's encoder, so the network sees the same bytes in training and in play. The network reads only what a dragon can know: its candidates come from the body it tracks, and no privileged value reaches its inputs.</p>
<h3 id="network">2. A small policy/value network that fits the judge</h3>
<p>The judge prices every WebAssembly instruction at a fixed cost, so a network's cost per evaluation is an exact function of its shape, and everything else is sized from it (<a href="#budget">Budget</a>). The network multiplies int8 weights by 7-bit activations with the relaxed-SIMD dot, with its weights compiled into the code as immediates, and the bot reproduces the trained integer network on every turn. These terms are explained under <a href="#network-integer">Integer arithmetic in the judge</a> below; in short, the network runs in exact 8-bit integer arithmetic, sixteen multiplications per instruction. A probe network of 2.8M random int8 weights and about 9.7M multiply-adds costs 4.49M points an evaluation, so a turn would afford about 20 of it if the network were all the turn ran. With the belief and the leaf's encoding, a search simulation costs 5.4M to 5.9M points, and about 5.7 run a turn (part 4). The rest of a turn is measured by map size and belief size (<a href="#budget">Budget</a>): on help.map (64 × 64, the largest map; measurements use seed 7, which fixes its pearls and the bots' random draws, so each one replays the same game) with 128 states a filter, <code>expert-0001</code>'s turn costs 17.4M points, its own network evaluation included. The 4 MB submission holds about 5.7M trained int8 weights.</p>
<aside class="oy-card oy-alert" id="c-policyvalue">
<h3>Policy and value heads</h3>
<p>The network answers two questions at once. Its <em>policy</em> output scores each candidate move: how likely the expert would be to choose it. Its <em>value</em> output estimates how the game will end from here, a number from losing to winning. AlphaZero showed that one network with a shared body and two small "heads" learns both better than two separate networks, because what makes a position good and what makes a move good depend on the same features. The policy tells the search where to look, and the value tells it how good a position is without playing it out.</p>
</aside>
<aside class="oy-card oy-alert" id="c-conv">
<h3>Crops and convolutions</h3>
<p>The network doesn't read the whole map at full detail. It reads a <em>crop</em>: a small window of cells around the dragon's head, turned so "ahead" is always up. Near the head is where precise detail matters, and a fixed-size, head-centred window lets the same weights work on every map size.</p>
<p>A <em>convolution</em> slides a small grid of weights, here 3 × 3, across the crop. At each cell it multiplies the 3 × 3 neighbourhood of every input channel by the matching weights and sums them, producing one number per output channel. The same weights are used at every cell, so a pattern such as "kelp ahead with an enemy head beside it" is recognised wherever it appears, with far fewer weights than a fully connected layer. Each of the 3 × 3 positions is called a <em>tap</em>. The first convolution over the input is the <em>stem</em>, and the stack of identical layers after it the <em>trunk</em>. Stacking layers grows the area each output depends on, its <em>receptive field</em>, by two cells a layer: after the stem and four trunk layers, each output sees an 11 × 11 neighbourhood.</p>
<p>Two other layer types complete the network. A <em>1 × 1 convolution</em> mixes a cell's channels without looking at its neighbours, which is how the squeeze shrinks 32 channels to 16. A <em>dense</em>, or fully connected, layer connects every input to every output, used once the spatial grid has been <em>flattened</em> into one long vector: 15 × 15 cells × 16 channels become 3,600 numbers summarised into 64.</p>
</aside>
<p>The network reads the belief planes of part 1 and the candidates of part 3, and returns a score for each candidate and a value for the position. It is feed-forward: memory lives in the belief, not in a recurrent layer (a layer that carries a hidden state from one turn to the next, as in an RNN or GRU). Its shape is chosen by playing candidates of equal measured cost against each other in the training loop, starting from shapes sized to the budget, and a recurrent candidate is kept only if it wins at equal cost. That comparison hasn't run. The bot's network, about 0.42M weights in a 3 × 3 stem and four 3 × 3 trunk layers of 32 channels, is the kickstart's placeholder shape (the kickstart is the first network, trained by imitating top teams, part 5). Its evaluation costs 4.24M points on help.map seed 7, most of each search simulation's 5.4M to 5.9M, so the network's shape sets how many simulations a turn affords.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 220" role="img" aria-label="A 3 by 3 convolution: a window over the input channels at one cell is multiplied by the kernel's weights and summed into one value per output channel; the window slides to every cell">
  <rect class="frame" x="30" y="40" width="150" height="150"/>
  <rect class="frame" x="40" y="30" width="150" height="150"/>
  <rect class="frame" x="50" y="20" width="150" height="150"/>
  <rect class="layer" x="80" y="70" width="60" height="60"/>
  <path class="rule" d="M100,70 L100,130 M120,70 L120,130 M80,90 L140,90 M80,110 L140,110"/>
  <text class="small" x="125" y="205" text-anchor="middle">input: cells × channels</text>
  <rect class="box" x="270" y="70" width="60" height="60"/>
  <path class="rule" d="M290,70 L290,130 M310,70 L310,130 M270,90 L330,90 M270,110 L330,110"/>
  <text class="small" x="300" y="150" text-anchor="middle">weights (one 3×3 set</text>
  <text class="small" x="300" y="164" text-anchor="middle">per in × out channel)</text>
  <text class="head" x="215" y="104" text-anchor="middle">×</text>
  <text class="head" x="370" y="104" text-anchor="middle">Σ</text>
  <rect class="frame" x="430" y="40" width="150" height="150"/>
  <rect class="frame" x="440" y="30" width="150" height="150"/>
  <rect class="layer" x="490" y="80" width="20" height="20"/>
  <path class="flow" d="M140,100 L268,100" marker-end="url(#arrow)"/>
  <path class="flow" d="M380,100 L488,92" marker-end="url(#arrow)"/>
  <text class="small" x="515" y="205" text-anchor="middle">output: cells × channels</text>
  <text class="small" x="620" y="70">slide the window</text>
  <text class="small" x="620" y="86">to every cell;</text>
  <text class="small" x="620" y="102">same weights</text>
  <text class="small" x="620" y="118">everywhere</text>
</svg>
<figcaption>Textbook: one output of a 3 × 3 convolution over a multi-channel input.</figcaption>
</figure>
<p>Beside the crop, the network reads a 15 × 15 overview of the whole map and a record of 48 bytes for each candidate (<code>features/0002.h</code>). A candidate's record includes the room its action leaves: the cells reachable from its end, at most 32, with the dragon's own segments admitted once they have left, cells another dragon was seen on this round shut, and a first step beside another dragon's head seen this round shut (<code>candidates/0001.h</code>'s <code>RoomAfter</code>).</p>
<p>The figure below assembles those pieces into the whole network, drawn as the shapes of the arrays that flow through it. Read it left to right. The crop enters as a block of 17 × 17 cells, 56 numbers deep, one number per channel. The stem's 3 × 3 convolution turns it into 32 new channels over 15 × 15 cells. These are features the network has learned, such as "open space ahead", not facts we chose. The four trunk layers transform those 32 channels four more times, each output cell seeing a little further. At any one cell, the 32 numbers down the depth of the block are that cell's <em>feature vector</em>.</p>
<p>From there the network splits. The <em>body</em> summarises the whole picture into one global vector of 128 numbers: the trunk squeezed to 16 channels and flattened, the overview, and the scalars. Two <em>heads</em> read the body. The <em>value head</em> turns the global vector into one number, the expected result. The <em>policy head</em> runs once for each candidate: it takes the trunk's feature vector at the cell where that candidate ends, the candidate's own bytes and a context drawn from the global vector, and scores the candidate. A softmax over the scores, exp(score) normalised to sum to 1 across the candidates, turns them into the policy, the probability of each candidate being the best.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 560" role="img" aria-label="The network drawn as arrays: the 17 by 17 by 56 crop passes through a 3 by 3 stem to 15 by 15 by 32, four 3 by 3 trunk layers, a 1 by 1 squeeze to 16 channels and a dense layer to 64; the overview and scalars become 32 each; together a 128-wide global vector; the value head reads it to one number; the policy head, once per candidate, reads the trunk's feature vector at the candidate's end cell, its 48 bytes and a 32-wide context, and gives a score">
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
<p>The network inputs must include the following information already available in the belief. This input redesign remains to be implemented:</p>
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
<p>Training uses floating-point numbers, but floats are slow to multiply in bulk and four bytes each. <em>Quantisation</em> stores each weight as an 8-bit integer, −128 to 127, times a per-layer scale, and each activation as an unsigned 7-bit integer, 0 to 127. A layer then computes an exact integer sum of products, and a final integer rescale, (sum × multiplier + offset) shifted right, brings the result back into the 0–127 range for the next layer, clamped at zero where the layer is rectified. Because everything is integer, the bot's answer is exactly reproducible, which floats across different compilers aren't.</p>
<p>The catch is that rounding changes the network's answers. <em>Quantisation-aware training</em> (Jacob et al., 2018) fixes this by simulating the rounding during training: the forward pass rounds as the bot will, and for the backward pass, where rounding's gradient is zero almost everywhere, the <em>straight-through estimator</em> (Bengio, Léonard and Courville, 2013) treats rounding as the identity. The network learns weights that work after rounding. The trainer does exactly this (<code>tools/learning/trainer/network.h</code>), and its <code>IntegerNetwork</code> computes what the bot will compute.</p>
</aside>
<aside class="oy-card oy-alert" id="c-simd">
<h3>WebAssembly, SIMD and the relaxed dot</h3>
<p>WebAssembly is a portable, sandboxed instruction set; the judge compiles our C, C++ and Nim to it and counts every instruction. <em>SIMD</em> (single instruction, multiple data) instructions work on a 128-bit register as several lanes at once, such as sixteen 8-bit values. The judge charges every SIMD instruction 2 points whatever its lanes, so a vector instruction does up to sixteen times the work of a scalar one for twice the price.</p>
<p>WebAssembly keeps a function's working values in <em>locals</em>, which act like registers: reading one costs a point. Everything else lives in <em>linear memory</em>, one big byte array, and a load from it costs 2 points plus whatever address arithmetic the compiler adds. So a fast kernel keeps its inputs in locals and touches memory as rarely as it can.</p>
<p>The <em>relaxed dot</em>, <code>i32x4.relaxed_dot_i8x16_i7x16_add_s</code>, from WebAssembly's relaxed-SIMD extension, multiplies sixteen int8 weights by sixteen 7-bit activations, adds them in groups of four into four 32-bit sums, and adds those to an accumulator: sixteen multiply-adds in one instruction. "Relaxed" means hardware may differ in edge cases, but with the second operand kept within 0–127 every implementation agrees, which is why activations are 7-bit.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 200" role="img" aria-label="The relaxed dot: sixteen int8 weights times sixteen 7-bit activations, summed in groups of four, added into four 32-bit accumulator lanes, in one 2-point instruction">
  <text class="small" x="20" y="36">weights, int8 ×16</text>
  <text class="small" x="20" y="86">activations, 0..127 ×16</text>
  <g>
    <rect class="box" x="170" y="20" width="30" height="24"/><rect class="box" x="200" y="20" width="30" height="24"/><rect class="box" x="230" y="20" width="30" height="24"/><rect class="box" x="260" y="20" width="30" height="24"/>
    <rect class="box" x="300" y="20" width="30" height="24"/><rect class="box" x="330" y="20" width="30" height="24"/><rect class="box" x="360" y="20" width="30" height="24"/><rect class="box" x="390" y="20" width="30" height="24"/>
    <rect class="box" x="430" y="20" width="30" height="24"/><rect class="box" x="460" y="20" width="30" height="24"/><rect class="box" x="490" y="20" width="30" height="24"/><rect class="box" x="520" y="20" width="30" height="24"/>
    <rect class="box" x="560" y="20" width="30" height="24"/><rect class="box" x="590" y="20" width="30" height="24"/><rect class="box" x="620" y="20" width="30" height="24"/><rect class="box" x="650" y="20" width="30" height="24"/>
    <rect class="layer" x="170" y="70" width="30" height="24"/><rect class="layer" x="200" y="70" width="30" height="24"/><rect class="layer" x="230" y="70" width="30" height="24"/><rect class="layer" x="260" y="70" width="30" height="24"/>
    <rect class="layer" x="300" y="70" width="30" height="24"/><rect class="layer" x="330" y="70" width="30" height="24"/><rect class="layer" x="360" y="70" width="30" height="24"/><rect class="layer" x="390" y="70" width="30" height="24"/>
    <rect class="layer" x="430" y="70" width="30" height="24"/><rect class="layer" x="460" y="70" width="30" height="24"/><rect class="layer" x="490" y="70" width="30" height="24"/><rect class="layer" x="520" y="70" width="30" height="24"/>
    <rect class="layer" x="560" y="70" width="30" height="24"/><rect class="layer" x="590" y="70" width="30" height="24"/><rect class="layer" x="620" y="70" width="30" height="24"/><rect class="layer" x="650" y="70" width="30" height="24"/>
  </g>
  <path class="flow" d="M230,96 L230,128" marker-end="url(#arrow)"/>
  <path class="flow" d="M360,96 L360,128" marker-end="url(#arrow)"/>
  <path class="flow" d="M490,96 L490,128" marker-end="url(#arrow)"/>
  <path class="flow" d="M620,96 L620,128" marker-end="url(#arrow)"/>
  <rect class="good" x="170" y="130" width="120" height="30"/><rect class="good" x="300" y="130" width="120" height="30"/><rect class="good" x="430" y="130" width="120" height="30"/><rect class="good" x="560" y="130" width="120" height="30"/>
  <text class="small" x="230" y="150" text-anchor="middle">acc + Σ4 products</text>
  <text class="small" x="360" y="150" text-anchor="middle">acc + Σ4 products</text>
  <text class="small" x="490" y="150" text-anchor="middle">acc + Σ4 products</text>
  <text class="small" x="620" y="150" text-anchor="middle">acc + Σ4 products</text>
  <text class="small" x="20" y="150">four int32 lanes</text>
  <text class="small" x="425" y="188" text-anchor="middle">16 multiply-adds for 2 points; with the weight as an immediate constant, about 5 points a dot in all</text>
</svg>
<figcaption>Textbook: what one relaxed int8 dot computes.</figcaption>
</figure>
<p>The weights are <em>immediates</em>: constants written into the instruction stream itself, so loading one costs no memory access or address arithmetic (<a href="#budget">Budget</a>). That is why the network is compiled into the bot as code rather than loaded as data.</p>
<h4 id="network-stem">The turn-stable crop and the incremental stem</h4>
<aside class="oy-card oy-alert" id="c-nnue">
<h3>Efficiently updatable networks (NNUE)</h3>
<p>Computer chess engines such as Stockfish evaluate millions of positions a second with a network whose first layer is updated, not recomputed. Moving one piece changes only a few inputs, and a layer's output is a sum over inputs, so subtracting the old inputs' contributions and adding the new ones gives the same result for a fraction of the work. Nasu called this an efficiently updatable neural network, NNUE.</p>
<p>The same idea works here if the inputs mostly don't change between one evaluation and the next. A crop that stores "seen 3 rounds ago" changes every round; one that stores "seen in round 412" doesn't. So the crop's stable channels count time from a fixed epoch, and the per-cell sums of the first layer are cached and reused until a byte in their window changes.</p>
</aside>
<p>The crop is turn-stable, so the first layer's work carries across the search's leaves (the positions a search evaluates, part 4) and the dragon's turns, as an efficiently updatable network's first layer does in computer chess (Nasu, 2018). It is a window of 17 × 17 real cells around the head in the dragon's frame, so the 3 × 3 stem's 15 × 15 outputs see true neighbours instead of a zero border. Its 56 channels are listed in <code>bots/expert/lib/games/loong/features/0002.h</code> and written by <code>crop/0002.h</code>. Channels 0–47 depend only on the cell's place on the map, what the view shows and the facing. Times in them are counted from an epoch base, a multiple of 64 between 64 and 127 rounds back, so a cell outside the view keeps its bytes while its memory stands. Channel 48 is the round past that base, the same in every cell, from which the network derives each age. Channels 49–55 are read at the stem's centre tap only, and training holds their other taps' weights at zero. These are the filters' head chances and lengths and the pearl chance, which spread every round, and the steps from the head and the enemies' reach, which move with it.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 196" role="img" aria-label="The crop's 56 channels in groups: map memory, edges, dragons, marks, inferred and told facts, the epoch round, and the centre-tap channels">
  <rect class="box" x="36" y="86" width="11.5" height="34"/>
  <rect class="box" x="47.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="59" y="86" width="11.5" height="34"/>
  <rect class="box" x="70.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="82" y="86" width="11.5" height="34"/>
  <text class="head" x="64.75" y="18" text-anchor="middle">map memory</text>
  <text class="small" x="64.75" y="32" text-anchor="middle">seen, age, pearl, spawn</text>
  <path class="rule" d="M64.75,36 L64.75,84"/>
  <rect class="layer" x="93.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="105" y="86" width="11.5" height="34"/>
  <rect class="layer" x="116.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="128" y="86" width="11.5" height="34"/>
  <rect class="layer" x="139.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="151" y="86" width="11.5" height="34"/>
  <rect class="layer" x="162.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="174" y="86" width="11.5" height="34"/>
  <text class="head" x="139.5" y="50" text-anchor="middle">edges</text>
  <text class="small" x="139.5" y="64" text-anchor="middle">kelp, portals</text>
  <path class="rule" d="M139.5,68 L139.5,84"/>
  <rect class="box" x="185.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="197" y="86" width="11.5" height="34"/>
  <rect class="box" x="208.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="220" y="86" width="11.5" height="34"/>
  <rect class="box" x="231.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="243" y="86" width="11.5" height="34"/>
  <rect class="box" x="254.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="266" y="86" width="11.5" height="34"/>
  <rect class="box" x="277.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="289" y="86" width="11.5" height="34"/>
  <rect class="box" x="300.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="312" y="86" width="11.5" height="34"/>
  <rect class="box" x="323.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="335" y="86" width="11.5" height="34"/>
  <text class="head" x="266" y="18" text-anchor="middle">dragons here</text>
  <text class="small" x="266" y="32" text-anchor="middle">kind, age, facing, order</text>
  <path class="rule" d="M266,36 L266,84"/>
  <rect class="layer" x="346.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="358" y="86" width="11.5" height="34"/>
  <rect class="layer" x="369.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="381" y="86" width="11.5" height="34"/>
  <rect class="layer" x="392.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="404" y="86" width="11.5" height="34"/>
  <rect class="layer" x="415.5" y="86" width="11.5" height="34"/>
  <rect class="layer" x="427" y="86" width="11.5" height="34"/>
  <text class="head" x="392.5" y="50" text-anchor="middle">marks</text>
  <text class="small" x="392.5" y="64" text-anchor="middle">claims, corpses, queens</text>
  <path class="rule" d="M392.5,68 L392.5,84"/>
  <rect class="box" x="438.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="450" y="86" width="11.5" height="34"/>
  <rect class="box" x="461.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="473" y="86" width="11.5" height="34"/>
  <rect class="box" x="484.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="496" y="86" width="11.5" height="34"/>
  <rect class="box" x="507.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="519" y="86" width="11.5" height="34"/>
  <rect class="box" x="530.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="542" y="86" width="11.5" height="34"/>
  <rect class="box" x="553.5" y="86" width="11.5" height="34"/>
  <rect class="box" x="565" y="86" width="11.5" height="34"/>
  <rect class="box" x="576.5" y="86" width="11.5" height="34"/>
  <text class="head" x="513.25" y="18" text-anchor="middle">inferred, told</text>
  <text class="small" x="513.25" y="32" text-anchor="middle">kelp chance, landings</text>
  <path class="rule" d="M513.25,36 L513.25,84"/>
  <rect class="mixed" x="588" y="86" width="11.5" height="34"/>
  <rect class="good" x="599.5" y="86" width="11.5" height="34"/>
  <rect class="good" x="611" y="86" width="11.5" height="34"/>
  <rect class="good" x="622.5" y="86" width="11.5" height="34"/>
  <rect class="good" x="634" y="86" width="11.5" height="34"/>
  <rect class="good" x="645.5" y="86" width="11.5" height="34"/>
  <rect class="good" x="657" y="86" width="11.5" height="34"/>
  <rect class="good" x="668.5" y="86" width="11.5" height="34"/>
  <text class="head" x="639.75" y="18" text-anchor="middle">centre tap</text>
  <text class="small" x="639.75" y="32" text-anchor="middle">chances, distances</text>
  <path class="rule" d="M639.75,36 L639.75,84"/>
  <text class="small" x="41.75" y="136" text-anchor="middle">0</text>
  <text class="small" x="191.25" y="136" text-anchor="middle">13</text>
  <text class="small" x="352.25" y="136" text-anchor="middle">27</text>
  <text class="small" x="444.25" y="136" text-anchor="middle">35</text>
  <text class="small" x="593.75" y="136" text-anchor="middle">48</text>
  <text class="small" x="674.25" y="136" text-anchor="middle">55</text>
  <text class="small" x="593.75" y="152" text-anchor="middle">48: round past the epoch base</text>
  <path class="rule" d="M36,164 L588,164"/>
  <text class="small" x="312" y="180" text-anchor="middle">0–47 stable: the map cell, the view and the facing only, so their stem sums are cached</text>
  <path class="rule" d="M599.5,164 L680,164"/>
  <text class="small" x="639.75" y="180" text-anchor="middle">centre tap only</text>
</svg>
<figcaption>The crop's channels as <code>features/0002.h</code> lists them, one square each. </figcaption>
</figure>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 250" role="img" aria-label="The stem: channels 0 to 47 give cached sums per frame and map cell, recomputed only where a window byte changed; channel 48's sum over the taps and channels 49 to 55 at the centre tap are added; the total is requantised into the trunk's input">
  <rect class="box" x="10" y="95" width="120" height="64" rx="6"/>
  <text class="head" x="70" y="121" text-anchor="middle">Crop window</text>
  <text class="small" x="70" y="141" text-anchor="middle">17 × 17, 56 channels</text>
  <rect class="layer" x="180" y="10" width="220" height="70" rx="6"/>
  <text class="head" x="290" y="36" text-anchor="middle">Channels 0–47, 3 × 3</text>
  <text class="small" x="290" y="56" text-anchor="middle">int32 sums kept per frame and map cell,</text>
  <text class="small" x="290" y="71" text-anchor="middle">recomputed where a window byte changed</text>
  <rect class="layer" x="180" y="95" width="220" height="64" rx="6"/>
  <text class="head" x="290" y="121" text-anchor="middle">Channel 48</text>
  <text class="small" x="290" y="141" text-anchor="middle">its value × its weights' sum over the taps</text>
  <rect class="layer" x="180" y="174" width="220" height="64" rx="6"/>
  <text class="head" x="290" y="200" text-anchor="middle">Channels 49–55</text>
  <text class="small" x="290" y="220" text-anchor="middle">centre tap only, every evaluation</text>
  <rect class="box" x="450" y="95" width="120" height="64" rx="6"/>
  <text class="head" x="510" y="121" text-anchor="middle">Sum, requantise</text>
  <text class="small" x="510" y="141" text-anchor="middle">exact integers</text>
  <rect class="box" x="610" y="95" width="100" height="64" rx="6"/>
  <text class="head" x="660" y="121" text-anchor="middle">Trunk</text>
  <text class="small" x="660" y="141" text-anchor="middle">15 × 15 × 32</text>
  <path class="flow" d="M130,115 L178,50" marker-end="url(#arrow)"/>
  <path class="flow" d="M130,127 L178,127" marker-end="url(#arrow)"/>
  <path class="flow" d="M130,139 L178,204" marker-end="url(#arrow)"/>
  <path class="flow" d="M400,50 L448,115" marker-end="url(#arrow)"/>
  <path class="flow" d="M400,127 L448,127" marker-end="url(#arrow)"/>
  <path class="flow" d="M400,204 L448,139" marker-end="url(#arrow)"/>
  <path class="flow" d="M570,127 L608,127" marker-end="url(#arrow)"/>
</svg>
<figcaption>The stem as <code>techniques/neural/embedded/0002.nim</code>'s incremental form and <code>network/0002.nim</code> compute it.</figcaption>
</figure>
<p>A stem output's sum over channels 0–47 is then a function of its map cell, the facing and the epoch. The bot keeps those int32 sums per frame (facing, epoch parity, and whether the dragon is newborn, as the search's fresh encodings of other dragons are) and per map cell. A sum is reused while none of its window's cached bytes has changed since it was computed, which a stamp on each map cell tells. Integer sums don't depend on their order, so the outputs equal the full stem's bit for bit (<code>bots/expert/checks/stem</code>). On a map narrower than the window, which shows a cell twice, the full stem runs. On help.map, seed 7, the stem costs 666K points an evaluation against the full stem's 1.109M, and a trunk layer 666K. Register-blocking sibling leaves through the network's kernels, the generated functions that compute each layer (evaluating several leaves together so each weight, once loaded, serves all of them), saves 0.2% a leaf in the judge, because every relaxed dot reads its weight from a local whichever leaf it serves (<code>results/local/sibling-batching-20261006</code>). Batching leaves therefore saves points only where it removes work, and weight reads aren't such work.</p>
<h3 id="options">3. Options as the action space</h3>
<h4 id="qfoil-slots">Reserved qfoil plan slots — placeholders</h4>
<p><code>expert/0001x-slots</code> copies <code>0001v-round5</code> and its network, pinning <code>candidates/0004.h</code>, <code>features/0005.h</code>, <code>sonar/0003.h</code> and <code>belief/0003.h</code>. These reserve the formats for qfoil's later plan pieces. Candidate generators, plan selection, sonar senders and persistent plan filters remain placeholders. The existing turn and bot pieces are unchanged.</p>
<div class="oy-table-properties"><table>
<caption>Reserved slots in the unchanged 48-byte candidate vector; every new byte is zero while unused.</caption>
<thead><tr><th>Slot</th><th>Default and meaning</th><th>Bytes (zero-based)</th></tr></thead>
<tbody>
<tr><td><code>hideoutTarget</code></td><td>−1 for none; queen hideout or retreat world cell, encoded as cell + 1 in two base-128 digits, low digit first.</td><td>32–33</td></tr>
<tr><td><code>ward</code></td><td>−1 for none; guarded dragon ID (0–65535), encoded as ID + 1 in three base-128 digits, low digit first.</td><td>34–36</td></tr>
<tr><td><code>planPhase</code></td><td>0 none, 1 opening, 2 midgame, 3 consolidation.</td><td>37</td></tr>
<tr><td>Options 11 / 12 / 13</td><td>Hideout / ward / plan; one-hot 127 when selected. No generators yet.</td><td>43 / 44 / 45</td></tr>
<tr><td>Still spare</td><td>Zero.</td><td>38, 46–47</td></tr>
</tbody></table></div>
<p>The sonar placeholder uses the previously reserved prefix <code>11111</code>: guarding dragon ID (order-6 exp-Golomb), ward ID + 1 (order-6 exp-Golomb, zero for none), phase (two bits), and expiry after the send round (order-0 exp-Golomb, at most 64). Records must fit the existing frame capacity; old readers refuse this new kind. Existing records, frame layout and team keys keep their meaning. <code>belief/0003.h::HearMessage</code> decodes it into a separate team-plan word, tag <code>0x11</code>, readable by <code>ReadTeamPlan</code>; no action consumes it. Both new pieces derive from 0001v's pinned versions, without the unrelated sonar 0002 round keys or belief 0002 scalar changes. The candidate training row appends hideout target, ward and phase after the existing fields.</p>
<p>The network binary is byte-identical to 0001v's; its layout sidecar names the new compatible pieces and the extended 23-field training row. Registered build <code>eb1fac38-f13b-5cd9-a42e-0d8618bf6420</code> completed four sandbox games against foil 0039: held-out maps <code>pool_00000</code> (seed 4003323317) and <code>pool_00005</code> (seed 3164992018), in both seats, paired with 0001v build <code>8c4c8c25-0e83-579e-9033-6e1d04ad3965</code>. Every unpacked replay word matched after removing the team-name strings and their pointers; those names explain the raw file differences. Replays are retained under <code>assets/games/tmp--r2--crew-slots--games</code>. Native checks also matched 10,000 candidate vectors and 640 existing sonar-frame cases against the frozen encoders, and passed 156 new wire-to-belief frame round trips. These checks establish format compatibility and unchanged play on these games; the qfoil behavior remains a placeholder.</p>
<h4 id="round5-options">Round 5's candidate additions</h4>
<p><code>expert/0001v-round5</code> pins <code>candidates/0003.h</code>, derived from <code>0001u-queen-search</code>'s <code>candidates/0001.h</code>. The queen retains search and her safety rule; other dragons retain the network's choice. The new options are offered to that same network and search.</p>
<div class="oy-table-properties"><table>
<caption>Implemented generators in candidates/0003.h; all routes use the remembered map's shortest-path first move.</caption>
<thead><tr><th>Option</th><th>Eligibility and target</th><th>Candidate byte</th></tr></thead>
<tbody>
<tr><td>7: Champion walk</td><td>The longest other teammate in the dragon's filters, alive with probability at least one half and with a head state. Equal lengths keep filter order. Approach its modal head by targeting the reachable neighbouring cell with the shortest route, breaking ties by cell index.</td><td>22</td></tr>
<tr><td>8: Champion feed</td><td>The same champion, passed to <code>QueenCandidates</code> with <code>ahead=2</code>, exactly as queen feed does: walk to the highest-weight reachable cell two steps ahead of its expected head, where a later death leaves pearls in its path. Neither champion option may end its action or target a possible champion head. No new deliberate death is added; <code>FeedingDeathCandidates</code> keeps that responsibility.</td><td>23</td></tr>
<tr><td>9: Queen retreat</td><td>Only our queen, identified by her dragon ID. In addition to ordinary escape, offer up to two first moves toward cells with at least two unblocked, unoccupied exits. Maximise the sum of wrapped grid distances from enemy modal heads fixed this round or last, each weighted by its probability of being alive. Ties prefer shorter routes then lower cell indices. No nearby-threat threshold applies; without recent filters, choose nearest open ground.</td><td>40</td></tr>
<tr><td>10: Queen escort</td><td>A non-queen within eight wrapped grid steps of our queen's modal head, with her alive probability at least one half. Find the nearest recent enemy modal head with at least one-half alive probability. Target a reachable adjacent cell on the queen's enemy-facing side, minimising its distance to that enemy.</td><td>41</td></tr>
</tbody></table></div>
<p>These are candidates-only option codes. <code>turn/0004.h::IntentOf</code> suppresses codes above <code>SONAR_OPTIONS = 6</code>, preserving the sonar wire format and its existing readers. The filters omit self. Candidate capacity grows by five: two champion actions, one escort and two queen retreats.</p>
<p><code>SurvivalDepth</code> records a witnessed continuation of up to eight further single steps after each move or sprint. Its depth-first search rejects blocked edges, current occupied cells and the simulated own body before the tail moves, and accounts for remembered pearls growing that body once per path. Each primitive examines at most 32 edges; option copies reuse the primitive's result. Fatal actions, splits and unknown endpoints have depth zero. <code>features/0004.h</code> writes depth times 16, saturated at 127, to spare byte 42 of the unchanged 48-byte candidate input. <code>bot/0005.cc</code> also exposes it in decision diagnostics.</p>
<p>On the judge, survival work shares a 4M-point cutoff across the real turn's root and search leaves, checked before each explored edge. The remaining margin under 5M covers the final edge and bookkeeping. Once exhausted, subsequent candidates receive zero depth. The diagnostics report its measured spend separately.</p>
<p>The registered round 5 bot completed its four sandbox smoke games against foil 0039, 2 wins and 2 losses, with zero failed expert turns across 97,241 turns and a peak of 93.3M points, below the 100M judge limit. Native hand-derived checks cover tail vacating, pearl growth closing a loop, occupied exits, fatal actions, queen-only retreat without a nearby threat, and champion feed matching queen feed without a head-on endpoint. Evidence is retained in <code>results/local/round-robin/crew-round5-smoke-20261007</code>. No full evaluation was run.</p>
<aside class="oy-card oy-alert oy-alert-error"><h4>Round 5 conformance placeholders</h4><p>The bounded survival search returns a lower bound when its edge or turn-point budget expires; exact exhaustive survival depth is a placeholder. Native and CUDA training use the same 32-edge cap per primitive without the judge's turn-point cutoff. Retreat and escort use modal filter heads and wrapped grid distance for target ranking; shortest-path routing still respects remembered walls and portals. Ablations and decision review establishing these generators' playing value remain placeholders. The four-game smoke check establishes execution and point limits only.</p></aside>
<p>Behaviour modules such as harvest, escape, door clearance and the queen strike generate candidate targets and joint plays. The network scores those candidates instead of raw moves. In the options framework (Sutton, Precup and Singh, 1999), a chosen option is executed by a route controller, and it ends when its termination condition holds.</p>
<aside class="oy-card oy-alert" id="c-options">
<h3>The options framework</h3>
<p>Anything a dragon can reach within one turn is already a single decision: a sprint covers many cells in one action, and the candidates list a sprint to each reachable cell (part 5's primitive actions). Plans longer than one turn are what is hard. Reaching a spawning tile beyond this turn's reach, just as its next attempt is due, takes a decision on each of several turns, any of which can go astray, and a search a few turns deep never sees the payoff. An <em>option</em> is a temporally extended action: a policy for getting something done ("go harvest the spawn at (31, 7)"), a rule for when it may start, and a termination condition. Sutton, Precup and Singh showed that a decision process over options is still a well-defined (semi-Markov) decision process, so the same learning and search methods apply, just over bigger steps.</p>
<p>Here, hand-written <em>generators</em> propose concrete options each turn, and the network learns which to pick. The generators supply reach, a plan many cells long, while the choice between them, and so the team's roles and timing, is learned. Raw primitive moves stay among the candidates, so a behaviour no generator anticipated can still emerge.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 220" role="img" aria-label="Generators such as harvest, escape, queen strike and feed propose candidates alongside the primitive moves; the network scores them all; the chosen option's route controller emits this turn's action until the option terminates">
  <rect class="box" x="10" y="20" width="130" height="34" rx="6"/><text class="small" x="75" y="42" text-anchor="middle">harvest</text>
  <rect class="box" x="10" y="62" width="130" height="34" rx="6"/><text class="small" x="75" y="84" text-anchor="middle">escape</text>
  <rect class="box" x="10" y="104" width="130" height="34" rx="6"/><text class="small" x="75" y="126" text-anchor="middle">queen strike, feed, …</text>
  <rect class="neutral" x="10" y="160" width="130" height="34" rx="6"/><text class="small" x="75" y="182" text-anchor="middle">primitive moves</text>
  <rect class="layer" x="200" y="70" width="140" height="70" rx="6"/>
  <text class="head" x="270" y="98" text-anchor="middle">Candidate list</text>
  <text class="small" x="270" y="118" text-anchor="middle">48 bytes each</text>
  <rect class="layer" x="390" y="70" width="140" height="70" rx="6"/>
  <text class="head" x="460" y="98" text-anchor="middle">Network + search</text>
  <text class="small" x="460" y="118" text-anchor="middle">score and choose</text>
  <rect class="box" x="580" y="70" width="130" height="70" rx="6"/>
  <text class="head" x="645" y="98" text-anchor="middle">Route controller</text>
  <text class="small" x="645" y="118" text-anchor="middle">this turn's action</text>
  <path class="flow" d="M140,37 L198,90" marker-end="url(#arrow)"/>
  <path class="flow" d="M140,79 L198,100" marker-end="url(#arrow)"/>
  <path class="flow" d="M140,121 L198,112" marker-end="url(#arrow)"/>
  <path class="flow" d="M140,177 L198,128" marker-end="url(#arrow)"/>
  <path class="flow" d="M340,105 L388,105" marker-end="url(#arrow)"/>
  <path class="flow" d="M530,105 L578,105" marker-end="url(#arrow)"/>
  <path class="flow dash" d="M645,140 L645,188 L460,188 L460,142" marker-end="url(#arrow)"/>
  <text class="small" x="552" y="208" text-anchor="middle">until it terminates, or a better option wins</text>
</svg>
<figcaption>Intended design: how options turn into actions.</figcaption>
</figure>
<p>Joint plays follow STP's plays (Browning et al., 2005): a few explicit cooperative tactics, such as guarding the queen or clearing its exit, coordinated over sonar. A dragon tells teammates its option in an intention record (option code, target and expiry), and a joint play is a one-record offer that the recipient accepts by acting on it, which its next status shows. There is no waiting action, so holding loops are candidates, and fatal actions stay candidates.</p>
<aside class="oy-card oy-alert" id="c-stp">
<h3>Skills, tactics and plays (STP)</h3>
<p>STP came from robot soccer, where several robots must cooperate in real time with little communication. Its layers are <em>skills</em> (low-level abilities like driving to a point), <em>tactics</em> (one robot's role in a situation, like "defend the goal") and <em>plays</em> (a short team script assigning tactics, like "one blocks while the other shoots"). A play is chosen only when its preconditions hold and ends when they fail. Here a joint play is the same idea in miniature: one dragon offers a role, the other accepts by acting.</p>
</aside>
<p>The behaviour catalogue is the pool generators are drawn from, not a list to build in full. The review carried over the behaviours and dropped the earlier planner's machinery around them: its task networks, commitment protocol and fixed roles. Generators are added in measured order, each costing candidates and points. The first are harvest timed to spawns with holding loops, escape, the queen strike, feed and recombination (its timing learned, not set by hand), the rearguard, and the child map upload with the split that puts the child behind its parent (roadmap item 10). Any other behaviour joins only when the value-lost report shows candidate gaps it would cover, and stays only if its ablation shows it earns its cost (below). Which generator to use, and when, is the network's choice.</p>
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
<div class="oy-table-properties"><table>
<caption>The 27 behaviours: each one's targets and how it executes (from the 4 October agreement)</caption>
<thead><tr><th>Behaviour</th><th>Targets and execution</th></tr></thead>
<tbody>
<tr><td>harvest</td><td>dated pearl cells; travel to the chosen cell</td></tr>
<tr><td>scavenge</td><td>corpse pearls a death left; collect them before they're taken</td></tr>
<tr><td>farm</td><td>known spawning patches; circulate clear of the spawning cells, collect, repeat</td></tr>
<tr><td>coil</td><td>known traversable cycles; follow one, expanding or leaving when growth makes it unsuitable; the anaconda ring is a coil</td></tr>
<tr><td>relocate</td><td>another productive region; travel there, then harvest or farm</td></tr>
<tr><td>race</td><td>a contested pearl; movement and sprint variants, with their paid segments counted</td></tr>
<tr><td>contest</td><td>a competing enemy's resources; approach or occupy its routes</td></tr>
<tr><td>expand</td><td>a legal split; value both resulting dragons and their next work</td></tr>
<tr><td>recruit</td><td>an unfilled task; split a child and give it the task</td></tr>
<tr><td>feed</td><td>a beneficiary; approach and deposit, often by a feeding death</td></tr>
<tr><td>relay</td><td>a recipient and useful records; get into line and send them</td></tr>
<tr><td>escape</td><td>reachable exits from a threat; complete movement and sprint routes</td></tr>
<tr><td>rescue</td><td>a trapped parent; a legal split, valuing parent and child separately</td></tr>
<tr><td>vanguard</td><td>a protected dragon and a threat; guard or intercept</td></tr>
<tr><td>rearguard</td><td>a protected dragon's tail; follow, keep launch space, report</td></tr>
<tr><td>door</td><td>an entrance; keep a moving blocking route until released</td></tr>
<tr><td>intercept</td><td>a threat's path; approach, obstruct or trade</td></tr>
<tr><td>assassin</td><td>the enemy queen's likely whereabouts; locate and hand over to a strike</td></tr>
<tr><td>strike</td><td>an enemy dragon; approach and head trade; a disappearance never proves a kill</td></tr>
<tr><td>tail strike</td><td>an enemy reachable from a child's start; set up and split; the tail lurker is one</td></tr>
<tr><td>blocker</td><td>an enemy's exits; place the body to restrict them</td></tr>
<tr><td>portal block</td><td>a portal landing; cover it when the enemy would arrive</td></tr>
<tr><td>jam</td><td>a narrow passage; occupy it while keeping a way out</td></tr>
<tr><td>standoff</td><td>an enemy and a possible child; split and trade combinations</td></tr>
<tr><td>scout</td><td>an observation centre; travel to reveal what is most uncertain</td></tr>
<tr><td>survey</td><td>an unfinished map lane; sweep it</td></tr>
<tr><td>probe portal</td><td>an unresolved portal; cross it and see where it leads</td></tr>
</tbody></table></div>
<p>The five joint plays are short sequences between two dragons: guarded escape (the queen holds, a worker clears the threat, the queen sees a usable exit and leaves), door clearance (the blocker releases, the beneficiary sees the gap and passes), feed transfer (a donor deposits, the beneficiary collects), vanguard handover (a replacement arrives, then the incumbent leaves) and survey recruitment (a parent splits, the child takes a lane and surveys). There is no standing still, so every holding step is a moving loop, and an offer that isn't accepted leaves both dragons free to do something else.</p>
<p>Generators are added, rewritten and removed by measurement, never tuned blind (part 5): a generator is added when candidate-gap losses cluster on a situation none covers, rewritten when its candidates are chosen but the teacher keeps preferring another variant of the same behaviour (another target or route), and removed when it is rarely chosen or its ablation (the bot with the generator removed, measured against the bot with it) shows no gain at equal cost. When ranking gaps dominate, the network is trained and the generators left alone.</p>
<h3 id="search">4. Online search within each dragon's budget</h3>
<p>Use determinised Monte Carlo tree search, in the form of information-set MCTS (Cowling, Powley and Whitehouse, 2012). Hidden enemies are sampled from the belief, and the network supplies priors and leaf values (Silver et al., 2017).</p>
<aside class="oy-card oy-alert" id="c-mcts">
<h3>Monte Carlo tree search</h3>
<p>MCTS (Coulom, 2006; Kocsis and Szepesvári, 2006, whose UCT rule applies the UCB1 bandit formula of Auer, Cesa-Bianchi and Fischer, 2002) builds a game tree selectively, one simulation at a time. Each simulation has four steps. <em>Select</em>: walk down from the root, at each node picking the child that best balances a good average result so far against being little explored. <em>Expand</em>: add a new child where the walk leaves the tree. <em>Evaluate</em>: estimate the new position's value, here with the network's value head instead of a random playout. <em>Back up</em>: add that value to the statistics of every node on the path. After many simulations, the most-visited root move is the choice. Promising lines get most of the effort, so the tree grows deep where it matters.</p>
<p>AlphaZero's version uses <em>PUCT</em> (after Rosin, 2011) for selection, drawn below: a child's score is its average value plus a bonus proportional to the network's prior for it and shrinking with its visit count, so the network tells the search where to look first. A node's running average value is written <em>Q</em>, and the network's probability for a move its <em>prior</em>.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 210" role="img" aria-label="MCTS's four steps: select down the tree, expand a new node, evaluate it with the value network, back the value up the path">
  <g>
  <circle class="layer" cx="90" cy="40" r="12"/><circle class="layer" cx="60" cy="100" r="12"/><circle class="layer" cx="120" cy="100" r="12"/><circle class="layer" cx="100" cy="160" r="12"/>
  <path class="rule" d="M90,52 L62,88 M90,52 L118,88 M120,112 L102,148"/>
  <path class="flow" d="M100,45 L125,85" marker-end="url(#arrow)"/>
  <text class="head" x="90" y="200" text-anchor="middle">Select</text>
  </g>
  <g>
  <circle class="layer" cx="270" cy="40" r="12"/><circle class="layer" cx="240" cy="100" r="12"/><circle class="layer" cx="300" cy="100" r="12"/><circle class="layer" cx="280" cy="160" r="12"/><circle class="box open" cx="320" cy="160" r="12"/>
  <path class="rule" d="M270,52 L242,88 M270,52 L298,88 M300,112 L282,148 M300,112 L318,148"/>
  <text class="head" x="270" y="200" text-anchor="middle">Expand</text>
  </g>
  <g>
  <circle class="box" cx="450" cy="100" r="14"/>
  <rect class="good" x="410" y="140" width="80" height="30" rx="6"/>
  <text class="small" x="450" y="160" text-anchor="middle">value net</text>
  <path class="flow" d="M450,138 L450,116" marker-end="url(#arrow)"/>
  <text class="head" x="450" y="200" text-anchor="middle">Evaluate</text>
  </g>
  <g>
  <circle class="layer" cx="630" cy="40" r="12"/><circle class="layer" cx="660" cy="100" r="12"/><circle class="box" cx="680" cy="160" r="12"/>
  <path class="flow" d="M676,148 L664,114" marker-end="url(#arrow)"/>
  <path class="flow" d="M656,88 L636,54" marker-end="url(#arrow)"/>
  <text class="head" x="630" y="200" text-anchor="middle">Back up</text>
  </g>
</svg>
<figcaption>Textbook: one MCTS simulation.</figcaption>
</figure>
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
<figcaption>Textbook PUCT, with the constants <code>tree/0002.h</code>'s <code>SelectEdge</code> uses: the bonus pulls the search toward moves the network rates highly but the search hasn't checked.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-ismcts">
<h3>Determinisation and information-set MCTS</h3>
<p>MCTS needs a concrete game to simulate, but a dragon doesn't know where the hidden enemies are. <em>Determinisation</em> samples a complete hidden state from the belief, a plausible guess for every unseen dragon, and simulates in that. Done naively, a separate tree per sample lets the search act on things it can't know ("the enemy is behind that wall in this sample, so turn left"), a flaw called strategy fusion (Frank and Basin, 1998). Long and colleagues (2010) studied when such perfect-information sampling still works well.</p>
<p><em>Information-set MCTS</em> fixes it by keying nodes by what the searching dragon has observed rather than by the sampled state. Every simulation draws a fresh sample, but all samples that look the same from the dragon's point of view share one node and so get one decision. The statistics then average over the hidden possibilities in proportion to how likely the belief says they are.</p>
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
<p>The leaf values come from the value head distilled in part 5, read only once it passes part 5's checks. <code>expert-0001</code>'s search still reads its imitation-trained network's head, which fails them. The root simulates its likeliest candidates and narrows them by sequential halving, which improves the policy even at the few evaluations a turn affords (Danihelka et al., 2022). At play, and in every evaluation of a bot, a teacher or a network, its Gumbel draws are zero, so the move is the candidate sequential halving leaves by prior and value, deterministically, as Gumbel MuZero evaluates; the draws, which sample candidates for exploration, belong only to the teacher's self-play data collection (part 5).</p>
<aside class="oy-card oy-alert" id="c-gumbel">
<h3>Gumbel root search and sequential halving</h3>
<p>With hundreds of simulations, PUCT's most-visited move is reliably good. With five or ten, it often isn't: the search may never visit a strong move twice. Danihelka and colleagues' Gumbel search, used in Gumbel MuZero (MuZero being DeepMind's successor to AlphaZero; Schrittwieser et al., 2020), is designed for small budgets. At the root it takes the top few candidates by prior, then runs <em>sequential halving</em> (Karnin, Koren and Somekh, 2013): split the simulations across them, drop the worse half by prior plus estimated value, repeat until one remains. Two constants, c_visit and c_scale, set how strongly the estimated values outweigh the priors in that ranking. They proved that, given accurate value estimates, this choice improves on the network's own preference in expectation, a guarantee PUCT lacks at small counts.</p>
<p>AlphaZero explored by mixing random Dirichlet noise into the root's priors, which needs many simulations to pay off. For training-data collection here, random <em>Gumbel noise</em> is added to the priors before choosing which candidates to consider. Adding Gumbel noise to log-probabilities and taking the top k is exactly sampling k moves without replacement, the Gumbel-top-k trick (Kool, van Hoof and Welling, 2019), which gives exploration. In play, the noise is set to zero so the bot always plays its best estimate; measured, this was worth about +127 Elo against the same bot with noise.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 190" role="img" aria-label="Sequential halving: eight candidates share simulations, the better half by prior plus value survive each round, until one remains">
  <text class="small" x="20" y="40">round 1</text>
  <rect class="box" x="100" y="25" width="60" height="26"/><rect class="box" x="170" y="25" width="60" height="26"/><rect class="box" x="240" y="25" width="60" height="26"/><rect class="box" x="310" y="25" width="60" height="26"/>
  <rect class="neutral open" x="380" y="25" width="60" height="26"/><rect class="neutral open" x="450" y="25" width="60" height="26"/><rect class="neutral open" x="520" y="25" width="60" height="26"/><rect class="neutral open" x="590" y="25" width="60" height="26"/>
  <text class="small" x="20" y="90">round 2</text>
  <rect class="box" x="100" y="75" width="60" height="26"/><rect class="box" x="170" y="75" width="60" height="26"/>
  <rect class="neutral open" x="240" y="75" width="60" height="26"/><rect class="neutral open" x="310" y="75" width="60" height="26"/>
  <text class="small" x="20" y="140">round 3</text>
  <rect class="good" x="100" y="125" width="60" height="26"/><rect class="neutral open" x="170" y="125" width="60" height="26"/>
  <text class="small" x="420" y="92">dashed: dropped after the round</text>
  <text class="small" x="420" y="140">each round: share simulations, keep the better half</text>
  <text class="small" x="420" y="158">by prior + estimated value</text>
</svg>
<figcaption>Textbook: sequential halving over eight root candidates.</figcaption>
</figure>
<p>The number of simulations is set by what a node costs, so the encoding, the belief's prediction and the simulator are optimised to their limit before the state cap, the simulations, the depth and the network's size are balanced against each other; on help.map seed 7 a simulation costs 5.4M to 5.9M points, the leaf's network evaluation 4.24M of it and its encoding 1.15M to 1.26M, and about 5.7 simulations run a turn (<a href="#budget">Budget</a>). Each dragon's 100M points are its own and lapse when its turn ends (<code>planning/rules.md</code>), so every dragon searches with its own budget, quiet workers included. The search stops by the virtual clock, within the judge's backstop of 1 CPU second a turn.</p>
<h4 id="search-others">Other dragons in the search</h4>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 190" role="img" aria-label="How the search moves other dragons: nearby allies by their intentions, nearby enemies as chance nodes, distant dragons by heading, newborns by a fixed rule">
  <rect class="layer" x="250" y="8" width="220" height="40" rx="6"/>
  <text class="head" x="360" y="25" text-anchor="middle">A simulated round</text>
  <text class="small" x="360" y="41" text-anchor="middle">every other dragon moves</text>
  <rect class="layer" x="8" y="80" width="170" height="64" rx="6"/>
  <text class="head" x="93" y="98" text-anchor="middle">Nearby ally</text>
  <text class="small" x="93" y="115" text-anchor="middle">follows its intention</text>
  <text class="small" x="93" y="130" text-anchor="middle">via the route controller</text>
  <path class="flow" d="M360,48 L93,78" marker-end="url(#arrow)"/>
  <rect class="mixed" x="186" y="80" width="170" height="64" rx="6"/>
  <text class="head" x="271" y="98" text-anchor="middle">Nearby enemy</text>
  <text class="small" x="271" y="115" text-anchor="middle">chance node: safe moves</text>
  <text class="small" x="271" y="130" text-anchor="middle">network or mimic priors</text>
  <path class="flow" d="M360,48 L271,78" marker-end="url(#arrow)"/>
  <rect class="neutral open" x="364" y="80" width="170" height="64" rx="6"/>
  <text class="head" x="449" y="98" text-anchor="middle">Distant dragon</text>
  <text class="small" x="449" y="115" text-anchor="middle">keeps its heading</text>
  <text class="small" x="449" y="130" text-anchor="middle">or its intention</text>
  <path class="flow" d="M360,48 L449,78" marker-end="url(#arrow)"/>
  <rect class="neutral open" x="542" y="80" width="170" height="64" rx="6"/>
  <text class="head" x="627" y="98" text-anchor="middle">Newborn</text>
  <text class="small" x="627" y="115" text-anchor="middle">follows a fixed rule</text>
  <text class="small" x="627" y="130" text-anchor="middle"> </text>
  <path class="flow" d="M360,48 L627,78" marker-end="url(#arrow)"/>
  <text class="small" x="360" y="162" text-anchor="middle">never frozen, and never acting on the searcher's sampled hidden state;</text>
  <text class="small" x="360" y="177" text-anchor="middle">dashed: placeholders, kept only if they beat richer models at equal cost</text>
</svg>
<figcaption>Part 4's model of the other dragons inside a simulation.</figcaption>
</figure>
<p>Other dragons in the search are never frozen, and never act on the searcher's sampled hidden state or its knowledge. Nearby allies follow their reported intentions through the route controller, nearby enemies are chance nodes over their safe moves with priors from one network evaluation each at the root, or from their team's mimic (a network trained to play like that team, part 6) once it passes its fidelity check (a test that it really plays like that team), distant dragons keep their heading or intention, and newborns follow a fixed rule. Several choices in this model are placeholders: the distance that makes a dragon nearby, the fixed rules for distant dragons and newborns, and limiting enemies to safe moves. Each is kept only if it beats a richer model at equal cost, such as network or mimic priors for more dragons. Nodes are keyed by the observation history, so samples that differ only in hidden cells reach the same decision. Results are wins, draws and losses under the exact lexicographic scoring (the Objective's order: queens, then longest dragon, then total length), without survival shaping (extra reward for merely staying alive, which would discourage useful sacrifices). A complete action is ready before search starts, and search memory fits the 48 MB in dense arrays. Each simulation copies its sampled game, 215,552 bytes, at the bulk-memory floor, the cost of WebAssembly's <code>memory.copy</code> (<code>results/local/bot-floors-20261006/summary.md</code>). Undo in place of the copy is adopted only if it costs fewer points.</p>
<aside class="oy-card oy-alert" id="c-chance">
<h3>Chance nodes and expectimax</h3>
<p>In a two-player game with perfect information, the opponent's moves are adversarial: you assume it picks the reply worst for you (minimax). With many independent opponents, each partly unpredictable, that assumption is too pessimistic. A <em>chance node</em> instead averages over the opponent's possible moves, weighted by how likely each is. Taking expectations at chance nodes and maxima at our own nodes is called expectimax. The better the weights predict real enemies, here from the network or a mimic of their team, the more useful the averages.</p>
</aside>
<p>A transposition table must be evaluated once the search reaches a useful depth (roadmap item 8). Positions are hashed, for example by Zobrist keys over the dragon's observation-relevant state, so different move orders that reach the same position share their statistics. On help.map seed 7, 17.1% of the nodes grown had a key another node already held, every one a child of the root. The table stays only if it saves points per useful node or wins at equal cost.</p>
<aside class="oy-card oy-alert" id="c-transposition">
<h3>Transpositions and Zobrist hashing</h3>
<p>Two move orders often reach the same position: north then east, or east then north. A tree treats them as different nodes and searches the position twice. A <em>transposition table</em> maps each position to one shared record, so work done on one path serves the other. To look positions up quickly, Zobrist hashing (Zobrist, 1970) gives every (feature, value) pair a random 64-bit number and XORs together those present. A move then updates the key with a few XORs instead of rehashing the whole position.</p>
</aside>
<h4 id="search-alternatives">Searching with hidden information: the alternatives</h4>
<p>Information-set MCTS is one of several ways to search when a player can't see the whole state. They differ in what the tree's nodes stand for, and so in what they cost and what they can guarantee. The figure compares them. Every one besides ours is a contender for part 4's decision record, to be tested at equal cost once the current design plays on the ladder (<a href="#principles">Principles</a>).</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 360" role="img" aria-label="Comparison of search methods for hidden information: policy only, determinised MCTS, information-set MCTS (ours), POMCP, and public-belief-state search as in ReBeL and Student of Games, by what nodes stand for, how hidden information is handled, what each needs, and its status here">
  <text class="head" x="14" y="24">Method</text><text class="head" x="164" y="24">Nodes stand for</text><text class="head" x="334" y="24">Hidden information</text><text class="head" x="514" y="24">Status here</text>
  <path class="rule" d="M8,34 L712,34"/>
  <rect class="neutral" x="8" y="42" width="148" height="52" rx="6"/><text class="head" x="82" y="64" text-anchor="middle">Policy only</text><text class="small" x="82" y="82" text-anchor="middle">no search at play</text>
  <text class="small" x="164" y="64">no tree: one network</text><text class="small" x="164" y="80">evaluation decides</text>
  <text class="small" x="334" y="64">whatever the network</text><text class="small" x="334" y="80">learned to infer</text>
  <text class="small" x="514" y="64">the baseline search must beat:</text><text class="small" x="514" y="80">it does, 27–13 (part 4)</text>
  <rect class="neutral" x="8" y="104" width="148" height="52" rx="6"/><text class="head" x="82" y="126" text-anchor="middle">Determinised MCTS</text><text class="small" x="82" y="144" text-anchor="middle">perfect-info sampling</text>
  <text class="small" x="164" y="126">full game states,</text><text class="small" x="164" y="142">one tree per sample</text>
  <text class="small" x="334" y="126">guessed per sample;</text><text class="small" x="334" y="142">suffers strategy fusion</text>
  <text class="small" x="514" y="126">superseded by information-set</text><text class="small" x="514" y="142">MCTS, which fixes the fusion</text>
  <rect class="good" x="8" y="166" width="148" height="52" rx="6"/><text class="head" x="82" y="188" text-anchor="middle">Information-set MCTS</text><text class="small" x="82" y="206" text-anchor="middle">ours (part 4)</text>
  <text class="small" x="164" y="188">what the dragon has</text><text class="small" x="164" y="204">observed; samples share nodes</text>
  <text class="small" x="334" y="188">fresh sample from the belief</text><text class="small" x="334" y="204">each simulation</text>
  <text class="small" x="514" y="188">used: ~6 simulations a turn,</text><text class="small" x="514" y="204">needs only a simulator + belief</text>
  <rect class="mixed" x="8" y="228" width="148" height="52" rx="6"/><text class="head" x="82" y="250" text-anchor="middle">POMCP</text><text class="small" x="82" y="268" text-anchor="middle">Silver and Veness</text>
  <text class="small" x="164" y="250">action–observation</text><text class="small" x="164" y="266">histories</text>
  <text class="small" x="334" y="250">particles kept at each node,</text><text class="small" x="334" y="266">built by the simulations</text>
  <text class="small" x="514" y="250">contender: close to ours, with</text><text class="small" x="514" y="266">particles for our Bayes filter</text>
  <rect class="mixed" x="8" y="290" width="148" height="60" rx="6"/><text class="head" x="82" y="312" text-anchor="middle">Public-belief search</text><text class="small" x="82" y="330" text-anchor="middle">ReBeL, Student of Games</text>
  <text class="small" x="164" y="312">public belief states: what</text><text class="small" x="164" y="328">everyone knows about all</text><text class="small" x="164" y="344">players' private information</text>
  <text class="small" x="334" y="312">solved for an equilibrium</text><text class="small" x="334" y="328">(CFR) with a value network</text><text class="small" x="334" y="344">over beliefs</text>
  <text class="small" x="514" y="312">contender: shown on two-player</text><text class="small" x="514" y="328">zero-sum games; scaling to</text><text class="small" x="514" y="344">many dragons is the open work</text>
</svg>
<figcaption>Textbook comparison, with each method's status in this design.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-nosearch">
<h3>Playing with no search</h3>
<p>The simplest option is to spend nothing on search and play the network's top-scored candidate. All of the strength then has to be learned, but every point of the turn can go to a bigger network. It is the baseline any search must beat at equal cost, which is why part 4's acceptance includes a match of the searching bot against the plain bot. Here the search, once its root noise was removed, beat the same network without search 27–13, so search stays. The comparison is rerun whenever the network or the search changes, because a stronger network narrows the gap.</p>
</aside>
<aside class="oy-card oy-alert" id="c-pomcp">
<h3>POMCP</h3>
<p>Silver and Veness's partially observable Monte Carlo planning (2010) builds the tree over the searcher's own history of actions and observations, like information-set MCTS. It keeps a set of sampled hidden states, <em>particles</em>, at each node, filled by the simulations that pass through it, and draws the next simulation's hidden state from the root's particles. That makes it a belief filter and a search in one, needing nothing but a simulator. This design already has a better-informed belief, the Bayes filters of part 1, so it samples from those instead. The open question for the decision record is whether per-node particles help deeper in the tree.</p>
</aside>
<aside class="oy-card oy-alert" id="c-pbs">
<h3>Public belief states: ReBeL and Student of Games</h3>
<p>In poker, each player's cards are private, but everyone can compute the same thing from the public actions: a probability distribution over every player's possible private cards. That distribution is the <em>public belief state</em>. Treating it as the state turns the imperfect-information game into a perfect-information game over beliefs, which can be searched like chess. ReBeL (Brown et al., 2020) does this with a value network over public belief states and counterfactual regret minimisation (CFR) to solve each small subgame for an equilibrium. A Nash equilibrium is a strategy for each player such that neither gains by changing theirs alone. In a two-player zero-sum game, playing one guarantees you can't be exploited, whatever the opponent does. Student of Games (Schmid et al., 2023) generalises it with growing-tree CFR, and plays chess, Go, poker and Scotland Yard with one algorithm.</p>
<p>Both were demonstrated on two-player zero-sum games with small private information. What stands between them and Loong is size and budget: a public belief over every unseen dragon's position and the team's private sonar is vastly larger than a poker hand, and an equilibrium solve per decision costs far more than the six or so simulations a turn affords. The work that would remove that is a compact public belief, such as the belief planes themselves, and a solver that fits the judge. The decision record tests it.</p>
</aside>
<h4 id="search-reuse">Search across turns</h4>
<p>Search work carries across turns, because a dragon's process lives for its whole life. Its search tree persists between its turns, as AlphaZero reuses its tree (Silver et al., 2017). When the dragon's next turn arrives, the root moves to the node reached by the action it took and the observation it then received, and every other branch is freed, so memory holds only what can still happen. If no grown node matches that observation, the search starts from a fresh root. The kept statistics were gathered under the earlier belief, so their visit counts are discounted, before this turn's simulations extend the tree, by a factor derived from how far the belief moved between turns, such as the KL divergence between the old and the new root's beliefs. Nothing is pruned for good: tree search never excludes a move, it only hasn't grown it yet. Each turn the root regenerates its candidates from the new belief and the Gumbel root samples them afresh, and progressive widening admits more moves at a node as its visits grow, so a move left unexplored earlier is grown whenever the search comes to favour it.</p>
<aside class="oy-card oy-alert" id="c-widening">
<h3>Progressive widening</h3>
<p>When a node has many possible moves, splitting a handful of visits among all of them learns nothing about any. <em>Progressive widening</em> limits a node to its k best moves by prior, and lets k grow as a power of its visit count, k ≈ C·n<sup>α</sup>. A node visited a lot considers more alternatives; a node visited rarely concentrates on its best few. Nothing is ever excluded permanently.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 220" role="img" aria-label="Progressive widening: the number of a node's moves the search may choose among grows as 2 plus the square root of its visits, up to the 16 it keeps">
  <path class="rule" d="M60,180 L680,180 M60,180 L60,20"/>
  <text class="small" x="370" y="208" text-anchor="middle">the node's visits</text>
  <text class="small" x="20" y="100" transform="rotate(-90 20 100)" text-anchor="middle">moves admitted</text>
  <path class="flow" d="M60,150 L80,150 L80,140 L140,140 L140,130 L240,130 L240,120 L380,120 L380,110 L560,110 L560,100 L680,100" marker-end="url(#arrow)"/>
  <text class="small" x="64" y="168">0: 2</text><text class="small" x="84" y="158">1: 3</text><text class="small" x="144" y="148">4: 4</text><text class="small" x="244" y="138">9: 5</text><text class="small" x="384" y="128">16: 6</text><text class="small" x="564" y="118">25: 7</text>
  <text class="small" x="370" y="40" text-anchor="middle">admitted = 2 + √visits, the best moves by prior first, up to the 16 a node keeps (tree/0002.h)</text>
</svg>
<figcaption>Progressive widening as <code>tree/0002.h</code>'s <code>SelectEdge</code> computes it; base and exponent are placeholders to be fitted (part 4).</figcaption>
</figure>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 210" role="img" aria-label="Tree reuse: after the dragon acts and observes, the matching child becomes the new root and every other branch is freed">
  <circle class="layer" cx="150" cy="30" r="14"/>
  <text class="small" x="172" y="34">root, turn t</text>
  <circle class="good" cx="90" cy="100" r="14"/><circle class="neutral open" cx="210" cy="100" r="14"/>
  <circle class="layer" cx="60" cy="170" r="12"/><circle class="layer" cx="120" cy="170" r="12"/><circle class="neutral open" cx="190" cy="170" r="12"/><circle class="neutral open" cx="230" cy="170" r="12"/>
  <path class="rule" d="M150,44 L92,86 M150,44 L208,86 M90,114 L62,158 M90,114 L118,158 M210,114 L192,158 M210,114 L228,158"/>
  <text class="small" x="72" y="96" text-anchor="end">acted +</text>
  <text class="small" x="72" y="110" text-anchor="end">observed</text>
  <text class="small" x="230" y="100">freed</text>
  <path class="flow" d="M300,100 L420,100" marker-end="url(#arrow)"/>
  <text class="small" x="360" y="90" text-anchor="middle">next turn</text>
  <circle class="good" cx="540" cy="30" r="14"/>
  <text class="small" x="562" y="34">new root, counts discounted</text>
  <circle class="layer" cx="500" cy="100" r="12"/><circle class="layer" cx="580" cy="100" r="12"/><circle class="box open" cx="640" cy="100" r="12"/>
  <path class="rule" d="M540,44 L502,88 M540,44 L578,88 M540,44 L636,88"/>
  <text class="small" x="640" y="132" text-anchor="middle">widened later</text>
</svg>
<figcaption>Textbook: tree reuse between a dragon's turns, as part 4 specifies it.</figcaption>
</figure>
<p>The Gumbel root's c_visit and c_scale (Danihelka et al.) and PUCT's constant (AlphaZero) are re-derived for our value scale and simulation count, progressive widening takes Couëtoux et al.'s exponent form with its exponent fitted, and the constants left are tuned jointly at equal cost by SPSA or CLOP, never one at a time by hand. Nodes live in a fixed arena, a block of node slots allocated once, within the 48 MB. When the arena is full, the search recycles its least-visited leaves.</p>
<aside class="oy-card oy-alert" id="c-spsa">
<h3>Tuning constants: SPSA and CLOP</h3>
<p>Search has several interacting constants, and each match result is noisy. Tuning them one at a time by hand misses interactions and overreacts to noise. <em>SPSA</em> (simultaneous perturbation stochastic approximation) nudges all constants at once by random ± amounts, plays both versions, and moves every constant a little in the direction that won: a gradient estimate from two noisy evaluations, whatever the number of constants. <em>CLOP</em> instead fits a smooth model of win rate over the constants from all games played and moves towards its predicted optimum. Both are standard in chess-engine tuning. Readers who know genetic algorithms can think of SPSA as a population of two with a principled step size.</p>
</aside>
<h4 id="search-budget">Spending the whole budget</h4>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 150" role="img" aria-label="The order a turn spends its points: network and root, then search, then the distance table, with a reserve for the reply">
  <path class="rule" d="M20,90 L700,90"/>
  <rect class="layer" x="20" y="40" width="90" height="50" rx="6"/>
  <text class="head" x="65" y="62" text-anchor="middle">network</text>
  <text class="small" x="65" y="78" text-anchor="middle">and root</text>
  <rect class="good" x="110" y="40" width="430" height="50" rx="6"/>
  <text class="head" x="325" y="62" text-anchor="middle">grow the reused tree,</text>
  <text class="small" x="325" y="78" text-anchor="middle">search as far as it pays</text>
  <rect class="mixed" x="540" y="40" width="100" height="50" rx="6"/>
  <text class="head" x="590" y="62" text-anchor="middle">distance table</text>
  <text class="small" x="590" y="78" text-anchor="middle">leftover points</text>
  <rect class="neutral open" x="640" y="40" width="60" height="50" rx="6"/>
  <text class="head" x="670" y="62" text-anchor="middle">reserve</text>
  <text class="small" x="670" y="78" text-anchor="middle">p99.99</text>
  <text class="small" x="20" y="112" text-anchor="start">0</text>
  <text class="small" x="700" y="112" text-anchor="end">100M points</text>
  <text class="small" x="360" y="136" text-anchor="middle">the virtual clock tells the dragon its exact spend at every moment; the search/table split is set by measurement</text>
</svg>
<figcaption>Part 4: how one turn's 100M points are spent, in order. Widths are illustrative.</figcaption>
</figure>
<p>The dragon also keeps an all-pairs distance table over its known map, 16 MB on a 64 × 64 board. It is updated as new map facts arrive and answers every distance the generators, the route controller and the search need in one lookup, so each simulated step costs fewer points and search reaches further, and the generators and leaf evaluation work from exact distances. The judge's clock is readable in play: virtual time advances 1 ns per point (<code>planning/rules.md</code>), so a dragon always knows its exact remaining budget. Every turn spends its full 100M points, less a measured reserve for its reply: the network and the root first, then growing the reused tree and searching as far as the budget allows, and building the distance table with whatever the search's marginal value doesn't claim, in a split set by measurement. Each of the two stays only if it saves measured points per useful node, or wins at equal cost. The reserve is a high quantile of the measured reply cost, p99.99 (the cost that only one reply in ten thousand exceeds) plus a margin; the current 6M points plus twice the costliest reply is a placeholder.</p>
<p>Recognising which top team's mimic this game's enemies resemble, from statistics of their moves, could give the enemy chance nodes better priors. Its value is uncertain: the ladder's bots change, and unseen tournament maps may make matching harder. It is tested late, against the final league, and kept only if it wins.</p>
<h3 id="teacher">5. The expensive teacher runs offline</h3>
<p>Round 5 refits round 2's final checkpoint on the generated <code>foil-dagger4-20261007</code> records with the exact library pinned by <code>expert/0001v-round5</code>. Native and CUDA engines and the C++ trainer share <code>candidates/0003.h</code> and <code>features/0004.h</code>; replay candidate columns include <code>survival_depth</code> after <code>room</code>. All 48 candidate bytes retain their tensor shape, so <code>--start /tmp/r2/dagger2-final.ten</code> can load without widening. The authorised refit uses one hour, 128 lanes, a 40,000-decision pool, batches of 2,048, 10,000 held-out decisions, split weight 4, learning rate 0.0001, patience 10 and queen weight 0. Export uses the resulting <code>checkpoint.ten</code>. Its held-out agreement and loss change measure imitation; playing strength and completion of the full teacher loop remain placeholders pending their own evidence.</p>
<p>The completed refit loaded round 2 directly and reached step 24,988. On the same 20,086 decisions spread over 53 held-out games, the final checkpoint improved agreement from 0.802201 to 0.807179 and reduced loss from 0.477824 to 0.463174 (change −0.014650). This is the exported checkpoint; the trainer's separate best-loss export is from step 18,000. The actual held-out spread exceeded the requested 10,000. Evidence is in <code>assets/learning/runs/round5-20261007/{baseline,final}/score.tsv</code> and <code>process.log</code>. The registered final-checkpoint bot is <code>8c4c8c25-0e83-579e-9033-6e1d04ad3965</code>.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 224" role="img" aria-label="Part 5's training timeline: a kickstart by imitation, then repeated cycles of self-play with the teacher, targets, distillation and a gate, with the privileged value supporting the teacher">
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
  <text class="head" x="643" y="58" text-anchor="middle">Gate</text>
  <text class="small" x="643" y="75" text-anchor="middle">beat the plain</text>
  <text class="small" x="643" y="90" text-anchor="middle">network to keep it</text>
  <path class="flow dash" d="M670,100 L670,130 L259,130 L259,102" marker-end="url(#arrow)"/>
  <text class="small" x="600" y="148" text-anchor="middle">next cycle starts from the stronger network</text>
  <rect class="good" x="200" y="170" width="340" height="44" rx="6"/>
  <text class="head" x="370" y="189" text-anchor="middle">Privileged value</text>
  <text class="small" x="370" y="205" text-anchor="middle">fitted on true states; values the teacher's leaves</text>
  <path class="flow" d="M370,170 L370,104" marker-end="url(#arrow)"/>
</svg>
<figcaption>Intended design: the kickstart, then expert-iteration cycles.</figcaption>
</figure>
<p>The first network is kickstarted by imitating the top ladder teams' decisions in public replays, which the organisers allow, each game replayed in the judge from its match seed so that every dragon's observation, pearl countdowns included, is the one it saw, before expert iteration takes over, as AlphaStar learned from human play before its league (Vinyals et al., 2019).</p>
<aside class="oy-card oy-alert" id="c-imitation">
<h3>Imitation learning and the kickstart</h3>
<p><em>Imitation learning</em>, or behaviour cloning, trains a network to predict what an expert did in recorded games: supervised learning with the expert's move as the label. It can only reach the level of what it copies, but it gets there quickly, and that starting point matters. Expert iteration from a random network spends a long time rediscovering basics, and its first searches, guided by a network that knows nothing, find little. AlphaStar first imitated human StarCraft players, then improved past them by reinforcement learning in a league. The same order here: the top ladder teams are the humans.</p>
</aside>
<p>From then on, the same search run with full information and generous budgets on the GPU or fleet (rented machines: CPU instances on AWS for games and builds, GPUs per job from Vast.ai, see <a href="#gpu">How the training runs on a GPU</a>) produces improved policy targets (Anthony et al., 2017). In that self-play data collection its root samples candidates by Gumbel draws, for exploration; its gate against the plain network (a match the teacher must win before its targets are trusted, against the network choosing without search), and every match, play with the draws at zero, as part 4's play does. A faithful simulator serves as the oracle there, never inside the bot. The value network takes privileged whole-board inputs and learns from the outcomes of search-played games, as in AlphaZero (Silver et al., 2017). Its values are used at search leaves only after its predictions pass a calibration check on held-out games (games kept out of training so the check measures generalisation, not memory).</p>
<aside class="oy-card oy-alert" id="c-basics">
<h3>Batches, steps and the learning rate</h3>
<p>Training never looks at all its data at once. Each <em>step</em> takes a <em>batch</em> of examples, a few hundred to a few thousand decisions, computes the loss and its gradient over them by backpropagation, and moves the weights a little against the gradient. One pass over the whole dataset is an <em>epoch</em>, though our trainers stream replayed games and count steps instead. A larger batch gives a smoother gradient and uses the GPU better, up to its memory.</p>
<p>How far each step moves is the <em>learning rate</em>. Too large and training diverges, too small and it crawls. The imitation trainer raises it linearly over its first 2,000 steps, a warm-up long enough for Adam's running averages to settle (2 / (1 − β₂) for β₂ = 0.999; Ma and Yarats, 2021), then lowers it along a cosine curve over the run, so late steps make fine adjustments (<code>tools/learning/README.md</code>).</p>
</aside>
<aside class="oy-card oy-alert" id="c-distil">
<h3>Distillation and cross-entropy</h3>
<p>The teacher's search ends with a distribution over the root's candidates: an improved policy. <em>Distillation</em> (Hinton, Vinyals and Dean, 2015) trains the student network to reproduce that distribution. The loss is <em>cross-entropy</em>, −Σ target(a) · log student(a): it is smallest when the student puts its probability where the teacher did, and it rewards matching the whole distribution, so the student also learns which alternatives were nearly as good. The value head is trained alongside on the squared error between its estimate and the game's outcome. <code>loong-distil</code> (<code>tools/learning/trainer/distil.cc</code>) minimises the cross-entropy plus a weighted value error, on 5% of games held out by hash for the calibration report.</p>
</aside>
<aside class="oy-card oy-alert" id="c-adamw">
<h3>AdamW</h3>
<p>Gradient descent updates each weight by a small step against its gradient. Plain gradient descent struggles when different weights' gradients differ wildly in scale, or are noisy from batch to batch. <em>Adam</em> (Kingma and Ba, 2015) keeps two running averages per weight: of the gradient (momentum, which smooths noise) and of its square (which measures typical size), and steps by the first divided by the square root of the second. Every weight then moves at a sensible rate whatever its gradient's scale. Early averages are corrected for starting at zero.</p>
<p>Networks also benefit from <em>weight decay</em>: shrinking every weight slightly each step, which discourages large weights and overfitting. In Adam, adding decay to the gradient gets distorted by the per-weight scaling. Loshchilov and Hutter's <em>AdamW</em> decouples it, shrinking weights directly, which works measurably better. Our trainer uses AdamW (<code>tools/learning/trainer/adamw.cc</code>) with weight decay 1e-4, momentum constants 0.9 and 0.999, and gradients clipped to norm 1 (a gradient vector longer than 1 is scaled down to length 1; Pascanu, Mikolov and Bengio, 2013), so one bad batch can't throw the weights far.</p>
</aside>
<aside class="oy-card oy-alert" id="c-cudagraph">
<h3>CUDA graphs</h3>
<p>A training step for a small network is hundreds of tiny GPU operations, and launching each from the CPU costs more time than the GPU spends on it. A <em>CUDA graph</em> records the whole sequence once and replays it with a single launch, so the GPU runs back to back. The trainer captures its forward pass, loss, backward pass, gradient clipping and AdamW step as one graph, one launch where the step run operation by operation needed about 1,700 (<code>tools/learning/trainer/graph.h</code>), checked to give the same weights as the step run operation by operation.</p>
</aside>
<h4 id="teacher-value">The leaf value decides the teacher's strength</h4>
<aside class="oy-card oy-alert" id="c-value">
<h3>Value functions, rollouts and privileged critics</h3>
<p>A search can only look a few moves ahead, so at its leaves it needs an estimate of who will win: a <em>value function</em>. There are two classic ways to get one. A <em>rollout</em> plays the game forward from the leaf with a fast policy and scores the result; it is unbiased if the policy plays well, but slow and noisy. A learned value network answers in one evaluation, but is only as good as its training.</p>
<p>The teacher has an advantage the bot lacks: it can see the true state. A value network given the whole board, a <em>privileged critic</em> as in asymmetric actor-critic (Pinto et al., 2018), can judge positions far better than one that sees a 7×7 window. The bot can't use it in play, but the teacher can, and the bot's own value head can then be trained to approximate it from what a dragon knows (asymmetric distillation, below).</p>
</aside>
<p>The leaf value decides the teacher's strength. On 32 small-map games against the plain network, the same seeds for each arm and no root noise, the teacher with the network's own value at its leaves scored 15 of 32 at 16 simulations and depth 2, and neither 256 simulations nor depth 4 raised it. Its leaf log shows why: the network's value is about 0.7 too optimistic at every depth, and its squared error against the outcome, 1.24 to 1.44, is worse than a constant's 0.98 to 0.99. On the same seeds, leaves played on by the network for 20 rounds on the true state and valued by the team's standing won 32 of 32, and the fitted privileged value at the leaves won 25 of 32. Rollouts ending on the privileged value won all 29 games finished. A 20-round rollout costs about 9 times a privileged leaf (0.9 steps a second against 7.8 on the RTX 5070 Ti).</p>
<div class="oy-table-properties"><table>
<caption>Teacher leaf values against the plain network, 32 small-map games, same seeds</caption>
<thead><tr><th>Leaf value</th><th>Teacher's wins</th></tr></thead>
<tbody>
<tr><td>Network's own value head (16 simulations; 256 and depth 4 no better)</td><td>15 of 32</td></tr>
<tr><td>Fitted privileged value</td><td>25 of 32</td></tr>
<tr><td>20-round rollout, valued by the team's standing</td><td>32 of 32</td></tr>
<tr><td>20-round rollout, ending on the privileged value</td><td>29 of the 29 finished</td></tr>
</tbody></table></div>
<p>So far the privileged value is fitted offline on recorded games, against the outcome, the n-step value 10 rounds on, and the team's shares of units, total length and longest dragon 10, 50 and 200 rounds on (<code>tools/learning/README.md</code>), and not yet on search-played games. It passes the calibration check, with an expected calibration error of 0.024 on 11,308 held-out positions. Cycle 1's teacher values its leaves by 20-round rollouts ending on the privileged value. A full-map gate of hundreds of games confirms this before the teacher generates data, since the small-map gate stands in for it. The rollout's cost is reduced by engineering: a cheap rollout policy over every lane's dragons in one kernel, rollouts only from leaves whose value is uncertain, the round loop captured as a CUDA graph, and games spread across GPUs. The teacher's simulations, depth, root width and rollout length are set by strength gained per GPU-second and per dollar on the rented cards' measured throughput, the root width never cut.</p>
<h4 id="teacher-head">Distilling the bot's value head</h4>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 220" role="img" aria-label="Distilling the bot's value head: targets from the privileged value of the true state and the outcome, an auxiliary head for shares, and three checks before the search uses it">
  <rect class="box" x="8" y="10" width="170" height="46" rx="6"/>
  <text class="head" x="93" y="30" text-anchor="middle">True state</text>
  <text class="small" x="93" y="46" text-anchor="middle">whole board</text>
  <path class="flow" d="M178,33 L216,33" marker-end="url(#arrow)"/>
  <rect class="good" x="218" y="10" width="170" height="46" rx="6"/>
  <text class="head" x="303" y="30" text-anchor="middle">Privileged value</text>
  <text class="small" x="303" y="46" text-anchor="middle">fitted, calibrated</text>
  <rect class="box" x="8" y="70" width="170" height="46" rx="6"/>
  <text class="head" x="93" y="90" text-anchor="middle">Game outcome</text>
  <text class="small" x="93" y="106" text-anchor="middle">win, draw, loss</text>
  <rect class="neutral" x="8" y="130" width="170" height="46" rx="6"/>
  <text class="head" x="93" y="150" text-anchor="middle">Shares 10/50/200 on</text>
  <text class="small" x="93" y="166" text-anchor="middle">a training-only head</text>
  <text class="small" x="320" y="146" text-anchor="middle">shapes the shared body</text>
  <rect class="layer" x="450" y="60" width="180" height="60" rx="6"/>
  <text class="head" x="540" y="87" text-anchor="middle">Bot's value head</text>
  <text class="small" x="540" y="103" text-anchor="middle">from the dragon's view</text>
  <path class="flow" d="M388,33 L448,75" marker-end="url(#arrow)"/>
  <path class="flow" d="M178,93 L448,90" marker-end="url(#arrow)"/>
  <path class="flow dash" d="M178,153 L448,105" marker-end="url(#arrow)"/>
  <rect class="mixed" x="450" y="150" width="260" height="60" rx="6"/>
  <text class="head" x="580" y="168" text-anchor="middle">Three checks</text>
  <text class="small" x="580" y="185" text-anchor="middle">calibration · forked continuations</text>
  <text class="small" x="580" y="200" text-anchor="middle">· searching bot beats plain bot</text>
  <path class="flow" d="M540,120 L540,148" marker-end="url(#arrow)"/>
  <text class="small" x="300" y="200" text-anchor="middle">then the bot's search reads it</text>
  <path class="flow" d="M450,180 L380,195" marker-end="url(#arrow)"/>
</svg>
<figcaption>Part 5: the targets the bot's value head learns, and the checks it passes before the search may read it.</figcaption>
</figure>
<p>The bot's value head is distilled from this value, as asymmetric distillation does (Warrington et al., 2021). At each of a dragon's decisions in training, on both teams' positions, it learns the fitted privileged value of the true state and the outcome. A training-only auxiliary head learns the team's shares of units, total length and longest dragon 10, 50 and 200 rounds on. The value targets use TD(λ) in place of fixed horizons, its λ fitted on held-out calibration, and training stops when held-out improvement falls within the run's measured noise. Decisions that carry only value targets train no policy. The search reads the head only after it passes three checks: the held-out calibration check, a forked-continuation test and a match of the searching bot against the plain bot. The forked-continuation test copies recorded games at a random round and plays each copy to the end with the policy network, so the head's values can be compared with the continuations' outcomes. The imitation-trained head in <code>expert-0001</code> fails the calibration check. It learnt only from the top ten teams' sides, which won 62.9% of their games, and on the teacher's states it reads about 0.7 too optimistic, with an error against the outcome of 1.24 to 1.44 where a constant gets 0.99. The single retrain on the new inputs replaces it.</p>
<aside class="oy-card oy-alert" id="c-td">
<h3>TD(λ)</h3>
<p>A value network needs a target to learn. The final outcome is honest but noisy: a game decided by a blunder 300 rounds later says little about this position. The value one step later, as estimated by the network itself, is less noisy but inherits the network's errors (this is <em>temporal-difference</em> learning; Sutton, 1988). The <em>n-step</em> target mixes them: real outcomes for n rounds, then the estimate. TD(λ) averages all n-step targets with weights (1−λ)λ<sup>n−1</sup>: λ near 0 trusts the estimate, λ near 1 trusts the outcome. Fitting λ on held-out calibration chooses the mix from evidence instead of fixing horizons by hand.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 150" role="img" aria-label="TD lambda: the target blends n-step returns with geometrically decaying weights, from the next state's estimate to the final outcome">
  <path class="rule" d="M40,100 L680,100"/>
  <circle class="layer" cx="60" cy="100" r="8"/><text class="small" x="60" y="128" text-anchor="middle">now</text>
  <rect class="box" x="120" y="40" width="40" height="60"/>
  <rect class="box" x="200" y="58" width="40" height="42"/>
  <rect class="box" x="280" y="71" width="40" height="29"/>
  <rect class="box" x="360" y="80" width="40" height="20"/>
  <rect class="box" x="440" y="86" width="40" height="14"/>
  <rect class="good" x="600" y="70" width="60" height="30"/>
  <text class="small" x="140" y="128" text-anchor="middle">1 step</text>
  <text class="small" x="220" y="128" text-anchor="middle">2</text>
  <text class="small" x="300" y="128" text-anchor="middle">3</text>
  <text class="small" x="380" y="128" text-anchor="middle">4</text>
  <text class="small" x="460" y="128" text-anchor="middle">…</text>
  <text class="small" x="630" y="128" text-anchor="middle">outcome</text>
  <text class="small" x="360" y="24" text-anchor="middle">bar heights: each n-step target's weight, (1−λ)λ^(n−1); the outcome takes the remaining weight</text>
</svg>
<figcaption>Textbook: how TD(λ) weights its targets.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-earlystop">
<h3>Stopping when improvement is within noise</h3>
<p>Training stops when the network stops getting better on held-out games, but "better" has to beat chance: two checkpoints' held-out losses differ a little even when neither is really better. So the trainer scores the current network and the best so far on the same held-out decisions and tests the difference. Because both are scored on the same decisions, the comparison is <em>paired</em>, which cancels out how hard each position is. Decisions from one game are correlated, so the standard error is <em>clustered by game</em>, treating each game's sum as one observation. Training goes on only while the mean improvement is below zero by more than 1.645 standard errors, a one-sided test at 95% (<code>tools/learning/trainer/early.h</code>).</p>
</aside>
<h4 id="teacher-gap">What the student can't copy</h4>
<p>A dragon sees only its 7×7 window, so targets chosen with information it lacks may be hard for it to imitate (Warrington et al., 2021). A student distilled from this teacher is therefore compared with one distilled at equal compute from a teacher whose determinisations come from the acting dragon's belief, and the teacher whose student wins is kept. Where the student still departs from the teacher, the departure is measured in value lost, the teacher's value of its move less its value of the student's. A fact that some teammate observes or decides earns a place in sonar when adding it to the student's inputs recovers that value, and facts are ranked by value recovered per bit of the 256 each dragon sends a turn. Departures that no teammate's knowledge could close are left to belief and search.</p>
<aside class="oy-card oy-alert" id="c-gap">
<h3>The imitation gap</h3>
<p>A teacher that sees everything sometimes makes a move only because it knows something hidden, like turning away from an enemy just out of sight. A student that can't see the enemy can't learn when to make that move. At best it learns to make it on average, sometimes when it shouldn't. Warrington and colleagues call this the <em>imitation gap</em>. Two remedies follow. Give the teacher only what the student could know, at some cost in teacher strength, which is what the A/B comparison above tests. Or close the gap from the student's side, by giving it the missing information, which is how sonar's content is chosen.</p>
</aside>
<p>A legal primitive action is a move, a legal split or a sprint, fatal ones included. A sprint is chosen first by its end cell and final heading, including one that ends by ramming an enemy head or by dying. Its route is a second choice under it, admitted by progressive widening as the branch's visits grow, ordered by how different the resulting states are (body cells, cells revealed, pearls eaten), with routes that leave the same state merged. The teacher searches every legal primitive action as well as the generators' candidates, so each departure is attributed to exactly one cause: a candidate gap, where no candidate represents the teacher's move; a ranking gap, where one does but the network scored it below the student's choice, a matter of training, data or capacity; or an information gap, where the move depends on facts the dragon couldn't have, a matter of belief or sonar. Searching every legal primitive action is a precondition of the value-lost report: until the teacher does, no departure can be called a candidate gap and no generator can be measured.</p>
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
<figcaption>Intended design: the value-lost report's three causes and the parts each points to.</figcaption>
</figure>
<p>Each cycle reports value lost by cause, candidate gaps by situation and by generator, and for each generator how often its candidates are chosen, the value lost to other variants of its behaviour, its cost in bot points and self-play throughput, and its equal-cost ablation (part 3). A teacher is used only after it beats the plain network in a match whose size and pass bar are fixed before it runs.</p>
<p>The teacher's targets come from a full-information search whose leaves are valued by the privileged value, alone or at the end of a rollout (above), over belief planes, in a league with outside opponents. Distillation's gain is measured in the first cycles of the loop, against the network before it.</p>
<h4 id="simulation">Playing many dragons' turns at once</h4>
<p>Most of the teacher's time goes to turns no search decides: inside every simulation, every other dragon is played by the network, one turn at a time, because the rules play a round's dragons in ascending ID order, each seeing the moves before it (<code>planning/rules.md</code>, Round and turn order). Two exact methods take that chain apart without changing a single choice.</p>
<p><strong>Parallel discrete-event simulation.</strong> Dragon j's turn depends on an earlier mover i only when i's action changes something j's turn reads: a cell in j's view (a body, a head, a pearl eaten or dropped by a death), j's inbox (the rays i casts, and the rays later movers cast that i's new or vacated segments now block or let through), or a cell j's own move passes. Each surviving dragon casts at most four rays after acting, one a direction, and a ray stops at kelp or the first living segment, so a mover's messages reach at most four dragons. Conservative scheduling (Chandy and Misra, 1979) plays together, as one wave, every dragon that no unplayed earlier mover can affect. Optimistic scheduling, Time Warp (Jefferson, 1985), plays later dragons speculatively, checks each once the earlier movers have acted, and replays only those an earlier move actually affected. Either yields exactly the game strict ID order yields, provided each dragon's random draws come from its own random stream rather than one shared stream consumed in turn order. Every turn also reads its team's unit count, which any teammate's split or death changes, so a purely conservative schedule waits on every earlier teammate: over 1,500 rounds of eight queen-era games it plays at most 1.70 turns a wave. A hybrid that waits only on earlier movers whose sprint could reach its view or whose rays could stop on its body, and plays again a dragon whose unit count an earlier split or death changed, plays 6.28 turns a wave on the same rounds, against 7.93 for the true dependencies, but needs that reach computed for every pending mover. The schedule built is optimistic in prefixes, which needs none: the next eight movers of a lane are decided together on the state the wave starts from, then played in order, each first checked to see the same turn block it was decided on; the first that doesn't ends the wave and is decided again, with those after it, in the next. It plays 4.60 turns a wave and discards 0.63 decisions a turn (3.34 and 0.17 at four movers, 4.92 and 1.82 at sixteen; <code>loong-turn-dependencies</code>). It applies to every turn the network plays: inside the teacher's simulations, and in played games (gates, matches and the league, part 6). The teacher's own searched decisions stay in order, each searched from the state its turn is reached in.</p>
<aside class="oy-card oy-alert" id="c-pdes">
<h3>Parallel discrete-event simulation</h3>
<p>A simulation of many actors that must act in a fixed order can still run them in parallel when most of them don't interact. Each actor only needs the earlier actors that could change what it reads. Conservative scheduling runs every actor whose possible influences have all finished. Optimistic scheduling (Time Warp) runs ahead regardless, records what each actor read, and rolls back and reruns the few whose reads an earlier actor turned out to change. Both reproduce the sequential result exactly.</p>
</aside>
<aside class="oy-card oy-alert" id="c-persistent">
<h3>Persistent kernels</h3>
<p>A GPU program normally launches a kernel, waits for it, and launches the next. When each kernel is short, the gaps between them can cost more than the work. A persistent kernel stays resident and loops over the steps itself, synchronising on the device, so the host only starts it and reads the result.</p>
</aside>
<aside class="oy-card oy-alert" id="c-playoutcap">
<h3>Playout cap randomization</h3>
<p>KataGo searches only a random fraction of its self-play moves in full and plays the rest with a small search, training only on the fully searched moves. Each game then costs less, so more games are played for the same compute, and the searched moves keep targets as good as before.</p>
</aside>
<p><strong>Persistent kernels.</strong> A long-running kernel for each block of games plays step after step on the device without returning to the host between them, as persistent megakernels do for language-model decoding, so the card isn't left idle between short launches. The results are the same as launching a kernel a step.</p>
<p>Both are checked the same way: choice traces byte-identical to the ID-order teacher on recorded seeds, and the teacher's step latency reported against its floor (the Budget).</p>
<p><strong>The searched share.</strong> Self-play searches only a share of decisions and plays the rest by the network, which is playout cap randomization (Wu, 2019, for KataGo): a full search on a randomly chosen fraction of moves, and fast play on the rest, so more games are played for the same compute while the searched decisions keep their full targets. Unlike the two methods above it changes the training data. Its share is set by measured strength per GPU-hour, comparing networks distilled from equal compute at different shares, and stays where it is until that comparison runs.</p>
<h3 id="league">6. League training</h3>
<p>Train against the frozen pool, the foil and mimics of top ladder teams, in the style of AlphaStar's league (Vinyals et al., 2019), so the policy doesn't overfit to itself. Its games play their network-chosen turns with part 5's parallel simulation (<a href="#simulation">Playing many dragons' turns at once</a>), exactly as strict ID order would. The mimics come from the same imitation that kickstarts the first network. Use generated maps matched to the official distribution, because tournament maps are unseen. The organisers allow training on public ladder games. No mimic is ever submitted as it stands. Registered builds such as the foil's play complete games beside the CUDA engine, with their WebAssembly run on the CPU, and on the CPU fleet (<a href="#budget">Budget</a>).</p>
<aside class="oy-card oy-alert" id="c-league">
<h3>League training</h3>
<p>Pure self-play has a known failure: the policy learns to beat its current self, forgets how to beat older strategies, and can cycle (rock beats scissors beats paper beats rock) without getting better overall. AlphaStar's <em>league</em> keeps a population of opponents: frozen past versions, agents trained specifically to exploit the current policy's weaknesses, and, in our case, mimics of the real teams we must beat. Training against the whole population keeps the policy robust. Readers who know evolutionary methods will recognise coevolution with a hall of fame, with gradient learning in place of mutation.</p>
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
<h3 id="review">7. Acceptance by decision review</h3>
<p>Decisions must be reviewed in the viewer. For every decision the viewer shows the candidates, the network's values and the search's verdict, so the reason for each choice is visible. Diagnostics follow the generic contract in <code>tools/viewer/diagnostics.md</code>. The teacher review shows, for each decision, the played, network and teacher choices, with each one's option, Q and value lost (<code>tools/viewer/teacher_review.odin</code>).</p>
<h4 id="gates">Gates</h4>
<p>Nothing is used or released on a hunch. Each stage passes a match or a check whose size and pass bar are fixed before it runs, so a lucky run can't be chosen after the fact. The release policy itself is owned by the roadmap's Release section. The ladder stays empty until a bot implementing the full expert design is at least as good as foil-0039 in a local match.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 206" role="img" aria-label="The gates: in training the teacher gate, the value checks and the search gate; for release the Wilson-bound gate against foil-0039, then upload; once live, learned changes pass a Wilson bound and logical fixes pass smoke games">
  <text class="head" x="14" y="22" text-anchor="start">Training</text>
  <rect class="layer" x="8" y="32" width="160" height="60" rx="6"/>
  <text class="head" x="88" y="52" text-anchor="middle">Teacher gate</text>
  <text class="small" x="88" y="69" text-anchor="middle">searched teacher beats</text>
  <text class="small" x="88" y="84" text-anchor="middle">the plain network</text>
  <path class="flow" d="M168,62 L196,62" marker-end="url(#arrow)"/>
  <rect class="layer" x="198" y="32" width="160" height="60" rx="6"/>
  <text class="head" x="278" y="52" text-anchor="middle">Value checks</text>
  <text class="small" x="278" y="69" text-anchor="middle">calibration, forked</text>
  <text class="small" x="278" y="84" text-anchor="middle">continuations, match</text>
  <path class="flow" d="M358,62 L386,62" marker-end="url(#arrow)"/>
  <rect class="layer" x="388" y="32" width="160" height="60" rx="6"/>
  <text class="head" x="468" y="52" text-anchor="middle">Search gate</text>
  <text class="small" x="468" y="69" text-anchor="middle">searching bot beats</text>
  <text class="small" x="468" y="84" text-anchor="middle">the plain bot</text>
  <text class="head" x="14" y="124" text-anchor="start">Release</text>
  <rect class="mixed" x="8" y="134" width="200" height="60" rx="6"/>
  <text class="head" x="108" y="154" text-anchor="middle">Release gate</text>
  <text class="small" x="108" y="171" text-anchor="middle">Wilson 95% lower bound</text>
  <text class="small" x="108" y="186" text-anchor="middle">above 50% vs foil-0039</text>
  <path class="flow" d="M208,164 L246,164" marker-end="url(#arrow)"/>
  <rect class="good" x="248" y="134" width="150" height="60" rx="6"/>
  <text class="head" x="323" y="154" text-anchor="middle">Upload</text>
  <text class="small" x="323" y="171" text-anchor="middle">the ladder; ladder</text>
  <text class="small" x="323" y="186" text-anchor="middle">games validate it</text>
  <rect class="neutral" x="430" y="134" width="282" height="60" rx="6"/>
  <text class="head" x="571" y="154" text-anchor="middle">Later, once a release is live</text>
  <text class="small" x="571" y="171" text-anchor="middle">a learned change: Wilson bound vs live;</text>
  <text class="small" x="571" y="186" text-anchor="middle">a logical fix: builds + smoke games</text>
  <path class="flow dash" d="M468,92 L108,132" marker-end="url(#arrow)"/>
  <text class="small" x="540" y="110" text-anchor="middle">size and pass bar fixed before each match</text>
</svg>
<figcaption>Every gate a network, search or bot passes before it is used or released. The release rules are owned by <code>planning/roadmap.md</code> ("Release").</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-wilson">
<h3>Wilson bounds</h3>
<p>A match result is a sample: 27 wins in 40 games is 67.5%, but the true win rate could easily be lower. The Wilson score interval gives the range of win rates consistent with the result at a chosen confidence, and behaves well for small samples and rates near 0 or 1, where the simple ±2 standard errors doesn't. The gate asks whether the interval's lower end, at 95%, is above 50%: is the new version better, not just luckier? The search bot's 27–13 against the plain bot gives 0.52 to 0.80, so it passes. Its 27–73 against foil-0039 gives 0.19 to 0.36, so it doesn't. A larger match narrows the interval, which is why gate sizes are chosen in advance.</p>
</aside>
<p>Aggregate numbers say whether the bot wins, not why. Reviewing individual decisions with the candidates, scores and search verdict on screen is how a wrong belief, a missing option or a misjudged value is found, and the value-lost report above points the review at the decisions that cost the most.</p>
<h2 id="strategic">Strategic improvement from review</h2>
<p>A learned bot can still make a mistake a person can see is plainly wrong: in a replay, a rare position where a move kills the enemy queen and the bot doesn't play it. This section is how such a mistake becomes a lasting correction rather than a hope that more training fixes it.</p>
<p>The routes already exist. Part 7's decision review shows, for each decision, the candidates, the network's scores and value, and the search's verdict, so the reviewer can see where the right move was lost. Part 3's candidate generators are hand-written, so a move that was never offered is fixed in logic. The release policy (`planning/roadmap.md`, Release) lets a <em>logical fix</em>, a change that stops the bot throwing a game in a specific, identified situation, go live once it builds and its smoke games (a few games checking it plays without a failed turn) show no failed turns, without the statistical gate a learned change needs. The Game knowledge section records the reviewer's notes for the options, rewards and review.</p>
<p>Each reviewed mistake is classified by where it was lost, because each place has a different fix.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 330" role="img" aria-label="Classifying a reviewed mistake, such as a missed queen kill: if the move wasn't a candidate, add or rewrite a generator; if it was but the network or value rated it low, train on the position; if the search had it but didn't choose it, prove the outcome; every reviewed position joins a library each new version is checked against">
  <rect class="layer" x="230" y="12" width="260" height="56" rx="6"/>
  <text class="head" x="360" y="36" text-anchor="middle">Reviewed mistake</text>
  <text class="small" x="360" y="56" text-anchor="middle">e.g. a queen kill the bot didn't play</text>
  <rect class="bad" x="10" y="110" width="220" height="74" rx="6"/>
  <text class="head" x="120" y="132" text-anchor="middle">Not a candidate</text>
  <text class="small" x="120" y="152" text-anchor="middle">candidate gap: add or rewrite</text>
  <text class="small" x="120" y="168" text-anchor="middle">a generator (part 3), a logical fix</text>
  <rect class="mixed" x="250" y="110" width="220" height="74" rx="6"/>
  <text class="head" x="360" y="132" text-anchor="middle">Candidate, rated low</text>
  <text class="small" x="360" y="152" text-anchor="middle">ranking gap: network or value</text>
  <text class="small" x="360" y="168" text-anchor="middle">misjudged it; train on it (part 5)</text>
  <rect class="neutral" x="490" y="110" width="220" height="74" rx="6"/>
  <text class="head" x="600" y="132" text-anchor="middle">Searched, not chosen</text>
  <text class="small" x="600" y="152" text-anchor="middle">few simulations missed a sure win;</text>
  <text class="small" x="600" y="168" text-anchor="middle">prove the outcome (part 4)</text>
  <path class="flow" d="M290,68 L130,108" marker-end="url(#arrow)"/>
  <path class="flow" d="M360,68 L360,108" marker-end="url(#arrow)"/>
  <path class="flow" d="M430,68 L590,108" marker-end="url(#arrow)"/>
  <rect class="good" x="160" y="236" width="400" height="74" rx="6"/>
  <text class="head" x="360" y="260" text-anchor="middle">Reviewed-positions library</text>
  <text class="small" x="360" y="280" text-anchor="middle">position, correct move and reason; every new version is checked</text>
  <text class="small" x="360" y="296" text-anchor="middle">against it, and the positions train with extra weight</text>
  <path class="flow" d="M120,184 L250,234" marker-end="url(#arrow)"/>
  <path class="flow" d="M360,184 L360,234" marker-end="url(#arrow)"/>
  <path class="flow" d="M600,184 L470,234" marker-end="url(#arrow)"/>
</svg>
<figcaption>Intended design: where a reviewed mistake goes. The proven outcomes and the library are agreed and not yet built (<code>planning/roadmap.md</code>, item 18).</figcaption>
</figure>
<p>Review requires the following two mechanisms for lasting correction. Both remain to be implemented (roadmap item 18).</p>
<p><strong>Proven outcomes in search.</strong> In the bot's search and the teacher's, a move the rules prove wins or loses outright is marked proven instead of averaged as an estimate, by MCTS-Solver (Winands, Björnsson and Saito, 2008). A proven win is always played and a proven loss never is, whatever the network says. Only two kinds of proof are sound in this search. Its tree holds the searching dragon's own decisions, with every other dragon's moves and the hidden state sampled between them, and a child stands for the observation that came back, so a proof can't pass through a transition whose other outcomes were never seen. (a) A root certainty: a move whose outcome the rules fix whatever is hidden, such as one that certainly kills the team's last dragon. (b) A proof over a fully determined segment, where nothing is hidden and no other dragon's move is sampled, such as an endgame with every relevant dragon in view; there proofs propagate up the segment. A queen kill doesn't end the game, since a game ends only when a team is eliminated or at round 500 (<code>planning/rules.md</code>), but it decides the round-500 comparison while our queen lives, so it belongs to the value's targets and the library of reviewed positions rather than to the solver. This is logic, not tuning: it removes a class of mistake rather than making it rarer.</p>
<aside class="oy-card oy-alert" id="c-solver">
<h3>MCTS-Solver</h3>
<p>Ordinary MCTS treats every result as a noisy estimate and averages it, so even a move that wins on the spot needs many visits before its average dominates, and with five or ten simulations it may never get them. MCTS-Solver adds proven values to the tree. A terminal position reached in a simulation is a known win or loss, not an estimate. At a node where we choose, one child proven to win makes the node a proven win. At a node where the opponent chooses, every child must be a proven win for us before the node is. Proofs propagate upward, and a proven move is played without further search. Here a proof is only allowed where nothing hidden could change it: if an unseen enemy could interfere, the outcome stays an estimate.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 200" role="img" aria-label="MCTS-Solver: one child of our node is a proven win, so our node becomes a proven win and the move is played; children that depend on hidden information stay estimates">
  <circle class="good" cx="360" cy="34" r="18"/>
  <text class="small" x="388" y="38">our node: proven win</text>
  <circle class="layer" cx="220" cy="120" r="16"/><text class="small" x="220" y="160" text-anchor="middle">estimate 0.31</text>
  <circle class="layer" cx="360" cy="120" r="16"/><text class="small" x="360" y="160" text-anchor="middle">estimate 0.47</text>
  <text class="small" x="360" y="176" text-anchor="middle">(depends on unseen enemies)</text>
  <circle class="good" cx="500" cy="120" r="16"/><text class="small" x="500" y="160" text-anchor="middle">proven win:</text>
  <text class="small" x="500" y="176" text-anchor="middle">certain queen kill</text>
  <path class="rule" d="M350,50 L228,105 M360,52 L360,104"/>
  <path class="flow" d="M492,106 L374,46" marker-end="url(#arrow)"/>
  <text class="small" x="450" y="70">proof propagates up</text>
</svg>
<figcaption>Textbook: MCTS-Solver's propagation at a node where we choose.</figcaption>
</figure>
<p><strong>A library of reviewed positions.</strong> Each position flagged during review must be kept with the correct move and the reason. Every new bot and network version is checked against the library, so a fixed mistake can't quietly return, as a regression test suite does for code. The same positions enter training with extra weight, labelled by the teacher, so the network learns from exactly the cases it got wrong, the idea behind hard-example mining (Shrivastava, Gupta and Girshick, 2016). It starts once the retrain's networks exist.</p>
<aside class="oy-card oy-alert" id="c-hardexamples">
<h3>Hard examples and regression libraries</h3>
<p>A network trained on millions of ordinary positions sees a rare decisive one, a queen kill in a crowded corner, almost never, so its loss barely notices getting it wrong. Hard-example mining raises the weight of the examples the model currently gets wrong, so training spends its effort where the errors are. Kept as a fixed set, the same examples also work as a regression test: a version that fails one it used to pass has broken something, and the library says which situation.</p>
</aside>
<h2 id="gpu">How the training runs on a GPU</h2>
<p>Parts 5 and 6 run on graphics cards, rented per job or local. Their speed decides how many expert-iteration cycles fit before the Grand Final, so the measurements in this page and the roadmap use a GPU's own vocabulary. This section explains it, with our measured figures.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 258" role="img" aria-label="A GPU: the host queues work; the GPU has 70 streaming multiprocessors, each running many warps of 32 threads, with tensor cores, registers and shared memory, over an L2 cache and device memory">
  <rect class="box" x="8" y="10" width="150" height="56" rx="6"/>
  <text class="head" x="83" y="30" text-anchor="middle">Host (CPU)</text>
  <text class="small" x="83" y="47" text-anchor="middle">queues work on</text>
  <text class="small" x="83" y="62" text-anchor="middle">a stream</text>
  <path class="flow" d="M158,38 L196,38" marker-end="url(#arrow)"/>
  <rect class="frame" x="200" y="8" width="512" height="244" rx="6"/>
  <text class="head" x="456" y="28" text-anchor="middle">GPU: RTX 5070 Ti, 70 streaming multiprocessors (SMs)</text>
  <rect class="layer" x="214" y="40" width="110" height="150" rx="6"/>
  <text class="head" x="269" y="58" text-anchor="middle">SM 1</text>
  <rect class="box" x="224" y="66" width="90" height="18"/>  <text class="small" x="269" y="79" text-anchor="middle">warp: 32 threads</text>
  <rect class="box" x="224" y="88" width="90" height="18"/>  <text class="small" x="269" y="101" text-anchor="middle">warp: 32 threads</text>
  <rect class="box" x="224" y="110" width="90" height="18"/>  <text class="small" x="269" y="123" text-anchor="middle">warp: 32 threads</text>
  <rect class="good" x="224" y="134" width="90" height="18"/>  <text class="small" x="269" y="147" text-anchor="middle">tensor cores</text>
  <text class="small" x="269" y="168" text-anchor="middle">registers,</text>
  <text class="small" x="269" y="182" text-anchor="middle">100 KB shared</text>
  <rect class="layer" x="334" y="40" width="110" height="150" rx="6"/>
  <text class="head" x="389" y="58" text-anchor="middle">SM 2</text>
  <rect class="box" x="344" y="66" width="90" height="18"/>  <text class="small" x="389" y="79" text-anchor="middle">warp: 32 threads</text>
  <rect class="box" x="344" y="88" width="90" height="18"/>  <text class="small" x="389" y="101" text-anchor="middle">warp: 32 threads</text>
  <rect class="box" x="344" y="110" width="90" height="18"/>  <text class="small" x="389" y="123" text-anchor="middle">warp: 32 threads</text>
  <rect class="good" x="344" y="134" width="90" height="18"/>  <text class="small" x="389" y="147" text-anchor="middle">tensor cores</text>
  <text class="small" x="389" y="168" text-anchor="middle">registers,</text>
  <text class="small" x="389" y="182" text-anchor="middle">100 KB shared</text>
  <rect class="layer" x="454" y="40" width="110" height="150" rx="6"/>
  <text class="head" x="509" y="58" text-anchor="middle">SM 3</text>
  <rect class="box" x="464" y="66" width="90" height="18"/>  <text class="small" x="509" y="79" text-anchor="middle">warp: 32 threads</text>
  <rect class="box" x="464" y="88" width="90" height="18"/>  <text class="small" x="509" y="101" text-anchor="middle">warp: 32 threads</text>
  <rect class="box" x="464" y="110" width="90" height="18"/>  <text class="small" x="509" y="123" text-anchor="middle">warp: 32 threads</text>
  <rect class="good" x="464" y="134" width="90" height="18"/>  <text class="small" x="509" y="147" text-anchor="middle">tensor cores</text>
  <text class="small" x="509" y="168" text-anchor="middle">registers,</text>
  <text class="small" x="509" y="182" text-anchor="middle">100 KB shared</text>
  <text class="small" x="580" y="96" text-anchor="start">… 70 SMs in all,</text>
  <text class="small" x="580" y="112" text-anchor="start">each holding up</text>
  <text class="small" x="580" y="128" text-anchor="start">to 48 warps</text>
  <rect class="neutral" x="214" y="198" width="490" height="22" rx="4"/>  <text class="small" x="459" y="213" text-anchor="middle">L2 cache, 48 MB</text>
  <rect class="neutral" x="214" y="224" width="490" height="22" rx="4"/>  <text class="small" x="459" y="239" text-anchor="middle">device memory (DRAM), 16 GB</text>
</svg>
<figcaption>The local card's layout, its figures from <code>cudaGetDeviceProperties</code>. </figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-sm">
<h3>Streaming multiprocessors, warps and occupancy</h3>
<p>A GPU is many small processors, <em>streaming multiprocessors</em> (SMs): the RTX 5070 Ti has 70. A program for it, a <em>kernel</em>, runs as thousands of threads grouped in <em>warps</em> of 32 that execute the same instruction together, so branches that send threads different ways cost time. An SM hides the slowness of memory by switching between many resident warps, up to 48 on this card. How many fit is its <em>occupancy</em>, limited by each block's registers and <em>shared memory</em>, a fast scratch memory each SM has 100 KB of.</p>
<p>Our engine's <code>Observe</code> kernel shows why this matters. Each block of 128 threads used 45 KB of shared memory, so only two blocks fit on an SM: 8 warps of 48, the 16.7% occupancy the roadmap records. With so few warps resident, the SM waits on memory instead of switching to other work.</p>
</aside>
<aside class="oy-card oy-alert" id="c-tensor">
<h3>Tensor cores</h3>
<p>Besides ordinary arithmetic units, each SM has <em>tensor cores</em>: hardware that multiplies small matrix tiles in one operation, in low precision (FP16, BF16, INT8, and on newer cards FP8 and FP4) while accumulating in FP32. Matrix products and convolutions run many times faster on them, but only when the work is shaped for them: the right precision and a memory layout such as channels-last, where a cell's channels sit together. The privileged value's fit runs under BF16 autocast in channels-last memory so cuDNN and cuBLAS use them (<code>tools/learning/README.md</code>). The teacher's own value kernels first ran as plain scalar dot products at 3.9–5.3% of the card's FP32 peak, and an FP16 tensor-core version ran 4.45 times faster on an RTX 5090, within 0.002 of FP32 on 4,096 held-out positions (<code>e7372bd36</code>). The bot's integer network was tried on INT8 tensor cores too, faster for one kernel and slower for another, so only the faster one moves (roadmap).</p>
</aside>
<aside class="oy-card oy-alert" id="c-roofline">
<h3>Compute-bound or memory-bound</h3>
<p>A kernel is limited either by arithmetic or by moving data. Its <em>arithmetic intensity</em> is the operations it does per byte it reads or writes. Below a threshold set by the card's peak arithmetic rate divided by its memory bandwidth, the kernel waits on memory however fast the arithmetic units are. Above it, the arithmetic units are the limit. This is the <em>roofline</em> model, and it decides what helps. Tensor cores and lower precision speed up only compute-bound work. Memory-bound work speeds up by reading less, by reusing data in registers and shared memory, or by packing it tighter, as the value fit's 12 KB boards do. A step that launches thousands of tiny kernels is bound by neither, only by launch overhead, which is what graphs remove.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 222" role="img" aria-label="The roofline: achievable speed rises with arithmetic intensity until it meets the compute peak; left of the corner a kernel is memory-bound, right of it compute-bound">
  <path class="rule" d="M80,180 L680,180 M80,180 L80,20"/>
  <path class="flow" d="M80,170 L330,50 L670,50" marker-end="url(#arrow)"/>
  <text class="small" x="250" y="152" text-anchor="start">memory-bound: speed = bandwidth × intensity</text>
  <text class="small" x="500" y="40" text-anchor="middle">compute-bound: the arithmetic peak</text>
  <text class="small" x="380" y="214" text-anchor="middle">arithmetic intensity (operations per byte)</text>
  <text class="small" x="40" y="100" text-anchor="middle">speed</text>
  <path class="rule" d="M330,50 L330,180"/>
  <text class="small" x="330" y="196" text-anchor="middle">peak ÷ bandwidth</text>
</svg>
<figcaption>Textbook: the roofline model.</figcaption>
</figure>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 244" role="img" aria-label="Eager execution launches each kernel from the host with gaps between; a CUDA graph replays the whole step from one launch; a host sync makes both sides wait">
  <text class="head" x="10" y="26" text-anchor="start">Eager</text>
  <text class="small" x="10" y="44" text-anchor="start">host launches</text>
  <text class="small" x="10" y="58" text-anchor="start">each kernel</text>
  <rect class="box" x="130" y="14" width="40" height="20" rx="3"/>  <text class="small" x="150" y="28" text-anchor="middle">launch</text>
  <rect class="layer" x="174" y="40" width="30" height="20" rx="3"/>  <rect class="box" x="222" y="14" width="40" height="20" rx="3"/>  <text class="small" x="242" y="28" text-anchor="middle">launch</text>
  <rect class="layer" x="266" y="40" width="30" height="20" rx="3"/>  <rect class="box" x="314" y="14" width="40" height="20" rx="3"/>  <text class="small" x="334" y="28" text-anchor="middle">launch</text>
  <rect class="layer" x="358" y="40" width="30" height="20" rx="3"/>  <rect class="box" x="406" y="14" width="40" height="20" rx="3"/>  <text class="small" x="426" y="28" text-anchor="middle">launch</text>
  <rect class="layer" x="450" y="40" width="30" height="20" rx="3"/>  <rect class="box" x="498" y="14" width="40" height="20" rx="3"/>  <text class="small" x="518" y="28" text-anchor="middle">launch</text>
  <rect class="layer" x="542" y="40" width="30" height="20" rx="3"/>  <rect class="box" x="590" y="14" width="40" height="20" rx="3"/>  <text class="small" x="610" y="28" text-anchor="middle">launch</text>
  <rect class="layer" x="634" y="40" width="30" height="20" rx="3"/>  <text class="small" x="400" y="76" text-anchor="middle">GPU waits between short kernels (idle gaps)</text>
  <text class="head" x="10" y="116" text-anchor="start">Graph</text>
  <text class="small" x="10" y="134" text-anchor="start">one launch</text>
  <text class="small" x="10" y="148" text-anchor="start">replays all</text>
  <rect class="box" x="130" y="104" width="40" height="20" rx="3"/>  <text class="small" x="150" y="118" text-anchor="middle">launch</text>
  <rect class="layer" x="176" y="130" width="30" height="20" rx="3"/>  <rect class="layer" x="208" y="130" width="30" height="20" rx="3"/>  <rect class="layer" x="240" y="130" width="30" height="20" rx="3"/>  <rect class="layer" x="272" y="130" width="30" height="20" rx="3"/>  <rect class="layer" x="304" y="130" width="30" height="20" rx="3"/>  <rect class="layer" x="336" y="130" width="30" height="20" rx="3"/>  <text class="small" x="470" y="144" text-anchor="middle">kernels run back to back</text>
  <text class="head" x="10" y="186" text-anchor="start">Host sync</text>
  <text class="small" x="10" y="204" text-anchor="start">host reads a</text>
  <text class="small" x="10" y="218" text-anchor="start">GPU value</text>
  <rect class="layer" x="130" y="174" width="60" height="20" rx="3"/>  <path class="flow" d="M190,184 L238,184" marker-end="url(#arrow)"/>
  <rect class="bad" x="240" y="174" width="110" height="20" rx="3"/>  <text class="small" x="295" y="188" text-anchor="middle">host waits</text>
  <path class="flow" d="M350,184 L398,184" marker-end="url(#arrow)"/>
  <rect class="layer" x="400" y="174" width="60" height="20" rx="3"/>  <text class="small" x="560" y="188" text-anchor="middle">GPU idles while the host decides</text>
  <text class="small" x="360" y="232" text-anchor="middle">a captured graph can hold no host sync: the host can't read a value mid-replay</text>
</svg>
<figcaption>Textbook: eager steps, a captured graph, and a host round trip.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-launch">
<h3>Kernel launches, host round trips and CUDA graphs</h3>
<p>The CPU, called the <em>host</em>, queues kernels on a <em>stream</em>, a first-in, first-out queue of GPU work, and the GPU runs them in order. Each launch costs the host a few microseconds. A small network's training step is hundreds of tiny kernels, so the GPU can finish each one before the host has queued the next, and sits idle between them. Distillation at batch 256 launched 1,670 kernels a step and kept the GPU busy only 14.4% of the time (<code>results/local/gpu-floors-20261006</code>).</p>
<p>A <em>host round trip</em>, or sync, is the host reading a value back from the GPU, such as a loss to log or a count that decides the next step. The host waits for the GPU to finish, then the GPU waits for the host. A <em>CUDA graph</em> records the step once and replays it from one launch, removing the launch gaps. A graph can't contain a sync, because nothing on the host can run in the middle of a replay, and its shapes are fixed, so a batch's variable candidate rows are padded to a capacity (<code>tools/learning/trainer/graph.h</code>).</p>
</aside>
<div class="oy-table-properties"><table>
<caption>Distillation on a rented RTX 3090, positions a second, with and without the captured graph (<code>results/local/card-bench-20261006/3090/distil.tsv</code>)</caption>
<thead><tr><th>Batch</th><th>Eager</th><th>Graph</th></tr></thead>
<tbody>
<tr><td>256</td><td>15,464</td><td>21,444</td></tr>
<tr><td>512</td><td>23,059</td><td>23,805</td></tr>
<tr><td>1,024</td><td>27,118</td><td>25,614</td></tr>
<tr><td>4,096</td><td>29,906</td><td>26,667</td></tr>
<tr><td>8,192</td><td>30,271</td><td>out of memory</td></tr>
</tbody></table></div>
<p>So the graph pays only for small batches, where launches dominate. From batch 1,024 the kernels are long enough to hide their launches, and the graph's padded buffers cost memory, so rented imitation jobs run eagerly. They also have to: in the retrain, the privileged-value and share targets sync with the host inside the step, which a capture can't hold (<code>tools/learning/jobs/imitate.sh</code>, <code>26beb33d8</code>).</p>
<aside class="oy-card oy-alert" id="c-streaming">
<h3>Streaming the training data</h3>
<p>Training data is never written to disk in encoded form. A rented job downloads the recorded games once and replays them on its own GPU with our engine. For the privileged value's fit, a replay thread plays the games, takes both teams' true states every few rounds, and hands over chunks of 256 finished games. A chunk joins a window of the last four, and training draws its batches from the window while the thread replays the next chunk. Board and training work overlap, and a board takes 12 KB packed instead of the engine's 64 KB (<code>trajectories.h</code>). On a 3090 the fit runs about 41,900 positions a second at batch 2,048.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 160" role="img" aria-label="The value fit streams: a replay thread plays recorded games on the GPU, hands over chunks of ended games, which join a window of recent chunks that training draws from while the next chunk replays">
  <rect class="layer" x="8" y="40" width="150" height="64" rx="6"/>
  <text class="head" x="83" y="60" text-anchor="middle">Replay thread</text>
  <text class="small" x="83" y="77" text-anchor="middle">recorded games on</text>
  <text class="small" x="83" y="92" text-anchor="middle">the job's GPU</text>
  <path class="flow" d="M158,72 L196,72" marker-end="url(#arrow)"/>
  <rect class="box" x="198" y="40" width="150" height="64" rx="6"/>
  <text class="head" x="273" y="60" text-anchor="middle">Chunk</text>
  <text class="small" x="273" y="77" text-anchor="middle">256 ended games,</text>
  <text class="small" x="273" y="92" text-anchor="middle">boards packed 12 KB</text>
  <path class="flow" d="M348,72 L386,72" marker-end="url(#arrow)"/>
  <rect class="mixed" x="388" y="40" width="150" height="64" rx="6"/>
  <text class="head" x="463" y="60" text-anchor="middle">Window</text>
  <text class="small" x="463" y="77" text-anchor="middle">last 4 chunks,</text>
  <text class="small" x="463" y="92" text-anchor="middle">λ-return targets</text>
  <path class="flow" d="M538,72 L576,72" marker-end="url(#arrow)"/>
  <rect class="good" x="578" y="40" width="134" height="64" rx="6"/>
  <text class="head" x="645" y="60" text-anchor="middle">Training steps</text>
  <text class="small" x="645" y="77" text-anchor="middle">AdamW,</text>
  <text class="small" x="645" y="92" text-anchor="middle">batches from the window</text>
  <path class="flow dash" d="M645,104 L645,130 L83,130 L83,106" marker-end="url(#arrow)"/>
  <text class="small" x="364" y="148" text-anchor="middle">while the network trains on this chunk, the thread replays the next: nothing is written to disk</text>
</svg>
<figcaption>The privileged value's fit as <code>tools/learning/trainer/trajectories.h</code> and <code>value-fit.cc</code> run it. </figcaption>
</figure>
<p>The value fit's <em>horizon</em> is how it sets TD(λ)'s λ (part 5). Samples are taken every K rounds, and a horizon of H rounds sets λ = 1 − K/H, so a target's bootstrap lies H rounds ahead on average. Each horizon is one job on its own card, and <code>--select</code> keeps the fit with the lowest calibration-set log loss among those that pass the calibration check. The 10-, 50- and 200-round horizons of the auxiliary shares are a separate thing: fixed lookaheads for the share targets (<code>trainer/value.h</code>).</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 156" role="img" aria-label="How a horizon sets TD lambda: lambda equals one minus the spacing over the horizon, so the target bootstraps about H rounds ahead">
  <path class="rule" d="M40,70 L680,70"/>
  <circle class="layer" cx="60" cy="70" r="7"/>  <text class="small" x="60" y="94" text-anchor="middle">round t</text>
  <circle class="layer" cx="180" cy="70" r="7"/>  <text class="small" x="180" y="94" text-anchor="middle">round t+1K</text>
  <circle class="layer" cx="300" cy="70" r="7"/>  <text class="small" x="300" y="94" text-anchor="middle">round t+2K</text>
  <circle class="layer" cx="420" cy="70" r="7"/>  <text class="small" x="420" y="94" text-anchor="middle">round t+3K</text>
  <circle class="layer" cx="540" cy="70" r="7"/>  <text class="small" x="540" y="94" text-anchor="middle">round t+4K</text>
  <circle class="layer" cx="660" cy="70" r="7"/>  <text class="small" x="660" y="94" text-anchor="middle">round t+5K</text>
  <rect class="good" x="640" y="58" width="60" height="24" rx="5"/>  <text class="small" x="670" y="74" text-anchor="middle">outcome</text>
  <path class="flow" d="M60,58 Q 240,10 420,58" marker-end="url(#arrow)"/>
  <text class="small" x="240" y="24" text-anchor="middle">bootstrap H rounds on, in expectation</text>
  <text class="small" x="360" y="124" text-anchor="middle">λ = 1 − K / H  ·  K: --spacing between sampled rounds  ·  H: --horizon</text>
  <text class="small" x="360" y="142" text-anchor="middle">H = 0 gives λ = 0 (the next sample's estimate)  ·  H = ∞ gives λ = 1 (the outcome alone)  ·  one H a job</text>
</svg>
<figcaption>The horizon and λ as <code>loong-value-fit</code> sets them. </figcaption>
</figure>
<p>The <em>value-distillation path</em> carries that fitted value into the bot. The chosen fit becomes <code>value.ten</code>, and the retrain imitates the top teams' moves on both sides of every game while its value head learns from <code>value.ten</code> and its auxiliary head from the recorded standings.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 210" role="img" aria-label="The value-distillation path: recorded games feed the privileged value fit, whose chosen network becomes value.ten; the retrain imitates top teams' moves while its value head learns from value.ten and its auxiliary head from the standings">
  <rect class="box" x="8" y="20" width="170" height="60" rx="6"/>
  <text class="head" x="93" y="40" text-anchor="middle">Recorded games</text>
  <text class="small" x="93" y="57" text-anchor="middle">replayed on the GPU,</text>
  <text class="small" x="93" y="72" text-anchor="middle">both teams' true states</text>
  <path class="flow" d="M178,50 L216,50" marker-end="url(#arrow)"/>
  <rect class="good" x="218" y="20" width="180" height="60" rx="6"/>
  <text class="head" x="308" y="40" text-anchor="middle">Privileged value fit</text>
  <text class="small" x="308" y="57" text-anchor="middle">one horizon a job;</text>
  <text class="small" x="308" y="72" text-anchor="middle">--select by calibration</text>
  <path class="flow" d="M398,50 L436,50" marker-end="url(#arrow)"/>
  <rect class="neutral" x="438" y="20" width="130" height="60" rx="6"/>
  <text class="head" x="503" y="40" text-anchor="middle">value.ten</text>
  <text class="small" x="503" y="57" text-anchor="middle">the chosen fit</text>
  <path class="flow" d="M568,50 L606,50" marker-end="url(#arrow)"/>
  <rect class="layer" x="608" y="10" width="104" height="80" rx="6"/>
  <text class="head" x="660" y="30" text-anchor="middle">Retrain</text>
  <text class="small" x="660" y="47" text-anchor="middle">imitate,</text>
  <text class="small" x="660" y="62" text-anchor="middle">both sides</text>
  <rect class="neutral" x="218" y="110" width="180" height="60" rx="6"/>
  <text class="head" x="308" y="130" text-anchor="middle">Top teams' moves</text>
  <text class="small" x="308" y="147" text-anchor="middle">policy targets</text>
  <path class="flow" d="M398,130 L420,98 L592,98 L606,84" marker-end="url(#arrow)"/>
  <rect class="neutral" x="438" y="110" width="130" height="60" rx="6"/>
  <text class="head" x="503" y="130" text-anchor="middle">standings.tensors</text>
  <text class="small" x="503" y="147" text-anchor="middle">share targets</text>
  <path class="flow" d="M568,140 L640,92" marker-end="url(#arrow)"/>
  <text class="small" x="360" y="196" text-anchor="middle">the retrain's value head learns the privileged value and the outcome; its auxiliary head the shares</text>
</svg>
<figcaption>Part 5's value-distillation path as <code>tools/learning/jobs/imitate.sh</code>'s retrain mode runs it. </figcaption>
</figure>
<p>Which card runs a job is measured, not assumed. Every candidate ran the same three workloads, and the RTX 3090 was the cheapest rented card per unit of work for all three, so per-job rentals default to it. The local RTX 5070 Ti, priced at its measured power draw and an assumed Sydney tariff, does about five times a rented 3090's work per dollar, but it is one card shared with the desktop, at about half a 3090's teacher rate, so rented 3090s carry the large jobs and the local card the short checks. An H100 finishes a single job 2.2 times faster for the teacher and 3.8 times for the value fit, at ten times the price (<code>results/local/card-bench-20261006/summary.md</code>).</p>
<div class="oy-table-properties"><table>
<caption>Work per second on the measured cards and their hourly price, 6 October</caption>
<thead><tr><th>Card</th><th>$/h</th><th>Teacher decisions/s</th><th>Distil positions/s</th><th>Value fit positions/s</th></tr></thead>
<tbody>
<tr><td>RTX 3090</td><td>0.176</td><td>189.6</td><td>30,271</td><td>41,888</td></tr>
<tr><td>RTX 4090</td><td>0.389</td><td>285.9</td><td>44,841</td><td>63,816</td></tr>
<tr><td>RTX 5090</td><td>0.470</td><td>310.1</td><td>58,927</td><td>72,076</td></tr>
<tr><td>L40S</td><td>0.536</td><td>263.3</td><td>45,162</td><td>60,919</td></tr>
<tr><td>A100 SXM4</td><td>0.403</td><td>182.1</td><td>48,053</td><td>62,947</td></tr>
<tr><td>H100 SXM</td><td>1.804</td><td>410.8</td><td>99,723</td><td>157,400</td></tr>
<tr><td>RTX 5070 Ti, local</td><td>0.020–0.045 (electricity)</td><td>103.4</td><td>26,283</td><td>38,470</td></tr>
</tbody></table></div>
<h2 id="budget">Budget</h2>
<p>The judge gives each dragon 100M points a turn, 48 MB of memory and one thread, and a team's submission is at most 4 MB. The rest of the limits are in <code>planning/rules.md</code>. Unless another source is named, the measurements here are in <code>results/local/judge-kernel-cost-20261005/summary.md</code>, taken in the official SDK 1.2.7 compiler and sandbox (the organisers' toolkit, which builds and runs bots exactly as the online judge does).</p>
<p><code>tools/judge/src/metering.zig</code> prices every instruction by its opcode, as the toolkit does. The prices and the rule for when the meter charges are in <code>planning/rules.md</code> (CPU point prices). Every SIMD instruction costs 2 points whatever its lanes. The price doesn't depend on data, so a branch-free kernel's cost is an exact function of its shape. The virtual clock advances one nanosecond per point, so a bot can read its own spending exactly. A pair of clock reads costs 28 points.</p>
<aside class="oy-card oy-alert" id="c-metering">
<h3>Why exact pricing changes how we optimise</h3>
<p>On a real CPU, speed depends on caches, branch prediction and memory latency, and must be measured statistically. In the judge, every instruction has a fixed price and nothing else counts. A cache miss costs nothing extra; a SIMD instruction doing sixteen lanes costs the same as one adding two numbers. So the cost of any code path is a sum we can compute, and optimising means using fewer, wider instructions, not being kind to the cache. It also means a design's cost is known before it is trained, which is why the network is sized from this table.</p>
</aside>
<div class="oy-table-properties"><table>
<caption>Multiply-adds per point by kernel form, measured with the judge's clock</caption>
<thead><tr><th>Kernel form</th><th>Multiply-adds per point</th></tr></thead>
<tbody>
<tr><td>A 2.8M-weight network with int16 dots and weights parsed from a string</td><td>about 0.58</td></tr>
<tr><td>Packed int16 3×3 convolution (<code>results/local/self-play/kernel-cost/summary.md</code>, 30 September)</td><td>0.63</td></tr>
<tr><td>Relaxed int8 dot, C loop, weights through pointers</td><td>0.94–1.18</td></tr>
<tr><td>Relaxed int8 dot, inputs in locals, accumulation chained, weights through pointers</td><td>1.79–1.81</td></tr>
<tr><td>Relaxed int8 dot, weights embedded as immediates, dense layer</td><td>2.86–2.87</td></tr>
<tr><td>The same, 3×3 convolution on the 15×15 crop, 32 and 64 channels</td><td>2.80 and 2.99</td></tr>
</tbody></table></div>
<p>The relaxed dot, <code>i32x4.relaxed_dot_i8x16_i7x16_add_s</code>, does 16 multiply-adds with accumulation in one 2-point instruction. The SDK's compiler accepts it in functions marked <code>target("relaxed-simd")</code> under the judge's fixed flags, and its sandbox runs it. With the second operand in 0..127, every implementation gives the same result, and no intermediate sum can saturate. Acceptance by the online judge hasn't been tested, because a test upload activates a submission.</p>
<p>The compiler adds two points of address arithmetic to every load through a pointer. When the weights are a const array filled by <code>#embed</code> (C23's directive that includes a file's bytes as array data) and read at constant indices, the compiler turns each load into a <code>v128.const</code> immediate. A dot then costs 5 points: the constant, the input from a local and the dot. That makes the ceiling 3.2 multiply-adds a point, before each output's reduction and store.</p>
<p>A probe network of 2.8M random int8 weights and about 9.7M multiply-adds costs 4,493,521 points an evaluation in this integer form, built in 30.1 s to 5.2 MB of WebAssembly, and its layers ran at 2.5–2.65 multiply-adds a point including requantisation (<code>results/local/embedded-kernels-20261005/summary.md</code>). On help.map (64 × 64), with 128 states a filter, a turn of <code>expert-0001</code> costs 17.4M points on average over a whole game (30,554 turns): the network 5.1M, the filters' prediction 3.2M, the reply's write 3.0M, listing the candidates 2.1M, the crop's encoding 1.0M, the overview 0.7M, the turn's distances 0.7M, the pearl chances 0.4M, reading the turn block 0.1M and the rest 1.0M. The remembered map's steps come from a step table kept across turns and refreshed only where edges change, and distances from a bitset breadth-first search (Cormen et al., 2022, chapter 20), each giving the same bytes as the per-cell search. The bot's passes over whole maps and planes use explicit WebAssembly SIMD, 4 to 16 cells an instruction: the overview's planes, transposed into 16-byte records a cell so one instruction combines every channel, the bitset search's masks, the network's bordered maps (a 16 × 16 byte transpose, the bot's crop written into its map directly), the enemy heads' reach, the candidates' enterable cells and the pearl chances. The GPU engine runs the same functions per cell, and native checks compare the two. The belief's cost grows with its state cap: 25.0M, 26.6M, 29.6M and 35.4M a turn at 32, 64, 128 and 255 states, each over a whole game on the same map and seed before these optimisations and the option generators. A search node advances the dragon's memory to its next turn; its leaves one round on start from the root's belief predicted once a turn, so a node costs its encoding, without prediction, and one network evaluation.</p>
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
<figcaption>Where one turn's points go on help.map with 128 states a filter, drawn to scale from the figures in this section; the reserve's width is its placeholder's 6M before the reply term.</figcaption>
</figure>
<p>On help.map the work outside the network costs 12.3M of that 17.4M, so the network and search have about 88M points a turn before the reply reserve. A 32-to-32 trunk layer costs 666,078 points, so 88M pays for about 130 such layers, or about 33 64-channel ones, on the 15 × 15 outputs.</p>
<div class="oy-table-properties"><table>
<caption><code>expert-0001</code>, searching, against its floors and bounds on help.map seed 7 against foil-0039 (18,037 turns at 73.5M points a turn, <code>results/local/bot-floors-20261006/summary.md</code>)</caption>
<thead><tr><th>Component</th><th>Points a turn</th><th>% of its floor</th><th>% of its bound</th><th>Not floored</th></tr></thead>
<tbody>
<tr><td>Network (0001 kernels)</td><td>34.79M</td><td>115%</td><td>121%</td><td>0</td></tr>
<tr><td>Distances and step tables</td><td>7.37M</td><td>149%</td><td>~2,000%</td><td>0</td></tr>
<tr><td>Encoding</td><td>11.82M</td><td>177%</td><td>~1,300%</td><td>3.25M</td></tr>
<tr><td>Filters, with the pearl filter</td><td>8.42M</td><td>148%</td><td>~1,100%</td><td>0.05M</td></tr>
<tr><td>Search and tree</td><td>4.16M</td><td>134%</td><td>~3,500%</td><td>1.48M</td></tr>
<tr><td>Sonar</td><td>0.53M</td><td>≥138%</td><td>~1,800%</td><td>0.06M</td></tr>
</tbody></table></div>
<p>The floor is the fewest points the component's current algorithm can cost, and the bound the fewest any algorithm needs for what it computes. The network is near both. The 0002 kernels, not yet in main-0001, cost 103% of their floor and 108% of the bound, and their incremental stem costs less than the full stem's bound because it does fewer multiply-adds. Everything else sits far further above its bound than above its floor, so its remaining gaps are mostly algorithmic: frontier-bounded distance levels, a dirty-cell list for the step table, incremental overview and crop encodings, a lazy foraging factor for the pearl filter, an overlay instead of a whole-game copy for each sample, and whole-field writes in the sonar's records. The summary gives each function's floor, bound and gap.</p>
<p>The submission carries the raw weights file through <code>#embed</code>. A trained int8 weights file deflated to 67% of its size (<code>results/local/inference-metering-20261005/summary.md</code>), so 4 MB holds about 5.7M trained weights beside the source. Embedded weights cost no points on the first turn. String-parsed weights cost 10–13 points a byte there. Memory isn't binding at these sizes. A 1M-weight layer took 23.8 s to build with the SDK compiler on one host thread and produced 1.7 MB of WebAssembly. The online judge's build-time limit isn't known.</p>
<p>On the RTX 5070 Ti, the CUDA engine in <code>tools/engine</code> plays a self-play step of 2,048 games in about 10 ms, with the belief's filters and the integer network. The teacher searches 195 to 265 decisions a second at 1,024 lanes, with 16 simulations and depth 2 (<code>planning/roadmap.md</code>, item 7). Measured against the card's limits (<code>results/local/gpu-floors-20261006/summary.md</code>):</p>
<ul>
<li>The native teacher keeps the GPU busy for 98% of a step. The engine's <code>Observe</code> and <code>ListCandidates</code> take 48% of its kernel time with privileged leaves and 61.5% with 20-round rollouts.</li>
<li>Distillation spends 85.6% of its step time without GPU work and launches 1,670 kernels a batch.</li>
<li>The privileged value's fit leaves the GPU idle 49.4% of the time.</li>
<li>The teacher value's hand-written convolutions reach 1.0% to 1.3% of the card's dense FP16 tensor rate (the rate of the units built for half-precision matrix products) at 256 positions. An FP16 tensor-core version, checked within 0.002 of the FP32 values on 4,096 held-out positions, runs the value 4.45 times faster on an RTX 5090 (<code>results/local/gpu-floors-20261006/tensor/summary.md</code>).</li>
</ul>
<p>A searched teacher decision is a chain of engine steps, its phases times its depth times the dragons a round, so a teacher step's latency is that chain times one engine step's, and an engine step's floor is set by its observe, its candidate listing and the network. Part 5's parallel simulation shortens the chain and its persistent kernels remove the launches between steps, both without changing a choice; each is reported against that floor.</p>
<p>These bound how much the offline teacher and the league can afford.</p>
<p>Games against registered builds run their WebAssembly on the CPU. With the CUDA engine, 44 complete games of foil-0039 against textbook-0021 took 509 s on the workstation and matched the official SDK byte for byte (<code>results/local/native-execution/cuda-pilot-20261003/summary.md</code>). On one 64-vCPU AWS worker the same pair played 10,000 games at 3.0 games a second, about 19,700 dragon-turns a game (<code>results/local/native-execution/full-match-workload-20261003/summary.md</code>).</p>
<p>Training time is bounded by the competition too, so the offline stages are sized as exactly as the bot. Every bulk stage (dataset extraction, the data feed, training steps and the teacher's search targets) is profiled before its long runs: where its time goes, how fully it uses the CPU and GPU, and its throughput in samples or targets a second. Its limiting resource is removed and the throughput recorded beside the measurements here, and long runs use the fastest measured configuration.</p>
<h2 id="start">Starting point</h2>
<p>These components exist and are current. Each one's README owns its commands. This section lists only what each component is.</p>
<div class="oy-table-properties"><table>
<caption>Current components the seven parts build on</caption>
<thead><tr><th>Component</th><th>What exists</th><th>Serves</th></tr></thead>
<tbody>
<tr><td><code>tools/engine</code></td><td>Fixed-array CPU and CUDA simulation of the queen rules, batched games through a C interface, and the integer network's GPU kernels. It runs the bot library's encoder, candidates and sonar, and passed lockstep checks against the official engine (both run the same games step by step and must agree on every state).</td><td>5, 6</td></tr>
<tr><td><code>bots/expert/lib</code></td><td>The rules engine compiled into the bot (<code>rules</code>), the remembered map, symmetry and tensors (<code>belief</code>), the filters over other dragons and pearls (<code>filters</code>), sonar, the turn's encoder and sonar choice (<code>turn</code>), the crop (<code>crop</code>), the network's input bytes (<code>features</code>), the candidates with the option generators for harvest, escape, the queen strike, feeding, the rearguard, accepting a joint play and feeding deaths (<code>candidates</code>), the games sampled from the belief and the distance table (<code>search</code>), the search tree (<code>tree</code>), the bot's C++ turn (<code>bot</code>), the network (<code>network</code>), the generator of integer layers with embedded weights (<code>techniques/neural/embedded</code>), SPECK and the enemy sonar signatures.</td><td>1, 2, 3, 4</td></tr>
<tr><td><code>bots/expert/0001</code></td><td>The first expert bot: the queen-era retrain of the kickstart's network, searching with <code>tree/0002.h</code> with the root's Gumbel draws at zero.</td><td>4, 7</td></tr>
<tr><td><code>tools/learning</code></td><td>The C++ trainer (imitation, distillation, the privileged value's fit and the data feed) and the teacher's gate in C++ and CUDA, beside the Python programs they are replacing: the mimics, self-play with the teacher's search on the GPU engine, and the GPU replay of recorded games.</td><td>2, 5, 6</td></tr>
<tr><td><code>bots/common/runtime</code></td><td>The protocol runtime every Nim and C bot uses.</td><td>All</td></tr>
<tr><td><code>tools/judge</code>, <code>tools/evaluation</code></td><td>The Zig judge, the build registry, the fleet, round robins, verdicts and the opponent pool. Pool opponents whose source was deleted play from their registered builds.</td><td>6, 7</td></tr>
<tr><td><code>tools/viewer</code></td><td>The replay viewer, decision recovery and the teacher review.</td><td>7</td></tr>
</tbody></table></div>
<p>The source of every deleted component is at git tag <code>pre-expert</code> or in git history.</p>
<h2 id="knowledge">Game knowledge</h2>
<p>Lessons from replay review and opponent study that the options, rewards and review should account for. Each is labelled with the rules it was observed under.</p>
<ul>
<li><strong>Enemy reach (earlier rules, 28 September).</strong> The foil started 133 of 167 head-on collisions against textbook-main-0024, 89 of them by sprint. A threat model has to include the sprint behind a head.</li>
<li><strong>Population (earlier rules, 28 September).</strong> The foil turned pearls into many dragons, keeping its longest at length 3–8 until round 420, then fed it from 40–51 dragons and finished longer. Under queen scoring, feeding consolidates into the queen instead. Recombination timing must be learned from its effect on queen survival and final length.</li>
<li><strong>Replay requirements from textbook-0026 against foil-0039 (queen rules, 4 October).</strong>
  <ul>
  <li>A child split directly behind its parent can receive a map upload over sonar.</li>
  <li>Re-entering a farmed pocket that already holds teammates crowds them and can kill one.</li>
  <li>A 1×1 dead end is rarely productive.</li>
  <li>Teammates' lengths can often be deduced exactly from observed splits and moves.</li>
  <li>A dragon inside our own view can't be where we believe a teammate is.</li>
  <li>Hard role holds should give way to a decaying persistence, so desperate need can still win.</li>
  </ul></li>
<li><strong>Requirements from earlier replay review (earlier rules, 27–30 September).</strong>
  <ul>
  <li>Arrive at a spawning tile when its attempt is due, instead of chasing pearls already there.</li>
  <li>An enemy that wants to live dodges a straight strike, so aim at the inner corner of its likely escape.</li>
  <li>Two teammates can seal each other into a pocket two moves deep.</li>
  <li>Late in the game, nearby dragons should consolidate into the scoring dragon, which under queen scoring is the queen.</li>
  <li>A route can collect pearls and reveal unseen ground at once, so collecting and exploring are values of one route, not rival tasks.</li>
  </ul></li>
<li><strong>Option requirements (30 September).</strong>
  <ul>
  <li>Anaconda ring: a long dragon encloses a large space as a ring around a farming area, then turns inside itself. It stays one sprint from safety, and an enemy caught inside costs a cheap split. It can't send sonar from inside.</li>
  <li>Tail lurker: a small dragon waits at the enemy queen's tail to take the head of anything it splits off.</li>
  <li>Rearguard: a length-2 dragon follows our queen and sends sonar of its rear, showing its escape route and where a rival's split could come from.</li>
  </ul></li>
</ul>
<h2 id="explored">Explored ideas not in the current design</h2>
<p>These methods were studied, and several were built, while the bot's training was designed. Most come from the reinforcement-learning line that preceded expert iteration, whose plan and measurements are in <code>planning/research/self-play.md</code> at git tag <code>pre-expert</code>. None is in the current design unless marked so. Each is a candidate for an equal-cost comparison under part 2's network-shape rule, roadmap item 11, or part 5's decision record. The current network started small and plain so the expert-iteration loop could be built and measured first. The RL line's larger, more elaborate networks didn't turn into strength: its distilled student scored 0.19 to 0.32 against the foil over 216 games a snapshot.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 300" role="img" aria-label="Where each explored idea would act: teacher network, student network, training objective, optimiser and precision; each marked as in the design, tried in the reinforcement-learning line, or not run">
  <rect class="frame" x="8" y="10" width="170" height="220" rx="6"/>
  <text class="head" x="93" y="32" text-anchor="middle">Teacher network</text>
  <rect class="good" x="16" y="46" width="154" height="26" rx="13"/><text class="small" x="93" y="63" text-anchor="middle">auxiliary prediction heads</text>
  <rect class="mixed" x="16" y="86" width="154" height="26" rx="13"/><text class="small" x="93" y="103" text-anchor="middle">mixture of experts</text>
  <rect class="mixed" x="16" y="126" width="154" height="26" rx="13"/><text class="small" x="93" y="143" text-anchor="middle">FiLM conditioning</text>
  <rect class="frame" x="186" y="10" width="170" height="220" rx="6"/>
  <text class="head" x="271" y="32" text-anchor="middle">Student network (bot)</text>
  <rect class="good" x="194" y="46" width="154" height="26" rx="13"/><text class="small" x="271" y="63" text-anchor="middle">quantisation-aware training</text>
  <rect class="mixed" x="194" y="86" width="154" height="26" rx="13"/><text class="small" x="271" y="103" text-anchor="middle">n-tuple tables</text>
  <rect class="mixed" x="194" y="126" width="154" height="26" rx="13"/><text class="small" x="271" y="143" text-anchor="middle">routed expert pairs</text>
  <rect class="mixed" x="194" y="166" width="154" height="26" rx="13"/><text class="small" x="271" y="183" text-anchor="middle">FiLM-style conditioning</text>
  <rect class="frame" x="364" y="10" width="170" height="220" rx="6"/>
  <text class="head" x="449" y="32" text-anchor="middle">Training objective</text>
  <rect class="good" x="372" y="46" width="154" height="26" rx="13"/><text class="small" x="449" y="63" text-anchor="middle">multi-step value targets</text>
  <rect class="neutral open" x="372" y="86" width="154" height="26" rx="13"/><text class="small" x="449" y="103" text-anchor="middle">multi-teacher distillation</text>
  <rect class="neutral open" x="372" y="126" width="154" height="26" rx="13"/><text class="small" x="449" y="143" text-anchor="middle">GRPO group advantages</text>
  <rect class="frame" x="542" y="10" width="170" height="220" rx="6"/>
  <text class="head" x="627" y="32" text-anchor="middle">Optimiser, precision</text>
  <rect class="neutral open" x="550" y="46" width="154" height="26" rx="13"/><text class="small" x="627" y="63" text-anchor="middle">FP8 / FP4 training</text>
  <rect class="neutral open" x="550" y="86" width="154" height="26" rx="13"/><text class="small" x="627" y="103" text-anchor="middle">Muon</text>
  <rect class="good" x="8" y="250" width="150" height="26" rx="13"/><text class="small" x="83" y="267" text-anchor="middle">in this design</text>
  <rect class="mixed" x="176" y="250" width="190" height="26" rx="13"/><text class="small" x="271" y="267" text-anchor="middle">tried in the RL line</text>
  <rect class="neutral open" x="384" y="250" width="190" height="26" rx="13"/><text class="small" x="479" y="267" text-anchor="middle">planned or never run</text>
</svg>
<figcaption>Where each explored idea would act, and how far each got. The RL line is the reinforcement-learning design before this one, at git tag <code>pre-expert</code>.</figcaption>
</figure>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 170" role="img" aria-label="Auxiliary prediction heads: a shared body feeds the main value head and extra heads predicting nearer futures, each trained by its own loss">
  <rect class="layer" x="10" y="55" width="140" height="50" rx="6"/>
  <text class="head" x="80" y="85" text-anchor="middle">Shared body</text>
  <rect class="good" x="230" y="8" width="170" height="32" rx="6"/>
  <text class="head" x="315" y="29" text-anchor="middle">value: outcome</text>
  <path class="flow" d="M150,80 L228,24" marker-end="url(#arrow)"/>
  <rect class="mixed" x="230" y="48" width="170" height="32" rx="6"/>
  <text class="head" x="315" y="69" text-anchor="middle">10 rounds on</text>
  <path class="flow" d="M150,80 L228,64" marker-end="url(#arrow)"/>
  <rect class="mixed" x="230" y="88" width="170" height="32" rx="6"/>
  <text class="head" x="315" y="109" text-anchor="middle">50 rounds on</text>
  <path class="flow" d="M150,80 L228,104" marker-end="url(#arrow)"/>
  <rect class="mixed" x="230" y="128" width="170" height="32" rx="6"/>
  <text class="head" x="315" y="149" text-anchor="middle">200 rounds on</text>
  <path class="flow" d="M150,80 L228,144" marker-end="url(#arrow)"/>
  <text class="small" x="560" y="40" text-anchor="middle">each head adds its own loss;</text>
  <text class="small" x="560" y="58" text-anchor="middle">the extra targets teach the body</text>
  <text class="small" x="560" y="76" text-anchor="middle">what matters sooner and more often,</text>
  <text class="small" x="560" y="94" text-anchor="middle">which the main value then reads</text>
</svg>
<figcaption>Textbook: auxiliary prediction heads, as part 5 uses them for the 10-, 50- and 200-round shares.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-aux">
<h3>Auxiliary prediction heads and multi-token prediction</h3>
<p>An auxiliary head is an extra output trained to predict something other than the main target. Its loss shapes the shared body's features. UNREAL (Jaderberg et al., 2017) showed that auxiliary tasks speed up reinforcement learning, because the body learns useful structure from dense signals long before the sparse reward arrives. Language models do the same with multi-token prediction: DeepSeek-V3 and V4 add modules that predict tokens beyond the next one (Gloeckle et al., 2024; DeepSeek-AI, 2024 and 2026).</p>
<p><strong>Here.</strong> In the design. Part 5's training-only auxiliary head predicts the team's shares of units, total length and longest dragon 10, 50 and 200 rounds on, and is never exported. The RL line's teacher had prediction heads for unseen countdowns, enemy heads a few rounds ahead and its own future length.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 190" role="img" aria-label="Mixture of experts: a router picks two of several expert networks for each input, and their outputs are combined">
  <rect class="box" x="10" y="60" width="120" height="50" rx="6"/>
  <text class="head" x="70" y="90" text-anchor="middle">Features</text>
  <rect class="layer" x="190" y="60" width="110" height="50" rx="6"/>
  <text class="head" x="245" y="82" text-anchor="middle">Router</text>
  <text class="small" x="245" y="99" text-anchor="middle">scores experts</text>
  <rect class="neutral open" x="360" y="10" width="110" height="22" rx="5"/>  <text class="small" x="415" y="25" text-anchor="middle">expert 1</text>
  <rect class="good" x="360" y="36" width="110" height="22" rx="5"/>  <text class="small" x="415" y="51" text-anchor="middle">expert 2</text>
  <rect class="neutral open" x="360" y="62" width="110" height="22" rx="5"/>  <text class="small" x="415" y="77" text-anchor="middle">expert 3</text>
  <rect class="neutral open" x="360" y="88" width="110" height="22" rx="5"/>  <text class="small" x="415" y="103" text-anchor="middle">expert 4</text>
  <rect class="good" x="360" y="114" width="110" height="22" rx="5"/>  <text class="small" x="415" y="129" text-anchor="middle">expert 5</text>
  <rect class="neutral open" x="360" y="140" width="110" height="22" rx="5"/>  <text class="small" x="415" y="155" text-anchor="middle">expert 6</text>
  <path class="flow" d="M130,85 L188,85" marker-end="url(#arrow)"/>
  <path class="flow" d="M300,78 L358,47" marker-end="url(#arrow)"/>
  <path class="flow" d="M300,92 L358,125" marker-end="url(#arrow)"/>
  <rect class="layer" x="540" y="60" width="170" height="50" rx="6"/>
  <text class="head" x="625" y="82" text-anchor="middle">Weighted sum</text>
  <text class="small" x="625" y="99" text-anchor="middle">of the chosen experts</text>
  <path class="flow" d="M470,47 L538,78" marker-end="url(#arrow)"/>
  <path class="flow" d="M470,125 L538,92" marker-end="url(#arrow)"/>
  <text class="small" x="415" y="180" text-anchor="middle">top-2 of 6 shown; soft MoE blends all experts by learned weights instead</text>
</svg>
<figcaption>Textbook: a mixture-of-experts layer. Only the chosen experts compute, so capacity grows without growing the cost of each input.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-moe">
<h3>Mixture of experts</h3>
<p>A mixture-of-experts (MoE) layer holds several expert sub-networks and a router that picks a few of them for each input (Shazeer et al., 2017). The model gains capacity while each input pays for only the experts it uses. Soft MoE blends every expert with learned weights instead of choosing (Puigcerver et al., 2024), and Obando-Ceron and colleagues (2024) found it lets deep RL networks scale where plain networks stop improving. Large language models such as Gemma 4's 26B model, with about 4B parameters active per token, and DeepSeek-V4 are built this way.</p>
<p><strong>Here.</strong> Tried in the RL line, not in the current design. Its teacher had two top-2-of-16 MoE layers whose routers read its recurrent memory, and its student ran one of four expert pairs a turn. In the judge, an expert that isn't chosen costs no points, so MoE suits the bot's budget. Whether it beats a plain network of equal measured cost is item 11's question.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 170" role="img" aria-label="FiLM: scalars pass through a small network giving a scale and shift per channel, which modulate a layer's feature map">
  <rect class="box" x="10" y="20" width="150" height="50" rx="6"/>
  <text class="head" x="85" y="42" text-anchor="middle">Scalars</text>
  <text class="small" x="85" y="59" text-anchor="middle">round, length, units</text>
  <rect class="layer" x="220" y="20" width="150" height="50" rx="6"/>
  <text class="head" x="295" y="42" text-anchor="middle">Small network</text>
  <text class="small" x="295" y="59" text-anchor="middle">one per layer</text>
  <path class="flow" d="M160,45 L218,45" marker-end="url(#arrow)"/>
  <rect class="box" x="10" y="100" width="150" height="50" rx="6"/>
  <text class="head" x="85" y="122" text-anchor="middle">Feature map</text>
  <text class="small" x="85" y="139" text-anchor="middle">a layer's channels</text>
  <rect class="layer" x="430" y="100" width="170" height="50" rx="6"/>
  <text class="head" x="515" y="122" text-anchor="middle">γ · features + β</text>
  <text class="small" x="515" y="139" text-anchor="middle">per channel</text>
  <path class="flow" d="M370,38 L470,98" marker-end="url(#arrow)"/>
  <text class="small" x="440" y="74" text-anchor="middle">γ, β</text>
  <path class="flow" d="M160,125 L428,125" marker-end="url(#arrow)"/>
  <rect class="good" x="640" y="100" width="70" height="50" rx="6"/>
  <text class="head" x="675" y="130" text-anchor="middle">Next</text>
  <path class="flow" d="M600,125 L638,125" marker-end="url(#arrow)"/>
</svg>
<figcaption>Textbook: FiLM conditioning, applied at every layer it is used in.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-film">
<h3>FiLM and per-layer conditioning</h3>
<p>Feature-wise linear modulation (Perez et al., 2018) lets a few global numbers steer every layer: a small network turns them into a scale γ and shift β for each channel, applied as γ·features + β. The round, the dragon's length and the team's size could change what every layer looks for, instead of entering once at the end. Gemma 4's smaller models use a related idea, per-layer embeddings: each layer gets its own small embedding of each token.</p>
<p><strong>Here.</strong> Tried in the RL line's teacher, whose eight residual blocks were each conditioned on the scalars by FiLM. The current network reads its scalars once, into the global vector (part 2's figure). Per-layer conditioning is a candidate shape for item 11.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 160" role="img" aria-label="An n-tuple network: fixed groups of cells index lookup tables, and the looked-up weights sum to a value">
  <rect class="good" x="20" y="20" width="20" height="20"/>
  <rect class="good" x="42" y="20" width="20" height="20"/>
  <rect class="good" x="64" y="20" width="20" height="20"/>
  <rect class="neutral" x="86" y="20" width="20" height="20"/>
  <rect class="neutral" x="108" y="20" width="20" height="20"/>
  <rect class="good" x="20" y="42" width="20" height="20"/>
  <rect class="neutral" x="42" y="42" width="20" height="20"/>
  <rect class="neutral" x="64" y="42" width="20" height="20"/>
  <rect class="neutral" x="86" y="42" width="20" height="20"/>
  <rect class="neutral" x="108" y="42" width="20" height="20"/>
  <rect class="neutral" x="20" y="64" width="20" height="20"/>
  <rect class="neutral" x="42" y="64" width="20" height="20"/>
  <rect class="mixed" x="64" y="64" width="20" height="20"/>
  <rect class="neutral" x="86" y="64" width="20" height="20"/>
  <rect class="neutral" x="108" y="64" width="20" height="20"/>
  <rect class="neutral" x="20" y="86" width="20" height="20"/>
  <rect class="neutral" x="42" y="86" width="20" height="20"/>
  <rect class="mixed" x="64" y="86" width="20" height="20"/>
  <rect class="mixed" x="86" y="86" width="20" height="20"/>
  <rect class="neutral" x="108" y="86" width="20" height="20"/>
  <rect class="neutral" x="20" y="108" width="20" height="20"/>
  <rect class="neutral" x="42" y="108" width="20" height="20"/>
  <rect class="neutral" x="64" y="108" width="20" height="20"/>
  <rect class="mixed" x="86" y="108" width="20" height="20"/>
  <rect class="neutral" x="108" y="108" width="20" height="20"/>
  <text class="small" x="75" y="148" text-anchor="middle">board: two 4-cell tuples</text>
  <rect class="good" x="200" y="20" width="190" height="46" rx="6"/>
  <text class="head" x="295" y="40" text-anchor="middle">Tuple 1 → index</text>
  <text class="small" x="295" y="57" text-anchor="middle">its cells' states, base k</text>
  <rect class="mixed" x="200" y="84" width="190" height="46" rx="6"/>
  <text class="head" x="295" y="104" text-anchor="middle">Tuple 2 → index</text>
  <text class="small" x="295" y="121" text-anchor="middle">its cells' states, base k</text>
  <rect class="box" x="440" y="20" width="130" height="46" rx="6"/>
  <text class="head" x="505" y="40" text-anchor="middle">Table 1</text>
  <text class="small" x="505" y="57" text-anchor="middle">one weight per index</text>
  <rect class="box" x="440" y="84" width="130" height="46" rx="6"/>
  <text class="head" x="505" y="104" text-anchor="middle">Table 2</text>
  <text class="small" x="505" y="121" text-anchor="middle">one weight per index</text>
  <rect class="layer" x="610" y="52" width="100" height="46" rx="6"/>
  <text class="head" x="660" y="80" text-anchor="middle">Σ = value</text>
  <path class="flow" d="M135,40 L198,43" marker-end="url(#arrow)"/>
  <path class="flow" d="M135,80 L198,107" marker-end="url(#arrow)"/>
  <path class="flow" d="M390,43 L438,43" marker-end="url(#arrow)"/>
  <path class="flow" d="M390,107 L438,107" marker-end="url(#arrow)"/>
  <path class="flow" d="M570,43 L608,68" marker-end="url(#arrow)"/>
  <path class="flow" d="M570,107 L608,82" marker-end="url(#arrow)"/>
</svg>
<figcaption>Textbook: an n-tuple network. Evaluation is a few table lookups and adds, with no multiplications.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-ntuple">
<h3>N-tuple tables</h3>
<p>An n-tuple network values a board by looking at fixed groups of cells: each group's contents form an index into a table of learned weights, and the value is the sum of the weights looked up. Buro's Logistello used such patterns to beat the Othello world champion (Buro, 1999), and Szubert and Jaśkowski (2014) trained them by temporal-difference learning to play 2048 well. DeepSeek's Engram brings the same idea to language models: large hashed tables of n-gram embeddings, looked up in constant time beside the network (DeepSeek-AI, 2026).</p>
<p><strong>Here.</strong> Tried in the RL line's student, which carried 13 n-tuple tables over the fresh view and the overview. In the judge a table lookup costs a few points where a network evaluation costs about 4.24M, so roadmap item 17 names linear or n-tuple tables distilled from the bot's value head as the first contender for a cheap leaf evaluator, giving a turn many more simulations.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 190" role="img" aria-label="Multi-teacher on-policy distillation: the student plays its own games and several specialist teachers score its positions, and the student learns from all of them">
  <rect class="layer" x="10" y="60" width="150" height="50" rx="6"/>
  <text class="head" x="85" y="82" text-anchor="middle">Student</text>
  <text class="small" x="85" y="99" text-anchor="middle">plays its own games</text>
  <path class="flow" d="M160,85 L218,85" marker-end="url(#arrow)"/>
  <rect class="box" x="220" y="60" width="150" height="50" rx="6"/>
  <text class="head" x="295" y="82" text-anchor="middle">Its positions</text>
  <text class="small" x="295" y="99" text-anchor="middle">and its moves</text>
  <rect class="mixed" x="430" y="8" width="220" height="36" rx="6"/>
  <text class="head" x="540" y="31" text-anchor="middle">specialist: harvest maps</text>
  <path class="flow" d="M370,85 L428,26" marker-end="url(#arrow)"/>
  <rect class="mixed" x="430" y="58" width="220" height="36" rx="6"/>
  <text class="head" x="540" y="81" text-anchor="middle">specialist: open maps</text>
  <path class="flow" d="M370,85 L428,76" marker-end="url(#arrow)"/>
  <rect class="mixed" x="430" y="108" width="220" height="36" rx="6"/>
  <text class="head" x="540" y="131" text-anchor="middle">specialist: an opponent style</text>
  <path class="flow" d="M370,85 L428,126" marker-end="url(#arrow)"/>
  <text class="small" x="360" y="178" text-anchor="middle">each specialist scores the student's own moves; the student minimises reverse KL to them</text>
</svg>
<figcaption>Textbook: on-policy distillation from several specialist teachers.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-multiteacher">
<h3>Multi-teacher on-policy distillation</h3>
<p><em>On-policy</em> distillation trains the student on positions from its own games, scored by the teacher, rather than on the teacher's games (Agarwal et al., 2024). The student then learns to recover from its own mistakes, which positions from a stronger player never show it. With several teachers, each a specialist, the student learns all their skills: Distral (Teh et al., 2017) distils task-specific policies into a shared one, and DeepSeek-V4 trains specialists for mathematics, coding, agents and instruction following, then distils them into one model by minimising reverse KL on the student's own outputs (DeepSeek-AI, 2026). Reverse KL, KL(student ‖ teacher), penalises the student for putting probability where the teacher puts little, so it commits to the teacher's preferred moves instead of spreading over all of them.</p>
<p><strong>Here.</strong> Planned in the RL line, never run: specialists fine-tuned by map type and opponent style, distilled on-policy into one student. The current teacher is a single search. Specialist teachers, such as one per map family or per opponent mimic, would fit part 5 as more teachers scoring the same student positions.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 170" role="img" aria-label="GRPO: several actions are sampled from the same state, and each one's advantage is its reward relative to the group's mean and spread, without a learned critic">
  <rect class="box" x="10" y="60" width="110" height="50" rx="6"/>
  <text class="head" x="65" y="90" text-anchor="middle">One state</text>
  <rect class="layer" x="170" y="8" width="120" height="32" rx="6"/>
  <text class="head" x="230" y="29" text-anchor="middle">sample 1</text>
  <path class="flow" d="M120,85 L168,24" marker-end="url(#arrow)"/>
  <rect class="neutral" x="330" y="8" width="90" height="32" rx="6"/>
  <text class="head" x="375" y="29" text-anchor="middle">reward r1</text>
  <path class="flow" d="M290,24 L328,24" marker-end="url(#arrow)"/>
  <rect class="layer" x="170" y="48" width="120" height="32" rx="6"/>
  <text class="head" x="230" y="69" text-anchor="middle">sample 2</text>
  <path class="flow" d="M120,85 L168,64" marker-end="url(#arrow)"/>
  <rect class="neutral" x="330" y="48" width="90" height="32" rx="6"/>
  <text class="head" x="375" y="69" text-anchor="middle">reward r2</text>
  <path class="flow" d="M290,64 L328,64" marker-end="url(#arrow)"/>
  <rect class="layer" x="170" y="88" width="120" height="32" rx="6"/>
  <text class="head" x="230" y="109" text-anchor="middle">sample 3</text>
  <path class="flow" d="M120,85 L168,104" marker-end="url(#arrow)"/>
  <rect class="neutral" x="330" y="88" width="90" height="32" rx="6"/>
  <text class="head" x="375" y="109" text-anchor="middle">reward r3</text>
  <path class="flow" d="M290,104 L328,104" marker-end="url(#arrow)"/>
  <rect class="layer" x="170" y="128" width="120" height="32" rx="6"/>
  <text class="head" x="230" y="149" text-anchor="middle">sample 4</text>
  <path class="flow" d="M120,85 L168,144" marker-end="url(#arrow)"/>
  <rect class="neutral" x="330" y="128" width="90" height="32" rx="6"/>
  <text class="head" x="375" y="149" text-anchor="middle">reward r4</text>
  <path class="flow" d="M290,144 L328,144" marker-end="url(#arrow)"/>
  <rect class="good" x="470" y="50" width="240" height="70" rx="6"/>
  <text class="head" x="590" y="82" text-anchor="middle">advantage = (r − mean) / std</text>
  <text class="small" x="590" y="99" text-anchor="middle">within the group; no critic</text>
  <path class="flow" d="M420,85 L468,85" marker-end="url(#arrow)"/>
</svg>
<figcaption>Textbook: GRPO's group-relative advantage.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-grpo">
<h3>GRPO: critic-free group advantages</h3>
<p>Policy-gradient methods need to know whether an action was better than usual, its <em>advantage</em>, which PPO estimates with a learned critic. GRPO (Shao et al., 2024), which DeepSeek-R1 used for reasoning (DeepSeek-AI, 2025), drops the critic: it samples a group of actions from the same state, and scores each one's reward against the group's mean and spread. It suits problems where many attempts from one state are cheap and the critic is hard to learn.</p>
<p><strong>Here.</strong> Planned in the RL line for isolated decisions such as splits, never run. Expert iteration takes its targets from search rather than from policy gradients, so GRPO has no direct place in the current loop. It could train a decision where search adds little, if one turns up.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 180" role="img" aria-label="Floating-point formats: FP32, BF16, FP8 and FP4 drawn bit by bit, showing sign, exponent and mantissa widths">
  <text class="small" x="100" y="31" text-anchor="end">FP32</text>
  <rect class="bad" x="110" y="14" width="14" height="24"/>  <rect class="layer" x="124" y="14" width="112" height="24"/>  <rect class="box" x="236" y="14" width="322" height="24"/>
  <text class="small" x="100" y="65" text-anchor="end">BF16</text>
  <rect class="bad" x="110" y="48" width="14" height="24"/>  <rect class="layer" x="124" y="48" width="112" height="24"/>  <rect class="box" x="236" y="48" width="98" height="24"/>
  <text class="small" x="100" y="99" text-anchor="end">FP8 E4M3</text>
  <rect class="bad" x="110" y="82" width="14" height="24"/>  <rect class="layer" x="124" y="82" width="56" height="24"/>  <rect class="box" x="180" y="82" width="42" height="24"/>
  <text class="small" x="100" y="133" text-anchor="end">FP4 E2M1</text>
  <rect class="bad" x="110" y="116" width="14" height="24"/>  <rect class="layer" x="124" y="116" width="28" height="24"/>  <rect class="box" x="152" y="116" width="14" height="24"/>
  <text class="small" x="110" y="166" text-anchor="start">sign · exponent (range) · mantissa (precision), 14 px a bit</text>
</svg>
<figcaption>Textbook: the formats, drawn to scale. FP8 and FP4 need per-block scale factors to cover a tensor's range.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-lowprec">
<h3>FP8 and FP4 training</h3>
<p>Narrower number formats move less data and use faster tensor-core instructions. BF16 keeps FP32's range with less precision. FP8 (Micikevicius et al., 2022) and FP4 need a scale factor per block of values to cover a tensor's range. DeepSeek-V3 trained in FP8, and DeepSeek-V4 adds FP4 quantisation-aware training for its MoE expert weights (DeepSeek-AI, 2024 and 2026). Gemma releases quantisation-aware-trained 4-bit checkpoints for the same reason.</p>
<p><strong>Here.</strong> Planned in the RL line (BF16 first, FP8 once stable, and an NVFP4 comparison on the RTX 5070 Ti), never run. The bot itself runs int8 by quantisation-aware training (part 2). For the offline stages, a lower precision is worth it only where the GPU's arithmetic, not data movement or launch overhead, limits the step. The Budget section's GPU measurements say where that holds.</p>
</aside>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 170" role="img" aria-label="Muon: a matrix's momentum is orthogonalised by Newton–Schulz iterations before being applied as the update">
  <rect class="box" x="10" y="60" width="140" height="50" rx="6"/>
  <text class="head" x="80" y="82" text-anchor="middle">Gradient</text>
  <text class="small" x="80" y="99" text-anchor="middle">a weight matrix</text>
  <path class="flow" d="M150,85 L198,85" marker-end="url(#arrow)"/>
  <rect class="layer" x="200" y="60" width="140" height="50" rx="6"/>
  <text class="head" x="270" y="82" text-anchor="middle">Momentum</text>
  <text class="small" x="270" y="99" text-anchor="middle">running average</text>
  <path class="flow" d="M340,85 L388,85" marker-end="url(#arrow)"/>
  <rect class="layer" x="390" y="60" width="170" height="50" rx="6"/>
  <text class="head" x="475" y="82" text-anchor="middle">Newton–Schulz</text>
  <text class="small" x="475" y="99" text-anchor="middle">orthogonalise it</text>
  <path class="flow" d="M560,85 L608,85" marker-end="url(#arrow)"/>
  <rect class="good" x="610" y="60" width="100" height="50" rx="6"/>
  <text class="head" x="660" y="90" text-anchor="middle">Update</text>
  <text class="small" x="360" y="150" text-anchor="middle">every direction of the update gets the same step size, so rare directions aren't drowned by common ones</text>
</svg>
<figcaption>Textbook: one Muon step for a weight matrix.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-muon">
<h3>Muon</h3>
<p>Muon (Jordan et al., 2024; Liu et al., 2025) is an optimiser for a network's weight matrices. It keeps momentum like Adam, but before applying it, orthogonalises the momentum matrix with a few Newton–Schulz iterations, so the update moves every direction of the matrix by the same amount. DeepSeek-V4 uses it for most of its modules, citing faster convergence and greater training stability (DeepSeek-AI, 2026).</p>
<p><strong>Here.</strong> Not tried. The trainer uses AdamW (part 5). Muon is a contender for the offline stages, measured by strength gained per GPU-second like any other training change.</p>
</aside>
<h3 id="explored-rl">The RL line's other methods</h3>
<p>The reinforcement-learning line trained a policy by trial and error with PPO rather than by imitating a search. These are the methods it used or cited beyond those above. Expert iteration replaced the whole approach, so none is in the current design. The callouts say what each would offer if it came back.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 320" role="img" aria-label="The reinforcement-learning line's other methods, grouped by role, marked as used or only cited">
  <rect class="frame" x="8" y="10" width="134" height="260" rx="6"/>
  <text class="head" x="75" y="30" text-anchor="middle">Policy optimisation</text>
  <rect class="mixed" x="14" y="56" width="122" height="24" rx="12"/><text class="small" x="75" y="72" text-anchor="middle">PPO, 37 details</text>
  <rect class="mixed" x="14" y="86" width="122" height="24" rx="12"/><text class="small" x="75" y="102" text-anchor="middle">GAE</text>
  <rect class="mixed" x="14" y="116" width="122" height="24" rx="12"/><text class="small" x="75" y="132" text-anchor="middle">reward shaping</text>
  <rect class="frame" x="150" y="10" width="134" height="260" rx="6"/>
  <text class="head" x="217" y="30" text-anchor="middle">Imitation</text>
  <text class="small" x="217" y="45" text-anchor="middle">warm starts</text>
  <rect class="mixed" x="156" y="56" width="122" height="24" rx="12"/><text class="small" x="217" y="72" text-anchor="middle">kickstarting</text>
  <rect class="mixed" x="156" y="86" width="122" height="24" rx="12"/><text class="small" x="217" y="102" text-anchor="middle">DAPG demos</text>
  <rect class="neutral open" x="156" y="116" width="122" height="24" rx="12"/><text class="small" x="217" y="132" text-anchor="middle">DAgger</text>
  <rect class="neutral open" x="156" y="146" width="122" height="24" rx="12"/><text class="small" x="217" y="162" text-anchor="middle">DQfD</text>
  <rect class="neutral open" x="156" y="176" width="122" height="24" rx="12"/><text class="small" x="217" y="192" text-anchor="middle">R2D2</text>
  <rect class="frame" x="292" y="10" width="134" height="260" rx="6"/>
  <text class="head" x="359" y="30" text-anchor="middle">Curricula</text>
  <text class="small" x="359" y="45" text-anchor="middle">populations</text>
  <rect class="mixed" x="298" y="56" width="122" height="24" rx="12"/><text class="small" x="359" y="72" text-anchor="middle">level replay</text>
  <rect class="mixed" x="298" y="86" width="122" height="24" rx="12"/><text class="small" x="359" y="102" text-anchor="middle">PFSP league</text>
  <rect class="neutral open" x="298" y="116" width="122" height="24" rx="12"/><text class="small" x="359" y="132" text-anchor="middle">PBT</text>
  <rect class="neutral open" x="298" y="146" width="122" height="24" rx="12"/><text class="small" x="359" y="162" text-anchor="middle">Procgen</text>
  <rect class="frame" x="434" y="10" width="134" height="260" rx="6"/>
  <text class="head" x="501" y="30" text-anchor="middle">Architecture</text>
  <rect class="mixed" x="440" y="56" width="122" height="24" rx="12"/><text class="small" x="501" y="72" text-anchor="middle">residual blocks</text>
  <rect class="mixed" x="440" y="86" width="122" height="24" rx="12"/><text class="small" x="501" y="102" text-anchor="middle">LayerNorm</text>
  <rect class="mixed" x="440" y="116" width="122" height="24" rx="12"/><text class="small" x="501" y="132" text-anchor="middle">GRU memory</text>
  <rect class="neutral open" x="440" y="146" width="122" height="24" rx="12"/><text class="small" x="501" y="162" text-anchor="middle">GroupNorm</text>
  <rect class="neutral open" x="440" y="176" width="122" height="24" rx="12"/><text class="small" x="501" y="192" text-anchor="middle">Neural Map</text>
  <rect class="neutral open" x="440" y="206" width="122" height="24" rx="12"/><text class="small" x="501" y="222" text-anchor="middle">SimBa, BRO</text>
  <rect class="neutral open" x="440" y="236" width="122" height="24" rx="12"/><text class="small" x="501" y="252" text-anchor="middle">Switch MoE</text>
  <rect class="frame" x="576" y="10" width="134" height="260" rx="6"/>
  <text class="head" x="643" y="30" text-anchor="middle">Hierarchy</text>
  <text class="small" x="643" y="45" text-anchor="middle">scale</text>
  <rect class="neutral open" x="582" y="56" width="122" height="24" rx="12"/><text class="small" x="643" y="72" text-anchor="middle">Option-Critic</text>
  <rect class="neutral open" x="582" y="86" width="122" height="24" rx="12"/><text class="small" x="643" y="102" text-anchor="middle">FeUdal</text>
  <rect class="mixed" x="582" y="116" width="122" height="24" rx="12"/><text class="small" x="643" y="132" text-anchor="middle">local SGD</text>
  <rect class="neutral open" x="582" y="146" width="122" height="24" rx="12"/><text class="small" x="643" y="162" text-anchor="middle">DiLoCo</text>
  <rect class="mixed" x="8" y="284" width="170" height="24" rx="12"/><text class="small" x="93" y="300" text-anchor="middle">used in the RL line</text>
  <rect class="neutral open" x="196" y="284" width="190" height="24" rx="12"/><text class="small" x="291" y="300" text-anchor="middle">cited in its plan only</text>
</svg>
<figcaption>Methods the RL line used or cited, from <code>planning/research/self-play.md</code> at <code>pre-expert</code>. None is in the current design.</figcaption>
</figure>
<aside class="oy-card oy-alert" id="c-ppo">
<h3>PPO, GAE and reward shaping</h3>
<p>PPO (Schulman et al., 2017) improves a policy from its own games, limiting each update so the policy can't change too far at once. Huang and colleagues (2022) catalogued the 37 implementation details that make it work. GAE (Schulman et al., 2016) estimates each action's advantage by blending a critic's estimates over many steps, much as TD(λ) blends value targets. Reward shaping adds small intermediate rewards to speed learning, and Ng, Harada and Russell (1999) proved that shaping by differences of a potential function leaves the best policy unchanged.</p>
<p><strong>Here.</strong> The RL line used all three. This design takes its policy targets from search, not policy gradients, and its values are wins, draws and losses without shaping (part 4), so none applies.</p>
</aside>
<aside class="oy-card oy-alert" id="c-warmstart">
<h3>Imitation with feedback: DAgger, DAPG, DQfD, kickstarting, R2D2</h3>
<p>Pure behaviour cloning drifts: once the student makes a mistake it reaches positions the expert never showed it. DAgger (Ross, Gordon and Bagnell, 2011) fixes this by letting the student play and asking the expert to label the positions it actually reaches, the same idea as on-policy distillation. DAPG (Rajeswaran et al., 2018) and DQfD (Hester et al., 2018) mix demonstrations into reinforcement learning. Kickstarting (Schmitt et al., 2018) adds a fading term that pulls a new agent toward a teacher's policy early in training. R2D2 (Kapturowski et al., 2019) trains recurrent agents from replayed experience.</p>
<p><strong>Here.</strong> The RL line used kickstarting and DAPG-style demonstrations from the foil's recorded games. The current kickstart is plain imitation of the top teams (part 5), and expert iteration's later cycles are DAgger-like by construction: the teacher labels positions from the student's own self-play.</p>
</aside>
<aside class="oy-card oy-alert" id="c-curricula">
<h3>Curricula and populations: level replay, PFSP, PBT, Procgen</h3>
<p>Prioritized Level Replay (Jiang et al., 2021) replays the generated levels, here maps, on which the agent's value estimates are most wrong, so training concentrates where there is most to learn. Procgen (Cobbe et al., 2020) showed agents trained on generated levels generalise to unseen ones, the reason this design trains on generated maps. Prioritised fictitious self-play, AlphaStar's matchmaking, picks league opponents the agent beats least often. Population-based training (Jaderberg et al., 2017) runs many agents at once and copies the weights and hyperparameters of the best into the worst.</p>
<p><strong>Here.</strong> The RL line used level replay and a PFSP league. Part 6's league is the current home for both. Level replay is a candidate for choosing which generated maps the league plays.</p>
</aside>
<aside class="oy-card oy-alert" id="c-arch">
<h3>Architecture: residual blocks, normalisation, recurrence, scaling</h3>
<p>Residual blocks (He et al., 2016) add each layer's input to its output, so deep networks train stably. Layer and group normalisation (Ba, Kiros and Hinton, 2016; Wu and He, 2018) rescale activations to keep training well-conditioned. A GRU (Cho et al., 2014) carries a learned memory across turns. Neural Map (Parisotto and Salakhutdinov, 2018) gives an agent a learned spatial memory written like a map. SimBa (Lee et al., 2025) and BRO (Nauman et al., 2024) report that RL networks scale with residual feed-forward blocks, normalisation and regularisation. Switch Transformers (Fedus, Zoph and Shazeer, 2022) route each input to a single expert.</p>
<p><strong>Here.</strong> The RL line's teacher was an eight-block residual network with LayerNorm and a 512-unit GRU. The current network is a plain integer stack without normalisation or recurrence, with memory in the belief instead (part 2). Residual connections, normalisation folded into the integer rescale, and a recurrent candidate are all shapes item 11 can test at equal cost.</p>
</aside>
<aside class="oy-card oy-alert" id="c-hierarchy">
<h3>Learned hierarchy and distributed training: Option-Critic, FeUdal, local SGD, DiLoCo</h3>
<p>Option-Critic (Bacon, Harb and Precup, 2017) learns options themselves, their policies and when to stop, instead of writing them by hand. FeUdal networks (Vezhnevets et al., 2017) have a manager set goals in a learned space that a worker pursues. Local SGD (Lin et al., 2020) and DiLoCo (Douillard et al., 2023) let several GPUs train mostly independently and average their weights occasionally, cutting communication.</p>
<p><strong>Here.</strong> The RL line averaged weights and optimiser state across GPUs every eight steps (local SGD). Part 3's options are hand-written generators. A learned-option method is a contender for part 3's decision record, most useful where the value-lost report keeps finding candidate gaps no generator covers.</p>
</aside>
<h2 id="concepts">Concept index</h2>
<p>Every concept explained on this page, in the order it first appears.</p>
<ul>
<li><a href="#c-pomdp">Partial observability and decentralisation</a> (the game)</li>
<li><a href="#c-rl">Reinforcement learning in one page</a> (the design)</li>
<li><a href="#c-exit">Expert iteration</a> and <a href="#c-ctde">CTDE</a> (the design)</li>
<li><a href="#c-floors">Floors and bounds</a> (principles)</li>
<li><a href="#c-encoding">Encoding, planes and channels</a>, <a href="#c-bayes">Bayes filters</a>, <a href="#c-filters">histogram, Bernoulli and renewal filters</a>, <a href="#c-checkbits">encryption and check bits</a>, <a href="#c-kld">KL divergence and KLD-sampling</a>, <a href="#c-calibration">calibration and informativeness</a> (part 1)</li>
<li><a href="#c-policyvalue">Policy and value heads</a>, <a href="#c-conv">crops, convolutions, stems and trunks</a>, <a href="#c-tokens">set encoders and attention</a>, <a href="#c-quant">quantisation to int8</a>, <a href="#c-simd">WebAssembly, SIMD and the relaxed dot</a>, <a href="#c-nnue">efficiently updatable networks</a> (part 2)</li>
<li><a href="#c-options">The options framework</a>, <a href="#c-stp">skills, tactics and plays</a> (part 3)</li>
<li><a href="#c-mcts">Monte Carlo tree search and PUCT</a>, <a href="#c-ismcts">determinisation and information-set MCTS</a>, <a href="#c-gumbel">Gumbel root search and sequential halving</a>, <a href="#c-chance">chance nodes</a>, <a href="#c-widening">progressive widening</a>, <a href="#c-spsa">SPSA and CLOP</a>, <a href="#c-transposition">transposition tables</a>, <a href="#c-nosearch">playing with no search</a>, <a href="#c-pomcp">POMCP</a>, <a href="#c-pbs">public belief states: ReBeL and Student of Games</a> (part 4)</li>
<li><a href="#c-imitation">Imitation learning</a>, <a href="#c-distil">distillation and cross-entropy</a>, <a href="#c-basics">batches, steps and the learning rate</a>, <a href="#c-adamw">AdamW</a>, <a href="#c-cudagraph">CUDA graphs</a>, <a href="#c-value">value functions, rollouts and privileged critics</a>, <a href="#c-td">TD(λ)</a>, <a href="#c-earlystop">stopping within noise</a>, <a href="#c-gap">the imitation gap</a> (part 5)</li>
<li><a href="#c-league">League training</a> (part 6)</li>
<li><a href="#c-wilson">Wilson bounds</a> (part 7)</li>
<li><a href="#c-solver">MCTS-Solver</a>, <a href="#c-hardexamples">hard examples and regression libraries</a> (strategic improvement)</li>
<li><a href="#c-pdes">Parallel discrete-event simulation</a>, <a href="#c-persistent">persistent kernels</a>, <a href="#c-playoutcap">playout cap randomization</a> (part 5)</li>
<li><a href="#c-sm">streaming multiprocessors, warps and occupancy</a>, <a href="#c-tensor">tensor cores</a>, <a href="#c-roofline">compute- or memory-bound</a>, <a href="#c-launch">launches, host round trips and CUDA graphs</a>, <a href="#c-streaming">streaming the training data</a> (GPU training)</li>
<li><a href="#c-metering">Exact pricing</a> (Budget)</li>
<li><a href="#c-aux">auxiliary heads and multi-token prediction</a>, <a href="#c-moe">mixture of experts</a>, <a href="#c-film">FiLM</a>, <a href="#c-ntuple">n-tuple tables</a>, <a href="#c-multiteacher">multi-teacher on-policy distillation</a>, <a href="#c-grpo">GRPO</a>, <a href="#c-lowprec">FP8 and FP4 training</a>, <a href="#c-muon">Muon</a>, <a href="#c-ppo">PPO, GAE and shaping</a>, <a href="#c-warmstart">DAgger and other warm starts</a>, <a href="#c-curricula">level replay, PFSP, PBT, Procgen</a>, <a href="#c-arch">architecture choices</a>, <a href="#c-hierarchy">learned hierarchy and distributed training</a> (explored ideas)</li>
</ul>
<h2 id="sources">Sources</h2>
<p>Every method on this page, grouped by where it sits. The figure shows the same grouping against the pipeline.</p>
<figure>
<svg class="oy-diagram" viewBox="0 0 720 534" role="img" aria-label="Where each source sits: the overall method across the top; the bot's belief, network, options and search in play; the kickstart, teacher, training and league offline">
  <rect class="frame" x="8" y="8" width="704" height="72" rx="6"/>
  <text class="head" x="20" y="30">Overall method</text>
  <text class="small" x="20" y="50">Anthony et al. (expert iteration) · Silver et al. (AlphaZero) · Lowe et al., Yu et al. (CTDE)</text>
  <text class="small" x="20" y="68">Kaelbling et al. (POMDP) · Bernstein et al. (Dec-POMDP) · Sutton and Barto (reinforcement learning)</text>
  <text class="head" x="20" y="108">In play: each dragon's turn (parts 1–4)</text>
  <rect class="layer" x="8" y="118" width="170" height="222" rx="6"/>
  <text class="head" x="93" y="138" text-anchor="middle">1 Belief, sonar</text>
  <text class="small" x="18" y="158">Thrun et al. (Bayes filters)</text>
  <text class="small" x="18" y="174">Ristic et al. (Bernoulli)</text>
  <text class="small" x="18" y="190">Feller (renewal)</text>
  <text class="small" x="18" y="206">Rabiner (hidden Markov)</text>
  <text class="small" x="18" y="222">Fox (KLD-sampling)</text>
  <text class="small" x="18" y="238">Kullback and Leibler</text>
  <text class="small" x="18" y="254">Guo et al. (calibration)</text>
  <text class="small" x="18" y="270">Beaulieu et al. (SPECK)</text>
  <text class="small" x="18" y="286">Golomb · Teuhola</text>
  <rect class="layer" x="186" y="118" width="170" height="222" rx="6"/>
  <text class="head" x="271" y="138" text-anchor="middle">2 Network</text>
  <text class="small" x="196" y="158">Jacob et al. (QAT)</text>
  <text class="small" x="196" y="174">Bengio et al. (STE)</text>
  <text class="small" x="196" y="190">Nasu (NNUE)</text>
  <text class="small" x="196" y="206">Zaheer et al. (Deep Sets)</text>
  <text class="small" x="196" y="222">Vaswani et al. (attention)</text>
  <rect class="layer" x="364" y="118" width="170" height="222" rx="6"/>
  <text class="head" x="449" y="138" text-anchor="middle">3 Options</text>
  <text class="small" x="374" y="158">Sutton, Precup and Singh</text>
  <text class="small" x="374" y="174">Browning et al. (STP)</text>
  <text class="small" x="374" y="190">Cormen et al. (BFS)</text>
  <rect class="layer" x="542" y="118" width="170" height="222" rx="6"/>
  <text class="head" x="627" y="138" text-anchor="middle">4 Search</text>
  <text class="small" x="552" y="158">Coulom · Kocsis, Szepesvári</text>
  <text class="small" x="552" y="174">Auer et al. (UCB1)</text>
  <text class="small" x="552" y="190">Rosin (PUCT)</text>
  <text class="small" x="552" y="206">Cowling et al. (ISMCTS)</text>
  <text class="small" x="552" y="222">Frank, Basin · Long et al.</text>
  <text class="small" x="552" y="238">Danihelka · Karnin · Kool</text>
  <text class="small" x="552" y="254">Couëtoux et al. (widening)</text>
  <text class="small" x="552" y="270">Winands et al. (solver)</text>
  <text class="small" x="552" y="286">Spall · Coulom (tuning)</text>
  <text class="small" x="552" y="302">Silver, Veness (POMCP)</text>
  <text class="small" x="552" y="318">Brown; Schmid (contenders)</text>
  <text class="head" x="20" y="374">Offline: training (parts 5–6)</text>
  <rect class="box" x="8" y="384" width="170" height="140" rx="6"/>
  <text class="head" x="93" y="404" text-anchor="middle">Kickstart</text>
  <text class="small" x="18" y="424">Vinyals et al. (AlphaStar)</text>
  <text class="small" x="18" y="440">behaviour cloning</text>
  <rect class="box" x="186" y="384" width="170" height="140" rx="6"/>
  <text class="head" x="271" y="404" text-anchor="middle">5 Teacher</text>
  <text class="small" x="196" y="424">Anthony · Silver et al.</text>
  <text class="small" x="196" y="440">Schrittwieser (MuZero)</text>
  <text class="small" x="196" y="456">Pinto et al. (privileged)</text>
  <text class="small" x="196" y="472">Warrington et al. (gap)</text>
  <text class="small" x="196" y="488">Sutton (TD(λ))</text>
  <rect class="box" x="364" y="384" width="170" height="140" rx="6"/>
  <text class="head" x="449" y="404" text-anchor="middle">Network training</text>
  <text class="small" x="374" y="424">Hinton et al. (distillation)</text>
  <text class="small" x="374" y="440">Kingma and Ba (Adam)</text>
  <text class="small" x="374" y="456">Loshchilov, Hutter (AdamW)</text>
  <text class="small" x="374" y="472">Pascanu et al. (clipping)</text>
  <text class="small" x="374" y="488">Shrivastava (hard examples)</text>
  <rect class="box" x="542" y="384" width="170" height="140" rx="6"/>
  <text class="head" x="627" y="404" text-anchor="middle">6 League</text>
  <text class="small" x="552" y="424">Vinyals et al. (AlphaStar)</text>
  <text class="small" x="552" y="440">Berner et al. (OpenAI Five)</text>
  <text class="small" x="552" y="456">Schulman et al. (PPO)</text>
  <text class="small" x="552" y="472">Elo (ratings)</text>
</svg>
<figcaption>Where each source on this page applies.</figcaption>
</figure>
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
<li>Cormen, Leiserson, Rivest and Stein, <em>Introduction to Algorithms</em>, 4th edition (MIT Press, 2022), chapter 20: breadth-first search, in the distances and the room a candidate leaves.</li>
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
<li>Ma and Yarats, On the adequacy of untuned warmup for adaptive optimization (AAAI, 2021): the warm-up length.</li>
<li>Williams, Waterman and Patterson, Roofline: an insightful visual performance model for multicore architectures (<em>Communications of the ACM</em>, 2009).</li>
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
<li>Kaggle Hungry Geese (2021), a four-player snake game on a wrapped board, won by DeNA's HandyRL team (<a href="https://dena.ai/news/kaggle-hungry-geese/">DeNA</a>; <a href="https://github.com/DeNA/HandyRL">HandyRL</a>). DeNA says the team combined recent reinforcement learning with established game AI techniques. The team trained a CNN, designed so convolutions respect the wrapped board, with distributed off-policy deep reinforcement learning in self-play (<a href="https://zenn.dev/ktechb/articles/e2394bc27358c4">a participant's review</a>). At play time it ran MCTS with a linear evaluation function, ensembled with a large network (<a href="https://speakerdeck.com/nagiss/kagglesimiyuresiyonkonpenodong-xiang">a competitor's survey of Kaggle simulation competitions</a>). The team's own write-up on Kaggle couldn't be retrieved. It is the closest published precedent to Loong: wrapped grid, snakes that grow by eating, a learned network with search at play time.</li>
</ul>
<h3 id="sources-explored">Explored ideas</h3>
<ul>
<li>Jaderberg et al., Reinforcement learning with unsupervised auxiliary tasks (ICLR, 2017): UNREAL.</li>
<li>Gloeckle et al., Better and faster large language models via multi-token prediction (ICML, 2024): multi-token prediction.</li>
<li>DeepSeek-AI, DeepSeek-V3 technical report (2024): FP8 training, multi-token prediction and DeepSeekMoE.</li>
<li>DeepSeek-AI, <a href="https://arxiv.org/abs/2606.19348">DeepSeek-V4: Towards Highly Efficient Million-Token Context Intelligence</a> (2026): Muon, FP4 quantisation-aware training of expert weights, and specialists distilled on-policy into one model.</li>
<li>DeepSeek-AI, Conditional Memory via Scalable Lookup: A New Axis of Sparsity for Large Language Models (2026): Engram's hashed n-gram tables.</li>
<li>DeepSeek-AI, DeepSeek-R1: Incentivizing reasoning capability in LLMs via reinforcement learning (2025), and Shao et al., DeepSeekMath (2024): GRPO.</li>
<li>Shazeer et al., Outrageously large neural networks: the sparsely-gated mixture-of-experts layer (ICLR, 2017); Puigcerver et al., From sparse to soft mixtures of experts (ICLR, 2024); Obando-Ceron et al., Mixtures of experts unlock parameter scaling for deep RL (ICML, 2024).</li>
<li>Google, <a href="https://ai.google.dev/gemma/docs/core">Gemma 4 documentation</a>: a 26B mixture-of-experts model with about 4B parameters active, per-layer embeddings in the smaller models, and quantisation-aware-trained checkpoints.</li>
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
<h3 id="sources-earlier">Considered in earlier designs, not used now</h3>
<p>The designs before expert iteration (at git tag <code>pre-expert</code>) cited these. The planning methods were replaced by the learned policy and information-set search above, and the data-structure methods belonged to the earlier belief and route code, which the current library doesn't contain. They stay candidates for part 5's decision records.</p>
<ul>
<li>Nau et al., SHOP2: An HTN Planning System (<em>JAIR</em>, 2003): hierarchical task-network planning, in the earlier team planner.</li>
<li>Gerkey and Matarić, A formal analysis and taxonomy of task allocation in multi-robot systems (<em>IJRR</em>, 2004), Smith, The contract net protocol (<em>IEEE Transactions on Computers</em>, 1980), and Stone and Veloso, Task decomposition, dynamic role assignment, and low-bandwidth communication for real-time strategic teamwork (<em>Artificial Intelligence</em>, 1999): explicit role and task allocation, which the learned choice among options now does.</li>
<li>Harel, Statecharts (1987), Millington and Funge, <em>Artificial Intelligence for Games</em> (2009), and Mark's infinite axis utility system (2009; GDC 2013 and 2015): hand-built behaviour selection.</li>
<li>Rawlings, Mayne and Diehl, <em>Model Predictive Control</em>: first-action execution and replanning.</li>
<li>Knuth and Moore, An analysis of alpha-beta pruning (1975), Luckhardt and Irani, An algorithmic solution of N-person games (AAAI, 1986), and Sturtevant and Korf, On pruning techniques for multi-player games (AAAI, 2000): adversarial search against several opponents.</li>
<li>Dijkstra (1959) and Dial (1969): shortest routes priced by passability; Hoare, Algorithm 65: find (1961): selecting a filter's states; Seidman, Network structure and minimum degree (1983): the 2-core; Gray and Cheriton, Leases (1989): claims that lapse unless renewed; Gelman et al., <em>Bayesian Data Analysis</em> (2013): a Dirichlet prior over edge kinds; Russell and Norvig, <em>Artificial Intelligence: A Modern Approach</em> (2020).</li>
</ul>
  
</div>

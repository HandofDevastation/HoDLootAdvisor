# Loot Advisor

The in-game half of [hodguild.com](https://www.hodguild.com)'s Loot Advisor.

When a boss dies, every raider sees the same ranked answer to **who is each of
these drops actually for, and what would it cost them** — at the moment they
have to decide, without alt-tabbing.

## Installing

**From a release:** unzip into `<WoW>/_retail_/Interface/AddOns/`. It must end
up as `Interface/AddOns/HoDLootAdvisor/HoDLootAdvisor.toc`. Restart WoW — a
`/reload` will not pick up a newly added addon.

## Using it

| | |
|---|---|
| `/la` | open the panel |
| `/la status` | what data is loaded, your spec, the raid payload, diagnostics |
| `/la load` | paste tonight's export from the website |
| `/la roster` | who is actually here, and who we cannot describe yet |
| `/la comms` | who else is running it, and what has been sent and received |

**Most people need none of that.** Install it, and it does the rest by itself.

## The design constraint

**Most of the raid will not install this.** So the system is fully useful with
exactly one installer and gets incrementally better with each additional one.
Nothing is gated behind "enough people have it".

That shapes everything. A raider who is not running the addon is still ranked,
from the website's gear snapshot and from an in-game inspection, and is
**never silently omitted** — an invisible raider is worse than an approximate
one. Where a reading came from is always shown, because "what they are wearing
right now" and "what a snapshot said this morning" are different claims.

## What it deliberately does not do

- **It does not decide loot.** Items are still won on the roll. It informs.
- **It does not talk to the internet.** Addons cannot. Everything arrives baked
  in, pasted in, or over addon comms.
- **It never speaks to the raid on its own.** Chat lines are posted only by a
  deliberate press. The failure mode of a loot addon nobody asked for is spam.
- **It does not show raw scores.** Badge and gap only — the raw number invites
  a precision the model does not have.

## Development

```
lua test/smoke.lua      # the whole addon end to end, no game
lua test/comms.lua      # two clients in one process, no game
lua test/roster.lua     # a raid full of strangers, no game
lua test/parity.lua     # the scorer against the website, 276,480 cases
./package.sh && lua test/package.lua dist/HoDLootAdvisor
```

`parity.lua` needs `test/fixtures.lua`, which is generated rather than
committed — 140 MB of cases produced by the real TypeScript engine at
`/api/loot-advisor/parity-fixtures`.

**Run parity twice — the game runs Lua 5.1 and the full fixture cannot.** Its
single chunk holds more than 5.1's ceiling of 65,536 constants, so a 5.1 parser
refuses the file and every parity run before Session 256 was under 5.4 or 5.5.
The 5.4 run now writes `test/fixtures-sample.lua` — one case per structural
shape, ~8,600 of them — which 5.1 can compile:

```
lua5.4 test/parity.lua   # all 276,480 cases, and writes the sample
luajit test/parity.lua   # the sample, under a 5.1 parser
```

The other harnesses already run under both and should be run both ways too.

**The website is the oracle.** Nothing here may quietly disagree with
`app/lib/loot-advisor.ts`. Any change to scoring is a change to both
implementations, plus a fixture regeneration and a parity re-run.

## Licence

Fonts in `Media/fonts` ship under the SIL Open Font License; see `OFL.txt` and
`FONT-LICENSES.md` beside them. General Sans is by the Indian Type Foundry.

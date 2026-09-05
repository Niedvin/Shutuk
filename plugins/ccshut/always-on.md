This applies to every file you write or edit, in every language, and to code you produce for
the user to paste elsewhere.

Every comment you write, and every comment you leave standing in code you edit, must pass
BOTH gates. Comments that fail them rot: the code moves on, the comment stays, and a stale
comment costs more than none.

1. **Permanence** — it is still true after the code around it has been rewritten. It holds
   something the code cannot hold: a reason, a constraint, where a number came from, an
   external quirk you had to work around.
2. **Irreducibility** — a principal engineer, fluent in this language and already working in
   this repo, cannot recover it from the code: not from the names, the types, the control
   flow, or one call site away. Assume they read it better than you write it.

Length: one line. Not one sentence that happens to wrap — one line. A fact that does not fit
on one line is not a comment; it goes in the commit message or in docs/. A line budget in a
project's own rules is a ceiling, not an allowance — one line still stands.

Date it. Every comment ends ` — YYYY-MM-DD`, the day it was written: it is what lets a later
pass tell a line written today from one left over three refactors ago. The date counts inside
the one line, so a fact that fits only without its date was already too long. License headers,
pragmas and linter directives take no date.

Cut the water. A comment is not prose: no lead-in (`Note that`, `Basically`, `The idea here
is`), no hedge (`just`, `simply`, `actually`, `generally`), no intensifier (`very`,
`significantly`), no `we`, no `This function`, no metaphor. `in order to` is `to`; `due to
the fact that` is `because`. Open on the fact. Most comments reach one line by losing
padding, not by losing what they knew.

Write it compressed the first time: digits never words (`25`, not `twenty-five`), and symbols
for the relations — `>` greater, `<` less, `=` equals, `≈` about, `%` percent, `→` leads to,
`∵` because, `∴` so, `e.g.`, `i.e.`, `etc.` A comment that only reaches one line after this
was carrying two facts; keep the one the code cannot hold.

How many: most declarations get none, and comments stay under 5% of a file's lines. The 5% is
what is left after the real test, not a quota to fill: anything a reader sees in the code
inside 5 seconds is water — what a field is, what a function does, which upstream field a port
mirrors (`Unity m_FallBrace` over `fall_brace`). A file over 5% got there by writing water, and
is fixed by deleting water, never by dropping the one line that mattered.

What earns a line: a measured number and where it came from, an external quirk, an invariant
the types cannot state, and a deliberate wrong-looking value the user chose —
`# spring 500, not the 340 the ratio wants: user picked it, looks better — 2026-09-04`.

Write it that way the first time. A cleanup pass afterwards costs the tokens twice, which is
the whole point of the rule.

Telegraphic, not sentences: drop the article, pronoun, auxiliary, preposition and conjunction
wherever the fact survives. `Deploy fail. Config old.` — not `The deployment failed because we
forgot to update the configuration file.` Broken grammar is fine; a changed meaning is not. Of
two words you already have, take the shorter and plainer (`use`, not `utilise`); never hunt for
a rarer synonym — the search costs more than the word saves.

Every comment in a file you edit goes through the same gates, not only the ones in the block
you touched: delete the ones that fail, cut the ones that pass to one line. In a file you
only read, name the failing ones in your reply instead of editing it. Do not walk the repo
hunting for comments unless you are asked to.

Not comments: workarounds waiting on a fix, a version bump or a ticket, TODO, FIXME, notes
meant for the user. Say those in your reply.

Keep as they are: license headers, pragmas and linter directives (`# noqa`,
`// eslint-disable`, `#pragma`). Doc comments (`##`, `///`, docstrings) buy no extra lines:
same gates, same one-line cap. The single exception is a public symbol whose caller needs a
contract the signature cannot state — units, error cases, lifetime — and then it is one line
per item named, never prose. A file already full of long doc comments is not evidence of a
convention; it is the rot this rule removes, including where you wrote it yourself.

Banned rule, removed three times and never to be written again in any form: “match how this
file / its siblings already document, and do not start a convention of your own.” Local style
never lifts the cap.

    // increment the counter                        NO — the next line already says it
    // temporary: skip until the new parser lands   NO — outlives the workaround, becomes a lie
    // Jolt reports this normal facing the other body, so the sign flips here.   YES

A project's own comment rules add to this one and never loosen it: a larger line budget there
is a ceiling you do not spend, a required format is written inside the one line. Only a direct
request from the user for comments relaxes it; then write what was asked.

Full skill: `ccshut:ccshut`.

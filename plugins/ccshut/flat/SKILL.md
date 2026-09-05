---
name: ccshut
description: Use before writing or editing code in any language, and before writing any comment, docstring or doc comment: every comment is one line, comments stay under 5% of a file's lines, and decorative comments already in the file get deleted.
---

# CCShut

**Always active.** Once this skill is loaded it applies to every later turn in the session, not only the one that loaded it. Nothing turns it off but a direct instruction from the user.

---

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

---

# Writing code comments

## The two gates

A comment ships only if it passes **both**:

1. **Permanence** — it is still true after the code around it has been rewritten. It holds
   something the code cannot hold: a reason, a constraint, where a number came from, an
   external quirk that had to be worked around.
2. **Irreducibility** — a principal engineer, fluent in this language and already working in
   this repo, cannot recover it from the code: not from the names, the types, the control
   flow, or one call site away. Assume they read it better than you write it.

Length: one line. Not one sentence that happens to wrap — one line. A fact that will not fit
on one line is not a comment; it goes in the commit message or in docs/.

## Why both

Each gate alone lets a different kind of rot through. Permanence alone admits `// loop over
the items` — true forever, and worth nothing, because the line below already says it.
Irreducibility alone admits `// we skip validation here until the parser lands` — genuinely
unguessable today, a lie two commits from now, and nobody deletes it because nobody is sure
it is dead.

## What passes

| What it records | Example |
|---|---|
| Why a non-obvious choice was made | `// Sorted before hashing: the server compares digests, not sets.` |
| An external constraint or upstream bug | `# Stripe returns amounts in cents for JPY too, despite the docs.` |
| Where a magic number came from | `// 0.62 measured on the reference rig; below it the spring rings.` |
| An invariant the types cannot state | `// Callers hold the write lock; this function does not take it.` |
| A workaround nothing is pending to remove, and what breaks without it | `// Reversed order avoids the D3D12 driver hang on Intel Arc.` |
| A pointer to the authority | `# Layout follows RFC 4122 §4.1.2.` |

## What fails

| Pattern | Do instead |
|---|---|
| Restating the line below | Delete. Rename the variable if the line is unclear. |
| Section banners — `// --- helpers ---`, `// Arrange` / `// Act` | Delete. The structure is the structure. |
| `// added by`, `// fixed the crash here` | Delete. `git log` holds authorship and change history. |
| Commented-out code | Delete. Git has it. |
| `TODO` / `FIXME`, or an explanation of a temporary hack | Report it in the reply to the user. |
| Teaching a language feature | Delete. The reader knows the language. |
| Docstring that restates the signature | Delete, or replace with what the caller cannot see. |
| Narrating your own edit (`// changed to fix flicker`) | Belongs in the commit message. |

## Cutting the water

A comment is not prose. What pushes one past a line is almost always padding, not fact.

| Cut | Why |
|---|---|
| Lead-ins — `Note that`, `Keep in mind`, `Basically`, `Essentially`, `The idea here is` | The reader is already reading it. |
| Hedges — `just`, `simply`, `actually`, `really`, `generally` | Either it is true or it is not. `usually` stays only when the frequency is the fact. |
| Intensifiers — `very`, `significantly`, `quite`, `heavily` | They move no number. If the size is the point, give the number. |
| `we`, `our`, `I`, `here we` | Nobody is in the room. State the fact. |
| `This function`, `This variable`, `This class` | The declaration is on the next line. |
| `in order to` → `to`, `due to the fact that` → `because`, `is able to` → `can` | Same fact, fewer words. |
| A second sentence explaining the first | Merge it or drop it. One fact per comment. |
| Articles, pronouns, auxiliaries, prepositions, conjunctions | Telegraphic. `Deploy fail. Config old.` |
| A longer word where a shorter one is already in mind | `use`, not `utilise`. Never hunt for a rarer synonym. |
| Metaphors and similes | Say the literal thing. |
| Words for numbers — `twenty-five`, `one hundred` | Digits: `25`, `100`. |
| `because`, `so`, `greater than`, `equals`, `approximately`, `percent` | `∵`, `∴`, `>`, `=`, `≈`, `%` |
| `for example`, `that is`, `and so on`, `leads to` | `e.g.`, `i.e.`, `etc.`, `→` |

    # Note that we basically just clamp this here in order to avoid the spring
    # ringing, since the driver is quite sensitive to large deltas.
    # Clamped: the Jolt driver rings above a 0.05 delta. — 2026-09-03

Same fact, one line, nothing lost. If cutting the padding still leaves two lines, the
comment is carrying two facts — keep the one the code cannot hold.

## How many

Most declarations get none, and comments stay under **5% of the file's lines**.

The 5% is not a quota to fill. It is what is left after the only test that matters: **is this
fact absent from the code, and not visible in it inside 5 seconds?** Anything a reader can see
— what a field is, what a function does, which upstream field a port mirrors — is water. A file
over 5% got there by writing water, and comes back under it by deleting water, never by
dropping the one line that mattered.

What earns a line:

- a measured number and where it came from
- an external quirk or upstream bug worked around
- an invariant the types cannot state
- a deliberate wrong-looking value the user chose: `# spring 500, not the 340 the ratio wants: user picked it, looks better — 2026-09-04`

Write it that way the first time. A cleanup pass afterwards pays for the same comment twice,
and paying twice is what this rule exists to stop.

Where consecutive declarations would each take the same shape of comment, that shape is the
tell: keep only the one whose content cannot be recovered from the symbol's own name, and
give the block one line instead of one per member. Naming the upstream field a port mirrors
(`Unity m_FallBrace`) is not a fact when the member is already called `fall_brace`.

    ## Unity `m_FootPlantTolerance` — below this the foot is fully planted.
    const PLANT_TOLERANCE: float = 0.01
    ## Unity `m_FootReleaseHeight` — the top of the geometric ramp.
    const RELEASE_HEIGHT: float = 0.12
    ## Where the floor actually is.
    const GROUND_Y: float = 0.0

The first two Unity names are already spelled out by the constants beneath them; the third
comment says the declaration back. One line above the block — `# Names mirror Unity's
fields.` — carries everything the three of them did.

## The date

Every comment ends with the day it was written, ISO, after an em dash:

    # Jolt reports this normal facing the other body, so the sign flips. — 2026-09-04

It is the only way a later pass can tell a line written for today's code from one that has
survived three rewrites of it. No date means no evidence, and a comment with no evidence is
the one that gets left standing because nobody can date it.

The date is inside the one-line cap, not an allowance on top of it. A fact that fits only
with the date cut was already two facts. License headers, pragmas and linter directives
(`# noqa`, `// eslint-disable`, `#pragma`) take no date — they are not comments in this sense.

## Doc comments

`##`, `///` and docstrings buy no extra lines: same two gates, same one-line cap. Marking a
comment as documentation changes where it is rendered, not what it is allowed to say.

The single exception is a public symbol whose caller needs a contract the signature cannot
state — units, error cases, lifetime, ownership. Then it is one line per item named, never
prose, and never a re-typing of the signature. A private or underscore-prefixed helper does
not get one at all.

A file already full of long doc comments is not evidence of a convention. It is the rot this
rule removes — including where you wrote it yourself an hour ago.

**Banned rule.** “Match how this file, or its sibling files, already document; do not start a
convention of your own” has been written into this skill by an agent and deleted by the user
three times. It is not the user's rule and it never was. Do not write it back in any wording.
Local style never lifts the cap.

## Comments already in the code

Open a file to edit it and every comment in it is yours, not only the ones in the block you
touched — you have now seen them, and leaving a comment you know is rotten is a choice. In a
file you only read, name the failing ones in your reply instead of editing it. Do not walk
the repo hunting for comments unless you are asked to.

For each comment in a file you edit:

- Is a license header, pragma, or linter directive (`# noqa`, `// eslint-disable`) → leave
  it; it is code, not commentary.
- Is a `TODO`/`FIXME` you did not write → leave it and mention it in your reply; it is
  someone's open note.
- Fails both gates → delete it.
- Passes, but runs long → cut it to one line.
- Contradicts the code → delete it, unless the corrected version passes both gates on its
  own; say in your reply that they had diverged.

## Cutting without losing what it knew

Deleting a comment can destroy the only record of something. Before a comment goes:

- If it carries a fact you cannot re-derive from the code — a bug number, a measured value,
  a vendor quirk, a decision and its reason — that fact survives. Drop the narration around
  it and keep the fact on one line.
- If it is reasoning that will not fit on one line, move it to the commit message, or to `docs/`
  if the project keeps design notes there — and leave a pointer comment only when it names
  that file by path.
- If it only describes what the code does, it knew nothing. Delete it whole.

## The check

Do this as you write the edit, not as a separate pass afterwards: for each comment in the
diff, name the fact it carries that is not anywhere in the code. If naming it means
restating the code, or you have to reach for it, the comment does not go in.

## When the user asks for comments

A request outranks this rule only when it names comments or documentation — a commented
example, a teaching walkthrough, docstrings. "Make it clearer" is not one of those; that is
a rename. Asked to *explain* code, explain it in the reply — the explanation is for the
person reading the answer, not for the file.

## Rationalizations

| Excuse | Reality |
|---|---|
| "This one genuinely aids readability." | If the code is unclear, rename it. A gloss on unclear code leaves two things to maintain. |
| "The user isn't a principal engineer." | The gate is the code's readers over its lifetime. Explanations for this user go in the reply. |
| "A senior would want this spelled out." | The bar is not a senior. It is someone who reads this language and this repo better than you do. |
| "It's a complex algorithm, it deserves a comment." | Name the algorithm and cite the source in one line. Do not narrate the steps. |
| "I'll add it now and tidy up later." | There is no later. The next edit inherits it and every edit after that. |
| "The file is already commented like this." | Match local formatting, not local rot. New rot is still rot. |
| "It's only one line." | One line per diff, every diff, is exactly how a file fills with lies. |
| "Each of these passes on its own." | Judge the file, not the line. A comment on every declaration is a pattern, and a pattern carries no information. |
| "The project allows three lines." | A project cap is a ceiling. One line is the rule underneath it. |
| "It's one sentence, it just wraps." | The unit is the line, not the sentence. If it wraps, cut it until it does not. |
| "It's a doc comment, so the cap is off." | Nothing turns the cap off. A public contract gets one line per item it names; that is the whole exception. |
| "I'm writing this file, so I set its style." | A convention you started on line 1 is not evidence of a convention. One line, everywhere. |
| "Every exported field deserves a line saying what it is." | Its name says what it is. Most fields get none. |
| "Naming the Unity field it ports is useful." | Not when the member is already named after it. The port mapping goes in docs/, once. |
| "Spelling the number out reads better." | Digits. `25`, not `twenty-five`. |
| "The symbols look terse." | Terse is the point. `∵` says `because` in a third of the tokens. |
| "This code is complex, it needs more than 5%." | Complex code needs better names. 5% holds for every file. |
| "I'll write it out now and trim in a cleanup pass." | The cleanup costs the same tokens again. Write it short the first time. |
| "Dropping the article makes it read badly." | Nobody reads a comment for prose. `Deploy fail.` is the target. |
| "The date is noise, git blame has it." | Blame moves on a reformat. The date is what survives the move, and it is 4 tokens. |
| "The project file doesn't ask for dates." | This rule does, in every project. A project can add to it, never take from it. |
| "I'll date it when it changes." | Then it carries the wrong date, which is worse than none. Date it as written. |
| "Dropping the date keeps it on one line." | Then it was two facts. Cut the fact, keep the date. |
| "This file documents itself this way already." | Banned rule. Local style never lifts the cap. |

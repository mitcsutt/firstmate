---
name: captain-asks
description: >-
  Keep one live Lavish page of everything waiting on the captain, so asks stop scattering across chat messages.
  Use when the captain invokes /captain-asks or asks for a live page, list, or board of the asks waiting on them.
  Also use when adding or removing an ask on that page, and on a procevent lavish wake whose source id is the asks page's.
user-invocable: true
metadata:
  internal: true
---

# captain-asks

One page, `data/captain-asks/asks.html` in this home, holds only what is waiting on the captain: questions, approvals, and commands for them to run.
It never holds anything waiting on other people; those are not the captain's move.
`assets/asks-template.html` is the starting page and the owner of the card markup and the browser-side persistence; copy it, do not retype it.
The captain's recorded page rules live in `data/captain.md` under "Asks and waits".

## Setup

1. Copy the template to `data/captain-asks/asks.html` (create the directory) and fill `{{LAST_CHANGED}}`.
2. Open it with `lavish-axi data/captain-asks/asks.html`, then arm it:

   ```sh
   bin/fm-procevent-lavish.sh arm data/captain-asks/asks.html
   ```

   Never run `lavish-axi poll` in a turn; the armed listener waits for the captain (`process-event-sources`).
3. Give the captain the session URL once.
   An existing page is reused, never recreated, so queued and half-typed answers are not lost.

## Page rules

- Ids are stable: `Q<n>` from the `next-id` comment at the top of the file, never reused or renumbered.
  Bump `next-id` with every new card.
- New cards are appended at the bottom, above the received list, in id order.
- Every card gives full context: what it is, why it matters, what each option does, why the recommendation, and who it affects.
  Write it in plain words, with PR URLs written out in full.
- Every card allows a comment-only answer; the template's form already does.
  Never remove the comment box or require an option.
- A command the captain must run, such as a worker's auto mode refusing an action, is a card too: show the exact command, say what it changes, and offer "I ran it" and "Don't run it" options.
- Verify live state before writing any card (re-read the PR, the status, the check), never from memory, and say in the card what was checked.
- Add a card the moment an ask opens and remove it the moment it is answered, whether the answer came through the page or chat.
- Batch page edits.
  Gather every add, removal, and move since the last edit into one rewrite instead of editing on each wake.
- A rewrite reloads the page and wipes unsent typed comments, so warn the captain before rewriting while a draft may exist.
  Queued and draft answers otherwise survive reloads through the page's local storage.
- Chat points at the page and names new asks by Q number; it never re-lists open asks.

## Handling a lavish wake for this page

On a `procevent lavish <source-id> <sequence>` wake whose source id is the asks page's (`bin/fm-procevent-lavish.sh source-id data/captain-asks/asks.html`):

1. Read the captured result with `bin/fm-procevent-lavish.sh read <result-file>`.
2. Act on each answer under the ordinary authority rules.
   The reader prints `Captain answer [<key>] <title>: <choice> | comment: <text>`, and a comment-only answer carries no choice; treat the comment as the answer.
3. Move each answered card to the received list as one `<li>` line saying what was done, then remove the card.
   Do this in the next batched rewrite, not necessarily this turn.
4. Acknowledge with `bin/fm-procevent.sh handled <source-id> <sequence>` once the actions are durable.

A non-terminal round keeps the page armed.
Retire it with `bin/fm-procevent-lavish.sh retire data/captain-asks/asks.html` only when the captain ends the session for good.

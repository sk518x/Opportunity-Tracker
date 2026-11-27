# Opportunity Tracker - System Documentation

A personal automation that captures bursaries, internships, and graduate program opportunities forwarded via Telegram, extracts structured details using AI, stores them in a database, and keeps a live, sorted Google Sheet - all running 24/7, free, independent of any personal device.

---

## 1. What It Does

- Forward any post (text, link, or photo) to a dedicated Telegram bot
- AI extracts: title, organization, type, deadline, application link, requirements
- Duplicate opportunities are automatically ignored (blocked at the database level)
- Entry is stored permanently in a PostgreSQL database - the single source of truth
- Google Sheet updates **immediately** with the new entry, sorted nearest-deadline-first
- Every morning at 7am, a digest message lists anything closing within 5 days
- Anything past its deadline (and not marked "Submitted") automatically moves to a separate "Expired" tab/status

---

## 2. A Note on Naming

### Render service URL

During initial setup, Render generated the service subdomain as **`indingo-opp-tracker`** — note the spelling: **"indingo," not "indigo."** This was an automatically assigned name, not an intentional spelling choice.

Changing the service's display name does not necessarily change its existing public URL. During an attempted rename, a different URL, `sk518x-opp-tracker`, was briefly referenced. That URL is not the active endpoint.

**The correct, working service URL is:**

```text
https://indingo-opp-tracker.onrender.com
```

Use this URL whenever the Render service endpoint is referenced in configuration or troubleshooting instructions.

### Telegram bot username

The Telegram bot was created with the username:

```text
@Indigo_Opportunity_tracker_bot
```

Telegram distinguishes between a bot's username and its display name:

- **Username:** Used for searching, mentions and the bot's `t.me` link. Telegram does not allow an existing bot's username to be changed.
- **Display name:** The name shown on the bot's profile. This can be changed through BotFather using `/setname`.

The existing username is retained throughout this project for consistency.

---

## 3. Services Used (all free, no card required)

| Service | Role | Notes |
|---|---|---|
| **Render** (render.com) | Hosts the n8n automation engine | Live URL: `https://indingo-opp-tracker.onrender.com`. Free services sleep when idle - see Section 9 |
| **n8n** | The automation workflow itself | Owner account created during setup |
| **Neon** (neon.tech) | PostgreSQL database - the real source of truth for all opportunity data | |
| **Telegram / BotFather** | Bot that receives forwarded posts and sends replies | Handle: `@Indigo_Opportunity_tracker_bot` (display name changeable, handle is not) |
| **Groq** (console.groq.com) | AI extraction - text and vision | Current model: `qwen/qwen3.8-27b` for both. Models get retired regularly - see Section 9 |
| **Google Sheets** | Human-readable mirror of the database, viewable/editable from phone or computer | Two tabs: Active, Expired |

---

## 4. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         INTAKE (on message)                           │
│                                                                         │
│  Telegram message → Classify (text/link/photo) → Route                │
│       │                    │                    │                     │
│    [text]               [link]               [photo]                  │
│       │                    │                    │                     │
│       │              Fetch page,          Download image,             │
│       │              strip HTML           encode base64               │
│       │                    │                    │                     │
│       └────────────────────┴────────────────────┘                     │
│                             │                                          │
│                    Groq AI extraction                                  │
│                             │                                          │
│                   Parse response → JSON                                │
│                             │                                          │
│                    Build dedup key                                     │
│                             │                                          │
│              INSERT into Postgres (dupes silently skipped)             │
│                    │                    │                              │
│              Confirm reply       Instant sheet refresh                 │
│              (Telegram)          (full copy of daily sync chain,       │
│                                    minus the digest message)           │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                    DAILY SYNC (7am schedule)                          │
│                                                                         │
│  Read all from Postgres → calculate days-left → split by status       │
│       │                                    │                           │
│   [active]                            [expired]                        │
│       │                                    │                           │
│  Rewrite Active tab                  Rewrite Expired tab               │
│       │                              + mark Expired in DB              │
│  Build digest of items                                                 │
│  closing within 5 days                                                 │
│       │                                                                 │
│  Send Telegram reminder (only if something is actually urgent)         │
└──────────────────────────────────────────────────────────────────────┘
```

**Key principle:** Postgres is the single source of truth. The Google Sheet is a disposable, read-focused view of it. **Never edit data in the Sheet expecting it to stick** - the next sync overwrites it.

---

## 5. Database Schema (Neon / Postgres)

The full schema, with constraints and indexes, is in [`schema.sql`](../schema.sql). In short:

- `dedup_key` = lowercased `title + "|" + org`, whitespace collapsed. The `UNIQUE` constraint plus `ON CONFLICT DO NOTHING` on insert is what makes duplicate detection automatic.
- `type` is restricted to: `Bursary`, `Internship`, `Graduate Program`, `Learnership`, `Other`. The "Parse Extracted Data" node normalizes any unexpected AI output to `Other` before insert, so the constraint is never violated.
- `status` is restricted to: `Not started`, `In progress`, `Submitted`, `Expired`
- Items marked `Submitted` are protected from ever being auto-moved to Expired, even if the deadline has passed.

---

## 6. n8n Workflow - Node Reference

### Intake chain (triggered by Telegram message)
| Node | Type | Purpose |
|---|---|---|
| New Telegram Message | Telegram Trigger | Entry point. Restricted to the owner's chat ID via "Restrict to Chat IDs" |
| Classify Message | Code | Sorts message into `text` / `link` / `photo`, captures `chat_id` |
| Switch | Switch | Branches to the text / link / photo extraction path based on the type set by Classify Message |
| Fetch Link Page / Strip HTML | HTTP Request + Code | For link messages: downloads and cleans page text |
| Get File Path / Download Photo / Encode Image | HTTP Request ×2 + Code | For photo messages: pulls the image from Telegram and base64-encodes it |
| AI Extraction | HTTP Request | Sends text to Groq for structured extraction |
| Extract From Photo | HTTP Request | Sends the encoded image to Groq's vision-capable model |
| Parse Extracted Data | Code | Strips AI "thinking" text, parses JSON, validates `type`, sets default status |
| Build Dedup Key | Code | Builds the `dedup_key` field |
| Insert To Postgres | Postgres | Inserts the row; duplicates silently rejected |
| Confirm To Me | HTTP Request (raw Telegram API call) | Sends the "Added: ..." reply |
| Instant Read Postgres → Instant Calculate & Split → Instant Is Active/Expired → Instant Clear/Refetch/Write tabs | *(duplicate of the daily sync chain)* | Refreshes the Sheet immediately, without triggering the digest message |

### Daily sync chain (triggered by 7am schedule)
| Node | Type | Purpose |
|---|---|---|
| Every Morning 7am | Schedule Trigger | Fires once daily |
| Read All From Postgres | Postgres | `SELECT * FROM opportunities;` |
| Calculate Days & Split | Code | Computes `days_left`, cleans date formatting (strips time/`Z` suffix), tags each row `active` or `expired` |
| Is Active / Is Expired | If ×2 | Routes rows to the correct tab-writing branch (replaced an earlier Switch node that silently dropped items - see Section 10) |
| Clear Active/Expired Tab | Google Sheets (Clear) | Wipes existing rows (keeps header). **"Execute Once" must be enabled** - otherwise it fires one request per row and hits Google's rate limit. "Retry On Fail" is also enabled |
| Refetch Active/Expired Rows | Code | Re-pulls the filtered list for writing |
| Write Active/Expired Tab | Google Sheets (Append) | Writes the fresh, sorted list |
| Mark Expired In DB | Postgres | `UPDATE opportunities SET status = 'Expired' WHERE dedup_key = ...` |
| Build Digest Message | Code | Builds a text summary of anything closing within 5 days |
| Anything Urgent? | If | Only proceeds if there's something to report |
| Send Reminder | Telegram | Sends the digest |

---

## 7. Google Sheet Structure

Two tabs, both with this header row (row 1 - never delete):
```
title | org | type | deadline | link | requirements | status | added_on | days_left
```

- **Active** - everything not yet expired, sorted nearest-deadline-first
- **Expired** - anything past its deadline (unless marked Submitted)

A dropdown is enabled on the `status` column (Data → Data validation) with options: `Not started`, `In progress`, `Submitted`.

---

## 8. How To Make Changes

| I want to... | Where to do it |
|---|---|
| Update a status (e.g. mark "Submitted") | Directly in the Google Sheet dropdown, **and** in Postgres to make it stick: `UPDATE opportunities SET status = 'Submitted' WHERE id = <id>;` |
| Delete a wrong/test entry | **Neon SQL Editor**, not the Sheet: `DELETE FROM opportunities WHERE id = <id>;` |
| See a change reflected immediately in the Sheet | New entries already trigger an instant refresh automatically; to force one manually, open "Every Morning 7am" in n8n → Execute step |
| Check raw data for a specific opportunity | Neon SQL Editor: `SELECT * FROM opportunities WHERE title ILIKE '%keyword%';` |
| Rename a node | Double-click its title. Then check any Code or HTTP nodes that reference it by name, e.g. `$('Node Name')` - n8n's automatic update is unreliable inside Code nodes |

---

## 9. Known Limitations

**Silent outcomes**
- **Duplicates produce no reply.** The insert returns no row for a duplicate, so the confirmation and instant-sync steps never run. A failed run is also silent to the user. Both are only visible in Executions.
- **No automatic failure alerts.** No error workflow is configured.

**Input handling**
- **Only one unparseable post can be stored at a time.** Fallback rows share the dedup key `could not parse - check manually|`, so any later one is silently dropped.
- **Unsupported message types aren't rejected.** A video without a caption, a voice note, or a file is classified as text with empty content and still sent to the AI.
- **Photo captions are ignored**, and each message produces at most one opportunity.
- **Link reading is limited.** Only messages that are purely a URL are fetched, only the first 3,000 characters of cleaned page text are used, and login-walled (private Facebook groups, some LinkedIn posts) or JavaScript-rendered pages return little.
- **Video isn't processed.**

**Data**
- **Opportunities with no deadline never expire** - `days_left` stays empty and they remain in Active.
- **Editing `status` in the Sheet doesn't persist** - it needs the matching Postgres update, or the next sync overwrites it.
- **Concurrent syncs can interleave.** Several posts sent in quick succession start several Sheet rebuilds at once; the Sheet may be briefly wrong and corrects on the next sync.

**Hosting**
- **Render's free tier sleeps after inactivity.** The first message after a quiet period takes 30–60 seconds longer. A *scheduled* trigger doesn't wake a sleeping service, so the 7am digest only fires if the service happens to be awake. A free keep-alive ping (e.g. cron-job.org requesting the service URL every 10 minutes) fixes this.
- **Neon's free tier suspends idle compute** - a brief delay on the first query after inactivity.
- **The Render subdomain and bot username are permanently fixed** at their originally-assigned values (see Section 2).

**AI provider**
- **Model names get retired repeatedly.** This project has been through several: `llama-3.2-90b-vision-preview` (decommissioned), `llama-3.3-70b-versatile` (shut down Aug 16, 2026), and `qwen/qwen3.6-27b` (shut down Sept 14, 2026). Current model for both text and vision: `qwen/qwen3.8-27b`. When extraction fails with a "model decommissioned" error, check console.groq.com/docs/deprecations and update the `model` value in both the "AI Extraction" and "Extract From Photo" nodes.
- **Free-tier rate limits apply** - pace large batches of posts.

---

## 10. Troubleshooting Checklist

1. **Something isn't working - where do I look first?** n8n → Executions tab → click the newest run → click through each node to see exactly where it stopped and why.
2. **A node shows grey / never ran** - trace backward to find the last node that *did* run; the break is the connection or condition right after it.
3. **A date/text field looks garbled or shifted into the wrong column** - almost always either (a) a stray leading `=` typed into a field that should be a plain expression, or (b) commas inside free-text content breaking a naive comma-separated parameter list (use a proper array expression instead, e.g. `{{ [$json.a, $json.b, ...] }}`).
4. **"Chat not found" from Telegram** - check the Credential dropdown on the relevant Telegram node is explicitly selected, and confirm it's using the currently valid bot token.
5. **A Switch/If node's output looks empty even though the input data is clearly correct** - check for a "Convert types where required" or "Type Validation: Strict" setting; loosen it, or replace the Switch with two separate If nodes.
6. **Changes made in the editor don't seem to take effect** - click **Publish**, not just save; published and draft versions are separate in this n8n setup.
7. **Google Sheets: "The service is receiving too many requests"** - a Clear node is running once per item. Open its Settings tab and enable **Execute Once**.
8. **Google Sheets: "credential needs to be reconnected"** - reconnect the credential. If it recurs weekly, the Google OAuth app is still in "Testing" status (refresh tokens expire after 7 days); publish it to production under Google Cloud Console → OAuth consent screen → Audience.
9. **"n8n can't listen for test executions at the same time as production ones"** - don't unpublish. Start the test from the schedule trigger instead (open "Every Morning 7am" → Execute step), or test the Telegram side by sending the bot a real message.
10. **Extraction suddenly returns "Could not parse" or errors for every post** - check for a retired model (see Section 9), then look at the AI node's raw output in Executions.

## 11. Error Handling

| Situation | What happens | Where you'd see it |
|---|---|---|
| AI wraps the JSON in reasoning text or prose | `<think>` blocks are stripped and the JSON object is extracted from the surrounding text | Nowhere - handled |
| AI output still isn't valid JSON | A fallback row titled "Could not parse - check manually" is inserted, with the first 200 characters of the raw response in `requirements` | The row, in the Sheet and database |
| AI returns a `type` outside the allowed list | Coerced to `Other` before insert, so the `CHECK` constraint is never violated | Silent |
| Duplicate opportunity | `ON CONFLICT DO NOTHING` - no row is inserted, and the branch stops before the confirmation reply | No reply; the run ends at "Insert To Postgres" in Executions |
| No deadline in the post | Stored as `NULL` (via `NULLIF`), shown as "no date" | The Sheet |
| Title missing entirely | The `NOT NULL` constraint fails the insert and the run errors | Executions only; no reply |
| Google Sheets rate limit | The four Clear nodes run once per execution ("Execute Once") and have "Retry On Fail" enabled | Executions, only if retries are exhausted |
| Message from anyone other than the owner | The Telegram Trigger's "Restrict to Chat IDs" setting drops it before the workflow starts | No run appears in Executions; the sender gets no reply |
| Sheet write fails partway | The Sheet is rebuilt from Postgres on the next sync, so it self-corrects | Self-heals |
| Deadline passes | The row's status becomes `Expired` and it moves to the Expired tab, unless it is marked `Submitted` | The Sheet |
| Any node errors | The run stops at that node. No error workflow is configured, so there is no alert | Executions only |

---

## 12. Future Improvements

**Security and reliability**
- An n8n error workflow that sends a Telegram alert whenever a run fails
- Reply "already tracked" on duplicates and a clear message when extraction fails
- A keep-alive ping so the daily digest fires reliably
- Retry with backoff on AI and Google API calls
- Make fallback rows unique (e.g. add a timestamp to their dedup key) and flag them for review
- Keep the model name in a single place, with a startup health check that detects retired models
- Move the bot token out of raw request URLs into an n8n credential, so exports need no scrubbing

**Usability**
- Bot commands (`/done`, `/list`, `/delete`) that update PostgreSQL directly, replacing manual SQL
- A helpful reply to unsupported message types; use photo captions as extra context
- Reminders at 7, 3, and 1 days before a deadline, plus a weekly summary
- Calendar (`.ics`) export of upcoming deadlines

**Architecture**
- Two-way status sync between the Sheet and PostgreSQL
- An authenticated, read-only web dashboard (prototyped early on, not included)
- Multi-user support, with opportunities scoped per chat

---

*Built and documented through iterative setup and debugging - every fix in Section 10 came from a real issue hit and resolved during development.*

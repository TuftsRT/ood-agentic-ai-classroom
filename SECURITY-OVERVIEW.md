# Security Overview

Plain-language summary of how this app handles data and access. See
`README.md` for the functional design.

## LLM sandboxing (on by default)

When "Sandbox the LLM environment" is checked (the default), the whole
`apptainer run --nv ...` launch is wrapped in [bubblewrap](https://github.com/containers/bubblewrap)
(`bwrap`, unprivileged, no setup required -- it's a plain binary on this
cluster):

- The host filesystem is shared back in **read-only**, so Apptainer, Lmod,
  and the CUDA driver see exactly the paths they already expect -- nothing
  about GPU passthrough changes or risks breaking.
- Your home directory is shadowed with an empty, private tmpfs: the path
  still exists, but the server cannot read or write anything actually in it.
- `/tmp` is likewise a private tmpfs, not the node's shared `/tmp`.
- The job's own working folder is bound **read-only** too, except
  `.xdg-runtime` (the one thing the NVIDIA driver needs to write) -- neither
  `llama-server` nor anything it spawns (its own built-in tools if ever
  enabled, or the web-search MCP subprocess, see below) can write anywhere
  in the session folder. It only ever needed to *read* the key file, roster
  CSV, model files, and MCP config -- never write them.
- New PID/IPC/UTS namespaces mean the server can't see or signal other
  users' processes on the same shared compute node.
- `llama-server` itself is started with `--offline` (no calls out to
  Hugging Face or anywhere else for model/tokenizer data).

**What this does *not* do: isolate the network.** Some process's listening
socket has to stay reachable from OOD's `rnode` reverse proxy and from
students elsewhere on the cluster network, so this app never puts `llama-server`
or `guardrails_proxy.py` (see "Guardrails" below -- the only one of the two
actually exposed; `llama-server` itself is loopback-only now) in its own
network namespace -- doing so would make the session unreachable by anyone,
defeating the point of the app. "Sandboxed" here means filesystem and
process containment, not an outbound-traffic firewall; don't read the
checkbox as a guarantee nothing in the job can make outbound network calls.
This toggle also only ever wraps `llama-server`'s own launch -- it does not
apply to `guardrails_proxy.py`, which runs unsandboxed via a separate
`apptainer exec` regardless (it needs no GPU access and only reads one text
file, so there's less for a sandbox to contain in the first place).

Unchecking the option drops bubblewrap and `apptainer run` executes
directly with this site's normal Apptainer defaults (the same behavior as
the plain `llm_api` app) -- useful if an exercise genuinely needs the server
to reach a dataset or service outside its own session folder.

## Credentials

- Each student's API key is a random 32-character alphanumeric string
  generated with `/dev/urandom`, never derived from their name/username.
- Keys are written to `.llm-keys/api.keys` (`chmod 700` directory,
  `chmod 600` file) and read by `llama-server` via `--api-key-file`. A key is
  never passed as a CLI argument, which would make it readable via `ps` or
  `/proc/<pid>/cmdline` by any other user on the same shared compute node.
- `roster.csv` (name -> key mapping) is also `chmod 600` and only reachable
  by the instructor who launched the job, through OOD's own authenticated
  file browser.
- When the roster comes from a course's storage group (not a manually-typed
  one), keys are *also* mirrored into that course's own storage directory
  for the Student role to read -- see "Faculty/Student roles and session
  auto-discovery" below for the details and the tradeoff this introduces.
- Anyone holding a key can use the server and see whatever is sent with it --
  the connection page says so next to the roster list. There's no
  per-student rate limiting or usage attribution beyond "this key exists".
- Every request now passes through `guardrails_proxy.py` (see "Guardrails"
  below) before reaching `llama-server`. It forwards the `Authorization`
  header unchanged and never inspects or stores it -- `llama-server`'s own
  `--api-key-file` check is still the sole authority on whether a key is
  valid.

## Faculty/Student roles and session auto-discovery

The launch form's first field picks a role. **Faculty/TA** is the
app described everywhere else in this document: it starts the actual GPU
session. **Student** submits a different, much smaller job -- no GPU, no
containers, no model -- whose only purpose is to find whichever instructor
session is already running for the student's own course and show its Base
URL and that student's own API key. This section covers what's new in that
second path; it does not change anything about how the Faculty/GPU session
itself runs.

**Job naming, and why it's the discovery mechanism.** Both roles submit
their Slurm job as `llm-classroom-sandbox/<course_group>` (see
`lib/course_storage.rb`'s `job_name_for`, used from `submit.yml.erb`) --
`<course_group>` is the course's storage directory name (e.g.
`c27sp1xx0001`), sanitized to `[A-Za-z0-9_-]`. A student's viewer job finds
the instructor's session with a plain `squeue --name=... --format='%k'`
(`%k` is the job's Comment field) -- deliberately *not* by reading anything
under the instructor's own OOD session directory, which is permission-
restricted to the instructor and unreadable by students. The Faculty
session publishes its host/port into that Comment field via
`scontrol update ... Comment=` once its `guardrails_proxy.py` is actually
listening (see `template/script.sh.erb`).

**This cross-user `squeue`/Comment visibility has not been verified against
a real Slurm controller.** It could not be checked from the unprivileged
dev shell this feature was built in (`squeue` there returned "Unable to
contact slurm controller"), and whether an ordinary user can see another
user's job name/Comment at all depends on this cluster's Slurm `PrivateData`
setting. If that turns out to be restrictive, the symptom is simply "Student
role never finds a running session" -- it fails closed (a student sees "no
active session found," never someone else's job details they shouldn't have
access to), not open.

**A second, file-based channel exists as a fallback for the same reason.**
The Faculty branch also writes `session.json` (course name, tier, host,
port -- no key material) into
`/cluster/tufts/<course_group>/.llm-classroom-sandbox/`, a directory it
creates under the course's own storage and restricts to that course's base
group (`chmod 750`/`640`, `chgrp` to the course group). Every enrolled
student is already a member of that base group (see `lib/course_storage.rb`
for the base-group-vs-`<name>admin`-group distinction this app relies on
throughout), so this is readable by the whole class, not by anyone with
cluster access. The student's viewer job tries `squeue` first and only
falls back to this file if that comes back empty.

**Per-student API keys, widened from instructor-only to course-member-only.**
When the roster is sourced from the course's storage group (not a manually-
typed one), the Faculty branch also writes `keys.csv`
(`username,api_key`) into that same shared directory, group-readable the
same way. **This is a real, deliberate widening of the trust boundary** for
one specific reason: this cluster's course storage is NFS-mounted (NFSv3),
and POSIX ACLs -- which would have let a single key file be scoped to read
access for one specific student -- do not work there (confirmed directly:
`setfacl` fails outright even on local scratch space on this cluster, not
just the NFS mount). Group-readable is the narrowest boundary actually
available. In practice this means **any student in the course could read
every classmate's key** by opening `keys.csv` directly, even though the
connection page itself only ever shows a student their own row (matched by
Unix username). This is the same "keys aren't strongly protected within the
class" tradeoff already accepted above for the Faculty-only `roster.csv`,
just extended to a wider, still course-scoped audience -- not a new
category of risk. Manually-typed rosters (the "Other" course option) never
produce a `keys.csv` at all -- there are no verified usernames to key off
of in that case, and that course also never appears in the Student dropdown
in the first place, since that dropdown is itself populated by base-group
membership.

**Cleanup.** The Faculty branch's existing `cleanup()` exit trap (already
covering `EXIT`/`INT`/`TERM` -- normal completion, the idle-shutdown
`scancel`, and signals alike) now also removes the entire
`.llm-classroom-sandbox/` directory it created, so `session.json`/`keys.csv`
never outlive the session they describe. A run that never reaches that trap
(e.g. a node failure) is self-healing rather than permanently stale: the
next session started for that course overwrites both files unconditionally
before use.

**The Student role's own job re-validates everything server-side,** exactly
like the Faculty branch already does for `course_group`: the submitted
course is re-checked against the submitting user's own real group
membership on the compute node (base group this time, not `<name>admin`),
never trusted just because it came from the dropdown.

## llama-server's bundled Web UI

Students connect through `llama-server`'s own built-in Web UI (reached via
the "Launch Web UI" button, OOD's `/rnode/<host>/<port>/` reverse proxy)
rather than a client this app provides. `--api-key-file` protects the Web
UI's static page itself, not just the API, so the connection page pre-seeds
the *first* roster entry's key into the browser's `localStorage` before
navigating there (same mechanism `llm_api` uses with its single shared key)
-- otherwise the very first page load 401s before any UI, including a
settings panel to enter a key, can render. Every student other than that
first one needs to replace it with their own key from the list once the Web
UI loads; the connection page says so explicitly. The Web UI
itself doesn't add a separate login; access is governed by the same API key
check as the raw HTTP API, so there's no weaker path in through it.

That same first key is also used client-side by the connection page's live
status indicator, to call `/metrics` and show "N request(s) processing."
No new exposure: it's the same key already shown in plain text in the
roster list a few lines above it on the same, instructor-only page.

## Tools (web_search, literature_search): scoped deliberately narrow

`llama-server` is given exactly two tools, `web_search` and
`literature_search`, via `--mcp-servers-config` -- never `--agent`, which
would also turn on llama.cpp's built-in `exec_shell_command`/`write_file`/
`edit_file`/`read_file` tools. llama.cpp's own docs call `--agent` unsafe
for untrusted environments; a classroom is one, for two specific,
compounding reasons:

1. Those built-in tools execute in-process inside `llama-server`, so they'd
   inherit exactly whatever sandbox already wraps the whole server -- there
   is no way to scope them more tightly than that from outside. Since the
   sandbox shares the host filesystem back read-only (`--ro-bind / /`, see
   above -- necessary so Apptainer/the CUDA driver keep working), `read_file`/
   `grep_search` would be able to read anything the instructor's own account
   can read across the whole cluster, not just this session's folder.
2. Both tools fetch content from external sources (a local search instance,
   or the open internet for literature search). Pairing either with a tool
   that can execute commands is a known indirect-prompt-injection path: a
   result could contain text crafted to look like an instruction, and the
   model has no reliable way to distinguish "data I fetched" from "a
   command I should run." Sandboxing limits what a tricked command could
   do; it doesn't stop the model from being tricked into issuing one in the
   first place.

Our own tools (`mcp_tools.py`, written into the session folder by
`before.sh.erb` at job start) do none of that -- each makes one outbound
HTTP GET/POST and returns text. It's stdlib-only Python with no filesystem
or shell access of its own. The two tools differ in where that request
actually goes:

- `web_search` calls a loopback-only SearXNG instance this same job
  launched (`127.0.0.1`, never reachable from outside the node).
- `literature_search` calls Semantic Scholar's public Graph API
  (`api.semanticscholar.org`) directly over the open internet -- a
  genuinely different trust boundary from `web_search`'s loopback call,
  though the same *category* of egress `web_search` already requires
  indirectly (SearXNG itself reaches out to the open internet on
  `web_search`'s behalf). No API key is sent; Semantic Scholar's anonymous
  tier is rate-limited, confirmed directly in testing (a burst of calls
  from this same outbound path returned HTTP 429), and the tool surfaces
  that as a clean error rather than crashing or hanging.

**Where the subprocess actually runs.** `llama-server` spawns `mcp_tools.py`
as its own child process, which inherits the exact same container/sandbox
`llama-server` itself is running in -- there's no narrower, separate
bubblewrap layer wrapped around just that one subprocess, because that
would itself require `bwrap` to exist inside `llama-server-gpu.sif`, an
assumption just as unverified as the one this already relies on (`python3`
being present there). What *is* enforced, and doesn't depend on guessing
the image's contents: the read-only `$PWD` bind described above applies to
this subprocess too.

## Guardrails: enforced at the network layer for remote clients, not a content filter

`llama-server` is not reachable directly *over the network*. It listens on
`127.0.0.1` on an internal-only port; `guardrails_proxy.py` is the only
process bound to the port OOD and students actually connect to, and every
remote request passes through it. For `.../chat/completions` requests
specifically, it parses the JSON body and merges the instructor's guardrails
text into the system message (appended to an existing one, or inserted as a
new one) before forwarding to `llama-server`. For any remote client -- the
Web UI, a raw `curl`/SDK call to the connection page's Base URL, a different
OpenAI-compatible client entirely -- there's no route to the model that
skips this.

**That guarantee stops at the compute node's edge, not before it.**
`llama_internal_port` is passed to `llama-server` as a plain CLI argument
(unlike the API key, deliberately never passed that way -- see
"Credentials" -- specifically so it isn't readable via `ps`/`/proc` by other
users on a shared node). The port number doesn't get that same protection,
and "Sandbox the LLM environment" never isolates the network namespace
either way (see above), so `127.0.0.1:$llama_internal_port` is reachable by
any other process running on that same physical node. On this cluster,
multi-GPU node types (the medium/large tiers' `a100-80G`/`h100-80G`/
`h200-141G` constraints typically mean 4-8 GPUs per box) make it plausible
for an unrelated job to land on the same node as this session while it's
running. Someone who is both (a) running a process there and (b) already
holds a valid API key for this session (keys are not strongly protected to
begin with -- see "Credentials") could read the port off the process list
and talk to `llama-server` directly, bypassing the guardrails merge. This is
**not** an authentication bypass -- `--api-key-file` still has to pass --
but it is a real gap in the "only path to the model" claim above, scoped to
that specific population.

What guardrails enforcement buys, for everyone else: the text is present in
the model's context on every request, not merely displayed on a page the
model never sees. What it does **not** buy, for anyone: a content filter.
The proxy only edits the `messages` array; the model still has to choose to
follow the instruction, the same as any system prompt. A sufficiently
adversarial prompt can still talk the model into ignoring it (classic
prompt-injection territory), and the proxy does nothing to detect or block
that -- it has no visibility into the model's actual output, only the
request going in. Don't rely on this for restricted or sensitive topics;
see "Data handling" below.

**New attack surface, scoped narrowly.** The proxy is a small hand-written
`http.server` instance, not hardened the way `llama-server`'s own HTTP
implementation is. It receives and `json.loads()`-parses request bodies from
anyone who can reach the port, *before* `llama-server`'s `--api-key-file`
check downstream ever runs -- so an unauthenticated request does reach
`json.loads()`, though nothing beyond that (no eval, no filesystem access
from request content, stdlib only). Authorization itself is untouched: the
proxy forwards the `Authorization` header as-is and never inspects or
stores it, so `llama-server` is still the sole source of truth for whether a
key is valid. It enforces a 20-second socket timeout and an 8MB cap on
incoming request bodies specifically so an unauthenticated client can't tie
up a thread indefinitely by sending headers and withholding the body (found
and fixed in testing: before these limits existed, this was a free,
credential-less way to grow unbounded threads on a shared GPU node). It is
otherwise new code, not yet load-tested under real classroom concurrency.

## Shell-injection hardening

Free-text form fields that get embedded into the generated job script
(course label, student roster, guardrails notice) are read back through
quoted bash heredocs (`<<'EOF'`) rather than interpolated into double-quoted
strings. That means `$()`, backticks, and `$VAR` typed into any of them are
inert text to the shell, not something that gets executed when the job
starts.

## CSV-formula-injection hardening

`roster.csv` is built from the pasted roster and is meant to be opened in a
spreadsheet (Excel/Sheets). A name starting with `=`, `+`, `-`, or `@` would
otherwise be interpreted as a formula by those tools (CWE-1236) -- `before.sh.erb`
prefixes a literal `'` to any name starting with one of those characters
before writing it out, which both Excel and Sheets treat as "force text".

## HTML-escaping on the connection page

The course label, the roster's name column, and the guardrails notice are
free text, rendered on the connection page (`view.html.erb`). That page is
confirmed to render through a plain `ERB` path elsewhere in this app (see
the `__dir__`/`session.app.root` note in `before.sh.erb`), so rather than
assume Rails' usual auto-escaping applies here, all three are passed through
the page's own `esc` helper (plain `String#gsub`, not `ERB::Util` or `CGI`,
for the same binding-dependency reason) explicitly before being written into
the page.

## Data handling

Model inference happens entirely within Tufts HPC; conversation content is
never sent to a third-party API. **`web_search` and `literature_search` are
the exceptions**: when the model calls either, the query text (not the
full conversation, just whatever the model chose to search for) leaves the
job -- through a local SearXNG instance to whatever external search engines
it queries, for `web_search`, or directly to Semantic Scholar's public API
over HTTPS, for `literature_search`. This is independent of the "Sandbox
the LLM environment" toggle, which has only ever covered the model's own
filesystem/process containment, never network egress. Per Tufts' AI usage
guidance (linked on the connection page), do not send restricted data
through either tool without review under the Tufts Information
Classification and Handling Policy -- this now includes being mindful of
what ends up in a search query, not just a chat message.

## Reference documents (RAG feature)

When an instructor sets `reference_docs_dir`, the session reads that folder
**read-only** (bind-mounted the same way the model directory already is)
and indexes it once at startup into an in-memory index held by
`rag_index_server.py` -- nothing from it is ever written back to disk, and
no bytes from it leave the compute node. Both the embedding model
(`nomic-embed-text-v1.5`) and the index itself run as loopback-only
(`127.0.0.1`) processes with no API-key protection of their own, same as
the existing SearXNG instance -- that's an accepted gap for the same reason:
nothing routes to them except this job's own `guardrails_proxy.py`, and
"Sandbox the LLM environment" never isolates the network namespace for any
process in this job (see "LLM sandboxing" above), so this isn't a new or
different trust boundary from what already exists.

**This is a class-wide knowledge base, not private per-student storage.**
Every student's question is scored against the same index; there's no
mechanism to scope a document to one student, and no per-student upload
path at all -- only the instructor sets this field, before the session
starts. Treat the folder like any other content you'd put in front of the
whole class: the same Tufts data-handling guidance above applies to it.

**Explicitly refuses to index this app's own shared session directory
(`.llm-classroom-sandbox/`, see "Faculty/Student roles" above).** This
matters because picking a known course auto-fills `reference_docs_dir` to
that course's storage *root* -- the same directory `.llm-classroom-sandbox/`
(and the `keys.csv` inside it) lives in. The directory-walk below already
skips dot-prefixed subdirectories for an unrelated reason (see "symlinks"
just below), which incidentally already covered the common case, but
`rag_index_server.py` now also checks for this directory by its exact name,
both as a subdirectory encountered mid-walk and as `reference_docs_dir`
itself -- the dot-prefix skip alone doesn't cover the latter, since
`os.walk` never re-checks its own starting path the way it filters
subdirectories. Worth calling out because `.csv`/`.json` (`keys.csv`'s and
`session.json`'s own extensions) are both on this indexer's allowed-
extensions list -- nothing about the extension allowlist itself would have
stopped either from being indexed and handed to the model as retrieval
context if this exclusion didn't exist.

On every `/chat/completions` request, `guardrails_proxy.py` now also makes
one additional loopback HTTP call (to `rag_index_server.py`'s `/retrieve`
endpoint) before forwarding to `llama-server`, with a 3-second timeout and
a broad `except Exception` around it -- a slow or failed retrieval call
degrades to "no reference-document context for this turn," it never blocks,
delays beyond that bound, or breaks the chat request itself. The retrieved
chunks are merged into the system message in plain text, exactly like
guardrails text already is -- the model sees them as regular context, not a
privileged or verified source, and can be prompted to ignore or misrepresent
them the same as any other part of its context window.

**Injected reference-document context is capped relative to the session's
actual context window, not a fixed chunk count.** This was found the hard
way: a large pre-loaded file on the Small/Large tier (`ctx_per_slot=4096`)
could push a single request over the model's context limit outright,
failing it (`--context-shift` only rescues a conversation that grows past
the window over many turns; it can't save one oversized request).
`guardrails_proxy.py` now receives `ctx_per_slot` directly and only
includes as many *whole* retrieved chunks as fit under roughly a quarter
of it (a conservative, tokenizer-free character-based estimate, since there
is no tokenizer in this environment) -- dropping lower-ranked chunks, or
skipping reference-document context for that turn entirely if even the
single best-ranked chunk doesn't fit, rather than ever risking an
over-budget request.

Indexing is restricted to an allowlist of extensions: plain text/Markdown/
code files, Word (`.docx`), PowerPoint (`.pptx`), and PDF. The Office
formats are parsed with pure-stdlib `zipfile`/XML (both are zip archives of
XML internally -- no external library involved, nothing beyond what every
Python install already ships). PDF has no equivalent library available in
this container, so it's parsed with a hand-rolled, best-effort extractor
(zlib decompression + regex over text-showing operators) that only
reliably handles simple, standard-font, text-based PDFs -- scanned/
image-only PDFs and PDFs with embedded subset/custom-encoded fonts can
produce no text or garbled text; a heuristic check (is the result mostly
printable characters, past a minimum length) skips the file entirely rather
than indexing garbage in either case. Every extractor -- Office or PDF -- is
wrapped in its own broad exception handling, so a corrupted or
unusually-structured file can only ever drop itself out of the index, never
abort indexing for the rest of the folder or crash the index process.
Legacy binary `.doc`/`.ppt` are not recognized at all (a different, much
older format this does not attempt to parse) and are skipped like any other
unlisted extension. Anything that doesn't successfully parse under its
format is skipped regardless of extension.

**Hardened against malicious documents, not just malformed ones.** A
`.docx`/`.pptx` is a zip archive, and a PDF content stream is independently
zlib-compressed -- both formats allow a small file to decompress into many
times its own size ("zip/decompression bombs"), and `.docx`/`.pptx` XML
parts could otherwise carry a DOCTYPE-based entity-expansion ("billion
laughs") payload (`xml.etree.ElementTree`, used here, is explicitly
documented as unsafe against this with no mitigation built in, and
`defusedxml` isn't available in this offline container). Three specific
defenses, all exercised in testing against a real zip-bomb `.docx`
(~39KB compressing to 40MB) and a billion-laughs payload, confirming both
are rejected in well under a second with memory staying bounded: a shared,
per-file byte budget (`MAX_EXTRACTED_BYTES_PER_FILE`) enforced via a
`read()`-wrapping class that counts actual bytes produced (never trusting
a zip entry's own declared/claimed size, which a malicious file can simply
lie about); PDF content streams are decompressed with zlib's own
`max_length` cap for the same reason; and any DOCTYPE declaration in an
Office XML part is rejected outright before parsing (genuine OOXML parts
never contain one). A zip's own entry *count* is separately capped
(`MAX_PPTX_SLIDES`) so a `.pptx` with an adversarially large number of
near-empty slide entries can't force an unbounded number of zip-open
operations either. None of this requires trusting the instructor's upload
to be well-formed -- the same bind-mount read-only guarantee this folder
already has is necessary but not sufficient on its own, since a crafted
file can still be *read* fully even from a read-only mount.

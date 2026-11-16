# Internal notes -- Agentic AI Classroom Sandbox

This supplements `README.md` with Tufts/Pax-specific operational detail
that doesn't fit the AppVerse README template's generic structure: a
field-by-field walkthrough of the launch form, exactly what a student sees
when connecting, and a deep dive on the optional reference-documents (RAG)
feature. See `README.md` for the template-shaped overview, requirements,
and install/verify steps, and `SECURITY-OVERVIEW.md` for the full
data-handling and trust-boundary writeup.

One shared LLM server for your whole class session, with tool use and web
search built in. Each student gets their own API key into the same running
model — no one needs their own GPU job.

## Faculty vs. Student

The first thing you pick when launching is **Faculty/TA** or **Student**.

- **Faculty/TA** is everything described in the rest of this doc — you pick
  a course, configure the session, and it starts the actual GPU job.
- **Student** is for students: pick your course and submit — this does
  *not* start a GPU job. It's a small, few-second lookup job that finds
  whichever session your instructor already has running for that course and
  shows you the Base URL and your own API key directly, no need for your
  instructor to paste you a key by hand. If nothing's running yet, the page
  says so and keeps checking automatically every 15 seconds — no need to
  reload it yourself.

Only courses you're actually enrolled in (a member of that course's storage
group) show up in the Student dropdown. If your course isn't listed, or the
session was started with a manually-typed roster instead of pulled from the
course's own storage group, ask your instructor for the connection link and
key directly instead — there's nothing to auto-discover in that case.

## What you choose when you launch (Faculty/TA)

- **Class size** — sets the GPU, number of student slots, and model together.

  | Tier   | Students | Model                          |
  |--------|---------:|---------------------------------|
  | Small  | 8        | Qwen 3.6                       |
  | Medium | 16       | Qwen 3.6                       |
  | Large  | 32       | Nemotron 3.5 Lightning         |

- **Course / session label** — cosmetic, shown on the connection page.
- **Student roster** (optional) — one name/email per line, up to your class
  size. Each line gets its own private key. Leave blank for anonymous
  "Slot 1, Slot 2, ..." keys instead.
- **Session length** — the job ends automatically once this many hours pass.
- **Guardrails** (optional) — topics you don't want students using the tool
  for. This gets added to the model's system prompt on every request, so it
  applies no matter what client a student connects with. It's a strong
  nudge, not a hard filter — a determined student could still prompt around
  it. Don't rely on it for sensitive topics.
- **Reference documents** (optional) — a folder of files to pre-load into
  the chatbot's knowledge base for the whole class. Upload files to cluster
  storage first via OOD's Files app, then browse to that folder with this
  field. Indexed once when the session starts — plain text, Markdown, code
  files, Word (`.docx`), PowerPoint (`.pptx`), and PDF are all supported
  (PDF is best-effort; see below for what it can't handle) — and made
  available to every student's questions automatically; see "How the
  reference-documents feature works" below.
- **Advanced Options** (collapsed by default) — expand this to reach the
  two fields below. Collapsing it doesn't change their values; it only
  hides the controls, so sandboxing stays on by default whether or not
  you've ever opened this section.
  - **Sandbox the LLM environment** (recommended, on by default) — shadows
    your home directory with an empty, private space and shares the rest of
    the cluster filesystem back read-only, so nothing outside the session
    folder can be modified from inside. Does not isolate the network --
    see SECURITY-OVERVIEW.md. Turn it off only if an exercise needs the
    server to reach something outside its own session folder.
  - **Prompt caching** (optional, off by default) — speeds up multi-turn
    conversations by reusing cached context instead of reprocessing it
    every message. New option, not yet load-tested at real class scale.

## How students connect

If you picked a course from the dropdown (not "Other"), students enrolled in
that course's storage group can self-serve: they pick **Student** on this
same app's launch form, pick their course, and get the Base URL and their
own key automatically, without you sharing anything by hand. This can take
up to about 15 seconds to catch up after your session actually starts.

Otherwise (or in addition), the connection page gives you:
- A base URL for any OpenAI-compatible client.
- A "Launch Web UI" button — llama.cpp's own built-in chat interface.
- A list of student keys, each with a copy button.

Every student needs their own key. The first key in the roster is pre-filled
when the Web UI opens; everyone else replaces it with their own from
Settings. Students can also ask the model to search the web, or to search
academic literature (Semantic Scholar — title, authors, abstract, citation
count, and an open-access PDF link when one legally exists) — only the
query text goes out through those tools, not the rest of the conversation.

## How the reference-documents feature works

- Indexing happens **once**, at session start, before students connect —
  not per-message, per-student, or per-attachment. All students in the
  session share the same pre-built index; there's no per-student upload or
  private document set.
- Files are chunked and scored with a hybrid of TF-IDF (lexical overlap) and
  neural embeddings (`nomic-embed-text-v1.5`, served locally by a small,
  CPU-only `llama-server` instance that never touches the GPU, so it can't
  slow down or compete with the shared generation model). Both run entirely
  on this compute node — nothing about this feature leaves the cluster.
- On each chat request, the top few relevant chunks for the student's
  question are added to the system prompt automatically (same mechanism
  that already merges in Guardrails text) — no extra tool call, no change
  to how students interact with the Web UI.
- **How many chunks get included adapts to the class-size tier's own
  context window**, not a fixed count — Small/Large tiers run a much
  tighter `ctx_per_slot` (4096) than Medium (8192), and a fixed "always
  inject the top 3 chunks" budget that's comfortable on Medium could
  overflow a single request outright on Small/Large (this happened in
  testing with a large pre-loaded PowerPoint). The proxy now only includes
  as many *whole* chunks as fit under roughly a quarter of that session's
  actual `ctx_per_slot`, dropping lower-ranked ones (or skipping RAG
  context for that turn entirely) rather than ever risking an over-budget
  request.
- **Supported formats:** plain text/Markdown/code files, Word (`.docx`),
  and PowerPoint (`.pptx`) all extract reliably (pure-stdlib zip/XML
  parsing — no external library needed). **PDF is best-effort**: this
  container has no real PDF library, so PDFs are parsed with a lightweight,
  hand-rolled extractor that handles simple, standard-font, text-based PDFs
  (the common case for a Word/Google Docs/LaTeX export) but not scanned/
  image-only PDFs (no OCR) or PDFs using embedded subset/custom-encoded
  fonts, where extracted text can come out garbled. A quality check skips
  any PDF whose extracted text looks empty or garbled rather than indexing
  it — so a PDF simply not showing up in retrieval results usually means
  this extractor couldn't read it, not that nothing in it was relevant.
  Legacy binary `.doc`/`.ppt` (not the modern `.docx`/`.pptx` formats) are
  not supported at all — save as the modern format first if you hit this.
- If the folder path is invalid, the embedding model hasn't been downloaded
  yet (`./download-embedding-model.sh`, see `README.md`), or indexing fails
  for any reason, the session starts normally without reference-document
  retrieval — this is never a reason the whole job fails.
- Hardened against malicious as well as malformed documents: decompression
  bombs (zip or zlib) and XML-entity-expansion ("billion laughs") payloads
  are specifically guarded against in the extractor, not just plain
  corrupt-file handling. See `SECURITY-OVERVIEW.md` for the details and
  what was tested.

## Good to know

- The GPU is shared across the whole class. More students active at once
  means slower responses for everyone, not dedicated throughput per student.
- A session with no activity for 2 hours ends automatically to free the
  GPU for other classes.
- There's no per-student usage tracking beyond "this key exists" — we don't
  log who asked what.
- Web search can get flaky if a lot of students search at the same time;
  it degrades to an error for that one request rather than breaking the
  session.
- Guardrails and the on-page usage disclaimer are reminders to students, not
  a content filter — see `SECURITY-OVERVIEW.md` for exactly what is and
  isn't technically enforced.
- Reference documents are shared class-wide, not private per student —
  don't use this field for anything a student shouldn't see, and remember
  the folder you point it at is read by the session, not copied into it.

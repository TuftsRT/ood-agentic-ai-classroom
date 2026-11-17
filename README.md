# Agentic AI with Llama Server (Classroom)

## Overview

Agentic AI with Llama Server (Classroom) is an Open OnDemand Batch Connect app that
launches [llama.cpp](https://github.com/ggml-org/llama.cpp)'s `llama-server`
as one shared, tool-calling-capable LLM session for an entire class. It is
designed for instructors who want every student in a session talking to the
same running model -- with web search, academic literature search, and an
optional, pre-loaded reference-document knowledge base available as tools
-- without giving each student their own GPU job.

- Upstream project: [llama.cpp](https://github.com/ggml-org/llama.cpp)
- Also launches: [SearXNG](https://github.com/searxng/searxng) (local web
  search backend) and, optionally,
  [nomic-embed-text-v1.5](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5)
  (embedding model for the reference-documents feature)
- Also calls out to: the [Semantic Scholar Graph API](https://api.semanticscholar.org/)
  (open academic literature search, no API key required)

## Screenshots

Not yet captured.

## Features

- **Faculty/Student role selector.** Faculty/TAs launch the GPU session as
  described below. Students instead pick their own course and submit a
  tiny, GPU-free lookup job that finds the instructor's running session (via
  Slurm job name + a shared marker in the course's own storage) and shows
  just the Base URL and their own API key -- no need for the instructor to
  distribute connection info by hand.
- Launches `llama-server` with `--parallel` inference slots, so one GPU
  serves the whole class instead of one job per student
- Tool/function calling enabled by default (`--jinja`), with built-in
  `web_search` (loopback-only SearXNG instance) and `literature_search`
  (Semantic Scholar's open academic catalog -- title, authors, abstract,
  citation count, and an open-access PDF link when one legally exists)
  tools
- Per-student API keys generated from an optional pasted roster, shown on
  the connection page with one-click copy
- Optional instructor **guardrails** merged into the system prompt of
  every request server-side, so it applies no matter what client connects
- Optional **reference documents**: pre-load a folder of course material
  (plain text, Markdown, code, Word, PowerPoint, and best-effort PDF) into
  a shared, class-wide knowledge base, indexed once at session start with
  hybrid TF-IDF + neural-embedding retrieval
- Automatic idle shutdown (2 hours with no active/queued requests)
  frees the GPU for other classes
- Optional filesystem/process sandboxing (bubblewrap) around the model
  server

## Requirements

### Compute Node Software

- [Apptainer](https://apptainer.org/) 1.4+ (module `apptainer`)
- An NVIDIA GPU with recent drivers -- every class-size tier requests one
  GPU (`--gres=gpu:1`); there is no CPU-only tier for the generation model
- [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`), only if
  "Sandbox the LLM environment" is left on (the default)
- Lmod or Environment Modules (for `module load apptainer`)

### Open OnDemand

- Open OnDemand with Batch Connect `"basic"` template support
- Slurm scheduler, `gpu` partition, with a GPU `--constraint` matching one
  of this app's class-size tiers (48GB/80GB/141GB-class GPUs)
- Lmod / Environment Modules

### Optional

- For the reference-documents feature: the `nomic-embed-text-v1.5` GGUF
  embedding model, fetched once via `download-embedding-model.sh` (see
  below) -- the feature is skipped gracefully if this hasn't been run
- A shared GGUF model catalog and `llama-server`/SearXNG container images
  reachable from the compute node (this deployment uses Tufts HPC's own
  catalog and images; another site points `lib/class_tiers.rb` at its own
  model catalog and overrides `container_dir`/`searxng_image` in
  `config/site.yml` -- see "1. Point it at your own site" below)

## App Installation

This app is not distributed as a generic git-clonable package today -- at
this site it lives directly at `~/ondemand/dev/llm-classroom-sandbox` as a
per-user Open OnDemand dev sandbox app (same pattern as the sibling
`rag-sandbox` app). A site wanting to run this as a shared, system-wide app
instead would place it under the standard Batch Connect apps directory
(e.g. `/var/www/ood/apps/sys/`) and adjust `lib/class_tiers.rb`'s model
paths and `template/script.sh.erb`'s container paths for its own cluster.

### 1. Point it at your own site

Two different kinds of site-specific value live in this app, handled two
different ways:

**Single-value overrides -- edit `config/site.yml`, not any template or
`lib/*.rb` file.** Copy `config/site.yml.example` to `config/site.yml` and
set only the keys you need (see `lib/site_config.rb` for the full list and
its Tufts defaults): the class-storage root and its admin-group naming
convention (`storage_root`, `admin_group_suffix`), the domain suffix shown
on a connection page's Base URL (`connection_host_suffix`), the partition
the GPU-free student lookup job uses (`student_lookup_partition`), and the
two container images the Faculty job launches (`container_dir`,
`searxng_image`). An absent `config/site.yml` is exactly today's Tufts
behavior -- nothing changes until you create one.

**The model catalog -- edit `lib/class_tiers.rb` directly.** Its GGUF model
paths, mmproj paths, and Slurm `--constraint` GPU-type strings are a
site-specific table with no single "root path" to override; there's no
`config/site.yml` key for this. Point each tier's `model_file`/
`mmproj_file` at your own catalog and each `constraint` string at your own
cluster's GPU type names.

**Course auto-discovery is a Tufts-shaped feature, not just a path.**
`lib/course_storage.rb`'s Faculty/Student course dropdowns only work at
all if your site has class storage directories matching its
`NAME_PATTERN` regex (`c` + 2-digit year + 2-letter term + session digit +
course code) with a paired `<name>`/`<name>admin` group convention
(`storage_root`/`admin_group_suffix` above only relocate *where* it looks
for that convention, they don't change what it looks for). At a site
without that convention, both dropdowns simply show no auto-detected
courses -- faculty and students both fall through to "Other" and type a
course label/roster by hand, which still works, it's just manual. Adapting
the auto-discovery itself to a different site's storage convention means
editing `CourseStorage.discover`/`.discover_as_student`/`NAME_PATTERN`.

### 2. Configure for your site

#### form.yml Attributes

| Attribute | Description | Default |
|-----------|-------------|---------|
| `cluster` | Target cluster ID | `"pax"` |
| `role_select` | Faculty/TA (start a GPU session) vs. Student (look up an already-running one) | `"faculty"` |
| `course_select` | Faculty-side course picker, populated by admin-group membership; picking a real course auto-fills `course_group`/`course_name`/`reference_docs_dir` and hides the manual roster field | `"__other__"` |
| `course_select_student` | Student-side course picker, populated by base-group (not admin-group) membership. Unlike `course_select` above, this defaults to the *first* auto-detected course rather than "Other" when one exists -- see the comment on this field in `form.yml.erb` for why | first auto-detected course, else `"__other__"` |
| `course_group` | Hidden field `course_select`'s JavaScript sets; re-validated server-side against real group membership (see before.sh.erb) rather than trusted as submitted | blank |
| `course_name` | Cosmetic label shown on the connection page | blank |
| `class_size` | Picks the GPU, slot count, and model together | `"small"` |
| `roster` | One student identifier per line; each gets a private API key | blank (anonymous keys) |
| `num_hours` | Maximum session wall time (hours) | `3` |
| `guardrail_coursework` | Tells the model not to discuss or help with this course's homework/problem sets/exams | `"1"` (on) |
| `guardrail_sensitive` | Tells the model not to engage with sensitive topics (e.g. exploits/malware); turn off for a security/offensive-topics course | `"1"` (on) |
| `guardrails` | Instructor text merged into the model's system prompt on every request, in addition to whichever checkboxes above are on | blank |
| `reference_docs_dir` | Folder of files to pre-load into a shared, class-wide knowledge base. Auto-fills, when a real course is picked, to a dedicated `llm-sandbox-reference-docs` subdirectory of that course's storage (not the storage root) -- create and populate that subdirectory to opt in; see `lib/course_storage.rb`'s `REFERENCE_DOCS_SUBDIR` | blank (feature off) |
| `advanced_options` | UI-only checkbox that reveals `sandbox_llm`/`prompt_caching` below; doesn't itself change job behavior | `"0"` (collapsed) |
| `sandbox_llm` | Wrap the model server in bubblewrap (filesystem/process containment) -- stays on by default even while collapsed | `"1"` (on) |
| `prompt_caching` | Reuse cached KV state across requests with a matching prompt prefix | `"0"` (off) |

#### manifest.yml Attributes

| Attribute | Change to |
|-----------|-----------|
| `name` | Your app's display name |
| `category` / `subcategory` | Match your site's OOD taxonomy |
| `description` | Your own model choice, GPU, and data-handling guidance |

### 3. Verify

No OOD restart is needed (Batch Connect apps are detected automatically).
Visit your OOD dashboard and look for **Agentic AI Classroom Sandbox**
under **Interactive Apps > AI**.

## Troubleshooting

### Connection page says "Model is still loading" for a long time

Normal for a minute or two while the GGUF model loads onto the GPU; if a
reference-documents folder was set, it indexes concurrently with this
wait. If it never clears, check **View Server Log** on the connection page
(Faculty connection page only -- a student with the same symptom should
ask their instructor to check it, or check the job's own output log via
the OOD dashboard's job list).

### `web_search` tool returns errors for every student

Check the job's output log for `WARNING: SearXNG did not become ready in
time` -- SearXNG failed its health check at startup and the tool will keep
erroring for the rest of the session.

### `literature_search` tool returns an error

Usually a rate limit from Semantic Scholar's free, keyless anonymous tier
(`HTTP Error 429`) under concurrent classroom use -- the tool surfaces this
as a clean error rather than hanging; it should clear up after a short
wait. Not something this app can configure around without adding a
Semantic Scholar API key (not currently wired up).

### Reference documents never show up in answers

Check the output log for one of: `reference_docs_dir ... is not a
directory` (bad path), `the embedding model is missing` (run
`download-embedding-model.sh` on a login node), or `did not become ready in
time` (the embedding server or index server failed to start). Any of these
disables the feature for that session without failing the job itself.

### Student role says "No active session found" even though the instructor started one

Check the student job's own output log. The two most likely causes: (1) the
instructor's session hasn't reached the point of publishing its connection
info yet (a few seconds after startup -- it retries every 15s, so this
should clear quickly), or (2) this cluster's Slurm `PrivateData` setting
restricts a student from seeing another user's job via `squeue` at all --
see "Faculty/Student roles and session auto-discovery" in
`SECURITY-OVERVIEW.md` for the fallback mechanism and what hasn't been
verified yet about this.

### A student's Web UI shows a 401 / won't load

The connection page only pre-fills the *first* roster key into the
browser. Every other student needs to open Settings (gear icon) in the Web
UI and replace it with their own key from the roster list.

## Testing

| Site | OOD Version | Scheduler | Status |
|------|-------------|-----------|--------|
| Tufts HPC (Pax cluster) | not recorded | Slurm | Core features (shared inference, roster/keys, guardrails, web search) in classroom use. Reference-documents (RAG) feature not yet verified end-to-end on a live job -- see Known Limitations. |

To verify your installation:

1. Launch the app from the OOD dashboard with default settings.
2. Confirm the connection page reaches "Ready" and the Web UI loads with
   the first roster key pre-filled.
3. Ask a question that requires current information; confirm `web_search`
   returns a result.
4. Ask a question about a known paper (e.g. "find the paper that
   introduced the Transformer architecture"); confirm `literature_search`
   returns a result with citation count and open-access info.
5. If testing the reference-documents feature: set `reference_docs_dir` to
   a folder containing a few files, confirm the output log shows an
   `indexed N chunks` line, and ask a question about that material.

## Known Limitations

- **Student-role session auto-discovery relies on `squeue` cross-user
  visibility, which has not been verified against a real Slurm controller**
  (this cluster's `PrivateData` setting determines whether it works at all;
  see `SECURITY-OVERVIEW.md`). It fails closed (a student just never sees a
  session) rather than open.
- **Per-student API keys published for the Student role are group-readable,
  not scoped to one student**, because this cluster's NFS-mounted course
  storage doesn't support POSIX ACLs (confirmed directly). Any student in
  the course could read a classmate's key if they went looking for it; see
  `SECURITY-OVERVIEW.md` for the full tradeoff.
- **Shared GPU, not dedicated throughput.** More students active at once
  means slower responses for everyone.
- **No per-student usage tracking** beyond "this key exists" -- there is no
  logging of who asked what.
- **`web_search` can get flaky under concurrent load**; it degrades to an
  error for that one request rather than breaking the session.
- **`literature_search` has no API key and a shared anonymous rate limit**
  (Semantic Scholar) -- confirmed directly in testing that concurrent
  classroom use can trigger `HTTP Error 429`; it degrades to a clean error
  for that one call, same as `web_search` under load.
- **Reference-document context is capped by a rough, tokenizer-free
  character estimate**, not exact token counting (no tokenizer is
  available in this environment) -- it's deliberately conservative to
  avoid ever overflowing a request, which means it can occasionally
  include slightly less context than the window would technically allow,
  never more.
- **Guardrails are a system-prompt nudge, not a content filter** -- see
  `SECURITY-OVERVIEW.md` for exactly what is and isn't technically
  enforced.
- **Reference documents are shared class-wide, not private per student** --
  there is no per-student upload path, only an instructor-set folder.
- **PDF support for reference documents is best-effort.** There is no real
  PDF library in this environment; a hand-rolled extractor handles simple,
  text-based PDFs but not scanned/image-only PDFs (no OCR) or PDFs with
  embedded subset/custom-encoded fonts.
- **Legacy binary `.doc`/`.ppt` are not supported** for reference documents
  -- only the modern `.docx`/`.pptx` formats.
- **Prompt caching is new** and not yet load-tested at real class scale.
- **The reference-documents (RAG) feature has not yet been run end-to-end
  on a live Slurm/GPU job** -- its components (chunking, TF-IDF, hybrid
  retrieval scoring, and the `.docx`/`.pptx`/PDF extractors, including
  against deliberately adversarial decompression-bomb and XML-entity-
  expansion test inputs) have been verified in isolation, not as a running
  session.


## References

- [llama.cpp](https://github.com/ggml-org/llama.cpp) -- the inference
  server this app launches
- [SearXNG](https://github.com/searxng/searxng) -- local web-search backend
  for the `web_search` tool
- [Semantic Scholar Graph API](https://api.semanticscholar.org/) -- open
  academic literature search backend for the `literature_search` tool
- [nomic-embed-text-v1.5](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5)
  -- the embedding model used by the optional reference-documents feature
- [Open OnDemand](https://openondemand.org/) -- the HPC portal framework

### Software Installation

`llama-server` and SearXNG run from this site's existing, shared container
images -- nothing is built or vendored by this app
for those. The one exception is the embedding model for the optional
reference-documents feature, which this app fetches and owns its own copy
of:

```bash
./download-embedding-model.sh
```
Run on a **login node** (needs internet); downloads `nomic-embed-text-v1.5`
(GGUF, Apache-2.0, ~140MB) into this app's own `models/` folder -- the same
model and pattern the sibling `rag-sandbox` app already uses.

## License

[MIT License](LICENSE)

## Acknowledgments

Deployed on Tufts University's HPC cluster, operated by Tufts
Technology Services Research Technology.

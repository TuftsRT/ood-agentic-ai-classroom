# Changelog

All notable changes to this app are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project does
not yet use tagged releases, so entries are dated instead of versioned.

## Unreleased

### Fixed

- Student-role connection page now gates the "Launch Web UI" button and API
  key reveal behind a real `/health` check against the running session,
  matching the readiness gate the Faculty-role page already had. Previously
  it revealed both as soon as the instructor's session was merely
  *discovered* (via `squeue`/`session.json`), which could be before
  `llama-server` had finished loading the model.
- Idle-shutdown watcher no longer passes a student API key as a literal
  `curl` command-line argument (readable via `ps`/`/proc/<pid>/cmdline` by
  any other user on the same shared compute node for the life of each
  60-second poll). It now writes the header to a private, `chmod 600` file
  read via `curl -K`, the same convention already used for `llama-server`'s
  own `--api-key-file`.
- `sandbox_llm` form field help text corrected to match
  `SECURITY-OVERVIEW.md`: the session's own working folder is also shared
  back read-only (not just "the rest of the cluster filesystem"), and the
  sandbox wraps only `llama-server`'s launch, not `guardrails_proxy.py`
  (the actual network-facing process).

### Added

- `appverse.yml` and this changelog, in preparation for Appverse catalog
  submission.

## Initial feature set (pre-dates this changelog)

- Faculty/Student role selector; students self-serve a connection link and
  per-student API key via course-storage-group auto-discovery, no manual
  distribution required.
- Shared `llama-server` session with `--parallel` inference slots across
  three class-size tiers (small/medium/large), each pinned to a verified
  tool-calling-capable model and GPU constraint.
- Built-in `web_search` (loopback-only SearXNG) and `literature_search`
  (Semantic Scholar) tools, deliberately scoped narrower than llama.cpp's
  `--agent` built-ins.
- Per-student API keys generated server-side from an optional pasted
  roster, written with `chmod 600`/`umask 077` discipline; CSV-formula-
  injection and shell-injection hardening on all free-text form fields.
- Optional instructor guardrails merged into every request via a small
  enforcement proxy in front of `llama-server`.
- Optional reference-documents (RAG) feature: hybrid TF-IDF + embedding
  retrieval over an instructor-provided folder, hardened against zip/zlib
  decompression bombs and XML entity-expansion payloads in `.docx`/`.pptx`/
  PDF inputs.
- Automatic idle shutdown (2 hours with no active/queued requests).
- Optional bubblewrap sandboxing of the model server's filesystem/process
  environment.

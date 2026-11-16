# frozen_string_literal: true

# Class-size presets for the Agentic AI Classroom Sandbox.
#
# There is no real NVIDIA MIG on this cluster (GPUs are only ever requested
# whole, via `--gres=gpu:N`). The practical equivalent for serving an LLM to
# a classroom is llama.cpp's own `--parallel` slots: one GPU, one model, N
# concurrent inference streams, each with its own context -- a software
# "sub-piece" of the GPU per student instead of N separate full-GPU jobs.
# Faculty pick a class-size tier; the GPU, slot count, and model are then
# fixed for that tier so every student in the session gets an identical,
# already-verified tool-calling setup. The model itself is intentionally
# NOT exposed as a form field.
#
# Small/medium reuse Qwen3.6-35B-A3B-Q8_0 -- the same model (and mmproj)
# that both rustgis-agentic and the llm_api example already run in
# production with --jinja tool calling confirmed working, rather than an
# unverified pick. Large uses a bigger GPU and a Nemotron MoE model so the
# extra slot count doesn't come at the cost of per-request latency.
module ClassTiers
  MODELS_DIR = '/cluster/tufts/datasets/ai/models/inference/gguf'

  Tier = Struct.new(
    :key, :label, :slots, :constraint, :cpus, :mem_gb,
    :model_file, :mmproj_file, :model_label, :ctx_per_slot,
    :batch_size, :ubatch_size
  ) do
    def total_ctx
      slots * ctx_per_slot
    end
  end

  PROVEN_QWEN_DIR = File.join(MODELS_DIR, 'Qwen3.6-35B-A3B-Q8_0')
  PROVEN_QWEN = File.join(PROVEN_QWEN_DIR, 'Qwen3.6-35B-A3B-Q8_0.gguf')
  PROVEN_QWEN_MMPROJ = File.join(PROVEN_QWEN_DIR, 'mmproj-BF16.gguf')

  LARGE_NEMOTRON = File.join(
    MODELS_DIR, 'NVIDIA-Nemotron-3.5-Lightning-30B-A3B-Q8_0',
    'NVIDIA-Nemotron-3.5-Lightning-30B-A3B-Q8_0.gguf'
  )

  # batch_size/ubatch_size scale with slot count: more concurrent students
  # means more prompts eligible to be prefilled together, and llama-server's
  # continuous batching only gets that benefit up to --ubatch-size tokens at
  # a time. Doubled over llama.cpp's defaults (2048/512) for medium/large;
  # kept closer to default for small given its tighter 48G-class VRAM budget.
  TIERS = {
    'small' => Tier.new(
      'small', 'Small (up to 8 students)', 8,
      'l40s-48G|rtx_6000_ada-48G|rtx_a6000-48G', 8, 48,
      PROVEN_QWEN, PROVEN_QWEN_MMPROJ, 'Qwen3.6-35B-A3B (Q8_0)', 4096,
      2048, 1024
    ),
    'medium' => Tier.new(
      'medium', 'Medium (up to 16 students)', 16,
      'a100-80G|h100-80G', 16, 96,
      PROVEN_QWEN, PROVEN_QWEN_MMPROJ, 'Qwen3.6-35B-A3B (Q8_0)', 8192,
      4096, 2048
    ),
    'large' => Tier.new(
      'large', 'Large (up to 32 students)', 32,
      'h200-141G|rtx_pro_6000-96G', 32, 160,
      LARGE_NEMOTRON, '', 'NVIDIA Nemotron 3.5 Lightning 30B-A3B (Q8_0)', 4096,
      4096, 2048
    )
  }.freeze

  def self.fetch(key)
    TIERS.fetch(key, TIERS['small'])
  end

  def self.select_options
    TIERS.values.map { |t| [t.label, t.key] }
  end
end

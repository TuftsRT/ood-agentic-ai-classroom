# frozen_string_literal: true

require 'yaml'

# Per-site overrides for the handful of Tufts-specific values the rest of
# this app assumes by default: the class-storage root and its admin-group
# naming convention (lib/course_storage.rb), the domain suffix appended to
# the hostname shown on a connection page (view.html.erb), the partition
# used by the GPU-free student lookup job (submit.yml.erb), and the two
# container images the Faculty job launches (template/script.sh.erb).
#
# Each constant in DEFAULTS is the value this app actually runs with today
# -- a site that deploys it unmodified gets exactly today's behavior.
# Overriding one is a one-line edit to config/site.yml (see
# config/site.yml.example), never a change to a .erb template or another
# lib/*.rb file. This module does NOT cover lib/class_tiers.rb (the GPU
# constraint/model-catalog table) -- those aren't single values with one
# sane Tufts-shaped default, so README.md still asks a deployer to edit
# that file directly.
module SiteConfig
  CONFIG_PATH = File.join(__dir__, '..', 'config', 'site.yml')

  DEFAULTS = {
    'storage_root' => '/cluster/tufts',
    'admin_group_suffix' => 'admin',
    'connection_host_suffix' => '.pax.tufts.edu',
    'student_lookup_partition' => 'batch,preempt',
    'container_dir' => '/cluster/tufts/apps/container/ai/images',
    'searxng_image' => '/cluster/tufts/ngc/images/searxng_2026.7.9.sif'
  }.freeze

  # Re-read on every call rather than cached -- this runs inline while
  # rendering a form/template, same "small file, re-read every time beats a
  # stale cache" tradeoff already used for status_path/roster_csv
  # elsewhere in this app. Absent file (the Tufts case, out of the box) or
  # any parse error both fall through to {} -- i.e. every DEFAULTS value --
  # rather than ever raising out of a form render.
  def self.overrides
    return {} unless File.file?(CONFIG_PATH)

    YAML.safe_load(File.read(CONFIG_PATH)) || {}
  rescue StandardError
    {}
  end

  def self.fetch(key)
    key = key.to_s
    value = overrides[key]
    value.nil? || value.to_s.empty? ? DEFAULTS.fetch(key) : value
  end

  def self.storage_root
    fetch('storage_root')
  end

  def self.admin_group_suffix
    fetch('admin_group_suffix')
  end

  def self.connection_host_suffix
    fetch('connection_host_suffix')
  end

  def self.student_lookup_partition
    fetch('student_lookup_partition')
  end

  def self.container_dir
    fetch('container_dir')
  end

  def self.searxng_image
    fetch('searxng_image')
  end
end

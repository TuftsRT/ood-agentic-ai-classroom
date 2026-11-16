# frozen_string_literal: true

require 'shellwords'
require_relative 'site_config'

# Discovers Tufts-style "class storage" directories under STORAGE_ROOT and
# narrows them down to the ones the logged-in user actually belongs to, so
# the course dropdowns in form.yml.erb can autofill the course name, storage
# path, and (via before.sh.erb) the student roster without anyone typing it
# by hand -- for faculty/TAs via the admin dropdown, for students via a
# separate one. STORAGE_ROOT and the "<name><admin-suffix>" convention below
# are overridable per site (see lib/site_config.rb) -- NAME_PATTERN is not:
# a site with a wholly different course-naming scheme needs its own
# discovery logic, not just a different root/suffix, so .discover simply
# finds nothing there rather than guessing.
#
# Confirmed directly against a real course on a Tufts login shell (not just
# assumed): `stat -c '%G' /cluster/tufts/c27sp1xx0001` -> "c27sp1xx0001",
# and `getent group c27sp1xx0001admin` -> a *different* group
# ("c27sp1xx0001admin:*:123456:<instructor>"). So the convention is a pair of
# groups per course: the base group (same name as the storage directory) is
# the one students and faculty are both members of -- faculty/TAs are
# additionally members of the "<name>admin" group, which Tufts' self-service
# storage portal uses to control who can administer that storage (and, here,
# who sees it in the Faculty dropdown at all). We use the base group as the
# roster/student-dropdown source and admin-group membership as "can this
# user see this course as an instructor".
module CourseStorage
  STORAGE_ROOT = SiteConfig.storage_root
  ADMIN_GROUP_SUFFIX = SiteConfig.admin_group_suffix

  # How long to wait on a single `squeue` call before giving up and treating
  # it as "couldn't check" -- this runs inline while rendering the launch
  # form (or, for a student, their course dropdown), so a hung or
  # unreachable Slurm controller must never hang page rendering.
  SQUEUE_TIMEOUT_SECONDS = 3

  # Matches the class-storage naming convention seen on this account's own
  # course (c27sp1xx0001) and in Jupyter Classroom's course->storage map
  # (c26fa1cs0101, c26fa1me0102, ...): "c" + 2-digit fiscal year + 2-letter
  # term code + session digit + course code (letters then digits).
  #
  # Deliberately narrower than "any directory with a matching <name>admin
  # group" -- Tufts' self-service storage portal uses the same base/admin
  # group pairing for lab and project storage too, which would otherwise
  # leak every lab an instructor happens to administer into a "pick your
  # course" dropdown meant only for classes.
  NAME_PATTERN = /\Ac\d{2}[a-z]{2}\d([a-z]+\d+)\z/i

  OTHER_VALUE = '__other__'

  # Autofilled reference_docs_dir points here, under the course storage
  # root, rather than at the root itself -- indexing the whole course tree
  # by default (everything from assignment submissions to other sections'
  # material) is far more than "pre-load some reference documents" implies,
  # and rag_index_server.py walks it as the instructor, not scoped to what
  # a student could already read. An instructor who wants the feature
  # creates this subdirectory and puts only what they intend to share in
  # it; one who doesn't gets a directory that doesn't exist yet, which
  # before.sh.erb already treats as "feature disabled for this session" --
  # same safe-by-default behavior as before, just scoped to an empty
  # subdirectory instead of an occupied root.
  REFERENCE_DOCS_SUBDIR = 'llm-sandbox-reference-docs'

  CourseDir = Struct.new(:dir_name, :path, :group, :admin_group, :code)

  # The Rails process rendering this form runs as the actual logged-in user
  # (OOD's per-user NGINX/Passenger model), so its own supplementary groups
  # are exactly the groups to check -- no separate user lookup needed.
  def self.current_user_groups
    `id -Gn`.split
  rescue StandardError
    []
  end

  def self.discover(groups = current_user_groups)
    discover_matching(groups) { |dir_name| groups.include?("#{dir_name}#{ADMIN_GROUP_SUFFIX}") }
  end

  # Student-facing counterpart to .discover above: same storage-directory
  # naming convention, but gated on membership in the *base* group (the one
  # that actually grants access to the storage) rather than the "<name>admin"
  # group. Faculty/TAs are members of both, so a faculty member opening the
  # Student role still sees their own courses here too -- expected, not a bug
  # (see the module comment above).
  def self.discover_as_student(groups = current_user_groups)
    discover_matching(groups) { |dir_name| groups.include?(dir_name) }
  end

  def self.discover_matching(groups)
    return [] unless Dir.exist?(STORAGE_ROOT)

    courses = []
    Dir.children(STORAGE_ROOT).sort.each do |dir_name|
      match = NAME_PATTERN.match(dir_name)
      next unless match
      next unless yield(dir_name)

      admin_group = "#{dir_name}#{ADMIN_GROUP_SUFFIX}"
      courses << CourseDir.new(dir_name, File.join(STORAGE_ROOT, dir_name), dir_name, admin_group, match[1].upcase)
    end
    courses
  rescue StandardError
    []
  end
  private_class_method :discover_matching

  # Builds the JSON `options:` array for the course_select widget: one entry
  # per discovered course plus a trailing "Other" entry. Known-course entries
  # carry the per-option dynamic-form directives (see
  # https://osc.github.io/ood-documentation -> Dynamic Form Widgets) that
  # autofill course_name/reference_docs_dir/course_group and hide the manual
  # roster field; "Other" explicitly clears course_group/course_name so
  # switching back to it doesn't leave a stale autofilled value behind.
  def self.select_options(courses)
    options = courses.map do |c|
      # The dropdown's own option label stays detailed ("CODE (dir_name)")
      # to disambiguate at pick-time, but the cosmetic course_name field it
      # autofills only needs the short code -- repeating the storage
      # directory name on the connection page adds noise without helping
      # anyone tell sessions apart.
      [
        "#{c.code} (#{c.dir_name})",
        c.dir_name,
        {
          'data-set-course-name' => c.code,
          'data-set-reference-docs-dir' => File.join(c.path, REFERENCE_DOCS_SUBDIR),
          'data-set-course-group' => c.group,
          'data-set-advanced-options' => 1,
          'data-hide-roster' => true
        }
      ]
    end
    options << [
      'Other (enter manually)',
      OTHER_VALUE,
      {
        'data-set-course-group' => '',
        'data-set-course-name' => ''
      }
    ]
    options
  end

  # Student dropdown's options are deliberately simpler than the Faculty
  # one above: there's no roster/reference-docs/advanced-options field to
  # autofill on that side of the form (see form.yml.erb), so each option's
  # own value (the storage directory name) is all script.sh.erb/
  # before.sh.erb need -- it's re-derived and re-validated server-side on
  # the compute node anyway, exactly like course_group is for Faculty (see
  # the "course_group rides in on a hidden form field" comment in
  # before.sh.erb), never trusted as-is just because it showed up in the
  # option list here.
  def self.select_options_student(courses)
    options = courses.map { |c| ["#{c.code} (#{c.dir_name})", c.dir_name] }
    options << ['Other (my course is not listed)', OTHER_VALUE]
    options
  end

  # Strips a course/storage-group name down to the charset Slurm job names
  # are known to behave well with, for use in --job-name/squeue --name. Not
  # a security boundary by itself (job names aren't shell/SQL/etc., just a
  # Slurm string) -- this exists so a free-typed "Other" course label, or any
  # future caller, can't accidentally produce a job name containing spaces,
  # slashes beyond the one separator we add ourselves, or other characters
  # that could make `squeue --name=...` matching unreliable. Returns nil for
  # an empty/unresolvable input rather than an empty string, so callers can
  # tell "no course group" apart from "sanitized down to nothing".
  def self.safe_group_name(raw)
    cleaned = raw.to_s.gsub(/[^A-Za-z0-9_-]/, '')
    cleaned.empty? ? nil : cleaned[0, 64]
  end

  # The Slurm job name both Faculty and Student submissions key off of, so a
  # student's session can find the instructor's GPU job (and vice versa, for
  # the "already running" dropdown hint) purely via `squeue --name=...` --
  # deliberately not dependent on reading anything under the instructor's own
  # (permission-restricted) OOD session directory. nil for course groups that
  # don't sanitize to anything (ad hoc/manual "Other" sessions have no
  # storage group to key off of, and also never appear in the Student
  # dropdown in the first place -- see .discover_as_student).
  def self.job_name_for(course_group)
    # OTHER_VALUE ("__other__") sanitizes to itself under safe_group_name's
    # charset filter -- it has to be excluded explicitly here, or an ad hoc/
    # manual ("Other") submission gets a seemingly-real, but meaningless,
    # "llm-classroom-sandbox/__other__" job name instead of falling back to
    # the generic "adhoc" one (confirmed directly against a real
    # submission). Harmless either way -- before.sh.erb's own course_group
    # handling already treats OTHER_VALUE as "no course" independently of
    # this -- but worth not leaking a bogus-looking group name into squeue.
    return nil if course_group.to_s == OTHER_VALUE

    group = safe_group_name(course_group)
    group ? "llm-classroom-sandbox/#{group}" : nil
  end

  # Best-effort squeue lookup for a course's job name, used to annotate the
  # Faculty course dropdown with an "already running" hint and to let a
  # student's own lightweight viewer job find the instructor's session.
  # Returns nil on anything from "no such job" to "squeue isn't reachable
  # from here" -- the caller's job either way is to degrade gracefully, not
  # to tell those cases apart. `squeue`'s own cross-user visibility (whether
  # a student can see a job submitted by their instructor at all) depends on
  # this cluster's Slurm `PrivateData` setting; this has not been verified
  # against the real controller from an unprivileged login/compute node
  # shell, only that `script: job_name:` in submit.yml.erb is itself a real,
  # renderable ood_core key (confirmed against sibling apps' submit.yml.erb).
  def self.active_session?(course_group)
    job_name = job_name_for(course_group)
    return nil unless job_name

    out = `timeout #{SQUEUE_TIMEOUT_SECONDS}s squeue --noheader --name=#{job_name.shellescape} --format='%i|%T|%u' 2>/dev/null`
    line = out.lines.first
    return nil unless line

    job_id, state, user = line.strip.split('|', 3)
    return nil if job_id.to_s.empty?

    { job_id: job_id, state: state, user: user }
  rescue StandardError
    nil
  end
end

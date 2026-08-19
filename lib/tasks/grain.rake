# frozen_string_literal: true

namespace :grain do
  desc "Check every rollup against its source. VERIFY_REPAIR=1 rebuilds what disagrees."
  task verify: :environment do
    repair = ENV["VERIFY_REPAIR"] == "1"
    reports = Grain::Registry.all.map { |rollup| rollup.verify(repair: repair) }
    reports.each { |report| puts report }

    # A non-zero exit so this can gate a build: a rollup that quietly disagrees
    # with its source is worse than one that is obviously broken.
    abort("grain:verify found disagreements") if reports.any? { |report| !report.clean? } && !repair
  end

  desc "Drain the change log until it is empty."
  task drain: :environment do
    applied = Grain::Worker.drain
    puts "grain: applied #{applied} change log #{'entry'.pluralize(applied)}"
  end
end

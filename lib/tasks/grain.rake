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

  desc "Re-attach the trigger function and every trigger. Needed after a schema load."
  task triggers: :environment do
    tables = Grain::Installer.install!
    if tables.empty?
      puts "grain: no rollups found, nothing to attach"
    else
      puts "grain: triggers attached to #{tables.join(", ")}"
    end
  end

  desc "Populate a rollup from data that already exists. ROLLUP=Name [FROM=2026-08-01] [PAUSE=0.5]"
  task backfill: :environment do
    name = ENV.fetch("ROLLUP") { abort("grain:backfill needs ROLLUP=SomeRollup") }
    rollup = Grain::RollupLookup.find!(name)
    from = ENV["FROM"]
    slices = rollup.backfill(from: from, pause: ENV.fetch("PAUSE", 0).to_f) do |value, index, total|
      # Printed so an interrupted backfill can be resumed with FROM= the last
      # slice reported: they are processed in order and repeating one is harmless.
      puts "grain: #{rollup} slice #{index}/#{total} #{value}"
    end
    puts "grain: #{rollup} backfilled #{slices} #{"slice".pluralize(slices)}"
  end

  desc "Drain the change log until it is empty."
  task drain: :environment do
    applied = Grain::Worker.drain
    puts "grain: applied #{applied} change log #{"entry".pluralize(applied)}"
  end
end

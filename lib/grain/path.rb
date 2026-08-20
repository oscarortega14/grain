# frozen_string_literal: true

module Grain
  # A declared route from the fact table to a value: zero or more belongs_to
  # association hops ending in a column.
  #
  #   Path.parse(:user_id)
  #   # hops [], column :user_id
  #
  #   Path.parse(testing_section: :school_id)
  #   # hops [:testing_section], column :school_id
  #
  #   Path.parse(testing_section: { assessment_window: :starts_on })
  #   # hops [:testing_section, :assessment_window], column :starts_on
  #
  # Only belongs_to chains are allowed. Every fact row has to resolve to exactly
  # one value per dimension: cross a has_many and a single row would land in
  # several cells at once, silently doubling every count.
  class Path
    MAX_HOPS = 3

    attr_reader :hops, :column

    def self.parse(via)
      hops, column = walk(via, [])
      new(hops, column)
    end

    # A path with no terminal column: just the associations a measure's expression
    # needs joined in, so it can read their columns.
    #
    #   parse_association(:match)          # hops [:match]
    #   parse_association(order: :store)   # hops [:order, :store]
    def self.parse_association(through)
      case through
      when Symbol, String then new([through], nil)
      when Hash
        hops, column = walk(through, [])
        new(hops + [column], nil)
      else
        raise InvalidDefinitionError, "through takes an association name or a nested hash, got #{through.inspect}"
      end
    end

    def self.walk(via, hops)
      case via
      when Symbol, String then [hops, via.to_sym]
      when Hash then walk_hash(via, hops)
      else
        raise InvalidDefinitionError,
              "via takes a column name or a nested hash of associations, got #{via.inspect}"
      end
    end
    private_class_method :walk

    def self.walk_hash(via, hops)
      unless via.size == 1
        raise InvalidDefinitionError,
              "each via hop takes exactly one association, got #{via.keys.inspect}"
      end

      association, rest = via.first
      walk(rest, hops + [association.to_sym])
    end
    private_class_method :walk_hash

    def initialize(hops, column)
      @hops = hops.map(&:to_sym).freeze
      @column = column&.to_sym
      validate!
      freeze
    end

    # A local path reads a column straight off the fact table, so no other table
    # has to be watched to keep it correct.
    def local?
      hops.empty?
    end

    def root_hop
      hops.first
    end

    def to_s
      (hops + [column]).compact.join(".")
    end

    def inspect
      "#<Grain::Path #{self}>"
    end

    def ==(other)
      other.is_a?(Path) && other.hops == hops && other.column == column
    end
    alias eql? ==

    def hash
      [hops, column].hash
    end

    private

    def validate!
      return if hops.size <= MAX_HOPS

      raise InvalidDefinitionError, "#{self} crosses #{hops.size} associations, the limit is #{MAX_HOPS}"
    end
  end
end

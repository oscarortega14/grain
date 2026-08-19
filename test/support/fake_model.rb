# frozen_string_literal: true

# Stand-ins for ActiveRecord models. Grain only ever asks a model for its columns
# and its belongs_to reflections, so that is all these provide.
#
# Fakes rather than a real database on purpose: what is under test is Grain's type
# rules, not an adapter's type mapping. SQLite would report a bigint column as an
# integer and the tests would be asserting the adapter's behaviour instead of ours.
module FakeModel
  Column = Struct.new(:type, :null)
  Reflection = Struct.new(:klass, :macro) do
    def belongs_to?
      macro == :belongs_to
    end
  end

  def self.extended(base)
    base.instance_variable_set(:@fake_columns, {})
    base.instance_variable_set(:@fake_associations, {})
  end

  def column(name, type, null: false)
    @fake_columns[name.to_s] = Column.new(type, null)
  end

  def fake_belongs_to(name, klass)
    @fake_associations[name.to_sym] = Reflection.new(klass, :belongs_to)
  end

  def fake_has_many(name, klass)
    @fake_associations[name.to_sym] = Reflection.new(klass, :has_many)
  end

  def columns_hash
    @fake_columns
  end

  def reflect_on_association(name)
    @fake_associations[name.to_sym]
  end
end

class FakeCategory
  extend FakeModel
  column :id, :bigint
end

class FakeProduct
  extend FakeModel
  column :id, :bigint
  # Deliberately nullable: an uncategorised product is ordinary, and it is what
  # forces the surrogate key path.
  column :category_id, :bigint, null: true
  fake_belongs_to :category, FakeCategory
end

class FakeStore
  extend FakeModel
  column :id, :bigint
  column :currency, :string
end

class FakeOrder
  extend FakeModel
  column :id, :bigint
  column :store_id, :bigint
  column :placed_at, :datetime
  column :state, :string
  fake_belongs_to :store, FakeStore
  fake_has_many :line_items, nil
end

class FakeLineItem
  extend FakeModel
  column :id, :bigint
  column :order_id, :bigint
  column :product_id, :bigint
  column :quantity, :integer
  column :unit_price_cents, :bigint
  fake_belongs_to :order, FakeOrder
  fake_belongs_to :product, FakeProduct
end

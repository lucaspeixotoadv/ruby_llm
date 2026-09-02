# frozen_string_literal: true

class AddEmbeddingDimensionsToModels < ActiveRecord::Migration[7.0]
  def change
    return if column_exists?(:models, :embedding_dimensions)

    add_column :models, :embedding_dimensions, :json
  end
end

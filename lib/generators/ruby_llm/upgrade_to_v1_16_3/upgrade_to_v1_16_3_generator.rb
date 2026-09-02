# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require_relative '../generator_helpers'

module RubyLLM
  module Generators
    # Generator adding the embedding_dimensions column introduced in the 1.16.3 fork tag.
    class UpgradeToV1163Generator < Rails::Generators::Base
      include Rails::Generators::Migration
      include RubyLLM::Generators::GeneratorHelpers

      namespace 'ruby_llm:upgrade_to_v1_16_3'
      source_root File.expand_path('templates', __dir__)

      argument :model_mappings, type: :array, default: [], banner: 'model:ModelName'

      desc 'Adds the embedding_dimensions column introduced in the 1.16.3 fork tag'

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_migration_file
        parse_model_mappings

        migration_template 'add_v1_16_3_model_columns.rb.tt',
                           'db/migrate/add_ruby_llm_v1_16_3_columns.rb',
                           migration_version: migration_version,
                           model_table_name: model_table_name
      end

      def show_next_steps
        say_status :success, 'Upgrade prepared!', :green
        say <<~INSTRUCTIONS

          Next steps:
          1. Review the generated migration
          2. Run: bin/rails db:migrate
          3. Refresh the registry so the new column is populated:
             bin/rails runner "Model.refresh!"

          Embedding models now carry their vector width in embedding_dimensions.
          Read it from there - max_output_tokens is a token limit and does not
          describe a vector.

        INSTRUCTIONS
      end
    end
  end
end

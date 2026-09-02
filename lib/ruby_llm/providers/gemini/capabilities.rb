# frozen_string_literal: true

module RubyLLM
  module Providers
    class Gemini
      # Provider-level capability checks and narrow registry fallbacks.
      module Capabilities
        module_function

        # Google announced an introductory price for these models that expires
        # on a known date, so both prices are recorded with the window each one
        # applies to. Writing only today's number would make the registry wrong
        # the moment the date passes.
        #
        # Source: Google Cloud "Agent Platform / Vertex AI" pricing page,
        # Standard tier, Global region (Input covers text, image, video and
        # audio alike - there is no separate audio price for these models).
        # Explicit context-cache *storage* is billed per token-hour, which this
        # registry has no way to express, so cache writes stay unknown.
        FLASH_3_6_3_7_SCHEDULE = [
          {
            effective_until: '2027-01-01',
            input_per_million: 0.75,
            output_per_million: 3.75,
            cache_read_input_per_million: 0.075
          },
          {
            effective_from: '2027-01-01',
            input_per_million: 1.50,
            output_per_million: 7.50,
            cache_read_input_per_million: 0.15
          }
        ].freeze

        PRICES = {
          flash_2: { input: 0.10, output: 0.40 }, # rubocop:disable Naming/VariableNumber
          flash_lite_2: { input: 0.075, output: 0.30 }, # rubocop:disable Naming/VariableNumber
          flash: { input: 0.075, output: 0.30 },
          flash_8b: { input: 0.0375, output: 0.15 },
          pro: { input: 1.25, output: 5.0 },
          pro_2_5: { input: 0.12, output: 0.50 }, # rubocop:disable Naming/VariableNumber
          gemini_embedding: { input: 0.002, output: 0.004 },
          embedding: { input: 0.00, output: 0.00 },
          imagen: { price: 0.03 },
          aqa: { input: 0.00, output: 0.00 },
          flash_3_6_3_7: { schedule: FLASH_3_6_3_7_SCHEDULE } # rubocop:disable Naming/VariableNumber
        }.freeze

        def supports_tool_choice?(_model_id)
          true
        end

        def supports_tool_parallel_control?(_model_id)
          false
        end

        def context_window_for(model_id)
          case model_id
          when /gemini-2\.5-pro-exp-03-25/, /gemini-2\.0-flash/, /gemini-2\.0-flash-lite/, /gemini-1\.5-flash/,
               /gemini-1\.5-flash-8b/
            1_048_576
          when /gemini-1\.5-pro/ then 2_097_152
          when /gemini-embedding-exp/ then 8_192
          when /text-embedding-004/, /embedding-001/ then 2_048
          when /aqa/ then 7_168
          when /imagen-3/ then nil
          else 32_768
          end
        end

        def max_tokens_for(model_id)
          case model_id
          when /gemini-2\.5-pro-exp-03-25/ then 64_000
          when /gemini-2\.0-flash/, /gemini-2\.0-flash-lite/, /gemini-1\.5-flash/, /gemini-1\.5-flash-8b/,
               /gemini-1\.5-pro/
            8_192
          when /gemini-embedding-exp/ then nil
          when /text-embedding-004/, /embedding-001/ then 768
          when /imagen-3/ then 4
          else 4_096
          end
        end

        def critical_capabilities_for(model_id)
          capabilities = []
          capabilities << 'function_calling' if supports_functions?(model_id)
          capabilities << 'structured_output' if supports_structured_output?(model_id)
          capabilities << 'vision' if supports_vision?(model_id)
          capabilities
        end

        # Returns pricing only for families we actually know the price of.
        #
        # An unknown family yields an empty hash, not a guess: the registry then
        # records no pricing for the model and Cost reports the cost as unknown
        # rather than as a plausible-looking wrong number. A family priced at
        # 0.00 is a known free price and is reported as such.
        def pricing_for(model_id)
          prices = PRICES[pricing_family(model_id)]
          return {} unless prices
          return { text_tokens: { standard: { schedule: prices[:schedule] } } } if prices[:schedule]

          standard = {
            input_per_million: prices[:input] || prices[:price],
            output_per_million: prices[:output] || prices[:price]
          }.compact
          return {} if standard.empty?

          { text_tokens: { standard: standard } }
        end

        # Modalities we have an official statement for, and nothing else.
        #
        # ListModels does not report modalities at all, so the alternative to an
        # empty answer here is a guess. Google's own pricing page bills 3.6 and
        # 3.7 Flash input as "text, image, video, audio" and their output as
        # text, which is a statement about what the models accept.
        def modalities_for(model_id)
          case model_id
          when /\Agemini-3\.[67]-flash\z/
            { input: %w[text image video audio pdf], output: %w[text] }
          else
            {}
          end
        end

        def supports_vision?(model_id)
          return false if model_id.match?(/text-embedding|embedding-001|aqa/)

          model_id.match?(/gemini|flash|pro|imagen/)
        end

        def supports_functions?(model_id)
          return false if model_id.match?(/text-embedding|embedding-001|aqa|flash-lite|imagen|gemini-2\.0-flash-lite/)

          model_id.match?(/gemini|pro|flash/)
        end

        def supports_structured_output?(model_id)
          if model_id.match?(/text-embedding|embedding-001|aqa|imagen|gemini-2\.0-flash-lite|gemini-2\.5-pro-exp-03-25/)
            return false
          end

          model_id.match?(/gemini|pro|flash/)
        end

        def pricing_family(model_id)
          case model_id
          when /\Agemini-3\.[67]-flash\z/ then :flash_3_6_3_7 # rubocop:disable Naming/VariableNumber
          when /gemini-2\.5-pro-exp-03-25/ then :pro_2_5 # rubocop:disable Naming/VariableNumber
          when /gemini-2\.0-flash-lite/ then :flash_lite_2 # rubocop:disable Naming/VariableNumber
          when /gemini-2\.0-flash/ then :flash_2 # rubocop:disable Naming/VariableNumber
          when /gemini-1\.5-flash-8b/ then :flash_8b
          when /gemini-1\.5-flash/ then :flash
          when /gemini-1\.5-pro/ then :pro
          when /gemini-embedding-exp/ then :gemini_embedding
          # Only the legacy embedders are actually free. Newer ones such as
          # gemini-embedding-001 are billed, so they fall through to :base and
          # are reported as unknown rather than as free.
          when /text-embedding-004/, /\Aembedding-001\z/ then :embedding
          when /imagen/ then :imagen
          when /aqa/ then :aqa
          else :base
          end
        end

        module_function :context_window_for, :max_tokens_for, :critical_capabilities_for, :pricing_for,
                        :supports_vision?, :supports_functions?, :supports_structured_output?, :pricing_family,
                        :modalities_for
      end
    end
  end
end

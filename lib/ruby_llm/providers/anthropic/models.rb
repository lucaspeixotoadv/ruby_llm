# frozen_string_literal: true

require 'time'

module RubyLLM
  module Providers
    class Anthropic
      # Models methods of the Anthropic API integration
      module Models
        module_function

        # The effort levels in the order the API documents them.
        EFFORTS = %w[low medium high xhigh max].freeze

        # The smallest thinking budget the API takes (`budget_tokens`).
        MINIMUM_THINKING_BUDGET = 1024

        def models_url
          'v1/models'
        end

        # `/v1/models` describes each model in the API's own words: the context
        # window, the output ceiling and a `capabilities` tree with
        # `supported: true/false` at every leaf. How reasoning is steered comes
        # from it as `reasoning_options` - the API is the first-hand source for
        # which efforts a model takes and whether its thinking can be turned
        # off or given a budget.
        def parse_list_models_response(response, slug, _capabilities)
          Array(response.body['data']).map do |model_data|
            model_id = model_data['id']
            capabilities = model_data['capabilities'] || {}
            reasoning_options = reasoning_options_from(capabilities)

            Model::Info.new(
              id: model_id,
              name: model_data['display_name'] || model_id,
              provider: slug,
              created_at: Time.parse(model_data['created_at']),
              context_window: model_data['max_input_tokens'],
              max_output_tokens: model_data['max_tokens'],
              capabilities: listed_capabilities(capabilities),
              metadata: reasoning_options.empty? ? {} : { reasoning_options: reasoning_options }
            )
          end
        end

        def listed_capabilities(capabilities)
          {
            'vision' => supported?(capabilities, 'image_input'),
            'structured_output' => supported?(capabilities, 'structured_outputs'),
            'reasoning' => supported?(capabilities, 'thinking')
          }.select { |_name, listed| listed }.keys
        end

        # `toggle` when thinking can be turned off (`disabled`), the efforts the
        # model takes, and `budget_tokens` when it takes a thinking budget
        # (`enabled`) - the vocabulary models.dev uses for the same facts.
        def reasoning_options_from(capabilities)
          types = capabilities.dig('thinking', 'types') || {}
          efforts = EFFORTS.select { |effort| supported?(capabilities, 'effort', effort) }

          options = []
          options << { type: 'toggle' } if supported?(types, 'disabled')
          options << { type: 'effort', values: efforts } if efforts.any?
          options << { type: 'budget_tokens', min: MINIMUM_THINKING_BUDGET } if supported?(types, 'enabled')
          options
        end

        def supported?(tree, *path)
          tree.dig(*path, 'supported') == true
        end

        def extract_model_id(data)
          data.dig('message', 'model')
        end

        def extract_input_tokens(data)
          data.dig('message', 'usage', 'input_tokens')
        end

        def extract_output_tokens(data)
          data.dig('message', 'usage', 'output_tokens') || data.dig('usage', 'output_tokens')
        end

        def extract_cached_tokens(data)
          data.dig('message', 'usage', 'cache_read_input_tokens') || data.dig('usage', 'cache_read_input_tokens')
        end

        def extract_cache_creation_tokens(data)
          Chat.cache_creation_tokens(extract_usage(data))
        end

        def extract_cache_creation_1h_tokens(data)
          Chat.cache_creation_1h_tokens(extract_usage(data))
        end

        # The usage of a stream event: `message_start` carries it in the
        # message, `message_delta` at the top.
        def extract_usage(data)
          data.dig('message', 'usage') || data['usage'] || {}
        end
      end
    end
  end
end

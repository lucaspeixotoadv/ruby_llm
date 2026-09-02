# frozen_string_literal: true

module RubyLLM
  module Providers
    class Gemini
      # Models methods for the Gemini API integration
      module Models
        module_function

        def models_url
          'models'
        end

        def parse_list_models_response(response, slug, capabilities)
          Array(response.body['models']).map do |model_data|
            model_id = model_data['name'].gsub('models/', '')

            Model::Info.new(
              id: model_id,
              name: model_data['displayName'] || model_id,
              provider: slug,
              created_at: nil,
              context_window: model_data['inputTokenLimit'] || capabilities.context_window_for(model_id),
              max_output_tokens: model_data['outputTokenLimit'] || capabilities.max_tokens_for(model_id),
              capabilities: model_capabilities(model_data, model_id, capabilities),
              modalities: capabilities.modalities_for(model_id),
              pricing: capabilities.pricing_for(model_id),
              metadata: {
                version: model_data['version'],
                description: model_data['description'],
                supported_generation_methods: model_data['supportedGenerationMethods']
              }
            )
          end
        end

        # ListModels reports two facts we would otherwise re-derive by guessing:
        # whether the model thinks, and whether it can back a context cache.
        # Take them from the API rather than from a pattern match on the id.
        def model_capabilities(model_data, model_id, capabilities)
          list = capabilities.critical_capabilities_for(model_id)
          list << 'reasoning' if model_data['thinking']
          list << 'caching' if Array(model_data['supportedGenerationMethods']).include?('createCachedContent')
          list.uniq
        end
      end
    end
  end
end

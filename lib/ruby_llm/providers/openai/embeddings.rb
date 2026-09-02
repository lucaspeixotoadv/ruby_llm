# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Embeddings methods of the OpenAI API integration
      module Embeddings
        module_function

        def embedding_url(...)
          'embeddings'
        end

        def render_embedding_payload(text, model:, dimensions:)
          {
            model: model,
            input: text,
            dimensions: dimensions
          }.compact
        end

        def parse_embedding_response(response, model:, text:)
          data = response.body
          # nil, not 0, when the response carries no usage: we did not measure
          # zero tokens, we measured nothing.
          input_tokens = data.dig('usage', 'prompt_tokens')&.to_i
          vectors = data['data'].map { |d| d['embedding'] }
          vectors = vectors.first if vectors.length == 1 && !text.is_a?(Array)

          Embedding.new(vectors:, model:, input_tokens:)
        end
      end
    end
  end
end

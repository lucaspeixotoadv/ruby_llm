# frozen_string_literal: true

module RubyLLM
  module Providers
    class Gemini
      # Embeddings methods for the Gemini API integration
      module Embeddings
        module_function

        def embedding_url(model:)
          "models/#{model}:batchEmbedContents"
        end

        def render_embedding_payload(text, model:, dimensions:, task: nil, title: nil)
          { requests: [text].flatten.map { |t| single_embedding_payload(t, model:, dimensions:, task:, title:) } }
        end

        # Google's wire spelling of a RubyLLM task name. The taskType enum of
        # EmbedContentRequest is exactly the upcased set of task names, which
        # is why this is a translation and not a lookup table to keep in sync.
        def task_type_for(task)
          task && Embedding::Task.from(task).to_s.upcase
        end

        def parse_embedding_response(response, model:, text:)
          body = response.body
          vectors = body['embeddings']&.map { |e| e['values'] }
          vectors = vectors.first if vectors&.length == 1 && !text.is_a?(Array)

          Embedding.new(vectors:, model:, input_tokens: extract_embedding_input_tokens(body))
        end

        # BatchEmbedContentsResponse carries an optional usageMetadata with
        # promptTokenCount. Older responses omit it entirely; then usage is
        # genuinely unknown and stays nil rather than being reported as 0.
        #
        # Named apart from Streaming#extract_input_tokens: both modules are
        # mixed into the same provider, so a shared name would shadow one.
        def extract_embedding_input_tokens(body)
          return nil unless body.is_a?(Hash)

          usage = body['usageMetadata']
          return nil unless usage.is_a?(Hash)

          prompt_tokens = usage['promptTokenCount']
          prompt_tokens&.to_i
        end

        private

        # taskType, title and outputDimensionality are sent as top-level
        # EmbedContentRequest fields. The v1beta discovery document marks them
        # deprecated in favour of embedContentConfig, but they remain the
        # fields the batchEmbedContents endpoint serves today and the ones this
        # payload has always used for dimensions.
        #
        # title is passed through as given: whether a task may carry one is
        # decided once, in Embedding::Task, not re-decided here.
        def single_embedding_payload(text, model:, dimensions:, task:, title:)
          {
            model: "models/#{model}",
            content: { parts: [{ text: text.to_s }] },
            taskType: task_type_for(task),
            title: title,
            outputDimensionality: dimensions
          }.compact
        end
      end
    end
  end
end

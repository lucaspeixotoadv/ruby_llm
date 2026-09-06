# frozen_string_literal: true

module RubyLLM
  class Embedding
    # What an embedding is *for*.
    #
    # The same sentence embedded as a document to be indexed and as a query to
    # search that index is not the same vector on every provider: Google's
    # embedding models take a taskType and produce asymmetric vectors tuned for
    # the side of the retrieval they were asked about. Only the calling
    # application knows which side it is on, so it says so, and this object
    # carries that intent through RubyLLM provider-agnostically.
    #
    # The names mirror the task types Google documents for EmbedContentRequest,
    # which is the only vocabulary any supported provider exposes today. A
    # provider whose API has no such parameter accepts none of them rather than
    # quietly ignoring the request - see Provider#embed.
    class Task
      NAMES = %i[
        retrieval_document
        retrieval_query
        semantic_similarity
        classification
        clustering
        question_answering
        fact_verification
        code_retrieval_query
      ].freeze

      # A title describes a document, so only a document embedding can carry
      # one. Google states the same rule for EmbedContentConfig.title: "Only
      # applicable when TaskType is RETRIEVAL_DOCUMENT".
      TITLED = %i[retrieval_document].freeze

      attr_reader :name

      # Accepts a Task, a RubyLLM task name (:retrieval_document,
      # 'retrieval_document') or a provider's own spelling of it
      # ('RETRIEVAL_DOCUMENT'), and nil for "no task stated".
      def self.from(value)
        return nil if value.nil?
        return value if value.is_a?(self)

        new(value)
      end

      # Coerces a task and checks it against the title it was given.
      #
      # This is the one place the task/title rule lives; both the public API
      # and Provider#embed call it, so a direct provider call is checked by
      # the same rule as RubyLLM.embed rather than by a copy of it.
      def self.coerce(task, title: nil)
        task = from(task)
        return task if title.nil? || task&.accepts_title?

        raise InvalidEmbeddingTaskError,
              'title: is only meaningful for an embedding task that describes a document ' \
              "(#{TITLED.join(', ')}), got #{task ? task.name.inspect : 'no task'}."
      end

      def initialize(name)
        @name = self.class.send(:normalize, name)
      end

      def self.normalize(value)
        name = value.to_s.strip.downcase.to_sym
        return name if NAMES.include?(name)

        raise InvalidEmbeddingTaskError,
              "Unknown embedding task #{value.inspect}. Known tasks: #{NAMES.join(', ')}."
      end
      private_class_method :normalize

      # True when this task takes a title alongside the text.
      def accepts_title?
        TITLED.include?(name)
      end

      def to_sym
        name
      end

      def to_s
        name.to_s
      end

      def ==(other)
        other.is_a?(self.class) && name == other.name
      end
      alias eql? ==

      def hash
        name.hash
      end

      def inspect
        "#<#{self.class.name} #{name}>"
      end
    end
  end
end

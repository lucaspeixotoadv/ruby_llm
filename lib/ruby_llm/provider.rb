# frozen_string_literal: true

require 'json'
require 'ruby_llm/error'

module RubyLLM
  # Base class for LLM providers.
  class Provider
    include Streaming

    attr_reader :config, :connection

    def initialize(config)
      @config = config
      ensure_configured!
      @connection = Connection.new(self, @config)
    end

    def api_base
      raise NotImplementedError
    end

    def headers
      {}
    end

    def slug
      self.class.slug
    end

    def name
      self.class.name
    end

    def capabilities
      self.class.capabilities
    end

    def configuration_requirements
      self.class.configuration_requirements
    end

    # rubocop:disable-next Metrics/ParameterLists
    def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil,
                 tool_prefs: nil, &)
      normalized_temperature = maybe_normalize_temperature(temperature, model)

      payload = Utils.deep_merge(
        render_payload(
          tool_results_carry_attachments? ? messages : ToolResultAttachments.relocate(messages),
          tools: tools,
          tool_prefs: tool_prefs,
          temperature: normalized_temperature,
          model: model,
          stream: block_given?,
          schema: schema,
          thinking: thinking
        ),
        params
      )
      payload = finalize_payload(payload)

      if block_given?
        stream_response @connection, payload, headers, &
      else
        sync_response @connection, payload, headers
      end
    end

    # The last word on the payload, after the caller's params are merged into it:
    # a provider drops what a param makes redundant (see
    # `Gemini::CachedContents#finalize_payload`).
    def finalize_payload(payload)
      payload
    end

    # Whether the API carries attachments inside a tool result. When it does
    # not, they reach the model in a message of their own, right after the tool
    # results (`ToolResultAttachments`), instead of being flattened into text.
    def tool_results_carry_attachments?
      false
    end

    def list_models
      response = @connection.get models_url
      parse_list_models_response response, slug, capabilities
    end

    def embed(text, model:, dimensions:, task: nil, title: nil)
      task = Embedding::Task.coerce(task, title:)
      ensure_embedding_task_supported!(task, model:)
      payload = render_embedding_payload(text, model:, dimensions:, task:, title:)
      response = @connection.post(embedding_url(model:), payload)
      parse_embedding_response(response, model:, text:)
    end

    def moderate(input, model:)
      payload = render_moderation_payload(input, model:)
      response = @connection.post moderation_url, payload
      parse_moderation_response(response, model:)
    end

    def paint(prompt, model:, size:, with: nil, mask: nil, params: {}) # rubocop:disable Metrics/ParameterLists
      validate_paint_inputs!(with:, mask:)
      payload = render_image_payload(prompt, model:, size:, with:, mask:, params:)
      response = @connection.post images_url(with:, mask:), payload
      parse_image_response(response, model:)
    end

    def transcribe(audio_file, model:, language:, **options)
      file_part = build_audio_file_part(audio_file)
      payload = render_transcription_payload(file_part, model:, language:, **options)
      response = @connection.post transcription_url, payload
      parse_transcription_response(response, model:)
    end

    def configured?
      configuration_requirements.all? { |req| @config.send(req) }
    end

    def local?
      self.class.local?
    end

    def remote?
      self.class.remote?
    end

    def assume_models_exist?
      self.class.assume_models_exist?
    end

    def parse_error(response)
      return if response.body.empty?

      body = try_parse_json(response.body)
      case body
      when Hash
        error = body['error']
        return error if error.is_a?(String)

        body.dig('error', 'message')
      when Array
        body.map do |part|
          error = part['error']
          error.is_a?(String) ? error : part.dig('error', 'message')
        end.join('. ')
      else
        body
      end
    end

    def format_messages(messages)
      messages.map do |msg|
        {
          role: msg.role.to_s,
          content: msg.content
        }
      end
    end

    def format_tool_calls(_tool_calls)
      nil
    end

    def parse_tool_calls(_tool_calls)
      nil
    end

    class << self
      def name
        to_s.split('::').last
      end

      def slug
        name.downcase
      end

      def capabilities
        nil
      end

      # Vector width of an embedding model, as the provider documents it.
      #
      # Answered by the provider's own capabilities rather than by reading a
      # token limit, so a registry entry can carry the real dimension even
      # when models.dev has none to give.
      def embedding_dimensions_for(model_id)
        return nil unless capabilities.respond_to?(:embedding_dimensions_for)

        capabilities.embedding_dimensions_for(model_id)
      end

      # Embedding task types a model accepts, as RubyLLM task names.
      #
      # Asked of the provider's own capabilities, the same way vector widths
      # are. A provider whose API has no task parameter has nothing to say and
      # so accepts none - which is a fact about that API, not a gap in this
      # list.
      def embedding_tasks_for(model_id)
        return [] unless capabilities.respond_to?(:embedding_tasks_for)

        Array(capabilities.embedding_tasks_for(model_id))
      end

      def configuration_requirements
        []
      end

      def configuration_options
        []
      end

      def local?
        false
      end

      def remote?
        !local?
      end

      def assume_models_exist?
        false
      end

      def configured?(config)
        configuration_requirements.all? { |req| config.send(req) }
      end

      def register(name, provider_class)
        providers[name.to_sym] = provider_class
        RubyLLM::Configuration.register_provider_options(provider_class.configuration_options)
      end

      def resolve(name)
        providers[name.to_sym]
      end

      def for(model)
        model_info = Models.find(model)
        resolve model_info.provider
      end

      def providers
        @providers ||= {}
      end

      def local_providers
        providers.select { |_slug, provider_class| provider_class.local? }
      end

      def remote_providers
        providers.select { |_slug, provider_class| provider_class.remote? }
      end

      def configured_providers(config)
        providers.select do |_slug, provider_class|
          provider_class.configured?(config)
        end.values
      end

      def configured_remote_providers(config)
        providers.select do |_slug, provider_class|
          provider_class.remote? && provider_class.configured?(config)
        end.values
      end
    end

    private

    def validate_paint_inputs!(with:, mask:)
      return if with.nil? && mask.nil?

      raise UnsupportedAttachmentError, 'image reference'
    end

    # A task RubyLLM understands but this model cannot be asked for is an
    # error, not a parameter to drop: the caller would otherwise store
    # general-purpose vectors believing they were tuned for retrieval.
    def ensure_embedding_task_supported!(task, model:)
      return if task.nil?

      supported = self.class.embedding_tasks_for(model)
      return if supported.include?(task.to_sym)

      hint = if supported.empty?
               'This model takes no task types; omit task: and title:.'
             else
               "Tasks it accepts: #{supported.join(', ')}."
             end

      raise UnsupportedEmbeddingTaskError, "#{slug}/#{model} cannot embed for the #{task} task. #{hint}"
    end

    def build_audio_file_part(file_path)
      require 'faraday/multipart'
      require 'marcel'
      require 'pathname'

      expanded_path = File.expand_path(file_path)
      mime_type = Marcel::MimeType.for(Pathname.new(expanded_path))

      Faraday::Multipart::FilePart.new(
        expanded_path,
        mime_type,
        File.basename(expanded_path)
      )
    end

    def try_parse_json(maybe_json)
      return maybe_json unless maybe_json.is_a?(String)

      JSON.parse(maybe_json)
    rescue JSON::ParserError
      maybe_json
    end

    def ensure_configured!
      missing = configuration_requirements.reject { |req| @config.send(req) }
      return if missing.empty?

      raise ConfigurationError,
            "Missing configuration for #{name}: #{missing.join(', ')}. " \
            'Set these keys on RubyLLM.config before using this provider.'
    end

    def maybe_normalize_temperature(temperature, _model)
      temperature
    end

    def sync_response(connection, payload, additional_headers = {})
      response = connection.post completion_url, payload do |req|
        req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
      end
      parse_completion_response response
    end
  end
end

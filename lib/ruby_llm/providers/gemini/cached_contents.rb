# frozen_string_literal: true

module RubyLLM
  module Providers
    class Gemini
      # Explicit context caching (`cachedContents`): the system instruction and
      # the tools stored at Gemini once, and referenced by name in the requests
      # that follow. Implicit caching is best effort; an explicit cache is read
      # on every request that names it, for as long as it lives.
      #
      # A request that references a cache cannot carry those fields again --
      # Gemini answers 400 -- so they leave the payload whenever `cachedContent`
      # is present (`finalize_payload`). Pass the cache name through
      # `Chat#with_params(cachedContent: name)`.
      module CachedContents
        CACHED_FIELDS = %i[systemInstruction tools toolConfig].freeze

        CachedContent = Struct.new(:name, :expires_at, :tokens, keyword_init: true)

        # What a cache holds for these messages and tools: the same system
        # instruction, tool declarations and calling mode a request would carry
        # -- the request that names the cache can carry none of them. Callers can
        # key their caches on it, so a changed prompt or tool means another cache.
        def cached_content_payload(messages, tools:, model:)
          payload = { model: "models/#{model.id}" }
          system_instruction = format_system_instruction(messages)
          payload[:systemInstruction] = system_instruction if system_instruction
          add_cached_tools(payload, tools) if tools.any?
          payload
        end

        def add_cached_tools(payload, tools)
          payload[:tools] = format_tools(tools)
          tool_config = tool_config(tools, nil)
          payload[:toolConfig] = tool_config if tool_config
        end

        # Stores the payload at Gemini for `ttl` seconds. The expiry is fixed:
        # using the cache does not extend it.
        def create_cached_content(payload, ttl:)
          body = @connection.post('cachedContents', payload.merge(ttl: "#{Integer(ttl)}s")).body

          CachedContent.new(
            name: body['name'],
            expires_at: body['expireTime'] && Time.parse(body['expireTime']),
            tokens: body.dig('usageMetadata', 'totalTokenCount')
          )
        end

        def finalize_payload(payload)
          return payload unless payload[:cachedContent]

          payload.except(*CACHED_FIELDS)
        end
      end
    end
  end
end

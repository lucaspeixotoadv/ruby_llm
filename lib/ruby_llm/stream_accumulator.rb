# frozen_string_literal: true

require 'json'
require 'securerandom'

module RubyLLM
  # Assembles streaming responses from LLMs into complete messages.
  class StreamAccumulator
    attr_reader :content, :model_id, :tool_calls

    def initialize
      @content = +''
      @thinking_text = +''
      @thinking_signature = nil
      @tool_calls = {}
      @input_tokens = nil
      @output_tokens = nil
      @cached_tokens = nil
      @cache_creation_tokens = nil
      @cache_creation_1h_tokens = nil
      @thinking_tokens = nil
      @latest_tool_call_id = nil
      @tool_call_ids_by_index = {}
    end

    def add(chunk)
      RubyLLM.logger.debug { chunk.inspect } if RubyLLM.config.log_stream_debug
      @model_id ||= chunk.model_id

      handle_chunk_content(chunk)
      append_thinking_from_chunk(chunk)
      count_tokens chunk
      RubyLLM.logger.debug { inspect } if RubyLLM.config.log_stream_debug
    end

    def to_message(response)
      Message.new(
        role: :assistant,
        content: content.empty? ? nil : content,
        thinking: Thinking.build(
          text: @thinking_text.empty? ? nil : @thinking_text,
          signature: @thinking_signature
        ),
        tokens: Tokens.build(
          input: @input_tokens,
          output: @output_tokens,
          cached: @cached_tokens,
          cache_creation: @cache_creation_tokens,
          cache_creation_1h: @cache_creation_1h_tokens,
          thinking: @thinking_tokens
        ),
        model_id: model_id,
        tool_calls: tool_calls_from_stream,
        raw: response
      )
    end

    private

    def tool_calls_from_stream
      tool_calls.transform_values do |tc|
        arguments = if tc.arguments.is_a?(String) && !tc.arguments.empty?
                      JSON.parse(tc.arguments)
                    elsif tc.arguments.is_a?(String)
                      {}
                    else
                      tc.arguments
                    end

        ToolCall.new(
          id: tc.id,
          name: tc.name,
          arguments: arguments,
          thought_signature: tc.thought_signature
        )
      end
    end

    def accumulate_tool_calls(new_tool_calls)
      RubyLLM.logger.debug { "Accumulating tool calls: #{new_tool_calls}" } if RubyLLM.config.log_stream_debug
      new_tool_calls.each do |stream_key, tool_call|
        if tool_call.id
          start_tool_call(stream_key, tool_call)
        else
          append_tool_call_fragment(stream_key, tool_call)
        end
      end
    end

    def start_tool_call(stream_key, tool_call)
      tool_call_id = tool_call.id.empty? ? SecureRandom.uuid : tool_call.id
      tool_call_key = tool_call.id

      @tool_calls[tool_call_key] = ToolCall.new(
        id: tool_call_id,
        name: tool_call.name,
        arguments: initial_tool_call_arguments(tool_call),
        thought_signature: tool_call.thought_signature
      )
      @tool_call_ids_by_index[stream_key] = tool_call_key unless stream_key.nil?
      @latest_tool_call_id = tool_call_key
    end

    def initial_tool_call_arguments(tool_call)
      arguments = tool_call.arguments
      return +'' if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)

      arguments
    end

    def append_tool_call_fragment(stream_key, tool_call)
      existing = find_tool_call(stream_key)
      return unless existing

      fragment = tool_call.arguments
      fragment = '' if fragment.nil?
      existing.arguments << fragment
      return unless tool_call.thought_signature && existing.thought_signature.nil?

      existing.thought_signature = tool_call.thought_signature
    end

    def find_tool_call(stream_key)
      return @tool_calls[@latest_tool_call_id] if stream_key.nil?

      @tool_calls[@tool_call_ids_by_index[stream_key]] || @tool_calls[stream_key]
    end

    def count_tokens(chunk)
      @input_tokens = chunk.input_tokens if chunk.input_tokens
      @output_tokens = chunk.output_tokens if chunk.output_tokens
      @cached_tokens = chunk.cached_tokens if chunk.cached_tokens
      @cache_creation_tokens = chunk.cache_creation_tokens if chunk.cache_creation_tokens
      @cache_creation_1h_tokens = chunk.cache_creation_1h_tokens if chunk.cache_creation_1h_tokens
      @thinking_tokens = chunk.thinking_tokens if chunk.thinking_tokens
    end

    def handle_chunk_content(chunk)
      return accumulate_tool_calls(chunk.tool_calls) if chunk.tool_call?

      content_text = chunk.content || ''
      @content << (content_text.is_a?(String) ? content_text : content_text.to_s)
    end

    def append_thinking_from_chunk(chunk)
      thinking = chunk.thinking
      return unless thinking

      @thinking_text << thinking.text.to_s if thinking.text
      @thinking_signature ||= thinking.signature # rubocop:disable Naming/MemoizedInstanceVariableName
    end
  end
end

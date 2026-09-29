# frozen_string_literal: true

module RubyLLM
  # Attachments a tool returned, for APIs whose tool results carry text only.
  #
  # A tool may answer with a Content that has attachments: an image it fetched,
  # a PDF it read. Anthropic and Bedrock carry them inside the tool result, and
  # Gemini 3 does too. OpenAI Chat Completions does not -- a `tool` message takes
  # text parts only. There the attachments move to one `user` message placed
  # right after the tool results of that turn, and each tool result keeps its
  # text and says the files follow. The model reads every file through the
  # channel that carries files, and never as base64 inside text.
  #
  # The chat history is not touched: this runs on the list being rendered, so
  # the tool message keeps the Content the tool returned.
  module ToolResultAttachments
    NOTE = 'The attachments returned by this call follow in the next message.'

    module_function

    def attachments?(message)
      message.role == :tool && message.content.is_a?(Content) && message.content.attachments.any?
    end

    # @param messages [Array<Message>]
    # @return [Array<Message>] the same list when no tool result has attachments
    def relocate(messages)
      return messages if messages.none? { |message| attachments?(message) }

      pending = []
      relocated = messages.each_with_object([]) do |message, result|
        flush(result, pending) unless message.role == :tool
        next result << message unless attachments?(message)

        pending << message
        result << text_only(message)
      end
      flush(relocated, pending)
    end

    def text_only(message)
      text = message.content.text.to_s
      Message.new(role: :tool, tool_call_id: message.tool_call_id,
                  content: text.empty? ? NOTE : "#{text}\n\n#{NOTE}")
    end

    # The files of a whole run of tool results go together, after the last of
    # them: the API wants every tool result right after the call that asked for
    # it, with nothing in between.
    def flush(result, pending)
      return result if pending.empty?

      attachments = pending.flat_map { |message| message.content.attachments }
      result << Message.new(role: :user, content: Content.new(label(pending), attachments))
      pending.clear
      result
    end

    def label(pending)
      calls = pending.map { |message| "#{message.tool_call_id} (#{message.content.attachments.size})" }
      "Attachments returned by the tool calls above, in order: #{calls.join(', ')}."
    end
  end
end

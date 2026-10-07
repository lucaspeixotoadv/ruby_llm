# frozen_string_literal: true

module RubyLLM
  # Represents provider thinking output.
  #
  # `blocks` is the assistant turn exactly as the provider returned it, kept for
  # providers that bind their reasoning to its place in the turn. Anthropic
  # does: a turn can carry several thinking blocks, each with its own
  # signature, between its text and tool calls, and the API refuses a turn
  # whose thinking comes back edited, merged or partially dropped. `text` and
  # `signature` stay the readable summary of the same reasoning.
  class Thinking
    attr_reader :text, :signature, :blocks

    def initialize(text: nil, signature: nil, blocks: nil)
      @text = text
      @signature = signature
      @blocks = blocks
    end

    def self.build(text: nil, signature: nil, blocks: nil)
      text = nil if text.is_a?(String) && text.empty?
      signature = nil if signature.is_a?(String) && signature.empty?

      return nil if text.nil? && signature.nil? && blocks.nil?

      new(text: text, signature: signature, blocks: blocks)
    end

    def pretty_print(printer)
      printer.object_group(self) do
        printer.breakable
        printer.text 'text='
        printer.pp text
        printer.comma_breakable
        printer.text 'signature='
        printer.pp(signature ? '[REDACTED]' : nil)
      end
    end
  end

  class Thinking
    # Normalized config for thinking across providers.
    class Config
      attr_reader :effort, :budget

      def initialize(effort: nil, budget: nil)
        @effort = effort.is_a?(Symbol) ? effort.to_s : effort
        @budget = budget
      end

      def enabled?
        !effort.nil? || !budget.nil?
      end
    end
  end
end
